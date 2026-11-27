package dev.digio.agentd_app.voice

import android.content.Context
import android.media.MediaPlayer
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import java.io.File
import java.util.Locale

/**
 * Speech out of the voice mode: Google TTS synthesizes into a file in
 * cacheDir and our own MediaPlayer plays it (see VoiceAudio: we must be the
 * app that played audio for the media buttons to reach us). One utterance
 * at a time: a new one, or [stop], ends the current one (its callback gets
 * null, as if it had finished). Long texts are split at sentence breaks and
 * played one piece after another. Never logs the text.
 * Main thread only.
 */
class VoiceSpeaker(ctx: Context, private val audio: VoiceAudio) {
    private val main = Handler(Looper.getMainLooper())
    private val dir = File(ctx.cacheDir, "voice").apply {
        mkdirs()
        listFiles()?.forEach { it.delete() }
    }
    private var ready = false
    private var failed = false
    private var pending: (() -> Unit)? = null
    private var pendingDone: ((String?) -> Unit)? = null
    private var seq = 0
    private var current: Utterance? = null
    private var player: MediaPlayer? = null

    private class Utterance(
        val id: Int,
        val chunks: List<String>,
        val locale: Locale,
        val done: (String?) -> Unit,
    ) {
        var index = 0
        var file: File? = null
    }

    private val tts: TextToSpeech = TextToSpeech(ctx.applicationContext, { status ->
        main.post {
            if (status == TextToSpeech.SUCCESS) {
                ready = true
                tts.setOnUtteranceProgressListener(progress)
            } else {
                failed = true
                Log.w(TAG, "TTS init failed: $status")
            }
            val p = pending
            pending = null
            pendingDone = null
            p?.invoke()
        }
    }, GOOGLE_TTS)

    private val progress = object : UtteranceProgressListener() {
        override fun onStart(utteranceId: String?) {}
        override fun onDone(utteranceId: String?) {
            main.post { synthesized(utteranceId) }
        }
        @Deprecated("Deprecated in Java")
        override fun onError(utteranceId: String?) {
            main.post { synthFailed(utteranceId, -1) }
        }
        override fun onError(utteranceId: String?, errorCode: Int) {
            main.post { synthFailed(utteranceId, errorCode) }
        }
    }

    val speaking get() = current != null

    /** Speaks [text]; [done] gets null when it ends or is stopped, an error message on failure. */
    fun say(text: String, lang: String?, done: (String?) -> Unit) {
        stop()
        if (text.isBlank()) return done(null)
        val run = run@{
            if (failed) return@run done("TTS no disponible")
            val locale = Locale.forLanguageTag(lang?.takeIf { it.isNotBlank() } ?: "es-ES")
            val max = (TextToSpeech.getMaxSpeechInputLength() - 1).coerceAtLeast(200)
            val u = Utterance(++seq, split(text, max), locale, done)
            current = u
            audio.acquireSpeakFocus()
            synthesizeNext(u)
        }
        if (ready || failed) run() else {
            pending = run
            pendingDone = done
        }
    }

    private fun synthesizeNext(u: Utterance) {
        if (current !== u) return
        val locale = u.locale
        if (tts.language != locale) {
            if (tts.isLanguageAvailable(locale) >= TextToSpeech.LANG_AVAILABLE) tts.language = locale
        }
        val f = File(dir, "utt-${u.id}-${u.index}.wav")
        u.file = f
        val r = tts.synthesizeToFile(u.chunks[u.index], Bundle(), f, key(u))
        if (r != TextToSpeech.SUCCESS) finish(u, "No se pudo sintetizar")
    }

    private fun key(u: Utterance) = "agentd-voice-${u.id}-${u.index}"

    private fun synthesized(id: String?) {
        val u = current ?: return
        if (id != key(u)) return
        val f = u.file ?: return finish(u, "Sin audio")
        val mp = MediaPlayer()
        player = mp
        try {
            mp.setAudioAttributes(audio.playAttrs)
            mp.setDataSource(f.absolutePath)
            mp.setOnCompletionListener { played(u, mp) }
            mp.setOnErrorListener { _, what, extra ->
                Log.w(TAG, "playback error $what/$extra")
                releasePlayer(mp)
                finish(u, "No se pudo reproducir")
                true
            }
            mp.prepare()
            mp.start()
        } catch (e: Exception) {
            Log.w(TAG, "playback failed: ${e.javaClass.simpleName}")
            releasePlayer(mp)
            finish(u, "No se pudo reproducir")
        }
    }

    private fun played(u: Utterance, mp: MediaPlayer) {
        releasePlayer(mp)
        u.file?.delete()
        u.file = null
        if (current !== u) return
        u.index++
        if (u.index < u.chunks.size) synthesizeNext(u) else finish(u, null)
    }

    private fun synthFailed(id: String?, code: Int) {
        val u = current ?: return
        if (id != key(u)) return
        Log.w(TAG, "synthesis error $code")
        finish(u, "No se pudo sintetizar")
    }

    private fun releasePlayer(mp: MediaPlayer) {
        try {
            mp.release()
        } catch (_: Exception) {
        }
        if (player === mp) player = null
    }

    private fun finish(u: Utterance, error: String?) {
        if (current !== u) return
        current = null
        player?.let {
            try {
                it.stop()
            } catch (_: Exception) {
            }
            releasePlayer(it)
        }
        u.file?.delete()
        u.file = null
        audio.releaseSpeakFocus()
        u.done(error)
    }

    /** Stops what is speaking (its callback gets null). */
    fun stop() {
        val waiting = pendingDone
        pending = null
        pendingDone = null
        waiting?.invoke(null)
        val u = current ?: return
        if (ready) tts.stop()
        finish(u, null)
    }

    fun shutdown() {
        stop()
        tts.shutdown()
        dir.listFiles()?.forEach { it.delete() }
    }

    companion object {
        private const val TAG = "VoiceSpeaker"
        private const val GOOGLE_TTS = "com.google.android.tts"

        /** Splits [text] into pieces of at most [max] chars, at sentence or word breaks. */
        fun split(text: String, max: Int): List<String> {
            val out = mutableListOf<String>()
            var rest = text.trim()
            while (rest.length > max) {
                val window = rest.substring(0, max)
                var cut = maxOf(window.lastIndexOf(". "), window.lastIndexOf("? "), window.lastIndexOf("! "), window.lastIndexOf('\n'))
                if (cut < max / 2) cut = window.lastIndexOf(' ')
                if (cut <= 0) cut = max - 1
                out.add(rest.substring(0, cut + 1).trim())
                rest = rest.substring(cut + 1).trim()
            }
            if (rest.isNotEmpty()) out.add(rest)
            return out
        }
    }
}
