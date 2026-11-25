package dev.digio.agentd_app.car

import android.content.Intent
import android.content.pm.ApplicationInfo
import androidx.car.app.CarAppService
import androidx.car.app.Screen
import androidx.car.app.Session
import androidx.car.app.validation.HostValidator
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner

/**
 * Android Auto entry (Car App Library, messaging category): the Panel on the
 * car screen. Debug builds accept any host (the Desktop Head Unit); release
 * builds only the known Android Auto hosts.
 */
class AgentdCarAppService : CarAppService() {
    override fun createHostValidator(): HostValidator =
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            HostValidator.ALLOW_ALL_HOSTS_VALIDATOR
        } else {
            HostValidator.Builder(applicationContext)
                .addAllowedHosts(androidx.car.app.R.array.hosts_allowlist_sample)
                .build()
        }

    override fun onCreateSession(): Session = AgentdCarSession()
}

class AgentdCarSession : Session() {
    override fun onCreateScreen(intent: Intent): Screen {
        CarEngine.ensure(carContext)
        CarEngine.sessionStarted()
        val speaker = CarSpeaker(carContext)
        lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onDestroy(owner: LifecycleOwner) {
                speaker.shutdown()
                CarEngine.sessionEnded()
            }
        })
        return PanelCarScreen(carContext, speaker)
    }
}
