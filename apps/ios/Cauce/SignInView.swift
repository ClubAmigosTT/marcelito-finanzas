import SwiftUI

struct SignInView: View {
    @Environment(AuthenticationModel.self) private var auth

    private enum AuthMode: String, CaseIterable, Identifiable, Hashable {
        case login
        case create

        var id: String { rawValue }
    }

    @State private var mode: AuthMode = .login
    @State private var username = ""
    @State private var password = ""

    private var isCreating: Bool { mode == .create }

    var body: some View {
        @Bindable var auth = auth

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: "waveform.path.ecg.rectangle.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(Color.marcelitoCream)
                            .frame(width: 52, height: 52)
                            .background(Color.marcelitoNavy, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                        Text("Marcelito")
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                            .foregroundStyle(Color.marcelitoNavyDeep)
                        Text("Tu dinero, explicado con claridad.")
                            .font(.title3)
                            .foregroundStyle(Color.marcelitoNavyMid)
                    }

                    Picker("Acceso", selection: $mode) {
                        Text("Entrar").tag(AuthMode.login)
                        Text("Crear usuario").tag(AuthMode.create)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Tipo de acceso")

                    VStack(alignment: .leading, spacing: 16) {
                        Text(isCreating ? "Crea tu acceso" : "Bienvenido de vuelta")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Color.marcelitoNavyDeep)

                        VStack(spacing: 12) {
                            TextField("Usuario", text: $username)
                                .textContentType(.username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding(.horizontal, 14)
                                .frame(minHeight: 52)
                                .background(Color.marcelitoCreamSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                            SecureField(isCreating ? "Crea una contraseña" : "Contraseña", text: $password)
                                .textContentType(isCreating ? .newPassword : .password)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 52)
                                .background(Color.marcelitoCreamSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }

                        if let message = auth.message {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline)
                                .foregroundStyle(Color.marcelitoDanger)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Button {
                            if isCreating {
                                auth.createAccount(username: username, password: password)
                            } else {
                                auth.signIn(username: username, password: password)
                            }
                        } label: {
                            Text(isCreating ? "Crear acceso" : "Entrar")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.marcelitoNavy)

                        if !isCreating {
                            Button {
                                Task { await auth.unlockWithFaceID() }
                            } label: {
                                Label("Entrar con Face ID", systemImage: "faceid")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, minHeight: 50)
                            }
                            .buttonStyle(.bordered)
                            .tint(Color.marcelitoNavy)
                        }
                    }
                    .marcelitoCard(fill: Color.marcelitoCreamTint, radius: 18, padding: 20)
                }
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 30)
            }
            .scrollIndicators(.hidden)
            .background(Color.marcelitoCream.ignoresSafeArea())
            .foregroundStyle(Color.marcelitoNavy)
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: mode) { _, _ in
                auth.message = nil
                password = ""
            }
        }
    }
}
