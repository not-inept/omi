package com.friend.ios.djimic

import android.Manifest
import android.app.Application
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * The DJI Mic 3 / Bluetooth-communication-device-mic capture state machine —
 * the structural peer of [com.friend.ios.phonemic.PhoneMicController] (same
 * main-thread confinement, session-id discipline, and epoch-gated emission
 * via [DjiMicEventEmitter]). Read that class's doc first if you're touching
 * this one.
 *
 * Deliberately scoped down from it in one respect: PhoneMicController's
 * multi-cause interruption handling (silencing vs call-mode vs stall, each
 * with its own resume policy, heartbeat, and bounded rebuild retries) exists
 * because the built-in mic can be silently preempted by another app/the
 * system in several distinct ways. A Bluetooth communication-device route
 * has one real interruption signal — the route itself disconnecting (the
 * transmitter powered off, walked out of range, or the user unpaired it) —
 * so this controller has one recovery path: on an unexpected route loss
 * while RUNNING, go INTERRUPTED and attempt exactly one reconnect; on
 * failure, go IDLE and report `route_lost` rather than retry indefinitely.
 * Tuning that into a bounded-retry/backoff policy like the phone-mic engine
 * needs real hardware to validate against and is intentionally deferred
 * (tracking: the DJI Mic 3 hardware-verification follow-up noted in the repo
 * plan for this feature).
 *
 * Threading: identical contract to PhoneMicController — all control state is
 * confined to the MAIN thread. [DjiMicBluetoothRoute] callbacks and
 * [DjiMicCaptureEngine]'s chunk callback are the only two entry points that
 * can arrive off small threads; both are hopped to main immediately.
 */
class DjiMicController private constructor(private val application: Application) {

    private val mainHandler = Handler(Looper.getMainLooper())
    private val emitter = DjiMicEventEmitter(mainHandler)
    private val route: DjiMicBluetoothRoute = DjiMicBluetoothRoute.create(application, mainHandler)

    private var state: DjiMicCaptureState = DjiMicCaptureState.IDLE
    private var currentSessionId: Long = 0L
    private var currentInputUid: String? = null
    private var pendingStop = false
    private var engine: DjiMicCaptureEngine? = null
    private var reconnectAttempted = false

    private val pendingStartCallbacks = mutableListOf<(Result<Unit>) -> Unit>()
    private val pendingStopCallbacks = mutableListOf<(Result<Unit>) -> Unit>()

    // MARK: - Public surface (main-confined)

    fun bindFlutterApi(api: DjiMicFlutterApi) {
        emitter.bind(api)
    }

    /** Mirrors PhoneMicController.onFlutterEngineDestroyed: the Flutter engine and
     *  main isolate die with the activity, so a live session must not outlive it. */
    fun onFlutterEngineDestroyed() = runOnMain {
        if (state != DjiMicCaptureState.IDLE) {
            handleStop {}
        }
        emitter.unbind()
    }

    fun getAvailableInputs(callback: (Result<List<BluetoothMicInput>>) -> Unit) = runOnMain {
        callback(Result.success(route.listInputs()))
    }

    fun start(inputUid: String, sessionId: Long, callback: (Result<Unit>) -> Unit) = runOnMain {
        handleStart(inputUid, sessionId, callback)
    }

    fun stop(callback: (Result<Unit>) -> Unit) = runOnMain {
        handleStop(callback)
    }

    val isRecording: Boolean
        get() = state != DjiMicCaptureState.IDLE

    // MARK: - Command handling (main)

