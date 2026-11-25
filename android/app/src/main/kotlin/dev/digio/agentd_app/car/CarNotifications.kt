package dev.digio.agentd_app.car

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import androidx.core.app.RemoteInput
import dev.digio.agentd_app.MainActivity
import dev.digio.agentd_app.R

/**
 * Messaging notifications of the car engine: one per open question or
 * terminal menu, in the form Android Auto shows and Google Assistant reads
 * aloud (MessagingStyle + a Reply action with RemoteInput + Mark as read,
 * neither opening a UI). A dictated reply goes to CarReplyReceiver.
 */
object CarNotifications {
    const val CHANNEL = "agentd_attention"
    const val ID = 7502
    const val KEY_REPLY = "agentd_reply"
    const val EXTRA_TAG = "agentd_tag"
    const val EXTRA_KEY = "agentd_key"
    const val EXTRA_SESSION = "agentd_session_name"
    const val ACTION_REPLY = "dev.digio.agentd.car.REPLY"
    const val ACTION_READ = "dev.digio.agentd.car.READ"

    private val posted = linkedSetOf<String>()

    private fun me() = Person.Builder().setKey("me").setName("Tú").build()

    private fun agent(key: String, name: String) = Person.Builder().setKey(key).setName(name).setBot(true).build()

    fun ensureChannel(ctx: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = ctx.getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL) != null) return
        val ch = NotificationChannel(CHANNEL, "Decisiones pendientes", NotificationManager.IMPORTANCE_HIGH)
        ch.description = "Un agente te pregunta o pide permiso (notificaciones push de los hosts)"
        nm.createNotificationChannel(ch)
    }

    fun post(ctx: Context, m: Map<String, Any?>) {
        val tag = m["tag"] as? String ?: return
        val key = m["sessionKey"] as? String ?: return
        val session = m["session"] as? String ?: key
        val host = m["host"] as? String ?: ""
        val text = m["text"] as? String ?: ""
        show(ctx, tag, key, session, host, listOf(text to agent(key, session)))
        posted.add(tag)
    }

    /** After a reply: the conversation with the driver's words and the outcome. */
    fun update(ctx: Context, tag: String, key: String, session: String, said: String, outcome: String) {
        show(ctx, tag, key, session, "", listOf(said to null, outcome to agent(key, session)), alert = false)
    }

    private fun show(
        ctx: Context,
        tag: String,
        key: String,
        session: String,
        host: String,
        messages: List<Pair<String, Person?>>,
        alert: Boolean = true,
    ) {
        ensureChannel(ctx)
        val now = System.currentTimeMillis()
        val style = NotificationCompat.MessagingStyle(me())
            .setConversationTitle(if (host.isEmpty()) session else "$session · $host")
            .setGroupConversation(false)
        messages.forEachIndexed { i, (t, who) ->
            style.addMessage(NotificationCompat.MessagingStyle.Message(t, now + i, who))
        }
        val code = tag.hashCode()
        val base = Intent(ctx, CarReplyReceiver::class.java)
            .putExtra(EXTRA_TAG, tag)
            .putExtra(EXTRA_KEY, key)
            .putExtra(EXTRA_SESSION, session)
        val replyFlags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
        val replyIntent = PendingIntent.getBroadcast(ctx, code, Intent(base).setAction(ACTION_REPLY), replyFlags)
        val readIntent = PendingIntent.getBroadcast(
            ctx, code, Intent(base).setAction(ACTION_READ),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val reply = NotificationCompat.Action.Builder(R.drawable.ic_stat_agentd, "Responder", replyIntent)
            .addRemoteInput(RemoteInput.Builder(KEY_REPLY).setLabel("Responder a $session").build())
            .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_REPLY)
            .setShowsUserInterface(false)
            .build()
        val read = NotificationCompat.Action.Builder(R.drawable.ic_stat_agentd, "Marcar como leído", readIntent)
            .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_MARK_AS_READ)
            .setShowsUserInterface(false)
            .build()
        val open = PendingIntent.getActivity(
            ctx, code,
            Intent(ctx, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(MainActivity.EXTRA_SESSION, key),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val n = NotificationCompat.Builder(ctx, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_agentd)
            .setStyle(style)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(open)
            .setAutoCancel(true)
            .setOnlyAlertOnce(!alert)
            .addAction(reply)
            .addInvisibleAction(read)
            .build()
        try {
            NotificationManagerCompat.from(ctx).notify(tag, ID, n)
        } catch (_: SecurityException) {
            // POST_NOTIFICATIONS not granted: the car screens still show it.
        }
    }

    fun cancel(ctx: Context, tag: String) {
        posted.remove(tag)
        NotificationManagerCompat.from(ctx).cancel(tag, ID)
    }

    fun cancelAll(ctx: Context) {
        posted.toList().forEach { cancel(ctx, it) }
    }
}
