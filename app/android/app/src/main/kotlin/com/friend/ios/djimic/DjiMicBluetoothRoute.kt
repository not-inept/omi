package com.friend.ios.djimic

import android.app.Application
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothClass
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Routes system audio input to a Bluetooth communication-device (HFP/SCO)
 * microphone, and lists the candidates a caller can route to. DJI Mic 3
 * connects to Android as a plain Bluetooth Classic HFP device (confirmed via
 * DJI's own Android third-party app compatibility list) — this route
 * abstraction is deliberately generic over "a Bluetooth communication-device
 * mic" rather than DJI-specific, matching the [DjiMicHostApi] contract.
 *
 * Two implementations, selected by SDK level: `AudioDeviceInfo`/
 * `setCommunicationDevice` (API 31+) is the modern, non-deprecated API and
 * the primary path on the vast majority of devices in the field by the time
 * this ships. The legacy `startBluetoothSco()` path (API 29-30, this app's
 * `minSdk`) is exercised far less by real-world Android versions but kept so
 * the feature isn't silently unavailable below API 31.
 *
 * [onRouteLost] callbacks arrive on whatever thread the underlying platform
 * callback/broadcast runs on (not guaranteed to be main) — callers must hop
 * to their own confinement thread before touching shared state.
 */
interface DjiMicBluetoothRoute {
    fun listInputs(): List<BluetoothMicInput>

    /**
     * Attempts to route system audio input to [uid]. Always asynchronous, even
     * though the API 31+ implementation could resolve synchronously — the legacy
     * SCO path must wait for a broadcast, and a uniform async contract keeps the
     * caller (confined to main) from ever blocking on it.
     *
     * [onResult] fires exactly once. [onRouteLost] fires at most once, only after
     * a `true` result, if the route later disconnects on its own (transmitter
     * powered off, out of range, BLUETOOTH_CONNECT revoked, etc). Both callbacks
     * arrive on [mainHandler]/[Context.getMainExecutor] — main thread.
     */
    fun connect(uid: String, onResult: (Boolean) -> Unit, onRouteLost: () -> Unit)

    /** Idempotent; safe to call whether or not [connect] ever succeeded. */
    fun disconnect()

    companion object {
        private const val TAG = "DjiMic.Route"

        fun create(application: Application, mainHandler: Handler): DjiMicBluetoothRoute {
            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                DjiMicCommunicationDeviceRoute(application)
            } else {
                DjiMicScoRoute(application, mainHandler)
            }
        }

        /** Bluetooth "audio/video" major device class covers headsets, handsfree,
         *  and (per Android's own BluetoothClass docs) wearable audio devices —
         *  the bucket DJI Mic 3 and other Bluetooth communication mics fall into. */
        fun isAudioDevice(bluetoothClass: BluetoothClass?): Boolean =
            bluetoothClass?.majorDeviceClass == BluetoothClass.Device.Major.AUDIO_VIDEO
    }
}

private fun hasBluetoothConnectPermission(context: Context): Boolean {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true // permission didn't exist pre-31
    return ContextCompat.checkSelfPermission(context, android.Manifest.permission.BLUETOOTH_CONNECT) ==
        android.content.pm.PackageManager.PERMISSION_GRANTED
}

/** API 31+: [AudioManager.getAvailableCommunicationDevices] / [AudioManager.setCommunicationDevice]. */
@androidx.annotation.RequiresApi(Build.VERSION_CODES.S)
private class DjiMicCommunicationDeviceRoute(private val application: Application) : DjiMicBluetoothRoute {
    private val audioManager = application.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var listener: AudioManager.OnCommunicationDeviceChangedListener? = null
    private var connectedUid: String? = null

    override fun listInputs(): List<BluetoothMicInput> {
        if (!hasBluetoothConnectPermission(application)) return emptyList()
        return audioManager.availableCommunicationDevices
            .filter { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }
            .mapNotNull { device ->
                val uid = device.address
                if (uid.isNullOrEmpty()) null else BluetoothMicInput(uid, device.productName?.toString() ?: uid)
            }
    }

    override fun connect(uid: String, onResult: (Boolean) -> Unit, onRouteLost: () -> Unit) {
        if (!hasBluetoothConnectPermission(application)) {
            onResult(false)
            return
        }
        val target = audioManager.availableCommunicationDevices
            .firstOrNull { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO && it.address == uid }
        if (target == null) {
            onResult(false)
            return
        }

        val newListener = AudioManager.OnCommunicationDeviceChangedListener { device ->
            if (device?.address != connectedUid) {
                onRouteLost()
            }
        }
        val ok = audioManager.setCommunicationDevice(target)
        if (!ok) {
            onResult(false)
            return
        }

        connectedUid = uid
        this.listener = newListener
        audioManager.addOnCommunicationDeviceChangedListener(application.mainExecutor, newListener)
        onResult(true)
    }

    override fun disconnect() {
        listener?.let {
            try {
                audioManager.removeOnCommunicationDeviceChangedListener(it)
            } catch (e: Exception) {
                Log.w("DjiMic.Route", "disconnect: removeListener failed: ${e.message}")
            }
        }
        listener = null
        connectedUid = null
        try {
            audioManager.clearCommunicationDevice()
        } catch (e: Exception) {
            Log.w("DjiMic.Route", "disconnect: clearCommunicationDevice failed: ${e.message}")
        }
    }
}

