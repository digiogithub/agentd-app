package dev.digio.agentd_app.voice

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.annotation.RequiresApi

/**
 * Audio plumbing of the voice mode: focus, the Bluetooth headset microphone
 * route (SCO) around each listen, and Bluetooth presence for `route` events.
 *
 * Every sound of the voice mode plays with [playAttrs] (USAGE_MEDIA +
 * CONTENT_TYPE_SPEECH) in this process: Android 8+ sends the headset media
 * buttons to the session of the app that last played audio, so speech and
 * earcons must be our own players, not the TTS engine's.
 * Main thread only.
 */
class VoiceAudio(ctx: Context) {
    private val audio = ctx.getSystemService(AudioManager::class.java)
    private val main = Handler(Looper.getMainLooper())

    val playAttrs: AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build()
    private val listenAttrs: AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ASSISTANT)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build()

    /** Speech and earcons: other audio ducks. */
    private val speakFocus: AudioFocusRequest? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
            .setAudioAttributes(playAttrs)
            .setOnAudioFocusChangeListener({}, main)
            .build()
    } else null

    /** Listening: other audio pauses, so the recognizer does not hear the music. */
    private val listenFocus: AudioFocusRequest? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
            .setAudioAttributes(listenAttrs)
            .setOnAudioFocusChangeListener({}, main)
            .build()
    } else null

    private var speakHolders = 0
    private var routed = false
    private var legacySco = false
    private var routeWait: Runnable? = null
    private var commListener: Any? = null
    private var gen = 0

    fun acquireSpeakFocus() {
        if (speakHolders++ == 0) {
            if (speakFocus != null) audio.requestAudioFocus(speakFocus)
            else @Suppress("DEPRECATION") audio.requestAudioFocus(null, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
        }
    }

    fun releaseSpeakFocus() {
        if (speakHolders == 0) return
        if (--speakHolders == 0) {
            if (speakFocus != null) audio.abandonAudioFocusRequest(speakFocus)
            else @Suppress("DEPRECATION") audio.abandonAudioFocus(null)
        }
    }

    fun acquireListenFocus() {
        if (listenFocus != null) audio.requestAudioFocus(listenFocus)
        else @Suppress("DEPRECATION") audio.requestAudioFocus(null, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
    }

    fun releaseListenFocus() {
        if (listenFocus != null) audio.abandonAudioFocusRequest(listenFocus)
        else @Suppress("DEPRECATION") audio.abandonAudioFocus(null)
    }

    /** True when a Bluetooth audio output (headphones, headset, hearing aid) is connected. */
    fun bluetoothConnected(): Boolean =
        audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any { isBluetooth(it.type) }

    private fun isBluetooth(type: Int): Boolean = when (type) {
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> true
        AudioDeviceInfo.TYPE_HEARING_AID -> true
        AudioDeviceInfo.TYPE_BLE_HEADSET, AudioDeviceInfo.TYPE_BLE_SPEAKER -> Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
        else -> false
    }

    private var deviceCallback: AudioDeviceCallback? = null

    /** Calls [onChange] with the Bluetooth presence whenever it changes. */
    fun watchRoute(onChange: (Boolean) -> Unit) {
        unwatchRoute()
        var last = bluetoothConnected()
        val cb = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) = check()
            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) = check()
            private fun check() {
                val now = bluetoothConnected()
                if (now != last) {
                    last = now
                    onChange(now)
                }
            }
        }
        deviceCallback = cb
        audio.registerAudioDeviceCallback(cb, main)
    }

    fun unwatchRoute() {
        deviceCallback?.let { audio.unregisterAudioDeviceCallback(it) }
        deviceCallback = null
    }

    /**
     * Routes capture to the Bluetooth headset microphone when [headset] and
     * one is available, then calls [then] (once the link is up, or after a
     * short wait). Without a headset the phone microphone is used.
     */
    fun routeMic(headset: Boolean, onRouted: () -> Unit) {
        clearMic()
        val mine = gen
        // A clearMic() in between (stop, exit) cancels the pending callback.
        val then = { if (gen == mine) onRouted() }
        if (!headset) return then()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) routeMicS(then) else routeMicLegacy(then)
    }

    @RequiresApi(Build.VERSION_CODES.S)
    private fun routeMicS(then: () -> Unit) {
        val dev = audio.availableCommunicationDevices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }
            ?: audio.availableCommunicationDevices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BLE_HEADSET }
            ?: return then()
        if (!audio.setCommunicationDevice(dev)) return then()
        routed = true
        if (audio.communicationDevice?.id == dev.id) {
            // Selected, but the SCO link may still be coming up.
            return wait(300, then)
        }
        var done = false
        val finish = {
            if (!done) {
                done = true
                (commListener as? AudioManager.OnCommunicationDeviceChangedListener)
                    ?.let { audio.removeOnCommunicationDeviceChangedListener(it) }
                commListener = null
                routeWait?.let { main.removeCallbacks(it) }
                routeWait = null
                then()
            }
        }
        val l = AudioManager.OnCommunicationDeviceChangedListener { d ->
            if (d?.id == dev.id) main.postDelayed({ finish() }, 150)
        }
        commListener = l
        audio.addOnCommunicationDeviceChangedListener({ main.post(it) }, l)
        wait(1500) { finish() }
    }

    private fun routeMicLegacy(then: () -> Unit) {
        @Suppress("DEPRECATION")
        if (!audio.isBluetoothScoAvailableOffCall || audio.getDevices(AudioManager.GET_DEVICES_INPUTS)
                .none { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }
        ) return then()
        try {
            @Suppress("DEPRECATION")
            audio.startBluetoothSco()
            @Suppress("DEPRECATION")
            audio.isBluetoothScoOn = true
            legacySco = true
            routed = true
        } catch (_: Exception) {
            return then()
        }
        wait(800, then)
    }

    private fun wait(ms: Long, then: () -> Unit) {
        val r = Runnable {
            routeWait = null
            then()
        }
        routeWait = r
        main.postDelayed(r, ms)
    }

    /** Back to the default route after a listen. */
    fun clearMic() {
        gen++
        routeWait?.let { main.removeCallbacks(it) }
        routeWait = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (commListener as? AudioManager.OnCommunicationDeviceChangedListener)
                ?.let { audio.removeOnCommunicationDeviceChangedListener(it) }
        }
        commListener = null
        if (!routed) return
        routed = false
        if (legacySco) {
            legacySco = false
            @Suppress("DEPRECATION")
            audio.isBluetoothScoOn = false
            @Suppress("DEPRECATION")
            audio.stopBluetoothSco()
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            audio.clearCommunicationDevice()
        }
    }

    fun shutdown() {
        clearMic()
        unwatchRoute()
        while (speakHolders > 0) releaseSpeakFocus()
        releaseListenFocus()
    }
}
