package dev.digio.agentd_app.car

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.car.app.connection.CarConnection
import androidx.lifecycle.Observer

/**
 * Sees every FCM message next to firebase_messaging's own receiver (same
 * `com.google.android.c2dm.intent.RECEIVE` broadcast, which it does not
 * consume). The daemons' pushes are notification messages that Android Auto
 * does not show (no reply action), so while the phone is in the car an
 * agentd push wakes the car engine: it reconnects and posts its messaging
 * notification for the question, which the car shows and reads aloud.
 * Nothing of the message is logged.
 */
class AgentdPushReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val extras = intent.extras ?: return
        if (extras.getString("v") != "1" || extras.getString("host_ref").isNullOrEmpty()) return
        val app = context.applicationContext
        val main = Handler(Looper.getMainLooper())
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
