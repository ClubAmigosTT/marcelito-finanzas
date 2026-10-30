import XCTest
@testable import Marcelito

/// The "Grabar reunión" shortcut opens the recorder; "Terminar reunión"
/// without a recording in progress saves nothing.
@MainActor
final class MeetingIntentTests: XCTestCase {
    override func tearDown() {
        MeetingStore.shared.isRecorderPresented = false
        MeetingStore.shared.lastRecordedID = nil
        super.tearDown()
    }

    func testStartShortcutShowsTheRecorder() async throws {
        MeetingStore.shared.isRecorderPresented = false
        _ = try await StartMeetingRecordingIntent().perform()
        XCTAssertTrue(MeetingStore.shared.isRecorderPresented)
        XCTAssertTrue(StartMeetingRecordingIntent.openAppWhenRun)
    }

    func testFinishWithoutRecordingSavesNothing() {
        let store = MeetingStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.presentRecorder()
        XCTAssertNil(store.finishRecording())
        XCTAssertFalse(store.isRecorderPresented)
        XCTAssertTrue(store.meetings.isEmpty)
        XCTAssertNil(store.lastRecordedID)
    }
}
