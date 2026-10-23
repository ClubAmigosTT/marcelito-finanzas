import Foundation
import Observation

/// One stretch of speech by one speaker.
struct MeetingUtterance: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    /// Speaker label from the diarizer ("1", "2"…); renamed through Meeting.speakerNames.
    var speaker: String
    var start: Double
    var end: Double
    var text: String
}

struct MeetingActionItem: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var owner: String
    var task: String
}

struct MeetingNotes: Codable, Equatable, Sendable {
    var summary: String
    var decisions: [String]
    var actionItems: [MeetingActionItem]
}

struct Meeting: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case recorded, processing, ready, failed }

    var id = UUID()
    var title: String
    var date: Date
    var duration: Double
    var audioFileName: String
    var status: Status = .recorded
    var statusDetail: String?
    var utterances: [MeetingUtterance] = []
    /// Diarizer label → name the user gave ("1" → "Ana").
    var speakerNames: [String: String] = [:]
    var notes: MeetingNotes?
    /// The recording is deleted once it has been turned into text.
    var audioDeleted: Bool?

    var hasAudio: Bool { audioDeleted != true }

    var speakers: [String] {
        var seen = Set<String>()
        return utterances.map(\.speaker).filter { seen.insert($0).inserted }
    }

    func displayName(for speaker: String) -> String {
        if let name = speakerNames[speaker], !name.isEmpty { return name }
        let index = (speakers.firstIndex(of: speaker) ?? 0) + 1
        return "Hablante \(index)"
    }

    /// Plain text with names, for notes, sharing and copying.
    var transcriptText: String {
        utterances.map { "\(displayName(for: $0.speaker)): \($0.text)" }.joined(separator: "\n")
    }
}

/// Meetings and their audio live only on this iPhone, in Application
/// Support/MarcelitoMeetings, protected until the device is first unlocked.
@MainActor
@Observable
final class MeetingStore {
    private(set) var meetings: [Meeting] = []
    /// Step shown while a meeting is being processed.
    private(set) var progress: [UUID: String] = [:]
    let directory: URL

    /// Transcribe, separate speakers and write notes. Keeps running when the
    /// screen that started it closes.
    func process(_ id: UUID) {
        guard progress[id] == nil, meeting(id)?.hasAudio == true else { return }
        progress[id] = "Preparando…"
        Task { @MainActor in
            await MeetingProcessor.process(id, store: self) { [weak self] step in self?.progress[id] = step }
            // Text only: once the words and the speakers are in, the audio goes.
            // It stays when something failed, so the meeting can be retried.
            if let done = meeting(id), done.status == .ready, done.statusDetail == nil, !done.utterances.isEmpty {
                deleteAudio(of: id)
            }
            progress[id] = nil
        }
    }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MarcelitoMeetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([Meeting].self, from: data) {
            // A recording interrupted while being processed can be retried.
            meetings = saved.map { meeting in
                var meeting = meeting
                if meeting.status == .processing { meeting.status = .recorded; meeting.statusDetail = nil }
                return meeting
            }
            // Meetings transcribed by builds that kept the recording.
            for meeting in meetings where meeting.status == .ready && meeting.statusDetail == nil && meeting.hasAudio && !meeting.utterances.isEmpty {
                deleteAudio(of: meeting.id)
            }
        }
    }

    /// Removes the recording and keeps only the text.
    func deleteAudio(of id: UUID) {
        guard var meeting = meeting(id) else { return }
        try? FileManager.default.removeItem(at: audioURL(for: meeting))
        meeting.audioDeleted = true
        update(meeting)
    }

    /// Notes again from the transcript (no audio needed), e.g. after naming the speakers.
    func rewriteNotes(_ id: UUID) {
        guard progress[id] == nil, let meeting = meeting(id), !meeting.utterances.isEmpty else { return }
        progress[id] = "Tomando notas…"
        Task { @MainActor in
            let snapshot = meeting
            let notes = try? await MeetingProcessor.withTimeout(120 + max(1, meeting.duration / 60) * 20, step: "Las notas") {
                await MeetingNotesWriter.notes(for: snapshot)
            }
            if var current = self.meeting(id), let notes = notes ?? nil {
                current.notes = notes
                update(current)
            }
            progress[id] = nil
        }
    }

    private var indexURL: URL { directory.appendingPathComponent("meetings.json") }

    func audioURL(for meeting: Meeting) -> URL { directory.appendingPathComponent(meeting.audioFileName) }

    func newAudioURL() -> (name: String, url: URL) {
        let name = "\(UUID().uuidString).m4a"
        return (name, directory.appendingPathComponent(name))
    }

    func meeting(_ id: UUID) -> Meeting? { meetings.first { $0.id == id } }

    func add(_ meeting: Meeting) {
        meetings.insert(meeting, at: 0)
        save()
    }

    func update(_ meeting: Meeting) {
        guard let index = meetings.firstIndex(where: { $0.id == meeting.id }) else { return }
        meetings[index] = meeting
        save()
    }

    func delete(_ meeting: Meeting) {
        if meeting.hasAudio { try? FileManager.default.removeItem(at: audioURL(for: meeting)) }
        meetings.removeAll { $0.id == meeting.id }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(meetings) else { return }
        try? data.write(to: indexURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

enum MeetingTranscriptMerger {
    struct Word: Equatable, Sendable { let text: String; let start: Double; let end: Double }
    struct SpeakerSpan: Equatable, Sendable { let speaker: String; let start: Double; let end: Double }

    /// Gives every transcribed word the speaker whose span overlaps it most
    /// (or the nearest span when it falls in a gap), then joins consecutive
    /// words of the same speaker into one utterance.
    static func merge(words: [Word], spans: [SpeakerSpan]) -> [MeetingUtterance] {
        let ordered = spans.sorted { $0.start < $1.start }
        func speaker(for word: Word) -> String {
            guard !ordered.isEmpty else { return "1" }
            var best: (speaker: String, overlap: Double)?
            for span in ordered {
                let overlap = min(word.end, span.end) - max(word.start, span.start)
                if overlap > 0, overlap > (best?.overlap ?? 0) { best = (span.speaker, overlap) }
            }
            if let best { return best.speaker }
            let middle = (word.start + word.end) / 2
            return ordered.min { distance(middle, $0) < distance(middle, $1) }!.speaker
        }
        func distance(_ time: Double, _ span: SpeakerSpan) -> Double {
            time < span.start ? span.start - time : max(0, time - span.end)
        }
        var result: [MeetingUtterance] = []
        for word in words where !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let who = speaker(for: word)
            if var last = result.last, last.speaker == who {
                let attaches = word.text.first.map { $0.isWhitespace || ".,;:!?)…".contains($0) } ?? true
                last.text += attaches ? word.text : " " + word.text
                last.end = word.end
                result[result.count - 1] = last
            } else {
                result.append(MeetingUtterance(speaker: who, start: word.start, end: word.end, text: word.text))
            }
        }
        return result.map { utterance in
            var cleaned = utterance
            cleaned.text = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            return cleaned
        }
    }

    /// Splits a long transcript into pieces small enough for the on-device
    /// model, cutting only between lines.
    static func chunks(of text: String, maxCharacters: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        for line in text.components(separatedBy: "\n") {
            if !current.isEmpty, current.count + line.count + 1 > maxCharacters {
                pieces.append(current)
                current = ""
            }
            current += current.isEmpty ? line : "\n" + line
            while current.count > maxCharacters {
                pieces.append(String(current.prefix(maxCharacters)))
                current = String(current.dropFirst(maxCharacters))
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}
