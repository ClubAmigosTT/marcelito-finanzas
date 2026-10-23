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
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .spokenAudio, options: [.allowBluetoothHFP])
            try session.setActive(true)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                errorMessage = "No se pudo iniciar la grabación."
                return false
            }
            self.recorder = recorder
            fileURL = url
            state = .recording
            elapsed = 0
            startTimer()
            return true
        } catch {
            errorMessage = "No se pudo iniciar la grabación: \(error.localizedDescription)"
            return false
        }
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
