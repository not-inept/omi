package com.friend.ios.djimic

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.SystemClock
import android.util.Log

/**
 * Owns one [AudioRecord] routed to the current Bluetooth communication device
 * and one dedicated read thread, resampling to 16kHz mono PCM16 before
 * handing chunks back. Structurally mirrors [com.friend.ios.phonemic.PhoneMicCaptureEngine]
 * (same read-loop/teardown discipline) — read that class first if you're
 * touching this one; it documents the threading and shutdown-ordering
 * invariants this engine also relies on.
 *
 * One real difference from the phone-mic engine: [MediaRecorder.AudioSource.VOICE_COMMUNICATION]
 * over a Bluetooth SCO route is, on some devices, restricted to the link's
 * actual negotiated rate (8kHz CVSD narrowband is the one every HFP device
 * must support; 16kHz mSBC wideband is common but not guaranteed) — unlike
 * [MediaRecorder.AudioSource.MIC], which Android will resample from any HAL
 * rate transparently. [start] tries 16kHz first (cheapest — no resampling
 * needed) and falls back to 8kHz + [DjiMicResampler] only if 16kHz
 * initialization fails. Which path a given device/transmitter combination
 * actually takes has not been verified against real hardware — see the repo
 * plan's "cannot verify" note.
 *
 * [onChunk] and [onReadError] are invoked on the "DjiMicRead" thread; hopping
 * to whatever thread the emitter needs is the controller's responsibility.
 */
@SuppressLint("MissingPermission") // Controller gates on BLUETOOTH_CONNECT/RECORD_AUDIO before start().
class DjiMicCaptureEngine(
    private val onChunk: (ByteArray) -> Unit,
    private val onReadError: (Int) -> Unit,
) {
    companion object {
        private const val TAG = "DjiMic"
        private const val PREFERRED_RATE = 16000
        private const val FALLBACK_RATE = 8000
        private const val CHUNK_MS = 80
        private const val THREAD_JOIN_TIMEOUT_MS = 1000L
    }

    /** Uptime of the last successful read; mirrors PhoneMicCaptureEngine's liveness
     *  timestamp (see that class for how a stall would be detected upstream). */
    @Volatile
    var lastDataUptimeMs: Long = 0L
        private set

    /** The input rate capture actually initialized at (16000 or 8000), valid after
     *  [start] succeeds. Exposed for logging/diagnostics, not correctness — every
     *  emitted chunk is always 16kHz regardless of this value. */
    @Volatile
    var inputSampleRate: Int = 0
        private set

    private var record: AudioRecord? = null
    private var readThread: Thread? = null
    private var resampler: DjiMicResampler? = null
    private var inputChunkBytes: Int = 0

    @Volatile
    private var stopping = false

    /** Builds and starts the AudioRecord (16kHz direct, or 8kHz + resample fallback)
     *  and spins up the read thread. Throws [IllegalStateException] on any bring-up
     *  failure; the controller maps a throw to `engine_start_failed`. */
    fun start() {
        val record = buildRecord(PREFERRED_RATE) ?: buildRecord(FALLBACK_RATE)
            ?: throw IllegalStateException("AudioRecord failed to initialize at both $PREFERRED_RATE and $FALLBACK_RATE Hz")

        this.record = record
        this.inputSampleRate = record.sampleRate
        this.resampler = if (record.sampleRate == DjiMicResampler.OUTPUT_RATE) {
            null
        } else {
            DjiMicResampler(record.sampleRate)
        }
        this.inputChunkBytes = (record.sampleRate * CHUNK_MS / 1000) * 2 // 16-bit mono
        this.lastDataUptimeMs = SystemClock.uptimeMillis()

        record.startRecording()
        if (record.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            val recState = record.recordingState
            teardown()
            throw IllegalStateException("AudioRecord did not enter RECORDING (recordingState=$recState)")
        }

        Log.i(TAG, "start: inputRate=${record.sampleRate} chunkBytes=$inputChunkBytes resampling=${resampler != null}")
        val thread = Thread({ readLoop(record) }, "DjiMicRead")
        this.readThread = thread
        thread.start()
    }

    /** One AudioRecord.Builder attempt at [rate]; returns null (never throws) on any
     *  failure to initialize so [start] can fall back to the next candidate rate. */
    private fun buildRecord(rate: Int): AudioRecord? {
        val minBuf = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (minBuf <= 0) {
            Log.w(TAG, "buildRecord($rate): getMinBufferSize failed: $minBuf")
            return null
        }
        // Same headroom reasoning as PhoneMicCaptureEngine: floor at 4 chunks so the
        // ring buffer always has multi-chunk headroom regardless of device minimum.
        val chunkBytes = (rate * CHUNK_MS / 1000) * 2
        val bufferSize = maxOf(2 * minBuf, 4 * chunkBytes)

        val record = try {
            AudioRecord.Builder()
                .setAudioSource(MediaRecorder.AudioSource.VOICE_COMMUNICATION)
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setSampleRate(rate)
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                        .build()
                )
                .setBufferSizeInBytes(bufferSize)
                .build()
        } catch (e: Exception) {
            Log.w(TAG, "buildRecord($rate): construction threw: ${e.message}")
            return null
        }

        if (record.state != AudioRecord.STATE_INITIALIZED) {
            Log.w(TAG, "buildRecord($rate): not initialized (state=${record.state})")
            record.release()
            return null
        }
        return record
    }

    private fun readLoop(record: AudioRecord) {
        val buf = ByteArray(inputChunkBytes)
        while (true) {
            val n = try {
                record.read(buf, 0, inputChunkBytes)
            } catch (e: Throwable) {
                if (stopping) return
                Log.e(TAG, "read() threw; reporting as read error", e)
                onReadError(AudioRecord.ERROR)
                return
            }
            if (n > 0) {
                lastDataUptimeMs = SystemClock.uptimeMillis()
                emit(buf, n)
                continue
            }
            if (stopping) return
            if (n < 0) {
                onReadError(n)
                return
            }
            // n == 0 outside stop: spurious wake (rare); keep reading. See
            // PhoneMicCaptureEngine's readLoop for why an in-loop stall counter
            // would be dead code here too.
        }
    }

    private fun emit(buf: ByteArray, n: Int) {
        val resampler = this.resampler
        if (resampler == null) {
            onChunk(if (n == buf.size) buf.copyOf() else buf.copyOf(n))
            return
        }
        val shorts = DjiMicPcm.bytesToShortsLE(buf, n)
        val resampled = resampler.process(shorts)
        if (resampled.isEmpty()) return
        onChunk(DjiMicPcm.shortsToBytesLE(resampled))
    }

    /** Idempotent, defensive teardown — same fixed order and reasoning as
     *  PhoneMicCaptureEngine.teardown(): raise the stop flag, stop() to unblock the
     *  parked read(), join() the read thread, release() the record, drop refs. */
    fun teardown() {
        stopping = true
        val rec = record
        val thread = readThread
        try {
            rec?.stop()
        } catch (e: Exception) {
            Log.w(TAG, "teardown: stop() failed: ${e.message}")
        }
        try {
            thread?.join(THREAD_JOIN_TIMEOUT_MS)
        } catch (e: InterruptedException) {
            Log.w(TAG, "teardown: join interrupted")
            Thread.currentThread().interrupt()
        }
        try {
            rec?.release()
        } catch (e: Exception) {
            Log.w(TAG, "teardown: release() failed: ${e.message}")
        }
        record = null
        readThread = null
        resampler = null
    }
}
