package dev.digio.agentd_app.voice

import android.content.Context
import dev.digio.agentd_app.car.CarEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Channel `agentd/voice` on the car engine's messenger: the native half of
 * the voice mode. Kotlin only plays, listens and forwards; the Dart voice
 * controller decides everything.
 *
 * Dart -> Android:
 *  - say {text, lang?} -> null when playback ends or is stopped; error 'tts'.
 *  - listen {maxMs, lang?, headsetMic?} -> {alts: [..]} or {error: code}.
 *  - earcon {kind: listenStart|listenEnd|ok|error} -> null once played.
 *  - stopSpeaking -> null.
 *  - exit -> null: stops VoiceService.
 *  - state {text} -> null: the voice notification's text.
 * Android -> Dart: button {key: playPause|next|previous},
 * started {source: launcher|app|notification}, stopped {}, route {bt}.
 * Main thread only.
 */
class VoiceChannel(
    ctx: Context,
    messenger: BinaryMessenger,
    private val onExit: () -> Unit,
    private val onState: (String) -> Unit,
) {
    private val audio = VoiceAudio(ctx)
    private val speaker = VoiceSpeaker(ctx, audio)
    private val listener = VoiceListener(ctx)
    private val earcons = VoiceEarcons(audio)
    private val channel = MethodChannel(messenger, NAME)
    private var open = true

    init {
        channel.setMethodCallHandler(::handle)
        audio.watchRoute { bt -> send("route", mapOf("bt" to bt)) }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "say" -> {
                val text = call.argument<String>("text") ?: ""
                speaker.say(text, call.argument<String>("lang")) { err ->
                    if (err == null) result.success(null) else result.error("tts", err, null)
                }
            }
            "listen" -> {
                if (listener.listening) return result.success(mapOf("error" to "busy"))
                val maxMs = call.argument<Int>("maxMs") ?: 8000
                val lang = call.argument<String>("lang")
                val headset = call.argument<Boolean>("headsetMic") ?: true
                // One sound at a time: the recognizer must not hear our speech.
                speaker.stop()
                earcons.stop()
                if (!listener.hasPermission()) return result.success(mapOf("error" to "permission"))
                audio.acquireListenFocus()
                var answered = false
                val reply = { r: Map<String, Any> ->
                    if (!answered) {
                        answered = true
                        audio.clearMic()
                        audio.releaseListenFocus()
                        result.success(r)
                    }
                }
                pendingListen = reply
                audio.routeMic(headset) {
                    listener.listen(maxMs, lang) { r ->
                        pendingListen = null
                        reply(r)
                    }
                }
            }
            "earcon" -> earcons.play(call.argument<String>("kind") ?: "") { result.success(null) }
            "stopSpeaking" -> {
                speaker.stop()
                earcons.stop()
                result.success(null)
            }
            "exit" -> {
                result.success(null)
                onExit()
            }
            "state" -> {
                onState(call.argument<String>("text") ?: "")
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** Answers a listen still waiting for the SCO route (on close). */
    private var pendingListen: ((Map<String, Any>) -> Unit)? = null

    fun bluetooth() = audio.bluetoothConnected()

    /** Calls Dart once its engine is ready (queued until then, like the car channel). */
    fun send(method: String, args: Any?) {
        CarEngine.whenReady { if (open) channel.invokeMethod(method, args) }
    }

    /** Stops every sound and listen, tells Dart `stopped`, detaches the handler. */
    fun close() {
        if (!open) return
        speaker.shutdown()
        earcons.stop()
        listener.cancel(silent = false)
        pendingListen?.invoke(mapOf("error" to "other"))
        pendingListen = null
        audio.shutdown()
        CarEngine.whenReady { channel.invokeMethod("stopped", emptyMap<String, Any>()) }
        open = false
        channel.setMethodCallHandler(null)
    }

    companion object {
        const val NAME = "agentd/voice"
    }
}