/**
 * API 29-30 fallback: the deprecated but still-functional [AudioManager.startBluetoothSco]
 * path. There is no "list currently connectable communication devices" API pre-31, so
 * [listInputs] falls back to bonded audio-class devices — this can list a paired DJI
 * transmitter that is powered off or out of range; [connect] is the real availability
 * check (it waits for [android.media.AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED] to
 * report CONNECTED and fails/returns false on timeout).
 */
private class DjiMicScoRoute(
    private val application: Application,
    private val mainHandler: Handler,
) : DjiMicBluetoothRoute {
    companion object {
        private const val SCO_CONNECT_TIMEOUT_MS = 5000L
    }

    private val audioManager = application.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var receiver: BroadcastReceiver? = null
    private var connected = false

    override fun listInputs(): List<BluetoothMicInput> {
        val adapter = BluetoothAdapter.getDefaultAdapter() ?: return emptyList()
        if (!hasBluetoothConnectPermission(application)) return emptyList()
        val bonded = try {
            adapter.bondedDevices
        } catch (e: SecurityException) {
            return emptyList()
        }
        return bonded
            .filter { DjiMicBluetoothRoute.isAudioDevice(it.bluetoothClass) }
            .map { device: BluetoothDevice -> BluetoothMicInput(device.address, device.name ?: device.address) }
    }

    override fun connect(uid: String, onResult: (Boolean) -> Unit, onRouteLost: () -> Unit) {
        val adapter = BluetoothAdapter.getDefaultAdapter()
        val target = try {
            adapter?.bondedDevices?.firstOrNull { it.address == uid }
        } catch (e: SecurityException) {
            null
        }
        if (target == null || !DjiMicBluetoothRoute.isAudioDevice(target.bluetoothClass)) {
            onResult(false)
            return
        }

        // AudioManager.mode is process-global, and this app already drives it for
        // Twilio phone calls (see PhoneCallsPlugin.kt's startBluetoothSco() usage).
        // If something else already owns MODE_IN_COMMUNICATION (an active call),
        // refuse rather than stomp it — better to fail this connect than corrupt
        // a live call's audio. API 31+'s setCommunicationDevice() is properly
        // scoped per-app by the platform and doesn't have this problem; this
        // guard only applies to this legacy (API 29-30) fallback.
        @Suppress("DEPRECATION")
        if (audioManager.mode != AudioManager.MODE_NORMAL) {
            Log.w("DjiMic.Route", "connect: refusing — AudioManager.mode is already ${audioManager.mode}, not MODE_NORMAL")
            onResult(false)
            return
        }

        // Guards so exactly one of {timeout, broadcast-connected, broadcast-failed}
        // resolves onResult, however they race.
        var resolved = false
        val timeoutRunnable = Runnable {
            if (resolved) return@Runnable
            resolved = true
            disconnect()
            onResult(false)
        }

        val newReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val state = intent.getIntExtra(AudioManager.EXTRA_SCO_AUDIO_STATE, AudioManager.SCO_AUDIO_STATE_ERROR)
                when (state) {
                    AudioManager.SCO_AUDIO_STATE_CONNECTED -> {
                        if (!connected) {
                            connected = true
                            if (!resolved) {
                                resolved = true
                                mainHandler.removeCallbacks(timeoutRunnable)
                                onResult(true)
                            }
                        }
                    }
                    AudioManager.SCO_AUDIO_STATE_DISCONNECTED -> {
                        val wasConnected = connected
                        connected = false
                        if (!resolved) {
                            resolved = true
                            mainHandler.removeCallbacks(timeoutRunnable)
                            disconnect()
                            onResult(false)
                        } else if (wasConnected) {
                            onRouteLost()
                        }
                    }
                }
            }
        }
        receiver = newReceiver
        ContextCompat.registerReceiver(
            application,
            newReceiver,
            IntentFilter(AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        mainHandler.postDelayed(timeoutRunnable, SCO_CONNECT_TIMEOUT_MS)

        @Suppress("DEPRECATION")
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        @Suppress("DEPRECATION")
        audioManager.startBluetoothSco()
    }

    override fun disconnect() {
        receiver?.let {
            try {
                application.unregisterReceiver(it)
            } catch (e: Exception) {
                Log.w("DjiMic.Route", "disconnect: unregisterReceiver failed: ${e.message}")
            }
        }
        receiver = null
        connected = false
        @Suppress("DEPRECATION")
        try {
            audioManager.stopBluetoothSco()
        } catch (e: Exception) {
            Log.w("DjiMic.Route", "disconnect: stopBluetoothSco failed: ${e.message}")
        }
        // Only reset mode if it's still what connect() set it to. This is a
        // partial mitigation, not full ownership tracking — see the
        // MODE_NORMAL guard in connect() for the fuller explanation. If a
        // call started after we connected and is also driving
        // MODE_IN_COMMUNICATION, this still can't tell the two apart; that
        // gap needs real cross-subsystem coordination with PhoneCallsPlugin,
        // which is out of scope here.
        @Suppress("DEPRECATION")
        if (audioManager.mode == AudioManager.MODE_IN_COMMUNICATION) {
            @Suppress("DEPRECATION")
            audioManager.mode = AudioManager.MODE_NORMAL
        }
    }
}
