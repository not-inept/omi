package com.friend.ios.djimic

/**
 * Identity tokens for the two kinds of input [DjiMicBluetoothRoute] can list.
 *
 * A uid is persisted on the Dart side as `BtDevice.id` and handed back on a
 * later launch to reconnect, so its format is a compatibility surface: it must
 * survive an app restart, a replug, and an upgrade of this app.
 *
 * **Bluetooth** inputs keep the bare MAC address they have always used. It is
 * stable across reboots and replugs, and leaving it unprefixed keeps every
 * device paired before USB support existed working untouched.
 *
 * **USB** inputs have no address at all — `AudioDeviceInfo.getAddress()` is
 * empty for USB audio class devices — and their numeric `AudioDeviceInfo.id`
 * is handed out fresh on every enumeration, so it is useless as durable
 * identity. The token therefore carries both: the id, which makes rematching
 * exact within one plug-in session, and the product name, which is what makes
 * it work again after the receiver is unplugged and plugged back in.
 *
 *     usb:37:DJI MIC 3 RX
 *     └─┬ └┬ └────┬─────
 *       │  │      product name (may itself contain ':')
 *       │  AudioDeviceInfo.id at the time the uid was minted
 *       kind prefix
 *
 * Pure string logic, deliberately free of any Android dependency so it is
 * covered by a plain JVM unit test rather than needing a device.
 */
object DjiMicInputUid {
    const val USB_PREFIX = "usb:"

    /** True when [uid] names a USB audio input rather than a Bluetooth one. */
    fun isUsb(uid: String): Boolean = uid.startsWith(USB_PREFIX)

    /** Mints the durable token for a USB input. [productName] is stored as-is
     *  (including any ':'), which is why only the first two segments are ever
     *  split off when reading it back. */
    fun encodeUsb(deviceId: Int, productName: String): String = "$USB_PREFIX$deviceId:$productName"

    /** The `AudioDeviceInfo.id` a USB uid was minted with, or null if [uid] is
     *  not a USB uid or its id segment is not an integer (a corrupted or
     *  hand-edited persisted value must not crash device restore). */
    fun usbDeviceId(uid: String): Int? {
        if (!isUsb(uid)) return null
        val rest = uid.removePrefix(USB_PREFIX)
        val sep = rest.indexOf(':')
        val idPart = if (sep < 0) rest else rest.substring(0, sep)
        return idPart.toIntOrNull()
    }

    /** The product name a USB uid was minted with, or null when [uid] is not a
     *  USB uid or carries no name segment. */
    fun usbProductName(uid: String): String? {
        if (!isUsb(uid)) return null
        val rest = uid.removePrefix(USB_PREFIX)
        val sep = rest.indexOf(':')
        if (sep < 0 || sep == rest.length - 1) return null
        return rest.substring(sep + 1)
    }

    /**
     * Picks the current input a stored USB [uid] refers to, from [candidates]
     * given as (deviceId, productName) pairs in the order the platform listed
     * them.
     *
     * Exact id first: within one plug-in session that is unambiguous, and it
     * distinguishes two identical receivers plugged in at once. Product name
     * second: after a replug the id has changed and the name is all that is
     * left to go on. Returning the first name match is a deliberate choice —
     * with two identically named receivers and no ids in common there is
     * nothing left to tell them apart, and refusing to route at all would be
     * worse than routing to one of them.
     */
    fun matchUsb(uid: String, candidates: List<Pair<Int, String>>): Pair<Int, String>? {
        if (!isUsb(uid)) return null
        val wantedId = usbDeviceId(uid)
        if (wantedId != null) {
            candidates.firstOrNull { it.first == wantedId }?.let { return it }
        }
        val wantedName = usbProductName(uid) ?: return null
        if (wantedName.isEmpty()) return null
        return candidates.firstOrNull { it.second == wantedName }
    }
}
