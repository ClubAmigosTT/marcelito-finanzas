import SwiftUI

/// Local-only gate for the personal finance book. Face ID is the normal path;
/// the fallback is revealed only when biometrics are unavailable or have
/// failed repeatedly.
struct SignInView: View {
    @Environment(AuthenticationModel.self) private var auth
    @State private var fallbackPassword = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: "faceid")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(Color.marcelitoCream)
                            .frame(width: 52, height: 52)
                            .background(Color.marcelitoNavyDeep, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                        Text("Marcelito")
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                            .foregroundStyle(Color.marcelitoNavyDeep)
                        Text("Tu dinero, explicado con claridad.")
                            .font(.title3)
                            .foregroundStyle(Color.marcelitoNavyMid)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        Label("Acceso protegido", systemImage: "lock.shield.fill")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Color.marcelitoNavyDeep)

                        Text(auth.requiresFallback
                            ? "Face ID no está disponible ahora. Usa tu clave de respaldo para continuar."
                            : "Face ID se solicitará automáticamente para desbloquear tus finanzas.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        if auth.requiresFallback {
                            SecureField("Clave de respaldo", text: $fallbackPassword)
                                .textContentType(.password)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding(.horizontal, 14)
                                .frame(minHeight: 52)
                                .background(Color.marcelitoCreamSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                            Button {
                                auth.unlockWithFallback(fallbackPassword)
                                fallbackPassword = ""
                            } label: {
                                Label("Desbloquear", systemImage: "lock.open.fill")
                            }
                            .buttonStyle(.marcelitoPrimary)
                        } else {
                            Button {
                                Task { await auth.unlockWithFaceID() }
                            } label: {
                                Label("Entrar con Face ID", systemImage: "faceid")
                            }
                            .buttonStyle(.marcelitoPrimary)

                            Button("Usar clave de respaldo") {
                                auth.showFallback()
                            }
                            .buttonStyle(.marcelitoSecondary)
                        }

                        if let message = auth.message {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline)
                                .foregroundStyle(Color.marcelitoDanger)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Text("La sesión se bloquea al salir de la aplicación. Tus credenciales permanecen en el Keychain de este iPhone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .marcelitoCard(fill: Color.marcelitoCreamTint, radius: 18, padding: 20)
                }
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 30)
            }
            .scrollIndicators(.hidden)
            .background(MarcelitoAmbientBackground())
            .foregroundStyle(Color.marcelitoNavy)
            .toolbar(.hidden, for: .navigationBar)
            .task {
                await auth.unlockAutomatically()
            }
        }
    }
}
