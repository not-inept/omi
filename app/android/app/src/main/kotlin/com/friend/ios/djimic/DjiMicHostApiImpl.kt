package com.friend.ios.djimic

/**
 * Pigeon adapter: forwards host-API calls straight to the controller. No
 * logic lives here — the controller confines itself to the main thread and
 * resolves the Pigeon callbacks itself. Mirrors
 * [com.friend.ios.phonemic.PhoneMicHostApiImpl].
 */
class DjiMicHostApiImpl(private val controller: DjiMicController) : DjiMicHostApi {
    override fun getAvailableInputs(callback: (Result<List<BluetoothMicInput>>) -> Unit) =
        controller.getAvailableInputs(callback)

    override fun start(inputUid: String, sessionId: Long, callback: (Result<Unit>) -> Unit) =
        controller.start(inputUid, sessionId, callback)

    override fun stop(callback: (Result<Unit>) -> Unit) =
        controller.stop(callback)

    override fun isRecording(): Boolean = controller.isRecording
}
