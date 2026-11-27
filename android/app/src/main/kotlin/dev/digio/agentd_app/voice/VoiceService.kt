package dev.digio.agentd_app.voice

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.IBinder
import android.util.Log
import android.view.KeyEvent
import dev.digio.agentd_app.MainActivity
import dev.digio.agentd_app.R
import dev.digio.agentd_app.car.CarEngine

/**
 * Foreground service of the hands-free voice mode (types microphone +
 * mediaPlayback). While it runs: the car engine is held (its Dart side runs
 * the voice controller), channel `agentd/voice` is attached (VoiceChannel),
 * a MediaSession is active so the headset buttons reach us, and an ongoing
 * notification offers Hablar (= playPause) and Salir.
 *
 * A microphone foreground service cannot start from the background: start it
 * only from the foreground (VoiceActivity, MainActivity) or its own
 * notification. Main thread only.
 */
class VoiceService : Service() {
    companion object {
        const val CHANNEL_ID = "agentd_voice"
        const val NOTIFICATION_ID = 7510
        const val EXTRA_SOURCE = "source"
        const val ACTION_START = "dev.digio.agentd.voice.START"
        const val ACTION_TALK = "dev.digio.agentd.voice.TALK"
        const val ACTION_EXIT = "dev.digio.agentd.voice.EXIT"
        private const val HOLD = "voice"
        private const val TAG = "VoiceService"

        /** True while the service runs. */
        @Volatile
        var running = false
            private set

        /** Answers of [start]. */
        const val START_OK = "ok"
        const val START_NO_BLUETOOTH = "no_bluetooth"
        const val START_REFUSED = "refused"

        /**
         * Starts the voice mode from the foreground. Only with Bluetooth audio
         * connected: without headphones there is no button to talk.
         */
        fun start(ctx: Context, source: String): String {
            if (!VoiceAudio(ctx).bluetoothConnected()) return START_NO_BLUETOOTH
            val i = Intent(ctx, VoiceService::class.java).setAction(ACTION_START).putExtra(EXTRA_SOURCE, source)
            return try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ctx.startForegroundService(i) else ctx.startService(i)
                START_OK
            } catch (e: Exception) {
                Log.w(TAG, "start refused: ${e.javaClass.simpleName}")
                START_REFUSED
            }
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, VoiceService::class.java))
        }
    }

    private var session: MediaSession? = null
    private var voice: VoiceChannel? = null
    private var text = "Pulsa el botón de los auriculares para hablar"

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_EXIT -> {
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_TALK -> {
                if (running) {
                    voice?.send("button", mapOf("key" to "playPause"))
                    return START_NOT_STICKY
                }
                if (!begin("notification")) return START_NOT_STICKY
            }
            else -> {
                val source = intent?.getStringExtra(EXTRA_SOURCE) ?: "app"
                if (running) {
                    // startForegroundService again: answer it with startForeground.
                    goForeground()
                    // Already on: Dart may greet again.
                    voice?.send("started", mapOf("source" to source))
                    return START_NOT_STICKY
                }
                if (!begin(source)) return START_NOT_STICKY
            }
        }
        return START_NOT_STICKY
    }

    private fun begin(source: String): Boolean {
        if (!goForeground()) {
            stopSelf()
            return false
        }
        running = true
        CarEngine.ensure(applicationContext)
        CarEngine.hold(HOLD)
        val messenger = CarEngine.messenger
        if (messenger == null) {
            stopSelf()
            return false
        }
        val v = VoiceChannel(applicationContext, messenger, onExit = { stopSelf() }, onState = ::updateText)
        voice = v
        startSession()
        v.send("started", mapOf("source" to source))
        v.send("route", mapOf("bt" to v.bluetooth()))
        return true
    }

    /** startForeground with microphone only when RECORD_AUDIO is granted (Android 14 demands it). */
    private fun goForeground(): Boolean {
        ensureChannel()
        val n = build()
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                var types = ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                    types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                }
                startForeground(NOTIFICATION_ID, n, types)
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
            } else {
                startForeground(NOTIFICATION_ID, n)
            }
            true
        } catch (e: Exception) {
            // ForegroundServiceStartNotAllowedException / SecurityException: from the background.
            Log.w(TAG, "startForeground refused: ${e.javaClass.simpleName}")
            false
        }
    }

    private fun startSession() {
        val s = MediaSession(this, "agentd-voice")
        s.setCallback(object : MediaSession.Callback() {
            override fun onMediaButtonEvent(mediaButtonIntent: Intent): Boolean {
                val ev = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    mediaButtonIntent.getParcelableExtra(Intent.EXTRA_KEY_EVENT, KeyEvent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    mediaButtonIntent.getParcelableExtra(Intent.EXTRA_KEY_EVENT)
                } ?: return false
                if (ev.action != KeyEvent.ACTION_DOWN || ev.repeatCount > 0) return true
                val key = when (ev.keyCode) {
                    KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, KeyEvent.KEYCODE_MEDIA_PLAY,
                    KeyEvent.KEYCODE_MEDIA_PAUSE, KeyEvent.KEYCODE_HEADSETHOOK -> "playPause"
                    KeyEvent.KEYCODE_MEDIA_NEXT -> "next"
                    KeyEvent.KEYCODE_MEDIA_PREVIOUS -> "previous"
                    else -> return false
                }
                button(key)
                return true
            }

            // Transport controls (watch, car, system UI) instead of key events.
            override fun onPlay() = button("playPause")
            override fun onPause() = button("playPause")
            override fun onSkipToNext() = button("next")
            override fun onSkipToPrevious() = button("previous")
        })
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            @Suppress("DEPRECATION")
            s.setFlags(MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS)
        }
        s.setMetadata(
            MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, "agentd · modo voz")
                .build(),
        )
        s.setPlaybackState(
            PlaybackState.Builder()
                .setActions(
                    PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY_PAUSE or
                        PlaybackState.ACTION_SKIP_TO_NEXT or PlaybackState.ACTION_SKIP_TO_PREVIOUS,
                )
                // Playing: the session that plays wins the media buttons.
                .setState(PlaybackState.STATE_PLAYING, PlaybackState.PLAYBACK_POSITION_UNKNOWN, 1f)
                .build(),
        )
        s.isActive = true
        session = s
    }

    private fun button(key: String) {
        voice?.send("button", mapOf("key" to key))
    }

    private fun updateText(t: String) {
        text = t.ifBlank { text }
        if (!running) return
        try {
            getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, build())
        } catch (_: SecurityException) {
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val ch = NotificationChannel(CHANNEL_ID, "Modo voz", NotificationManager.IMPORTANCE_LOW)
        ch.description = "Modo voz activo: usa agentd con los auriculares"
        ch.setShowBadge(false)
        ch.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        nm.createNotificationChannel(ch)
    }

    private fun build(): Notification {
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val talk = PendingIntent.getService(
            this, 1,
            Intent(this, VoiceService::class.java).setAction(ACTION_TALK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val exit = PendingIntent.getService(
            this, 2,
            Intent(this, VoiceService::class.java).setAction(ACTION_EXIT),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, CHANNEL_ID)
        else @Suppress("DEPRECATION") Notification.Builder(this)
        return b.setSmallIcon(R.drawable.ic_stat_agentd)
            .setContentTitle("agentd · modo voz")
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setShowWhen(false)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setCategory(Notification.CATEGORY_SERVICE)
            .addAction(Notification.Action.Builder(null, "Hablar", talk).build())
            .addAction(Notification.Action.Builder(null, "Salir", exit).build())
            .apply {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
                }
            }
            .build()
    }

    override fun onDestroy() {
        val wasRunning = running
        running = false
        voice?.close()
        voice = null
        session?.let {
            it.isActive = false
            it.release()
        }
        session = null
        if (wasRunning) CarEngine.release(HOLD)
        super.onDestroy()
    }
}
