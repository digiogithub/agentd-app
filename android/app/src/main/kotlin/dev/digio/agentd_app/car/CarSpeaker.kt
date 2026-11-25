package dev.digio.agentd_app.car

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import java.util.Locale

/**
 * Reads text aloud through the car (TextToSpeech, assistant usage, transient
 * focus that ducks the music). One utterance at a time: a new one replaces
 * the one playing.
 */
class CarSpeaker(ctx: Context) {
    private val audio = ctx.getSystemService(AudioManager::class.java)
    private val attrs = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ASSISTANT)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build()
    private val focus: AudioFocusRequest? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK).setAudioAttributes(attrs).build()
    } else null
    private var ready = false
    private var waiting: String? = null
    private var seq = 0
    private val tts: TextToSpeech = TextToSpeech(ctx.applicationContext) { status ->
        if (status == TextToSpeech.SUCCESS) onReady()
    }

    private fun onReady() {
        val es = Locale.forLanguageTag("es-ES")
        if (tts.isLanguageAvailable(es) >= TextToSpeech.LANG_AVAILABLE) tts.language = es
        tts.setAudioAttributes(attrs)
        tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {}
            override fun onDone(utteranceId: String?) = release()
            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String?) = release()
            override fun onError(utteranceId: String?, errorCode: Int) = release()
        })
        ready = true
        waiting?.let { say(it) }
        waiting = null
    }

    fun say(text: String) {
        if (text.isBlank()) return
        if (!ready) {
            waiting = text
            return
        }
        if (focus != null) audio.requestAudioFocus(focus)
        tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, "agentd-${++seq}")
    }

    fun stop() {
        tts.stop()
        release()
    }

    private fun release() {
        if (focus != null) audio.abandonAudioFocusRequest(focus)
    }

    fun shutdown() {
        stop()
        tts.shutdown()
    }
}
