package dev.digio.agentd_app.car

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.core.app.RemoteInput

/**
 * Reply and Mark as read of the car notifications (Android Auto, Google
 * Assistant, or the phone's shade). A reply goes to the car engine's
 * `reply` (answers the open question, picks the menu option it names, or
 * becomes an instruction); the notification then shows what happened.
 */
class CarReplyReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val tag = intent.getStringExtra(CarNotifications.EXTRA_TAG) ?: return
        val key = intent.getStringExtra(CarNotifications.EXTRA_KEY) ?: return
        val session = intent.getStringExtra(CarNotifications.EXTRA_SESSION) ?: key
        val app = context.applicationContext
        when (intent.action) {
            CarNotifications.ACTION_READ -> CarNotifications.cancel(app, tag)
            CarNotifications.ACTION_REPLY -> {
                val text = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(CarNotifications.KEY_REPLY)?.toString()?.trim()
                if (text.isNullOrEmpty()) return
                val pending = goAsync()
                val main = Handler(Looper.getMainLooper())
                var finished = false
                val finish = {
                    if (!finished) {
                        finished = true
                        pending.finish()
                    }
                }
                // A cold engine connects to the host first; the call goes on
                // after the receiver's window if it must.
                main.postDelayed(finish, 9000)
                main.post {
                    CarEngine.ensure(app)
                    CarEngine.call(
                        "reply", mapOf("key" to key, "text" to text),
                        onResult = { r ->
                            CarNotifications.update(app, tag, key, session, text, r as? String ?: "Enviado")
                            finish()
                        },
                        onError = { e ->
                            CarNotifications.update(app, tag, key, session, text, "No se pudo: $e")
                            finish()
                        },
                    )
                }
            }
        }
    }
}
