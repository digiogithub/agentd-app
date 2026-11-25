package dev.digio.agentd_app.car

import androidx.car.app.CarContext
import androidx.car.app.CarToast
import androidx.car.app.Screen
import androidx.car.app.constraints.ConstraintManager
import androidx.car.app.messaging.model.CarMessage
import androidx.car.app.messaging.model.ConversationCallback
import androidx.car.app.messaging.model.ConversationItem
import androidx.car.app.model.Action
import androidx.car.app.model.ActionStrip
import androidx.car.app.model.CarText
import androidx.car.app.model.Header
import androidx.car.app.model.Item
import androidx.car.app.model.ItemList
import androidx.car.app.model.ListTemplate
import androidx.car.app.model.MessageTemplate
import androidx.car.app.model.Row
import androidx.car.app.model.SectionedItemList
import androidx.car.app.model.Template
import androidx.core.app.Person
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner

/**
 * Conversations (dictated replies on the car screen) need the messaging
 * category, which this app declares (see the manifest). Without them the
 * screens fall back to rows and a "Dictar instrucción" notification.
 */
private const val CONVERSATIONS = true

/** A screen redrawn on every snapshot of the car engine while it is shown. */
abstract class LiveCarScreen(ctx: CarContext, protected val speaker: CarSpeaker) : Screen(ctx) {
    private val listener: () -> Unit = { invalidate() }

    init {
        lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) = CarEngine.addListener(listener)
            override fun onStop(owner: LifecycleOwner) = CarEngine.removeListener(listener)
        })
    }

    protected val listLimit: Int
        get() = try {
            carContext.getCarService(ConstraintManager::class.java).getContentLimit(ConstraintManager.CONTENT_LIMIT_TYPE_LIST)
        } catch (_: Exception) {
            6
        }

    protected fun toast(text: String) = CarToast.makeText(carContext, text, CarToast.LENGTH_LONG).show()

    /** Shows and says [text] (the outcome of an action). */
    protected fun tell(text: String) {
        toast(text)
        speaker.say(text)
    }

    /**
     * Car API level 7 (Android Auto 2024+) brings headers and conversations
     * (dictated replies on the car screen). Older hosts get a title, an
     * action strip and plain rows; replies then go through the notifications.
     */
    protected val modern get() = carContext.carAppApiLevel >= 7

    private fun header(title: String, back: Boolean, end: Action?): Header {
        val h = Header.Builder().setTitle(title)
        if (back) h.setStartHeaderAction(Action.BACK)
        end?.let { h.addEndHeaderAction(it) }
        return h.build()
    }

    protected fun listTemplate(title: String, back: Boolean, end: Action? = null): ListTemplate.Builder {
        val t = ListTemplate.Builder()
        if (modern) return t.setHeader(header(title, back, end))
        t.setTitle(title)
        if (back) t.setHeaderAction(Action.BACK)
        end?.let { t.setActionStrip(ActionStrip.Builder().addAction(it).build()) }
        return t
    }

    protected fun messageTemplate(text: String, title: String, back: Boolean): MessageTemplate.Builder {
        val t = MessageTemplate.Builder(text)
        if (modern) return t.setHeader(header(title, back, null))
        t.setTitle(title)
        if (back) t.setHeaderAction(Action.BACK)
        return t
    }

    protected fun action(title: String, onClick: () -> Unit): Action =
        Action.Builder().setTitle(title).setOnClickListener { onClick() }.build()

    private val me = Person.Builder().setKey("me").setName("Tú").build()

    /**
     * The conversation with [agent]: the host reads [messages] aloud and
     * offers a dictated reply, sent as the car engine's `reply`.
     */
    protected fun conversation(agent: CarAgent, messages: List<String>, open: (() -> Unit)? = null): Item {
        // Before car API 7 (or without conversations): a row, tap = open the
        // agent or hear it.
        if (!CONVERSATIONS || !modern) {
            val last = messages.lastOrNull() ?: agent.preview ?: "Sin mensajes"
            return Row.Builder()
                .setTitle(if (agent.host.isEmpty()) agent.name else "${agent.name} · ${agent.host}")
                .addText(last.take(200))
                .setOnClickListener { if (open != null) open() else speaker.say(messages.joinToString(". ").ifBlank { last }) }
                .build()
        }
        val who = Person.Builder().setKey(agent.key).setName(agent.name).setBot(true).build()
        val now = System.currentTimeMillis()
        val msgs = messages.ifEmpty { listOf(agent.preview ?: "Sin mensajes") }.mapIndexed { i, t ->
            CarMessage.Builder()
                .setSender(who)
                .setBody(CarText.create(t.take(1000)))
                .setReceivedTimeEpochMillis(now - (messages.size - i))
                .setRead(!agent.waiting)
                .build()
        }
        val b = ConversationItem.Builder()
            .setId(agent.key)
            .setTitle(CarText.create(if (agent.host.isEmpty()) agent.name else "${agent.name} · ${agent.host}"))
            .setSelf(me)
            .setMessages(msgs)
            .setGroupConversation(false)
            .setConversationCallback(object : ConversationCallback {
                override fun onMarkAsRead() {}
                override fun onTextReply(replyText: String) = reply(agent, replyText)
            })
        if (open != null) b.addAction(action("Abrir") { open() })
        return b.build()
    }

    protected fun reply(agent: CarAgent, text: String) {
        if (!agent.canOperate) return tell("Este dispositivo solo puede mirar en ese host")
        CarEngine.call("reply", mapOf("key" to agent.key, "text" to text), onResult = { tell(it as? String ?: "Enviado") }, onError = ::tell)
    }

    /** What an agent waits on, as the messages of its conversation. */
    protected fun waitingMessages(a: CarAgent): List<String> {
        val out = mutableListOf<String>()
        for (q in a.questions) {
            val opts = if (q.options.isEmpty()) "" else "\nOpciones: ${CarModel.spokenOptions(q.options)}"
            out.add("Pregunta: ${q.body.trim().take(600)}$opts")
        }
        a.menu?.let { m ->
            val what = if (m.kind == "permission") "Pide permiso" else "Espera tu decisión"
            val detail = m.detail?.takeIf { it.isNotBlank() }?.let { "\n$it" } ?: ""
            val opts = if (m.options.isEmpty()) "" else "\nOpciones: ${CarModel.spokenOptions(m.options.map { it.label })}"
            out.add("$what: ${m.question.trim().take(400)}$detail$opts")
        }
        return out
    }

    protected fun subtitle(a: CarAgent): String {
        val parts = mutableListOf(a.host, a.statusLabel)
        if (a.total > 0) parts.add("${a.done}/${a.total}")
        a.current?.let { parts.add(it) }
        return parts.filter { it.isNotBlank() }.joinToString(" · ")
    }
}

