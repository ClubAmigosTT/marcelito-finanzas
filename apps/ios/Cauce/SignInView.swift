import SwiftUI

/// Local-only gate for the personal finance book. Face ID is the normal path
/// and iOS offers the iPhone passcode when it is unavailable; the app keeps no
/// password of its own.
struct SignInView: View {
    @Environment(AuthenticationModel.self) private var auth
    @Environment(MeetingStore.self) private var meetings

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

                        Text("Face ID se solicitará automáticamente. Si no está disponible, iOS te pedirá el código de tu iPhone.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Button {
                            Task { await auth.unlock() }
                        } label: {
                            Label("Desbloquear", systemImage: "faceid")
                        }
                        .buttonStyle(.marcelitoPrimary)

                        if let message = auth.message {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline)
                                .foregroundStyle(Color.marcelitoDanger)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Text("La sesión se bloquea al salir de la aplicación. Marcelito no guarda contraseñas: usa Face ID y el código de este iPhone.")
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
            // Face ID waits while a recording is on screen and asks as soon
            // as it is finished.
            .task(id: meetings.isRecorderPresented) {
                guard !meetings.isRecorderPresented else { return }
                await auth.unlockAutomatically()
            }
        }
    }
}
