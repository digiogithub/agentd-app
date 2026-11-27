package dev.digio.agentd_app.voice

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.Toast

/**
 * Transparent trampoline of the "agentd voz" launcher entry (and of "Hey
 * Google, abre agentd voz"): asks for the missing permissions, starts
 * VoiceService with source `launcher` while still in the foreground (a
 * microphone service cannot start from the background), and finishes.
 */
class VoiceActivity : Activity() {
    private val main = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val missing = wanted().filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isEmpty()) startVoice() else requestPermissions(missing.toTypedArray(), REQUEST)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST) return
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            Toast.makeText(this, "El modo voz necesita el micrófono", Toast.LENGTH_LONG).show()
        }
        startVoice()
    }

    private fun startVoice() {
        when (VoiceService.start(applicationContext, "launcher")) {
            VoiceService.START_NO_BLUETOOTH ->
                Toast.makeText(this, "Conecta unos auriculares Bluetooth para usar el modo voz", Toast.LENGTH_LONG).show()
            VoiceService.START_REFUSED -> Toast.makeText(this, "No se pudo iniciar el modo voz", Toast.LENGTH_LONG).show()
        }
        // Stay visible a moment: the service enters the foreground while we are on screen.
        main.postDelayed({ finish() }, 600)
    }

    private fun wanted(): List<String> = buildList {
        add(Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) add(Manifest.permission.BLUETOOTH_CONNECT)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) add(Manifest.permission.POST_NOTIFICATIONS)
    }

    companion object {
        private const val REQUEST = 7511
    }
}
