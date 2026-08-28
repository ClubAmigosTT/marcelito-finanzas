import SwiftUI

@main
struct MarcelitoApp: App {
    @State private var financeStore = FinanceStore()
    @State private var authModel = AuthenticationModel()

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
            .tint(.marcelitoNavy)
            .preferredColorScheme(.light)
        }
    }
}
