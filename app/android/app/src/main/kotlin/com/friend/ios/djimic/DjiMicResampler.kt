package com.friend.ios.djimic

import kotlin.math.floor

/**
 * Streaming linear-interpolation resampler from an arbitrary input rate to a
 * fixed output rate, operating on mono 16-bit PCM samples.
 *
 * Bluetooth SCO negotiates 8kHz (CVSD/narrowband) or 16kHz (mSBC/wideband)
 * and this app does not control which the link picks. [DjiMicCaptureEngine]
 * runs every captured chunk through this before it reaches Dart, so
 * PhoneMicSource's fixed 320-byte/16kHz framing assumption downstream
 * (lib/services/audio_sources/phone_mic_source.dart) holds regardless of the
 * negotiated codec.
 *
 * Streaming-safe: [position] carries the fractional remainder across calls,
 * so interpolation stays continuous across chunk boundaries. The one
 * approximation is at the trailing edge of each chunk: the interpolation
 * target just past the last sample clamps to that last sample rather than
 * blending with the next chunk's first sample (avoiding cross-chunk sample
 * buffering) — this affects at most one output sample per chunk, negligible
 * for speech at the chunk sizes this engine uses (tens of milliseconds).
 */
class DjiMicResampler(private val inputRate: Int, private val outputRate: Int = OUTPUT_RATE) {
    companion object {
        const val OUTPUT_RATE = 16000
    }

    init {
        require(inputRate > 0) { "inputRate must be positive" }
        require(outputRate > 0) { "outputRate must be positive" }
    }

    /** True when no resampling is needed; [process] returns its input unchanged. */
    val isPassthrough: Boolean = inputRate == outputRate

    private var position: Double = 0.0

    /** Resamples one chunk of mono PCM16 samples. Call in arrival order — this
     *  resampler is stateful across calls (see class doc). */
    fun process(input: ShortArray): ShortArray {
        if (isPassthrough || input.isEmpty()) return input

        val ratio = inputRate.toDouble() / outputRate.toDouble()
        val output = ArrayList<Short>((input.size / ratio).toInt() + 2)

        while (position < input.size) {
            val i0 = floor(position).toInt()
            val frac = position - i0
            val a = input[i0]
            val b = if (i0 + 1 < input.size) input[i0 + 1] else input[i0]
            val value = a + (b - a) * frac
            output.add(value.toInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort())
            position += ratio
        }

        position -= input.size
        return output.toShortArray()
    }
}

/** Little-endian PCM16 byte <-> short conversions shared by the capture engine and tests. */
object DjiMicPcm {
    fun bytesToShortsLE(bytes: ByteArray, length: Int = bytes.size): ShortArray {
        val sampleCount = length / 2
        val out = ShortArray(sampleCount)
        for (i in 0 until sampleCount) {
            val lo = bytes[i * 2].toInt() and 0xFF
            val hi = bytes[i * 2 + 1].toInt()
            out[i] = ((hi shl 8) or lo).toShort()
        }
        return out
    }

    fun shortsToBytesLE(shorts: ShortArray): ByteArray {
        val out = ByteArray(shorts.size * 2)
        for (i in shorts.indices) {
            val v = shorts[i].toInt()
            out[i * 2] = (v and 0xFF).toByte()
            out[i * 2 + 1] = ((v shr 8) and 0xFF).toByte()
        }
        return out
    }
}
