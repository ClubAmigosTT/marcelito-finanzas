import AVFoundation
import CoreMedia
import FluidAudio
import Foundation
import Speech
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Turns a recording into a transcript with speakers and notes, all on the
/// iPhone: Apple's speech recognizer for the words, FluidAudio for who spoke
/// when, and Apple Intelligence for the notes.
enum MeetingProcessor {
    enum Failure: LocalizedError {
        case transcriptionUnavailable(String)
        case nothingHeard
        case timedOut(String)

        var errorDescription: String? {
            switch self {
            case .transcriptionUnavailable(let reason): return reason
            case .nothingHeard: return "No se reconoció voz en la grabación."
            case .timedOut(let step): return "\(step) tardó demasiado y se detuvo. Vuelve a intentarlo."
            }
        }
    }

    /// Returns the work's result, or fails after `seconds` even if the work
    /// never answers (a system recognizer that hangs must not hang the app).
    static func withTimeout<T: Sendable>(_ seconds: Double, step: String, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let gate = OnceGate()
        return try await withCheckedThrowingContinuation { continuation in
            let worker = Task {
                do {
                    let value = try await work()
                    if gate.claim() { continuation.resume(returning: value) }
                } catch {
                    if gate.claim() { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if gate.claim() {
                    worker.cancel()
                    continuation.resume(throwing: Failure.timedOut(step))
                }
            }
        }
    }

    static var transcriptionAvailable: Bool {
        if #available(iOS 26.0, *), SpeechTranscriber.isAvailable { return true }
        return SFSpeechRecognizer(locale: Locale(identifier: "es-MX"))?.supportsOnDeviceRecognition ?? false
    }

    @MainActor
    static func process(_ meetingID: UUID, store: MeetingStore, progress: @escaping @MainActor (String) -> Void) async {
        guard var meeting = store.meeting(meetingID) else { return }
        let url = store.audioURL(for: meeting)
        let minutes = max(1, meeting.duration / 60)
        meeting.status = .processing
        meeting.statusDetail = nil
        store.update(meeting)
        do {
            progress("Transcribiendo…")
            // Generous limits: the first run also downloads the Spanish model.
            let words = try await withTimeout(300 + minutes * 120, step: "La transcripción") { try await transcribe(url) }
            guard !words.isEmpty else { throw Failure.nothingHeard }
            progress("Separando quién habla…")
            // Without the speaker models (first use offline) the transcript
            // still arrives, as a single speaker.
            let spans = (try? await withTimeout(300 + minutes * 60, step: "La separación de hablantes") { try await diarize(url) }) ?? []
            meeting.utterances = MeetingTranscriptMerger.merge(words: words, spans: spans)
            store.update(meeting)
            progress("Tomando notas…")
            let snapshot = meeting
            meeting.notes = try? await withTimeout(120 + minutes * 20, step: "Las notas") { await MeetingNotesWriter.notes(for: snapshot) }
            meeting.status = .ready
            if spans.isEmpty { meeting.statusDetail = "No se pudo separar a los hablantes; revisa tu conexión la primera vez y vuelve a procesar." }
        } catch {
            meeting.status = .failed
            meeting.statusDetail = error.localizedDescription
        }
        store.update(meeting)
    }

    // MARK: Words

    static func transcribe(_ url: URL) async throws -> [MeetingTranscriptMerger.Word] {
        if #available(iOS 26.0, *), SpeechTranscriber.isAvailable {
            return try await SpeechWords.read(url)
        }
        // Older iPhones: the classic recognizer, still only on the device.
        return try await LegacySpeechWords.read(url)
    }

    // MARK: Speakers

    static func diarize(_ url: URL) async throws -> [MeetingTranscriptMerger.SpeakerSpan] {
        try await Task.detached(priority: .userInitiated) {
            // The offline pipeline (pyannote segmentation, WeSpeaker voices,
            // VBx clustering) is the most accurate for a finished recording.
            // Models download once (~30 MB) and stay on the iPhone.
            let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
            try await manager.prepareModels()
            let result: DiarizationResult
            do {
                // Memory-mapped: long meetings never load fully into memory.
                result = try await manager.process(url)
            } catch {
                result = try await manager.process(audio: try AudioConverter().resampleAudioFile(url))
            }
            return result.segments.map {
                .init(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
            }
        }.value
    }
}

@available(iOS 26.0, *)
private enum SpeechWords {
    static func read(_ url: URL) async throws -> [MeetingTranscriptMerger.Word] {
        guard SpeechTranscriber.isAvailable else {
            throw MeetingProcessor.Failure.transcriptionUnavailable("El reconocimiento de voz de Apple no está disponible en este dispositivo.")
        }
        var supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "es-MX"))
        if supported == nil { supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "es-ES")) }
        guard let locale = supported else {
            throw MeetingProcessor.Failure.transcriptionUnavailable("El reconocimiento de voz en español no está disponible en este iPhone.")
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        // The Spanish model is downloaded by iOS once and shared by all apps.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task {
            var words: [MeetingTranscriptMerger.Word] = []
            for try await result in transcriber.results where result.isFinal {
                for run in result.text.runs {
                    guard let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] else { continue }
                    let text = String(result.text[run.range].characters)
                    words.append(.init(text: text, start: range.start.seconds, end: range.end.seconds))
                }
            }
            return words
        }
        if let end = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }
}

