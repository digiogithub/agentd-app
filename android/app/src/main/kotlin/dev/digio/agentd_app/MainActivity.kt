package dev.digio.agentd_app

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.car.app.connection.CarConnection
import androidx.lifecycle.Observer
import dev.digio.agentd_app.car.CarEngine
import dev.digio.agentd_app.car.CarNotifications
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
    private var car: CarConnection? = null

    /** Android Auto connected while the app runs: start the car engine (its notifications). */
    private val carObserver = Observer<Int> { type ->
        if (type == CarConnection.CONNECTION_TYPE_PROJECTION || type == CarConnection.CONNECTION_TYPE_NATIVE) {
            CarEngine.ensure(applicationContext)
        }
    }

    companion object {
        /** Event notifications (sound + vibration); replaces `agentd_events`, created without vibration. */
        const val EVENTS = "agentd_events_alert"
        private const val LEGACY_EVENTS = "agentd_events"
        const val EXTRA_SESSION = "agentd_session"

        /** True while the app is on screen: FCM does not show pushes then. */
        @Volatile
        var visible = false
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        createAttentionChannel()
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
                "appVersion" -> {
                    // versionName only: split APKs add 1000 * ABI to the code.
                    result.success(packageManager.getPackageInfo(packageName, 0).versionName ?: "")
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
        car = CarConnection(this).also { it.type.observeForever(carObserver) }
        ConnectionService.onDisconnect = { runOnUiThread { channel?.invokeMethod("disconnect", null) } }
        intent?.getStringExtra(EXTRA_SESSION)?.let { s -> ch.invokeMethod("open", s) }
    }

    override fun onResume() {
        super.onResume()
        visible = true
    }

    override fun onPause() {
        visible = false
        super.onPause()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.getStringExtra(EXTRA_SESSION)?.let { s -> channel?.invokeMethod("open", s) }
    }

    override fun onDestroy() {
        // The engine (and every SSH connection) goes with the activity: the
        // connection notification would lie.
        ConnectionService.onDisconnect = null
        car?.type?.removeObserver(carObserver)
        car = null
        if (isFinishing) stopService(Intent(this, ConnectionService::class.java))
        super.onDestroy()
    }

    /** The channel of the daemons' pushes; it must exist before one arrives. */
    private fun createAttentionChannel() = CarNotifications.ensureChannel(this)

    private fun requestNotifications(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return true
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7501)
        return false
    }

    private fun notifyEvent(id: Int, title: String, text: String, session: String?) {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && nm.getNotificationChannel(EVENTS) == null) {
            if (nm.getNotificationChannel(LEGACY_EVENTS) != null) nm.deleteNotificationChannel(LEGACY_EVENTS)
            val ch = NotificationChannel(EVENTS, "Avisos de los agentes", NotificationManager.IMPORTANCE_HIGH)
            ch.description = "Un agente espera respuesta, termina un turno o se cierra: suena y vibra"
            ch.enableVibration(true)
            ch.vibrationPattern = longArrayOf(0, 180, 120, 180)
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
            .apply {
                @Suppress("DEPRECATION")
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) setDefaults(Notification.DEFAULT_SOUND or Notification.DEFAULT_VIBRATE)
            }
            .build()
        nm.notify(id, n)
    }
}
