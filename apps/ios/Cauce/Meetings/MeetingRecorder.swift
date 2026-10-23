import AVFoundation
import Foundation
import Observation

/// Records the iPhone microphone to a compressed mono file. Keeps recording
/// with the screen locked (background audio mode).
@MainActor
@Observable
final class MeetingRecorder {
    enum State { case idle, recording, paused }

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    /// 0…1, for the level meter.
    private(set) var level: Double = 0
    private(set) var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private(set) var fileURL: URL?

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start(to url: URL) async -> Bool {
        errorMessage = nil
        guard await Self.requestPermission() else {
            errorMessage = "Permite el micrófono en Ajustes › Marcelito para grabar reuniones."
            return false
        }
        let session = AVAudioSession.sharedInstance()
        // Some iPhones reject a category/mode/option combination with
        // OSStatus -50; try plain recording setups in order of preference.
        let setups: [(AVAudioSession.Category, AVAudioSession.CategoryOptions)] = [
            (.record, [.allowBluetoothHFP]),
            (.record, []),
            (.playAndRecord, [.allowBluetoothHFP, .defaultToSpeaker]),
            (.playAndRecord, []),
        ]
        var sessionError: Error?
        var configured = false
        for (category, options) in setups {
            do {
                try session.setCategory(category, mode: .default, options: options)
                try session.setActive(true)
                configured = true
                break
            } catch {
                sessionError = error
            }
        }
        guard configured else {
            errorMessage = "No se pudo preparar el micrófono (\(Self.code(sessionError))). Cierra otras apps que lo usen y vuelve a intentar."
            return false
        }
        // AAC at 16 kHz is enough for speech and keeps files small; 44.1 kHz
        // is the fallback every iPhone encoder accepts.
        var recorderError: Error?
        for sampleRate in [16_000, 44_100] {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
            ]
            do {
                let recorder = try AVAudioRecorder(url: url, settings: settings)
                recorder.isMeteringEnabled = true
                guard recorder.record() else { continue }
                self.recorder = recorder
                fileURL = url
                state = .recording
                elapsed = 0
                startTimer()
                return true
            } catch {
                recorderError = error
            }
        }
        errorMessage = "No se pudo iniciar la grabación (\(Self.code(recorderError))). Vuelve a intentar."
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        return false
    }

    private static func code(_ error: Error?) -> String {
        guard let error else { return "sin detalle" }
        return "código \((error as NSError).code)"
    }

    func pause() {
        recorder?.pause()
        state = .paused
        level = 0
    }

    func resume() {
        guard recorder?.record() == true else { return }
        state = .recording
    }

    /// Stops and returns the recorded duration.
    func stop() -> TimeInterval {
        let duration = recorder?.currentTime ?? elapsed
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        state = .idle
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return max(duration, elapsed)
    }

    func discard() {
        _ = stop()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                if self.state == .recording {
                    self.elapsed = recorder.currentTime
                    recorder.updateMeters()
                    let power = Double(recorder.averagePower(forChannel: 0))
                    self.level = max(0, min(1, (power + 50) / 50))
                }
            }
        }
    }
}
