import SwiftUI

@main
struct MarcelitoApp: App {
    @State private var financeStore: FinanceStore
    @State private var authModel: AuthenticationModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        DiagnosticsRecorder.markLaunch()
        _financeStore = State(initialValue: FinanceStore())
        _authModel = State(initialValue: AuthenticationModel())
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if authModel.isAuthenticated {
                    RootTabView()
                        .environment(financeStore)
                        .environment(authModel)
                } else {
                    SignInView()
                        .environment(authModel)
                }
            }
            .background(MarcelitoAmbientBackground())
            .tint(Color.marcelitoNavy)
            .preferredColorScheme(.light)
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    DiagnosticsRecorder.markBackground()
                } else if phase == .active {
                    financeStore.runAutomaticAudit(trigger: "foreground")
                }
            }
        }
    }
}
