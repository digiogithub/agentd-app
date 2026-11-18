package dev.digio.agentd_app

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Bridge `agentd/background` (BackgroundBridge in Dart):
 *  - startService(title, text) / stopService(): the ConnectionService
 *    foreground notification (starting it again updates the text);
 *  - notify(id, title, text, session): an event notification (agent
 *    waiting, turn done, session closed); tapping it opens the app;
 *  - requestPermission(): POST_NOTIFICATIONS (Android 13+), → bool.
 * Dart is called back with disconnect() (the notification's Desconectar)
 * and open(session) (an event notification was tapped).
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    companion object {
        const val EVENTS = "agentd_events"
        const val EXTRA_SESSION = "agentd_session"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "agentd/background")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> {
                    val i = Intent(this, ConnectionService::class.java)
                        .putExtra(ConnectionService.EXTRA_TITLE, call.argument<String>("title"))
                        .putExtra(ConnectionService.EXTRA_TEXT, call.argument<String>("text"))
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(i) else startService(i)
                        result.success(true)
                    } catch (e: Exception) {
                        // Android 12+ refuses to start one from the background.
                        result.success(false)
                    }
                }
                "stopService" -> {
                    stopService(Intent(this, ConnectionService::class.java))
                    result.success(null)
                }
                "notify" -> {
                    notifyEvent(
                        call.argument<Int>("id") ?: 0,
                        call.argument<String>("title") ?: "",
                        call.argument<String>("text") ?: "",
                        call.argument<String>("session"),
                    )
                    result.success(null)
                }
                "requestPermission" -> result.success(requestNotifications())
                else -> result.notImplemented()
            }
        }
        ConnectionService.onDisconnect = { runOnUiThread { channel?.invokeMethod("disconnect", null) } }
        intent?.getStringExtra(EXTRA_SESSION)?.let { s -> ch.invokeMethod("open", s) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.getStringExtra(EXTRA_SESSION)?.let { s -> channel?.invokeMethod("open", s) }
    }

    override fun onDestroy() {
        // The engine (and every SSH connection) goes with the activity: the
        // connection notification would lie.
        ConnectionService.onDisconnect = null
        if (isFinishing) stopService(Intent(this, ConnectionService::class.java))
        super.onDestroy()
    }

    private fun requestNotifications(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return true
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7501)
        return false
    }

    private fun notifyEvent(id: Int, title: String, text: String, session: String?) {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && nm.getNotificationChannel(EVENTS) == null) {
            val ch = NotificationChannel(EVENTS, "Avisos de los agentes", NotificationManager.IMPORTANCE_HIGH)
            ch.description = "Un agente espera respuesta, termina un turno o se cierra"
            nm.createNotificationChannel(ch)
        }
        val open = PendingIntent.getActivity(
            this, id,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra(EXTRA_SESSION, session),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, EVENTS)
        else @Suppress("DEPRECATION") Notification.Builder(this)
        val n = b.setSmallIcon(R.drawable.ic_stat_agentd)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setContentIntent(open)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .build()
        nm.notify(id, n)
    }
}
