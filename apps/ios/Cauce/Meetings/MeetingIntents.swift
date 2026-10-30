import AppIntents

/// "Grabar reunión": opens Marcelito straight into the recorder, from Siri,
/// Spotlight, the Action button or a Shortcuts icon on the Home Screen. The
/// recorder shows over the Face ID lock and never shows finances or notes.
struct StartMeetingRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Grabar reunión"
    static let description = IntentDescription("Abre la app y empieza a grabar una reunión.")
    // The microphone can only start with the app on screen.
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        MeetingStore.shared.presentRecorder()
        return .result()
    }
}

/// "Terminar reunión": saves the recording in progress and starts its
/// transcription, without opening the app. Apple rejects intent texts
/// that name its products, such as "iPhone".
struct FinishMeetingRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Terminar reunión"
    static let description = IntentDescription("Termina la grabación en curso y empieza a transcribirla.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard MeetingStore.shared.finishRecording() != nil else {
            return .result(dialog: "No hay ninguna grabación en curso.")
        }
        return .result(dialog: "Listo. La reunión se está transcribiendo en Marcelito.")
    }
}

struct MarcelitoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartMeetingRecordingIntent(),
            phrases: [
                "Graba una reunión en \(.applicationName)",
                "Grabar reunión en \(.applicationName)",
                "Empieza a grabar en \(.applicationName)",
            ],
            shortTitle: "Grabar reunión",
            systemImageName: "mic.circle.fill"
        )
        AppShortcut(
            intent: FinishMeetingRecordingIntent(),
            phrases: [
                "Termina la reunión en \(.applicationName)",
                "Deja de grabar en \(.applicationName)",
            ],
            shortTitle: "Terminar reunión",
            systemImageName: "stop.circle.fill"
        )
    }
}
