import AVFoundation
import Flutter
import Foundation

/// iOS side of the DJI Mic Pigeon contract (lib/dji_mic_interface.dart).
///
/// Mirrors the Android DjiMicController's state machine: idle → starting →
/// running; a lost route or an interruption goes to `interrupted`, one
/// rebuild is attempted (`rebuilding`), and if that fails the session ends
/// in `idle` with a `route_lost` / `resume_failed` error. Every event
/// carries the Dart-minted sessionId; Dart drops events for stale sessions.
///
/// All state is touched on the main queue.
final class DjiMicHostApiImpl: DjiMicHostApi {
    private let flutterApi: DjiMicFlutterApi
    private let capture = DjiMicAudioCapture()

    private var state: DjiMicCaptureState = .idle
    private var sessionId: Int64 = 0
    private var inputUid: String?

    init(flutterApi: DjiMicFlutterApi) {
        self.flutterApi = flutterApi

        capture.onFrame = { [weak self] data in
            guard let self else { return }
            let sid = self.sessionId
            DispatchQueue.main.async {
                self.flutterApi.onAudioFrame(pcm16leMono16k: FlutterStandardTypedData(bytes: data), sessionId: sid) { _ in }
            }
        }
        capture.onRouteLost = { [weak self] message in
            guard let self, self.state == .running || self.state == .interrupted else { return }
            self.emitError("route_lost", message)
            self.enter(.interrupted)
            self.scheduleRebuild(after: 1.5, failureCode: "rebuild_failed")
        }
        capture.onInterrupted = { [weak self] message in
            guard let self, self.state == .running else { return }
            self.emitError("interrupted", message)
            self.enter(.interrupted)
        }
        capture.onInterruptionEnded = { [weak self] in
            guard let self, self.state == .interrupted else { return }
            self.scheduleRebuild(after: 0, failureCode: "resume_failed")
        }
        capture.onError = { [weak self] code, message in
            self?.emitError(code, message)
        }
    }

    // MARK: DjiMicHostApi

    func getAvailableInputs(completion: @escaping (Result<[BluetoothMicInput], Error>) -> Void) {
        DispatchQueue.main.async {
            // Listing needs the session to know Bluetooth is allowed, or HFP
            // ports are omitted from availableInputs. Category only; not activated.
            let session = AVAudioSession.sharedInstance()
            if !session.categoryOptions.contains(.allowBluetoothHFP) || session.category != .playAndRecord {
                try? session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
            }
            completion(.success(DjiMicAudioCapture.availableInputs()))
        }
    }

    func start(inputUid: String, sessionId: Int64, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.main.async {
            guard self.state == .idle else {
                completion(.failure(DjiMicPigeonError(code: "engine_start_failed",
                                                      message: "capture already in progress", details: nil)))
                return
            }
            guard Self.hasRecordPermission() else {
                completion(.failure(DjiMicPigeonError(code: "permission_denied",
                                                      message: "Microphone permission is not granted", details: nil)))
                return
            }
            self.sessionId = sessionId
            self.inputUid = inputUid
            self.enter(.starting)
            do {
                try self.capture.start(inputUid: inputUid)
                self.enter(.running)
                completion(.success(()))
            } catch let failure as DjiMicAudioCapture.StartFailure {
                self.state = .idle
                self.inputUid = nil
                switch failure {
                case .inputUnavailable:
                    completion(.failure(DjiMicPigeonError(code: "input_unavailable",
                                                          message: "\(inputUid) is not among the available inputs", details: nil)))
                case .routeFailed(let why):
                    completion(.failure(DjiMicPigeonError(code: "route_failed", message: why, details: nil)))
                case .engineStartFailed(let why):
                    completion(.failure(DjiMicPigeonError(code: "engine_start_failed", message: why, details: nil)))
                }
            } catch {
                self.state = .idle
                self.inputUid = nil
                completion(.failure(DjiMicPigeonError(code: "engine_start_failed",
                                                      message: error.localizedDescription, details: nil)))
            }
        }
    }

    func stop(completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.main.async {
            self.capture.stop()
            if self.state != .idle {
                self.enter(.idle)
            }
            self.inputUid = nil
            completion(.success(()))
        }
    }

    func isRecording() throws -> Bool {
        return state != .idle
    }

    // MARK: internals

    private func enter(_ next: DjiMicCaptureState) {
        state = next
        flutterApi.onStateChanged(state: next, sessionId: sessionId) { _ in }
    }

    private func emitError(_ code: String, _ message: String) {
        flutterApi.onCaptureError(code: code, message: message, sessionId: sessionId) { _ in }
    }

    /// One attempt to get the same input back. Bluetooth takes a moment to
    /// re-appear after a transmitter is switched back on, hence the delay.
    private func scheduleRebuild(after delay: TimeInterval, failureCode: String) {
        let sid = sessionId
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.sessionId == sid, self.state == .interrupted, let uid = self.inputUid else { return }
            self.enter(.rebuilding)
            do {
                try self.capture.start(inputUid: uid)
                self.enter(.running)
            } catch {
                self.emitError(failureCode, "could not resume capture on \(uid): \(error)")
                self.capture.stop()
                self.inputUid = nil
                self.enter(.idle)
            }
        }
    }

    private static func hasRecordPermission() -> Bool {
        if #available(iOS 17.0, *) {
            return AVAudioApplication.shared.recordPermission == .granted
        }
        return AVAudioSession.sharedInstance().recordPermission == .granted
    }
}