/**
 * The Panel in the car: what waits for a decision (conversations: listen and
 * answer by voice), blocked tasks, then the other agents. A row opens the
 * agent.
 */
class PanelCarScreen(ctx: CarContext, speaker: CarSpeaker) : LiveCarScreen(ctx, speaker) {
    override fun onGetTemplate(): Template {
        val snap = CarEngine.snapshot
        val refresh = action("Actualizar") {
            CarEngine.call("refresh", null)
            toast("Reconectando")
        }
        val t = listTemplate("agentd", false, refresh)
        if (snap == null) return t.setLoading(true).build()
        val agents = CarModel.agents(snap)
        var budget = listLimit
        fun <T : Item> take(items: List<T>): List<T> = items.take(budget.coerceAtLeast(0)).also { budget -= it.size }

        val waiting = take(agents.filter { it.waiting }.map { a -> conversation(a, waitingMessages(a)) { openAgent(a) } })
        val blocked = take(agents.flatMap { a -> a.blocked.map { b -> a to b } }.map { (a, b) ->
            Row.Builder().setTitle("${a.name}: ${b.title}")
                .apply { b.note?.takeIf { it.isNotBlank() }?.let { addText(it) } }
                .setBrowsable(true)
                .setOnClickListener { openAgent(a) }
                .build()
        })
        val rest = take(agents.filter { !it.waiting }.map { a ->
            Row.Builder().setTitle(a.name).addText(subtitle(a)).setBrowsable(true).setOnClickListener { openAgent(a) }.build()
        })
        if (waiting.isEmpty() && blocked.isEmpty() && rest.isEmpty()) {
            val online = (snap["online"] as? Number)?.toInt() ?: 0
            val msg = if (online == 0) "Ningún host conectado" else "No hay agentes"
            return t.setSingleList(ItemList.Builder().setNoItemsMessage(msg).build()).build()
        }
        fun section(items: List<Item>, title: String) {
            if (items.isEmpty()) return
            val l = ItemList.Builder()
            items.forEach { l.addItem(it) }
            t.addSectionedList(SectionedItemList.create(l.build(), title))
        }
        section(waiting, "Esperan tu decisión")
        section(blocked, "Bloqueos")
        section(rest, "Agentes")
        return t.build()
    }

    private fun openAgent(a: CarAgent) = screenManager.push(AgentCarScreen(carContext, speaker, a.key))
}

/**
 * One agent: its conversation (hear the last message, dictate an answer or
 * an instruction), the options of what it waits on, "Escuchar conclusión"
 * and "Últimas líneas".
 */
