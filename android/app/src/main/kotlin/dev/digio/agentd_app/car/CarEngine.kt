package dev.digio.agentd_app.car

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.car.app.connection.CarConnection
import androidx.lifecycle.Observer
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * The headless Flutter engine of the Android Auto client: Dart entry point
 * `carMain` (lib/main.dart -> lib/src/car/car_bridge.dart), with its own
 * repositories and connections, so the car works while the phone is locked
 * and the app closed. Channel `agentd/car` (protocol in car_bridge.dart).
 *
 * Started by the car session, by a push while Android Auto is connected, by
 * a notification reply, or by MainActivity when the car connects. Stopped
 * when nothing uses it: no car session, not in the car, no hold (the voice
 * mode holds it while VoiceService runs), idle for 2 minutes.
 * Main thread only.
 */
object CarEngine {
    private const val IDLE_MS = 2 * 60 * 1000L

    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var ready = false
    private val queue = mutableListOf<() -> Unit>()
    private val listeners = linkedSetOf<() -> Unit>()
    private val main = Handler(Looper.getMainLooper())
    private var app: Context? = null
    private var sessions = 0
    private var inCar = false
    private var lastUse = 0L
    private var connection: CarConnection? = null
    private val holds = linkedSetOf<String>()
    private val carObserver = Observer<Int> { type ->
        inCar = type == CarConnection.CONNECTION_TYPE_PROJECTION || type == CarConnection.CONNECTION_TYPE_NATIVE
        if (!inCar) scheduleIdleCheck()
    }

    /** The last Panel snapshot from Dart (null before the first one). */
    var snapshot: Map<String, Any?>? = null
        private set

    val running get() = engine != null

    /** The engine's messenger, for other channels (`agentd/voice`); null while stopped. */
    val messenger: BinaryMessenger? get() = engine?.dartExecutor?.binaryMessenger

    /**
     * Runs [block] once Dart has said `ready` (now if it already has). Like
     * [call], dropped if the engine stops first.
     */
    fun whenReady(block: () -> Unit) {
        touch()
        if (ready) block() else queue.add(block)
    }

    /** Keeps the engine running (the idle stop ignores it) until [release] with the same [tag]. */
    fun hold(tag: String) {
        holds.add(tag)
        touch()
    }

    fun release(tag: String) {
        holds.remove(tag)
        touch()
        scheduleIdleCheck()
    }

    fun ensure(ctx: Context) {
        touch()
        if (engine != null) return
        val appCtx = ctx.applicationContext
        app = appCtx
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(appCtx)
        loader.ensureInitializationComplete(appCtx, null)
        val e = FlutterEngine(appCtx)
        val ch = MethodChannel(e.dartExecutor.binaryMessenger, "agentd/car")
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "ready" -> {
                    ready = true
                    val q = queue.toList()
                    queue.clear()
                    q.forEach { it() }
                }
                "snapshot" -> {
                    @Suppress("UNCHECKED_CAST")
                    snapshot = call.arguments as? Map<String, Any?>
                    listeners.toList().forEach { it() }
                }
                "notify" -> {
                    @Suppress("UNCHECKED_CAST")
                    (call.arguments as? Map<String, Any?>)?.let { CarNotifications.post(appCtx, it) }
                }
                "cancel" -> (call.arguments as? String)?.let { CarNotifications.cancel(appCtx, it) }
            }
            result.success(null)
        }
        engine = e
        channel = ch
        ready = false
        e.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "carMain"))
        connection = CarConnection(appCtx).also { it.type.observeForever(carObserver) }
        scheduleIdleCheck()
    }

    /** Calls Dart [method]; [onError] gets a message for the driver. */
    fun call(method: String, args: Any?, onResult: (Any?) -> Unit = {}, onError: (String) -> Unit = {}) {
        touch()
        val run = {
            channel?.invokeMethod(method, args, object : MethodChannel.Result {
                override fun success(result: Any?) = onResult(result)
                override fun error(code: String, message: String?, details: Any?) =
                    onError(message ?: "No se pudo")
                override fun notImplemented() = onError("No disponible")
            }) ?: onError("agentd no está en marcha")
        }
        if (ready) run() else queue.add(run)
    }

    fun addListener(l: () -> Unit) {
        listeners.add(l)
    }

    fun removeListener(l: () -> Unit) {
        listeners.remove(l)
    }

    fun sessionStarted() {
        sessions++
        touch()
    }

    fun sessionEnded() {
        if (sessions > 0) sessions--
        touch()
        scheduleIdleCheck()
    }

    private fun touch() {
        lastUse = SystemClock.elapsedRealtime()
    }

    private fun scheduleIdleCheck() {
        main.removeCallbacks(idleCheck)
        main.postDelayed(idleCheck, IDLE_MS + 1000)
    }

    private val idleCheck = Runnable {
        if (engine == null) return@Runnable
        val idle = SystemClock.elapsedRealtime() - lastUse >= IDLE_MS
        if (sessions == 0 && !inCar && holds.isEmpty() && idle) stop() else scheduleIdleCheck()
    }

    private fun stop() {
        connection?.type?.removeObserver(carObserver)
        connection = null
        app?.let { CarNotifications.cancelAll(it) }
        channel?.setMethodCallHandler(null)
        channel = null
        engine?.destroy()
        engine = null
        ready = false
        snapshot = null
        queue.clear()
    }
}
