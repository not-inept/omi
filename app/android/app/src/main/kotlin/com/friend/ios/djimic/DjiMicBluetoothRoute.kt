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
 * Routes system audio input to a communication-device microphone, and lists
 * the candidates a caller can route to. DJI hardware reaches the phone two
 * ways and both are listed here:
 *
 *  * a **transmitter in DJI's Bluetooth mode**, which connects to Android as
 *    a plain Bluetooth Classic HFP device (confirmed via DJI's own Android
 *    third-party app compatibility list, and by DJI's Mic 3 FAQ, which caps
 *    that link at 16 kHz / 16-bit "similar to Bluetooth headsets");
 *  * the **receiver on USB-C**, which enumerates as a standard USB audio
 *    class input.
 *
 * The abstraction is deliberately generic over "a communication-device mic"
 * rather than DJI-specific — there is no DJI protocol to discover against —
 * matching the [DjiMicHostApi] contract.
 *
 * Two implementations, selected by SDK level: `AudioDeviceInfo`/
 * `setCommunicationDevice` (API 31+) is the modern, non-deprecated API and
 * the primary path on the vast majority of devices in the field by the time
 * this ships; it is also the only one that can route to a USB input, so USB
 * support is API 31+ only. The legacy `startBluetoothSco()` path (API 29-30,
 * this app's `minSdk`) is exercised far less by real-world Android versions
 * but kept so the Bluetooth feature isn't silently unavailable below API 31.
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
    private companion object {
        /** The USB input types Android reports for a class-compliant audio
         *  interface. TYPE_USB_DEVICE is the plain interface (what the DJI
         *  receiver enumerates as); TYPE_USB_HEADSET is the same silicon
         *  behind a headset-shaped descriptor, which some phones report
         *  instead; TYPE_USB_ACCESSORY is the Android-accessory protocol.
         *  All three are listed rather than guessing which one this hardware
         *  and this phone will agree on. */
        val USB_TYPES = setOf(
            AudioDeviceInfo.TYPE_USB_DEVICE,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_USB_ACCESSORY,
        )
    }

    private val audioManager = application.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var listener: AudioManager.OnCommunicationDeviceChangedListener? = null

    /** The `AudioDeviceInfo.id` currently routed to. Route-loss is judged on
     *  this rather than on the address, because USB inputs have no address —
     *  comparing addresses would report every USB route as instantly lost. */
    private var connectedDeviceId: Int? = null

    override fun listInputs(): List<BluetoothMicInput> {
        val devices = audioManager.availableCommunicationDevices
        val out = mutableListOf<BluetoothMicInput>()

        // BLUETOOTH_CONNECT gates only the Bluetooth half. A user who has
        // declined the Bluetooth permission but plugged in the receiver must
        // still see the receiver.
        if (hasBluetoothConnectPermission(application)) {
            devices.filter { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }
                .mapNotNullTo(out) { device ->
                    val uid = device.address
                    if (uid.isNullOrEmpty()) {
                        null
                    } else {
                        BluetoothMicInput(uid, device.productName?.toString() ?: uid, BluetoothMicInputKind.BLUETOOTH)
                    }
                }
        }

        devices.filter { it.type in USB_TYPES }
            .mapTo(out) { device ->
                val name = device.productName?.toString()?.takeIf { it.isNotBlank() } ?: "USB audio device"
                BluetoothMicInput(DjiMicInputUid.encodeUsb(device.id, name), name, BluetoothMicInputKind.USB)
            }

        return out
    }

    /** Resolves a stored uid against what is plugged in / paired right now.
     *  Bluetooth matches on address; USB delegates to [DjiMicInputUid.matchUsb]
     *  (id first, product name after a replug). */
    private fun resolve(uid: String): AudioDeviceInfo? {
        val devices = audioManager.availableCommunicationDevices
        if (!DjiMicInputUid.isUsb(uid)) {
            if (!hasBluetoothConnectPermission(application)) return null
            return devices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO && it.address == uid }
        }
        val usb = devices.filter { it.type in USB_TYPES }
        val match = DjiMicInputUid.matchUsb(uid, usb.map { it.id to (it.productName?.toString() ?: "") })
            ?: return null
        return usb.firstOrNull { it.id == match.first }
    }

    override fun connect(uid: String, onResult: (Boolean) -> Unit, onRouteLost: () -> Unit) {
        val target = resolve(uid)
        if (target == null) {
            onResult(false)
            return
        }

        val newListener = AudioManager.OnCommunicationDeviceChangedListener { device ->
            if (device?.id != connectedDeviceId) {
                onRouteLost()
            }
        }
        val ok = audioManager.setCommunicationDevice(target)
        if (!ok) {
            onResult(false)
            return
        }

        connectedDeviceId = target.id
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
        connectedDeviceId = null
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
 *
 * Bluetooth only. `startBluetoothSco()` has no USB analogue, so on API 29-30
 * a USB-C receiver is simply not offered rather than offered and then failing
 * to route. Routing capture to a USB input below API 31 would mean
 * `AudioRecord.setPreferredDevice()` inside [DjiMicCaptureEngine] instead of a
 * route abstraction, which is a different shape of change and is deliberately
 * not attempted for two OS versions this app barely sees.
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
            .map { device: BluetoothDevice ->
                BluetoothMicInput(device.address, device.name ?: device.address, BluetoothMicInputKind.BLUETOOTH)
            }
    }

    override fun connect(uid: String, onResult: (Boolean) -> Unit, onRouteLost: () -> Unit) {
        if (DjiMicInputUid.isUsb(uid)) {
            // Never listed by this implementation; a uid stored on a newer OS
            // and restored here must fail cleanly, not route to the phone mic.
            Log.w("DjiMic.Route", "connect: USB inputs need API 31+; refusing $uid")
            onResult(false)
            return
        }
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
