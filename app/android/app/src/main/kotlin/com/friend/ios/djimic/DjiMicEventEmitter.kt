package com.friend.ios.djimic

import android.os.Handler

/**
 * Monotonic capture epoch shared between the controller (writer) and the
 * event emitter (reader) — the DJI-mic peer of
 * [com.friend.ios.phonemic.PhoneMicGeneration]. Every frame carries the epoch
 * it was captured under; the emitter drops any frame whose epoch is no
 * longer the active one, so no frame is delivered after stop() and none
 * crosses a rebuild.
 *
 * All three methods AND the emitter's read of the epoch run on the main
 * thread only, so the fields are plain `Long` — no atomics or locks needed.
 */
class DjiMicGeneration {
    private var counter: Long = 0L
    private var active: Long = 0L

    fun advance(): Long {
        counter += 1L
        active = counter
        return counter
    }

    fun invalidate() {
        active = 0L
    }

    fun matches(epoch: Long): Boolean = epoch != 0L && active == epoch
}

/**
 * The only object that touches [DjiMicFlutterApi] — the DJI-mic peer of
 * [com.friend.ios.phonemic.PhoneMicEventEmitter]. Serializes every outbound
 * call onto the main thread and epoch-gates frames; see that class's doc for
 * why the epoch check must happen inside the posted runnable, and why every
 * emission (not just frames) is an unconditional post rather than an
 * inline-when-already-on-main fast path.
 */
class DjiMicEventEmitter(private val mainHandler: Handler) {
    val generation = DjiMicGeneration()

    private var api: DjiMicFlutterApi? = null

    fun bind(api: DjiMicFlutterApi) {
        this.api = api
    }

    fun unbind() {
        this.api = null
    }

    fun emitFrame(data: ByteArray, epoch: Long, sessionId: Long) {
        mainHandler.post {
            if (!generation.matches(epoch)) return@post
            api?.onAudioFrame(data, sessionId) {}
        }
    }

    fun emitState(state: DjiMicCaptureState, sessionId: Long) {
        mainHandler.post { api?.onStateChanged(state, sessionId) {} }
    }

    fun emitError(code: String, message: String, sessionId: Long) {
        mainHandler.post { api?.onCaptureError(code, message, sessionId) {} }
    }
}
