package dev.digio.agentd_app.voice

import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import kotlin.math.PI
import kotlin.math.min
import kotlin.math.sin

/**
 * Short generated tones (listen start / end, ok, error), played with an
 * AudioTrack through the same audio path as the speech (VoiceAudio). A short
 * silence leads each one so a Bluetooth link waking up does not clip it.
 * Main thread only.
 */
class VoiceEarcons(private val audio: VoiceAudio) {
    private val main = Handler(Looper.getMainLooper())
    private var track: AudioTrack? = null
    private var end: Runnable? = null
    /** The pending caller of [play]: answered when the tone ends or is cut. */
    private var pending: (() -> Unit)? = null

    /** Plays [kind]; [done] runs when it has played (or at once for an unknown kind). */
    fun play(kind: String, done: () -> Unit) {
        val notes = NOTES[kind] ?: return done()
        stop()
        val pcm = render(notes)
        val t = try {
            AudioTrack.Builder()
                .setAudioAttributes(audio.playAttrs)
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(RATE)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build(),
                )
                .setTransferMode(AudioTrack.MODE_STATIC)
                .setBufferSizeInBytes(pcm.size * 2)
                .build()
        } catch (_: Exception) {
            return done()
        }
        track = t
        audio.acquireSpeakFocus()
        t.write(pcm, 0, pcm.size)
        t.play()
        pending = done
        val r = Runnable {
            end = null
            stop()
        }
        end = r
        main.postDelayed(r, pcm.size * 1000L / RATE + 60)
    }

    fun stop() {
        end?.let { main.removeCallbacks(it) }
        end = null
        // A cut tone still answers its caller (Dart awaits the earcon call).
        pending?.let { pending = null; it() }
        val t = track ?: return
        track = null
        try {
            t.stop()
        } catch (_: Exception) {
        }
        t.release()
        audio.releaseSpeakFocus()
    }

    private data class Note(val hz: Double, val ms: Int)

    private fun render(notes: List<Note>): ShortArray {
        val lead = RATE * LEAD_MS / 1000
        val total = lead + notes.sumOf { RATE * it.ms / 1000 }
        val out = ShortArray(total)
        var pos = lead
        for (n in notes) {
            val len = RATE * n.ms / 1000
            val fade = min(len / 4, RATE * 8 / 1000)
            for (i in 0 until len) {
                val env = when {
                    n.hz <= 0 -> 0.0
                    i < fade -> i.toDouble() / fade
                    i >= len - fade -> (len - i).toDouble() / fade
                    else -> 1.0
                }
                out[pos + i] = (sin(2 * PI * n.hz * i / RATE) * env * AMPLITUDE).toInt().toShort()
            }
            pos += len
        }
        return out
    }

    companion object {
        private const val RATE = 22050
        private const val LEAD_MS = 120
        private const val AMPLITUDE = 0.35 * Short.MAX_VALUE

        private val NOTES = mapOf(
            "listenStart" to listOf(Note(660.0, 70), Note(0.0, 20), Note(990.0, 90)),
            "listenEnd" to listOf(Note(990.0, 70), Note(0.0, 20), Note(660.0, 90)),
            "ok" to listOf(Note(880.0, 60), Note(0.0, 15), Note(1320.0, 110)),
            "error" to listOf(Note(330.0, 140), Note(0.0, 40), Note(247.0, 220)),
        )
    }
}
