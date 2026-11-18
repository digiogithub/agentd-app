package dev.digio.agentd_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Foreground service that keeps the app process (and the SSH connections the
 * Flutter side holds) alive while the app is in the background. It does no
 * work of its own: it shows the "Conectado a …" notification with a
 * Desconectar action and forwards that action to Dart (BackgroundBridge).
 */
class ConnectionService : Service() {
    companion object {
        const val CHANNEL = "agentd_connection"
        const val NOTIFICATION_ID = 1
        const val ACTION_UPDATE = "dev.digio.agentd.UPDATE"
        const val ACTION_DISCONNECT = "dev.digio.agentd.DISCONNECT"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"

        /** Set by MainActivity: forwards Desconectar to Dart. */
        @Volatile
        var onDisconnect: (() -> Unit)? = null

        fun ensureChannel(ctx: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = ctx.getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL) == null) {
                val ch = NotificationChannel(CHANNEL, "Conexión con los hosts", NotificationManager.IMPORTANCE_LOW)
                ch.description = "Mantiene la conexión SSH abierta en segundo plano"
                ch.setShowBadge(false)
                nm.createNotificationChannel(ch)
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_DISCONNECT) {
            val cb = onDisconnect
            if (cb != null) {
                cb()
            } else {
                // No Flutter engine left to disconnect: nothing is kept alive.
                stopForegroundCompat()
                stopSelf()
            }
            return START_NOT_STICKY
        }
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "agentd"
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: ""
        ensureChannel(this)
        val n = build(title, text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
        // Not restarted by the system: without the Flutter side there is no
        // connection to keep.
        return START_NOT_STICKY
    }

    private fun build(title: String, text: String): Notification {
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val disconnect = PendingIntent.getService(
            this, 1,
            Intent(this, ConnectionService::class.java).setAction(ACTION_DISCONNECT),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, CHANNEL)
        else @Suppress("DEPRECATION") Notification.Builder(this)
        return b.setSmallIcon(R.drawable.ic_stat_agentd)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
            .addAction(Notification.Action.Builder(null, "Desconectar", disconnect).build())
            .build()
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) stopForeground(STOP_FOREGROUND_REMOVE)
        else @Suppress("DEPRECATION") stopForeground(true)
    }
}
