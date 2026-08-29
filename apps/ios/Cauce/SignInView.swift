import SwiftUI

struct SignInView: View {
    @Environment(AuthenticationModel.self) private var auth
    private enum AuthMode: Equatable {
        case login
        case create
    }

    @State private var mode: AuthMode = .login
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        @Bindable var auth = auth
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.largeTitle)
                            .foregroundStyle(Color.marcelitoNavy)
                        Text("Marcelito")
                            .font(.largeTitle.bold())
                        Text("Entiende el camino completo de tu dinero.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 16)
                }

                Section("Acceso") {
                    TextField("Usuario", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                    SecureField(mode == .create ? "Crea una contraseña" : "Contraseña", text: $password)
                        .textContentType(mode == .create ? .newPassword : .password)
                }

                if let message = auth.message {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.marcelitoNavy)
                    }
                }

                Section {
                    Button(mode == .create ? "Crear acceso" : "Entrar") {
                        if mode == .create {
                            auth.createAccount(username: username, password: password)
                        } else {
                            auth.signIn(username: username, password: password)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    if mode == .login {
                        Button {
                            Task { await auth.unlockWithFaceID() }
                        } label: {
                            Label("Entrar con Face ID", systemImage: "faceid")
                                .frame(maxWidth: .infinity)
                        }
                    }

                    Button {
                        mode = mode == .login ? .create : .login
                        auth.message = nil
                        password = ""
                    } label: {
                        Text(mode == .login ? "Crear un usuario" : "Ya tengo un usuario")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle(mode == .login ? "Tus finanzas" : "Nuevo acceso")
            .scrollContentBackground(.hidden)
            .background(Color.marcelitoCream)
        }
    }
}
