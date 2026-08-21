package com.friend.ios.djimic

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.roundToInt
import kotlin.math.sin

class DjiMicResamplerTest {
    @Test
    fun passthroughAt16kHzReturnsInputUnchanged() {
        val resampler = DjiMicResampler(16000)
        assertTrue(resampler.isPassthrough)
        val input = shortArrayOf(1, -2, 3, -4, 5)
        assertArrayEquals(input, resampler.process(input))
    }

    @Test
    fun passthroughReturnsEmptyForEmptyInput() {
        val resampler = DjiMicResampler(16000)
        assertEquals(0, resampler.process(ShortArray(0)).size)
    }

    @Test
    fun upsampleFrom8kHzDoublesSampleCountOverManyChunks() {
        // Chunk-boundary rounding means any single chunk can be off by one, but the
        // long-run output/input ratio must converge to exactly 2x (16000/8000).
        val resampler = DjiMicResampler(8000)
        assertTrue(!resampler.isPassthrough)

        var totalIn = 0
        var totalOut = 0
        val chunk = ShortArray(640) { 0 } // 80ms @ 8kHz
        repeat(50) {
            totalIn += chunk.size
            totalOut += resampler.process(chunk).size
        }

        val ratio = totalOut.toDouble() / totalIn.toDouble()
        assertTrue("expected ~2.0x, got $ratio", ratio in 1.98..2.02)
    }

    @Test
    fun upsampleInterpolatesBetweenKnownSamples() {
        // A single 8kHz chunk [0, 100]: the resampler should produce 4 output
        // samples at input-time positions 0, 0.5, 1.0, 1.5 -> values 0, 50, 100, 100
        // (the last clamps to the final input sample; see class doc).
        val resampler = DjiMicResampler(8000)
        val result = resampler.process(shortArrayOf(0, 100))
        assertArrayEquals(shortArrayOf(0, 50, 100, 100), result)
    }

    @Test
    fun upsamplePreservesToneFrequencyRoughly() {
        // A 1kHz tone sampled at 8kHz, resampled to 16kHz, should still look like a
        // ~1kHz tone: count zero-crossings and compare against the expected count for
        // the resampled duration instead of asserting exact sample values.
        val inputRate = 8000
        val toneHz = 1000.0
        val durationSec = 0.1 // 100ms
        val inputSamples = ShortArray((inputRate * durationSec).toInt()) { i ->
            (sin(2.0 * PI * toneHz * i / inputRate) * 10000).roundToInt().toShort()
        }

        val resampler = DjiMicResampler(inputRate)
        val output = resampler.process(inputSamples)

        assertEquals((inputSamples.size * 2), output.size)

        var crossings = 0
        for (i in 1 until output.size) {
            if ((output[i - 1] < 0) != (output[i] < 0)) crossings++
        }
        // A 1kHz tone over 100ms is 100 cycles (1000Hz * 0.1s), 2 zero crossings each.
        assertTrue("expected ~200 zero crossings, got $crossings", crossings in 190..210)
    }

    @Test
    fun pcmRoundTripPreservesSamples() {
        val samples = shortArrayOf(0, 1, -1, 32767, -32768, 12345, -12345)
        val bytes = DjiMicPcm.shortsToBytesLE(samples)
        assertEquals(samples.size * 2, bytes.size)
        val roundTripped = DjiMicPcm.bytesToShortsLE(bytes)
        assertArrayEquals(samples, roundTripped)
    }

    @Test
    fun bytesToShortsLeHonorsExplicitLength() {
        // A partial read (n < buffer.size) must only convert the valid prefix.
        val bytes = byteArrayOf(0x01, 0x00, 0x02, 0x00, 0x7F, 0x7F, 0x7F, 0x7F)
        val shorts = DjiMicPcm.bytesToShortsLE(bytes, length = 4)
        assertArrayEquals(shortArrayOf(1, 2), shorts)
    }
}