private enum LegacySpeechWords {
    static func read(_ url: URL) async throws -> [MeetingTranscriptMerger.Word] {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else {
            throw MeetingProcessor.Failure.transcriptionUnavailable("Permite el reconocimiento de voz en Ajustes › Marcelito para transcribir.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-MX")) ?? SFSpeechRecognizer(locale: Locale(identifier: "es-ES")),
              recognizer.supportsOnDeviceRecognition else {
            throw MeetingProcessor.Failure.transcriptionUnavailable("Este iPhone no puede transcribir español sin internet.")
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        // Never send the audio to Apple's servers.
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        let holder = TaskHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let gate = OnceGate()
                holder.task = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        if gate.claim() { continuation.resume(throwing: error) }
                        return
                    }
                    guard let result, result.isFinal, gate.claim() else { return }
                    continuation.resume(returning: result.bestTranscription.segments.map {
                        .init(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration)
                    })
                }
            }
        } onCancel: {
            holder.task?.cancel()
        }
    }

    private final class TaskHolder: @unchecked Sendable { var task: SFSpeechRecognitionTask? }
}

final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Summary, decisions and who committed to what, from the on-device model.
enum MeetingNotesWriter {
    static var available: Bool { OnDeviceExpenseClassifier.isAvailable }

    static func notes(for meeting: Meeting) async -> MeetingNotes? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), available {
            return try? await OnDeviceNotes.write(meeting)
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct GeneratedMeetingNotes {
    @Guide(description: "Resumen de la reunión en 2 a 5 oraciones, en español")
    var summary: String
    @Guide(description: "Acuerdos o decisiones tomadas; vacío si no hubo")
    var decisions: [String]
    @Guide(description: "Pendientes concretos con quién se comprometió a hacerlos")
    var actionItems: [GeneratedActionItem]
}

@available(iOS 26.0, *)
@Generable
struct GeneratedActionItem {
    @Guide(description: "Nombre de quien se comprometió, tal como aparece en la transcripción, o «Sin asignar»")
    var owner: String
    @Guide(description: "La tarea, breve")
    var task: String
}

@available(iOS 26.0, *)
private enum OnDeviceNotes {
    static let instructions = """
    Tomas notas de reuniones en español a partir de una transcripción donde cada línea empieza con el nombre de quien habla. \
    Sé fiel a lo dicho: no inventes acuerdos, cifras ni nombres que no aparezcan.
    """

    static func write(_ meeting: Meeting) async throws -> MeetingNotes {
        let transcript = meeting.transcriptText
        // The on-device model has a small context window: long meetings are
        // condensed piece by piece first.
        var material = transcript
        let pieces = MeetingTranscriptMerger.chunks(of: transcript, maxCharacters: 6_000)
        if pieces.count > 1 {
            var condensed: [String] = []
            for piece in pieces {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: "Resume en viñetas lo importante de esta parte, conservando quién dijo o se comprometió a qué:\n\n\(piece)")
                condensed.append(response.content)
            }
            material = MeetingTranscriptMerger.chunks(of: condensed.joined(separator: "\n"), maxCharacters: 7_000).first ?? ""
        }
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: "Escribe las notas de esta reunión:\n\n\(material)",
            generating: GeneratedMeetingNotes.self
        )
        let notes = response.content
        return MeetingNotes(
            summary: notes.summary,
            decisions: notes.decisions.filter { !$0.isEmpty },
            actionItems: notes.actionItems.map { MeetingActionItem(owner: $0.owner, task: $0.task) }
        )
    }
}
#endif
