package dev.digio.agentd_app.car

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.car.app.connection.CarConnection
import androidx.lifecycle.Observer
import dev.digio.agentd_app.MainActivity

/**
 * Sees every FCM message next to firebase_messaging's own receiver (same
 * `com.google.android.c2dm.intent.RECEIVE` broadcast, which it does not
 * consume). Nothing of the message is logged.
 *
 * - Data-only agentd pushes (daemon in Android data mode, agentd
 *   `[push] android_mode = "data"` or the app's `push_register {mode: data}`):
 *   drawn here as a messaging notification with Reply / Mark as read
 *   (Android Auto shows it, Assistant reads and answers it); a `resolved`
 *   push cancels it. With the car engine running, the engine draws instead.
 * - Notification pushes (older daemons): Android draws them in the
 *   background (Android Auto ignores them); with the app on screen FCM shows
 *   nothing, so they are drawn here too (sound and vibration).
 * In both cases, while the phone is in the car, the push wakes the car
 * engine, which reconnects and posts its own notification for the item.
 */
class AgentdPushReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val extras = intent.extras ?: return
        if (extras.getString("v") != "1" || extras.getString("host_ref").isNullOrEmpty()) return
        val app = context.applicationContext
        // The channel FCM falls back to must exist even if the app was not
        // opened since the update (closed app: FCM draws the push).
        CarNotifications.ensureChannel(app)
        val main = Handler(Looper.getMainLooper())
        val hostRef = extras.getString("host_ref")!!
        val session = extras.getString("session") ?: return
        val key = "$hostRef/agentd/$session"
        val reason = extras.getString("reason") ?: ""
        val system = extras.keySet().any { it.startsWith("gcm.notification.") || it.startsWith("gcm.n.") }
        if (reason == "resolved") {
            main.post {
                CarNotifications.cancelPush(app, key, extras.getString("resolves"))
                if (CarEngine.running) CarEngine.call("refresh", null)
            }
            return
        }
        // Data pushes are drawn here; notification pushes too while the app is
        // on screen (FCM shows nothing then, and the user wants the alert).
        if ((!system || MainActivity.visible) && !CarEngine.running) {
            fun field(k: String) = extras.getString(k) ?: extras.getString("gcm.notification.$k") ?: extras.getString("gcm.n.$k") ?: ""
            val title = field("title")
            val body = field("body")
            main.post { CarNotifications.postPush(app, key, session, reason, title, body) }
        }
        if (CarEngine.running) {
            main.post { CarEngine.call("refresh", null) }
            return
        }
        val pending = goAsync()
        main.post {
            val live = CarConnection(app).type
            var done = false
            lateinit var observer: Observer<Int>
            val finish = {
                if (!done) {
                    done = true
                    live.removeObserver(observer)
                    pending.finish()
                }
            }
            observer = Observer { type ->
                if (type == CarConnection.CONNECTION_TYPE_PROJECTION || type == CarConnection.CONNECTION_TYPE_NATIVE) {
                    CarEngine.ensure(app)
                }
                finish()
            }
            live.observeForever(observer)
            main.postDelayed(finish, 3000)
        }
    }
}
