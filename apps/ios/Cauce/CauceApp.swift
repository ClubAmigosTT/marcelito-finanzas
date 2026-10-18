import SwiftUI
import UserNotifications

@main
struct MarcelitoApp: App {
    @State private var financeStore: FinanceStore
    @State private var planningStore: FinancialPlanningStore
    @State private var recoveryError: String?
    @State private var authModel: AuthenticationModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UNUserNotificationCenter.current().delegate = PlanningNotificationDelegate.shared
        DiagnosticsRecorder.markLaunch()
        do {
            try FinanceBackup.recoverInterruptedRestore()
            _financeStore = State(initialValue: FinanceStore())
            _planningStore = State(initialValue: FinancialPlanningStore())
            _recoveryError = State(initialValue: nil)
        } catch {
            _financeStore = State(initialValue: FinanceStore.blockedRecoveryStore())
            _planningStore = State(initialValue: FinancialPlanningStore(defaults: UserDefaults(suiteName: "marcelito.blockedRecovery")!))
            _recoveryError = State(initialValue: "No se pudo completar la recuperación del respaldo. Tus archivos se conservan. Cierra y vuelve a abrir la app para reintentar.")
        }
        _authModel = State(initialValue: AuthenticationModel())
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let recoveryError {
                    ContentUnavailableView("Recuperación pendiente", systemImage: "externaldrive.badge.exclamationmark", description: Text(recoveryError))
                } else if authModel.isAuthenticated {
                    RootTabView()
                        .environment(financeStore)
                        .environment(authModel)
                        .environment(planningStore)
                } else {
                    SignInView()
                        .environment(authModel)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .financeBackupRestored)) { _ in
                financeStore = FinanceStore(); planningStore = FinancialPlanningStore(); authModel.lock()
            }
            .overlay {
                // iOS captures the app-switcher snapshot while the scene is
                // inactive, before `.background` locks the app. Cover the
                // figures so the snapshot never shows balances.
                if scenePhase != .active && authModel.isAuthenticated {
                    MarcelitoAmbientBackground().ignoresSafeArea()
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