    private fun handleStart(inputUid: String, sessionId: Long, callback: (Result<Unit>) -> Unit) {
        when (state) {
            DjiMicCaptureState.RUNNING -> {
                if (inputUid != currentInputUid) {
                    // A different input while already running is a deliberate switch,
                    // not a de-synced restart: stop first, then start fresh under the
                    // new id/uid so the caller sees a clean transition.
                    pendingStartCallbacks.add(callback)
                    handleStop {
                        handleStart(inputUid, sessionId, {})
                    }
                    return
                }
                // De-synced Dart restart of the same input: adopt the new id, re-emit
                // RUNNING so the caller converges, resolve.
                currentSessionId = sessionId
                emitter.emitState(DjiMicCaptureState.RUNNING, sessionId)
                callback(Result.success(Unit))
            }

            DjiMicCaptureState.STARTING, DjiMicCaptureState.INTERRUPTED -> {
                currentSessionId = sessionId
                pendingStartCallbacks.add(callback)
                if (state == DjiMicCaptureState.INTERRUPTED) {
                    emitter.emitState(DjiMicCaptureState.INTERRUPTED, sessionId)
                }
            }

            DjiMicCaptureState.REBUILDING -> {
                currentSessionId = sessionId
                pendingStartCallbacks.add(callback)
            }

            DjiMicCaptureState.IDLE -> {
                currentSessionId = sessionId
                currentInputUid = inputUid
                pendingStop = false
                reconnectAttempted = false
                pendingStartCallbacks.add(callback)
                enterState(DjiMicCaptureState.STARTING)
                beginStartSequence(inputUid)
            }
        }
    }

    private fun handleStop(callback: (Result<Unit>) -> Unit) {
        when (state) {
            DjiMicCaptureState.IDLE -> callback(Result.success(Unit))

            DjiMicCaptureState.STARTING -> {
                pendingStop = true
                pendingStopCallbacks.add(callback)
            }

            DjiMicCaptureState.RUNNING, DjiMicCaptureState.INTERRUPTED, DjiMicCaptureState.REBUILDING -> {
                pendingStopCallbacks.add(callback)
                finishStop()
            }
        }
    }

    // MARK: - Bring-up

    private fun beginStartSequence(inputUid: String) {
        val missing = missingPermission()
        if (missing != null) {
            failStart("permission_denied", "$missing is not granted")
            return
        }

        route.connect(
            uid = inputUid,
            onResult = { ok -> onConnectResult(inputUid, ok) },
            onRouteLost = { onRouteLost() },
        )
    }

