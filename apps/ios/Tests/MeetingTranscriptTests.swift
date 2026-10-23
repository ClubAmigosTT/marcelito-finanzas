import XCTest
@testable import Marcelito

final class MeetingTranscriptTests: XCTestCase {
    typealias Word = MeetingTranscriptMerger.Word
    typealias Span = MeetingTranscriptMerger.SpeakerSpan

    func testWordsJoinIntoUtterancesPerSpeaker() {
        let words = [
            Word(text: "Hola", start: 0.0, end: 0.4), Word(text: ",", start: 0.4, end: 0.45), Word(text: "¿cómo", start: 0.5, end: 0.8),
            Word(text: "estás?", start: 0.8, end: 1.2),
            Word(text: "Bien", start: 1.6, end: 1.9), Word(text: "gracias", start: 1.9, end: 2.3),
            Word(text: "Me", start: 2.9, end: 3.0), Word(text: "alegro", start: 3.0, end: 3.4),
        ]
        let spans = [Span(speaker: "A", start: 0, end: 1.3), Span(speaker: "B", start: 1.5, end: 2.5), Span(speaker: "A", start: 2.8, end: 3.5)]
        let utterances = MeetingTranscriptMerger.merge(words: words, spans: spans)
        XCTAssertEqual(utterances.map(\.speaker), ["A", "B", "A"])
        XCTAssertEqual(utterances.map(\.text), ["Hola, ¿cómo estás?", "Bien gracias", "Me alegro"])
        XCTAssertEqual(utterances[1].start, 1.6)
        XCTAssertEqual(utterances[1].end, 2.3)
    }

    func testWordInAGapTakesTheNearestSpeakerAndNoSpansMeansOneSpeaker() {
        let gap = [Word(text: "eh", start: 5.0, end: 5.2)]
        let spans = [Span(speaker: "A", start: 0, end: 4.0), Span(speaker: "B", start: 5.5, end: 8)]
        XCTAssertEqual(MeetingTranscriptMerger.merge(words: gap, spans: spans).first?.speaker, "B")
        XCTAssertEqual(Set(MeetingTranscriptMerger.merge(words: gap + [Word(text: "sí", start: 9, end: 9.2)], spans: []).map(\.speaker)), ["1"])
    }

    func testNamesAndChunks() {
        var meeting = Meeting(title: "Prueba", date: .now, duration: 10, audioFileName: "x.m4a")
        meeting.utterances = [
            MeetingUtterance(speaker: "7", start: 0, end: 1, text: "Hola"),
            MeetingUtterance(speaker: "3", start: 1, end: 2, text: "Qué tal"),
        ]
        XCTAssertEqual(meeting.displayName(for: "7"), "Hablante 1")
        XCTAssertEqual(meeting.displayName(for: "3"), "Hablante 2")
        meeting.speakerNames["3"] = "Ana"
        XCTAssertEqual(meeting.transcriptText, "Hablante 1: Hola\nAna: Qué tal")

        let text = (1...10).map { "Línea número \($0) con algo de texto" }.joined(separator: "\n")
        let pieces = MeetingTranscriptMerger.chunks(of: text, maxCharacters: 80)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= 80 })
        XCTAssertEqual(pieces.joined(separator: "\n"), text)
    }

    @MainActor
    func testStorePersistsAndDeletesAudio() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("meetings-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(directory: directory)
        let target = store.newAudioURL()
        try Data([1, 2, 3]).write(to: target.url)
        var meeting = Meeting(title: "Junta", date: .now, duration: 3, audioFileName: target.name)
        meeting.status = .processing
        store.add(meeting)
        // An interrupted run comes back as recorded, ready to retry.
        XCTAssertEqual(MeetingStore(directory: directory).meetings.first?.status, .recorded)
        store.delete(meeting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.url.path))
        XCTAssertTrue(MeetingStore(directory: directory).meetings.isEmpty)
    }
}
