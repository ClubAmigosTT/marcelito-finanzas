import SwiftUI

@main
struct MarcelitoApp: App {
    @State private var financeStore: FinanceStore
    @State private var planningStore = FinancialPlanningStore()
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
                        .environment(planningStore)
                } else {
                    SignInView()
                        .environment(authModel)
                }
            }
            .background(MarcelitoAmbientBackground())
            .tint(Color.marcelitoNavy)
            .preferredColorScheme(.light)
            .environment(\.locale, Locale(identifier: "es_MX"))
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    DiagnosticsRecorder.markBackground()
                    authModel.lock()
                } else if phase == .active {
                    // Returning from the app switcher must never run a
                    // synchronous reconciliation/serialization pass. The
                    // previous callback competed with the first SwiftUI
                    // frame and could make the app appear frozen or be killed
                    // by iOS while the user changed tabs. Audits already run
                    // after imports, rebuilds and explicit corrections; the
                    // diagnostic screen remains the explicit foreground
                    // refresh point.
                }
            }
        }
    }
}