    private fun missingPermission(): String? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            ContextCompat.checkSelfPermission(application, Manifest.permission.BLUETOOTH_CONNECT) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return "BLUETOOTH_CONNECT"
        }
        if (ContextCompat.checkSelfPermission(application, Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return "RECORD_AUDIO"
        }
        return null
    }

    private fun onConnectResult(inputUid: String, routed: Boolean) {
        if (state != DjiMicCaptureState.STARTING && state != DjiMicCaptureState.REBUILDING) return // superseded
        if (pendingStop) {
            route.disconnect()
            failStart("start_aborted", "stop() superseded start()")
            return
        }
        if (!routed) {
            failStart("input_unavailable", "could not route audio to input $inputUid")
            return
        }

        val epoch = emitter.generation.advance()
        val sid = currentSessionId
        val newEngine = DjiMicCaptureEngine(
            // emitFrame hops to main itself (see DjiMicEventEmitter) — no audioExecutor
            // hand-off needed here since, unlike PhoneMicController, there is no
            // batch-mode encode/write work to serialize before the main hop.
            onChunk = { chunk -> emitter.emitFrame(chunk, epoch, sid) },
            onReadError = { code -> mainHandler.post { handleReadError(code) } },
        )
        try {
            newEngine.start()
        } catch (t: Throwable) {
            Log.w(TAG, "engine.start() failed", t)
            newEngine.teardown()
            route.disconnect()
            failStart("engine_start_failed", t.message ?: "engine failed to start")
            return
        }
        engine = newEngine
        enterRunning()
    }

    private fun enterRunning() {
        reconnectAttempted = false
        enterState(DjiMicCaptureState.RUNNING)
        resolvePendingStarts(Result.success(Unit))
        if (pendingStop) finishStop()
    }

    private fun failStart(code: String, message: String) {
        Log.w(TAG, "start failed: $code ($message)")
        emitter.generation.invalidate()
        engine?.teardown()
        engine = null
        pendingStop = false
        state = DjiMicCaptureState.IDLE
        resolvePendingStarts(Result.failure(DjiMicPigeonError(code, message, null)))
        resolvePendingStops(Result.success(Unit))
        emitter.emitState(DjiMicCaptureState.IDLE, currentSessionId)
    }

    // MARK: - Runtime interruption / recovery

    /** Fired by the route when a previously-successful connection drops on its own. */
    // Explicit Unit return type: onRouteLost() calls itself (indirectly, via the
    // `onRouteLost = { onRouteLost() }` reconnect callback below), and Kotlin's
    // type inference cannot resolve a self-referential call through an inferred
    // return type.
    private fun onRouteLost(): Unit = runOnMain {
        if (state != DjiMicCaptureState.RUNNING && state != DjiMicCaptureState.INTERRUPTED) return@runOnMain
        emitter.emitError("route_lost", "Bluetooth communication device disconnected", currentSessionId)
        engine?.teardown()
        engine = null
        emitter.generation.invalidate()
        enterState(DjiMicCaptureState.INTERRUPTED)

        if (reconnectAttempted) {
            // One reconnect already failed this session; don't loop forever.
            giveUpAfterInterruption()
            return@runOnMain
        }
        reconnectAttempted = true
        enterState(DjiMicCaptureState.REBUILDING)
        val uid = currentInputUid
        if (uid == null) {
            giveUpAfterInterruption()
            return@runOnMain
        }
        route.connect(
            uid = uid,
            onResult = { ok -> onConnectResult(uid, ok) },
            onRouteLost = { onRouteLost() },
        )
    }

    private fun giveUpAfterInterruption() {
        emitter.emitError("route_lost", "reconnect attempt failed; capture stopped", currentSessionId)
        route.disconnect()
        state = DjiMicCaptureState.IDLE
        emitter.emitState(DjiMicCaptureState.IDLE, currentSessionId)
        resolvePendingStops(Result.success(Unit))
    }

    private fun handleReadError(code: Int) {
        if (state != DjiMicCaptureState.RUNNING) return
        Log.w(TAG, "read error: $code")
        onRouteLost()
    }

    // MARK: - Stop

    private fun finishStop() {
        pendingStop = false
        engine?.teardown()
        engine = null
        emitter.generation.invalidate()
        route.disconnect()
        state = DjiMicCaptureState.IDLE
        emitter.emitState(DjiMicCaptureState.IDLE, currentSessionId)
        resolvePendingStops(Result.success(Unit))
    }

    // MARK: - Helpers

    private fun enterState(newState: DjiMicCaptureState) {
        state = newState
        emitter.emitState(newState, currentSessionId)
    }

    private fun resolvePendingStarts(result: Result<Unit>) {
        val callbacks = pendingStartCallbacks.toList()
        pendingStartCallbacks.clear()
        callbacks.forEach { it(result) }
    }

    private fun resolvePendingStops(result: Result<Unit>) {
        val callbacks = pendingStopCallbacks.toList()
        pendingStopCallbacks.clear()
        callbacks.forEach { it(result) }
    }

    private fun runOnMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else mainHandler.post { block() }
    }

    companion object {
        private const val TAG = "DjiMic.Controller"

        @Volatile
        private var _instance: DjiMicController? = null

        val instance: DjiMicController
            get() = _instance ?: throw IllegalStateException("DjiMicController not initialized")

        val isInitialized: Boolean
            get() = _instance != null

        fun initialize(application: Application) {
            if (_instance == null) {
                synchronized(this) {
                    if (_instance == null) {
                        _instance = DjiMicController(application)
                    }
                }
            }
        }
    }
}
