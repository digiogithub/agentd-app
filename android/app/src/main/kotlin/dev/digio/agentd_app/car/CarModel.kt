package dev.digio.agentd_app.car

/** The Panel snapshot of the car engine (CarHub.rebuild in Dart), typed. */
data class CarQuestion(val id: Long, val body: String, val headline: String, val options: List<String>)

data class CarOption(val id: String, val label: String)

data class CarMenu(val kind: String, val question: String, val detail: String?, val options: List<CarOption>)

data class CarBlocked(val title: String, val note: String?)

data class CarAgent(
    val key: String,
    val hostId: String,
    val host: String,
    val name: String,
    val status: String,
    val preview: String?,
    val current: String?,
    val done: Int,
    val total: Int,
    val canOperate: Boolean,
    val blocked: List<CarBlocked>,
    val questions: List<CarQuestion>,
    val menu: CarMenu?,
) {
    val waiting get() = questions.isNotEmpty() || menu != null

    /** Status in Spanish, for a row. */
    val statusLabel
        get() = when (status) {
            "working" -> "trabajando"
            "waiting" -> "esperando"
            "idle" -> "libre"
            "starting" -> "arrancando"
            "exited" -> "terminada"
            else -> status
        }
}

object CarModel {
    fun agents(snapshot: Map<String, Any?>?): List<CarAgent> =
        (snapshot?.get("agents") as? List<*>)?.mapNotNull { (it as? Map<*, *>)?.let(::agent) } ?: emptyList()

    fun agent(snapshot: Map<String, Any?>?, key: String): CarAgent? = agents(snapshot).firstOrNull { it.key == key }

    private fun str(m: Map<*, *>, k: String) = m[k] as? String

    private fun agent(m: Map<*, *>): CarAgent? {
        val key = str(m, "key") ?: return null
        val menu = (m["menu"] as? Map<*, *>)?.let { mm ->
            CarMenu(
                kind = str(mm, "kind") ?: "unknown",
                question = str(mm, "question") ?: "",
                detail = str(mm, "detail"),
                options = (mm["options"] as? List<*>)?.mapNotNull { o ->
                    (o as? Map<*, *>)?.let { om -> str(om, "id")?.let { CarOption(it, str(om, "label") ?: it) } }
                } ?: emptyList(),
            )
        }
        return CarAgent(
            key = key,
            hostId = str(m, "hostId") ?: "",
            host = str(m, "host") ?: "",
            name = str(m, "name") ?: key,
            status = str(m, "status") ?: "unknown",
            preview = str(m, "preview"),
            current = str(m, "current"),
            done = (m["done"] as? Number)?.toInt() ?: 0,
            total = (m["total"] as? Number)?.toInt() ?: 0,
            canOperate = m["canOperate"] == true,
            blocked = (m["blocked"] as? List<*>)?.mapNotNull { b ->
                (b as? Map<*, *>)?.let { bm -> str(bm, "title")?.let { CarBlocked(it, str(bm, "note")) } }
            } ?: emptyList(),
            questions = (m["questions"] as? List<*>)?.mapNotNull { q ->
                (q as? Map<*, *>)?.let { qm ->
                    val id = (qm["id"] as? Number)?.toLong() ?: return@let null
                    CarQuestion(
                        id = id,
                        body = str(qm, "body") ?: "",
                        headline = str(qm, "headline") ?: "",
                        options = (qm["options"] as? List<*>)?.filterIsInstance<String>() ?: emptyList(),
                    )
                }
            } ?: emptyList(),
            menu = menu,
        )
    }

    /** "1, Sí. 2, No." as Dart's spokenOptions. */
    fun spokenOptions(options: List<String>) = options.mapIndexed { i, o -> "${i + 1}, ${o.trim()}." }.joinToString(" ")
}
