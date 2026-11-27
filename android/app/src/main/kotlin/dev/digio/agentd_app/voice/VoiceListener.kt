package dev.digio.agentd_app.voice

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log

/**
 * Speech in of the voice mode: one SpeechRecognizer (the system's, Google on
 * Pixel) per listen, up to 5 alternatives, no partial results, a hard limit
 * of maxMs. The result is always a map for Dart: `{alts: [..]}` or
 * `{error: no_match|timeout|busy|audio|network|permission|other}`.
 * Never logs what was recognized. Main thread only.
 */
class VoiceListener(private val ctx: Context) {
    private val main = Handler(Looper.getMainLooper())
    private var recognizer: SpeechRecognizer? = null
    private var done: ((Map<String, Any>) -> Unit)? = null
    private var limit: Runnable? = null
    private var grace: Runnable? = null

    val listening get() = done != null

    fun hasPermission() = ctx.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    fun listen(maxMs: Int, lang: String?, onDone: (Map<String, Any>) -> Unit) {
        if (listening) return onDone(error("busy"))
        if (!hasPermission()) return onDone(error("permission"))
        if (!SpeechRecognizer.isRecognitionAvailable(ctx)) return onDone(error("other"))
        val r = try {
            SpeechRecognizer.createSpeechRecognizer(ctx)
        } catch (e: Exception) {
            Log.w(TAG, "recognizer: ${e.javaClass.simpleName}")
            return onDone(error("other"))
        }
        recognizer = r
        done = onDone
        val language = lang?.takeIf { it.isNotBlank() } ?: "es-ES"
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, language)
            .putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 5)
            .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, false)
            .putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 1500L)
            .putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 1500L)
            .putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, ctx.packageName)
        r.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onPartialResults(partialResults: Bundle?) {}
            override fun onEvent(eventType: Int, params: Bundle?) {}
            override fun onError(code: Int) {
                if (recognizer !== r) return
                Log.i(TAG, "recognizer error $code")
                finish(error(mapError(code)))
            }
            override fun onResults(results: Bundle?) {
                if (recognizer !== r) return
                val alts = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    ?.filter { it.isNotBlank() }.orEmpty()
                finish(if (alts.isEmpty()) error("no_match") else mapOf("alts" to alts))
            }
        })
        try {
            r.startListening(intent)
        } catch (e: Exception) {
            Log.w(TAG, "startListening: ${e.javaClass.simpleName}")
            return finish(error("other"))
        }
        val l = Runnable {
            limit = null
            // Time is up: ask for what was heard so far, then give up.
            try {
                recognizer?.stopListening()
            } catch (_: Exception) {
            }
            val g = Runnable {
                grace = null
                finish(error("timeout"))
            }
            grace = g
            main.postDelayed(g, GRACE_MS)
        }
        limit = l
        main.postDelayed(l, maxMs.toLong().coerceIn(1000L, 120_000L))
    }

    /** Ends a listen in progress: its callback gets `{error: other}` (nothing when [silent]). */
    fun cancel(silent: Boolean = false) {
        if (!listening) return
        if (silent) done = null
        finish(error("other"))
    }

    private fun finish(result: Map<String, Any>) {
        limit?.let { main.removeCallbacks(it) }
        grace?.let { main.removeCallbacks(it) }
        limit = null
        grace = null
        recognizer?.let {
            try {
                it.cancel()
                it.destroy()
            } catch (_: Exception) {
            }
        }
        recognizer = null
        val d = done
        done = null
        d?.invoke(result)
    }

    private fun error(code: String): Map<String, Any> = mapOf("error" to code)

    companion object {
        private const val TAG = "VoiceListener"
        private const val GRACE_MS = 2500L

        fun mapError(code: Int): String = when (code) {
            SpeechRecognizer.ERROR_NO_MATCH -> "no_match"
            SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "timeout"
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY, SpeechRecognizer.ERROR_TOO_MANY_REQUESTS -> "busy"
            SpeechRecognizer.ERROR_AUDIO -> "audio"
            SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT,
            SpeechRecognizer.ERROR_SERVER, SpeechRecognizer.ERROR_SERVER_DISCONNECTED -> "network"
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "permission"
            else -> "other"
        }
    }
}