class AgentCarScreen(ctx: CarContext, speaker: CarSpeaker, private val key: String) : LiveCarScreen(ctx, speaker) {
    private var conclusion: String? = null

    init {
        loadConclusion(speak = false)
    }

    private fun loadConclusion(speak: Boolean) {
        CarEngine.call("conclusion", mapOf("key" to key), onResult = {
            conclusion = it as? String
            invalidate()
            if (speak) conclusion?.let(speaker::say)
        }, onError = { if (speak) tell(it) })
    }

    override fun onGetTemplate(): Template {
        val a = CarModel.agent(CarEngine.snapshot, key)
            ?: return messageTemplate("Este agente ya no está en el panel", "agentd", true).build()
        val items = mutableListOf<Item>()
        val msgs = buildList {
            conclusion?.let { add(it) }
            addAll(waitingMessages(a))
        }
        items.add(conversation(a, msgs))
        val q = a.questions.firstOrNull()
        if (a.canOperate && q != null) {
            q.options.forEachIndexed { i, o ->
                items.add(Row.Builder().setTitle("${i + 1}. $o").addText("Responder: ${q.headline.take(80)}").setOnClickListener {
                    CarEngine.call("answer", mapOf("hostId" to a.hostId, "questionId" to q.id, "text" to o),
                        onResult = { tell("Respondido a ${a.name}: $o") }, onError = ::tell)
                }.build())
            }
        } else if (a.canOperate && a.menu != null) {
            a.menu.options.forEachIndexed { i, o ->
                items.add(Row.Builder().setTitle("${i + 1}. ${o.label}").addText(a.menu.question.take(80)).setOnClickListener {
                    CarEngine.call("choose", mapOf("key" to a.key, "optionId" to o.id),
                        onResult = { tell("Elegido en ${a.name}: ${o.label}") }, onError = ::tell)
                }.build())
            }
        }
        if (a.canOperate && !(CONVERSATIONS && modern)) {
            items.add(Row.Builder().setTitle("Dictar instrucción").addText("Pulsa Responder en el aviso y habla").setOnClickListener {
                // Templated IoT apps get no dictation: a messaging notification
                // does (Reply = Google Assistant dictation, sent as `reply`).
                CarNotifications.post(carContext, mapOf(
                    "tag" to "talk/${a.key}", "sessionKey" to a.key, "session" to a.name, "host" to a.host,
                    "text" to if (a.waiting) "Contesta a ${a.name}: ${waitingMessages(a).joinToString(" ").take(300)}" else "¿Qué le digo a ${a.name}?",
                ))
                tell("Responde al aviso de ${a.name}")
            }.build())
        }
        items.add(Row.Builder().setTitle("Escuchar conclusión").addText(subtitle(a)).setOnClickListener {
            toast("Leyendo la conclusión")
            loadConclusion(speak = true)
        }.build())
        items.add(Row.Builder().setTitle("Últimas líneas").setBrowsable(true).setOnClickListener {
            screenManager.push(LinesCarScreen(carContext, speaker, a.key, a.name))
        }.build())
        a.blocked.forEach { b ->
            items.add(Row.Builder().setTitle("Bloqueada: ${b.title}").apply { b.note?.takeIf { it.isNotBlank() }?.let { addText(it) } }.build())
        }
        val l = ItemList.Builder()
        items.take(listLimit).forEach { l.addItem(it) }
        return listTemplate(a.name, true).setSingleList(l.build()).build()
    }
}

/** The last lines of a session, shown and read aloud. */
class LinesCarScreen(ctx: CarContext, speaker: CarSpeaker, private val key: String, private val name: String) :
    LiveCarScreen(ctx, speaker) {
    private var lines: List<String>? = null
    private var error: String? = null

    init {
        load(speak = true)
    }

    private fun load(speak: Boolean) {
        CarEngine.call("lastLines", mapOf("key" to key, "n" to 8), onResult = { r ->
            lines = (r as? List<*>)?.filterIsInstance<String>() ?: emptyList()
            error = null
            invalidate()
            if (speak) speaker.say(spoken())
        }, onError = {
            error = it
            invalidate()
        })
    }

    private fun spoken() = lines.orEmpty().joinToString(". ") { it.removePrefix("> ") }.ifBlank { "Sin líneas todavía" }

    override fun onGetTemplate(): Template {
        val title = "Últimas líneas · $name"
        val ls = lines
        if (ls == null && error == null) return messageTemplate("Cargando…", title, true).setLoading(true).build()
        val text = error ?: ls.orEmpty().joinToString("\n").ifBlank { "Sin líneas todavía" }.takeLast(1000)
        return messageTemplate(text, title, true)
            .addAction(action("Escuchar") { speaker.say(spoken()) })
            .addAction(action("Actualizar") { load(speak = false) })
            .build()
    }
}
