import AVFoundation
import Foundation

/// Captures a DJI Mic 3 transmitter paired over Bluetooth (HFP), or the
/// receiver plugged into USB-C, through AVAudioSession.
///
/// DJI Mic 3 has no SDK and no BLE audio characteristic: a transmitter in
/// Bluetooth mode is an ordinary hands-free headset to iOS, and the receiver
/// on USB-C is a USB audio class interface. Both are plain AVAudioSession
/// input ports (`.bluetoothHFP` and `.usbAudio`), so one engine covers both.
///
/// The shape is RayBanMetaAudioCapture's, which already carries the HFP
/// route on iOS; this one differs by accepting a USB port, requiring an
/// explicit input, and reporting route loss as a distinct code so the Dart
/// side can tell "transmitter powered off" from "phone call".
///
/// Output is PCM16 little-endian mono at 16 kHz regardless of what the link
/// negotiated (8 kHz narrowband SCO, 16 kHz mSBC, or 48 kHz over USB).
final class DjiMicAudioCapture {
    static let targetSampleRate: Double = 16000.0

    /// Port types this engine will route to, and the Pigeon kind each maps to.
    static func kind(of port: AVAudioSessionPortDescription) -> BluetoothMicInputKind? {
        switch port.portType {
        case .bluetoothHFP: return .bluetooth
        case .usbAudio: return .usb
        default: return nil
        }
    }

    /// Inputs the OS currently offers of either kind. Unfiltered on purpose:
    /// there is no DJI discovery protocol and a renamed transmitter must
    /// still be findable; the Dart list sorts a likely DJI first.
    static func availableInputs() -> [BluetoothMicInput] {
        let session = AVAudioSession.sharedInstance()
        return (session.availableInputs ?? []).compactMap { port in
            guard let kind = kind(of: port) else { return nil }
            return BluetoothMicInput(uid: port.uid, name: port.portName, kind: kind)
        }
    }

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var isRunning = false
    private var targetInputUid: String?

    /// PCM16 LE mono frames at targetSampleRate.
    var onFrame: ((Data) -> Void)?
    /// The selected input stopped being the active route (powered off, out
    /// of range, unplugged). The engine has already been stopped.
    var onRouteLost: ((String) -> Void)?
    /// A system interruption (phone call, Siri) began; engine stopped.
    var onInterrupted: ((String) -> Void)?
    /// The interruption ended and the system says we may resume.
    var onInterruptionEnded: (() -> Void)?
    var onError: ((String, String) -> Void)?

    init() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleRouteChange(_:)),
                           name: AVAudioSession.routeChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(handleInterruption(_:)),
                           name: AVAudioSession.interruptionNotification, object: nil)
        center.addObserver(self, selector: #selector(handleEngineConfigurationChange(_:)),
                           name: .AVAudioEngineConfigurationChange, object: engine)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var running: Bool { isRunning }

    var isSelectedRouteActive: Bool {
        guard let uid = targetInputUid else { return false }
        return AVAudioSession.sharedInstance().currentRoute.inputs.contains {
            $0.uid == uid && Self.kind(of: $0) != nil
        }
    }

    enum StartFailure: Error {
        case inputUnavailable
        case routeFailed(String)
        case engineStartFailed(String)
    }

    func start(inputUid: String) throws {
        guard !isRunning else { return }

        let session = AVAudioSession.sharedInstance()
        guard let port = (session.availableInputs ?? []).first(where: { $0.uid == inputUid }),
              Self.kind(of: port) != nil
        else {
            throw StartFailure.inputUnavailable
        }

        do {
            // .allowBluetoothHFP is what makes a paired transmitter appear as a
            // route at all; USB needs nothing extra. .default mode keeps iOS
            // from forcing the voice-chat processing chain on a 48 kHz USB input.
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
            try session.setPreferredInput(port)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw StartFailure.routeFailed(error.localizedDescription)
        }
        targetInputUid = inputUid

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            targetInputUid = nil
            throw StartFailure.engineStartFailed("audio input format unavailable")
        }
        guard
            let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                             sampleRate: Self.targetSampleRate,
                                             channels: 1, interleaved: true),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            targetInputUid = nil
            throw StartFailure.engineStartFailed("could not build PCM16/16 kHz converter")
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.convertAndEmit(buffer: buffer, outputFormat: outputFormat)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.converter = nil
            targetInputUid = nil
            throw StartFailure.engineStartFailed(error.localizedDescription)
        }
        isRunning = true

        // Bluetooth takes a moment to actually switch the route; if after the
        // settle window the selected port still is not the active input, the
        // tap is recording the phone mic, which is the one thing this engine
        // must never do silently.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.isRunning, !self.isSelectedRouteActive else { return }
            self.stop()
            self.onRouteLost?("selected input did not become the active route")
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        isRunning = false
        targetInputUid = nil
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // Another component may hold the session; non-fatal.
        }
    }

    private func convertAndEmit(buffer: AVAudioPCMBuffer, outputFormat: AVAudioFormat) {
        guard let converter else { return }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var fed = false
        var conversionError: NSError?
        converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let conversionError {
            onError?("audio_convert", conversionError.localizedDescription)
            return
        }
        guard outBuffer.frameLength > 0, let channel = outBuffer.int16ChannelData?[0] else { return }
        onFrame?(Data(bytes: channel, count: Int(outBuffer.frameLength) * MemoryLayout<Int16>.size))
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard isRunning, !isSelectedRouteActive else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning, !self.isSelectedRouteActive else { return }
            self.stop()
            self.onRouteLost?("input disconnected during capture")
        }
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }
        switch type {
        case .began:
            guard isRunning else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRunning else { return }
                self.stop()
                self.onInterrupted?("audio interrupted by a call or another app")
            }
        case .ended:
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                DispatchQueue.main.async { [weak self] in self?.onInterruptionEnded?() }
            }
        @unknown default:
            break
        }
    }

    @objc private func handleEngineConfigurationChange(_ notification: Notification) {
        guard isRunning else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning else { return }
            // The tap is frozen at the old hardware format; continuing would
            // emit garbage. Treat it like a route loss and let the controller
            // decide whether to rebuild.
            self.stop()
            self.onRouteLost?("audio input configuration changed")
        }
    }
}
