package com.friend.ios.djimic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The uid is what survives an app restart and a replug, so these tests are
 * about durability, not formatting: a Bluetooth uid must stay byte-identical
 * to what earlier builds stored, and a USB uid must still find its receiver
 * after Android has renumbered every audio device.
 */
class DjiMicInputUidTest {

    @Test
    fun `a bare mac address is not a usb uid`() {
        assertFalse(DjiMicInputUid.isUsb("A1:B2:C3:D4:E5:F6"))
        assertNull(DjiMicInputUid.usbDeviceId("A1:B2:C3:D4:E5:F6"))
        assertNull(DjiMicInputUid.usbProductName("A1:B2:C3:D4:E5:F6"))
    }

    @Test
    fun `usb uid round-trips id and product name`() {
        val uid = DjiMicInputUid.encodeUsb(37, "DJI MIC 3 RX")
        assertEquals("usb:37:DJI MIC 3 RX", uid)
        assertTrue(DjiMicInputUid.isUsb(uid))
        assertEquals(37, DjiMicInputUid.usbDeviceId(uid))
        assertEquals("DJI MIC 3 RX", DjiMicInputUid.usbProductName(uid))
    }

    @Test
    fun `a product name containing a colon survives the round trip`() {
        val uid = DjiMicInputUid.encodeUsb(4, "Mic 3: RX")
        assertEquals(4, DjiMicInputUid.usbDeviceId(uid))
        assertEquals("Mic 3: RX", DjiMicInputUid.usbProductName(uid))
    }

    @Test
    fun `exact id wins over a same-named sibling`() {
        val uid = DjiMicInputUid.encodeUsb(37, "DJI MIC 3 RX")
        val match = DjiMicInputUid.matchUsb(uid, listOf(12 to "DJI MIC 3 RX", 37 to "DJI MIC 3 RX"))
        assertEquals(37 to "DJI MIC 3 RX", match)
    }

    @Test
    fun `after a replug renumbers everything the product name still matches`() {
        val uid = DjiMicInputUid.encodeUsb(37, "DJI MIC 3 RX")
        // Same receiver, new id: this is the whole reason the name is in the uid.
        val match = DjiMicInputUid.matchUsb(uid, listOf(91 to "USB-C to 3.5mm", 92 to "DJI MIC 3 RX"))
        assertEquals(92 to "DJI MIC 3 RX", match)
    }

    @Test
    fun `nothing plugged in matches nothing`() {
        val uid = DjiMicInputUid.encodeUsb(37, "DJI MIC 3 RX")
        assertNull(DjiMicInputUid.matchUsb(uid, emptyList()))
        assertNull(DjiMicInputUid.matchUsb(uid, listOf(3 to "Some Other Interface")))
    }

    @Test
    fun `a bluetooth uid never matches a usb candidate`() {
        assertNull(DjiMicInputUid.matchUsb("A1:B2:C3:D4:E5:F6", listOf(37 to "DJI MIC 3 RX")))
    }

    @Test
    fun `a corrupted persisted uid degrades instead of throwing`() {
        // Hand-edited or truncated values reach here through restored device
        // state; the contract is "no match", never a crash on launch.
        assertNull(DjiMicInputUid.usbDeviceId("usb:notanumber:Thing"))
        assertNull(DjiMicInputUid.usbProductName("usb:37"))
        assertNull(DjiMicInputUid.usbProductName("usb:37:"))
        assertNull(DjiMicInputUid.matchUsb("usb:", listOf(37 to "DJI MIC 3 RX")))
        // Id unparseable but the name still present: the name carries it.
        assertEquals(
            37 to "DJI MIC 3 RX",
            DjiMicInputUid.matchUsb("usb:notanumber:DJI MIC 3 RX", listOf(37 to "DJI MIC 3 RX")),
        )
    }
}
