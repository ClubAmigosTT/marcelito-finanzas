import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name { static let financeBackupRestored = Notification.Name("marcelito.financeBackupRestored") }
struct FinanceBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
struct FinanceBackupView: View {
    @Environment(FinancialPlanningStore.self) private var planning
    @State private var password = ""
    @State private var confirmation = ""
    @State private var busy = false
    @State private var exporting = false
    @State private var importing = false
    @State private var document = FinanceBackupDocument(data: Data())
    @State private var payload: FinanceBackupPayload?
    @State private var confirmRestore = false
    @State private var message: String?
    var body: some View {
        Form {
            Section("Respaldo completo") {
                Text("Incluye estados, capturas, movimientos, clasificaciones, reglas, ingresos, presupuestos, metas y préstamos. No incluye tu acceso, datos biométricos ni claves de IA.").font(.subheadline)
                SecureField("Contraseña · mínimo 12 caracteres", text: $password).textContentType(.newPassword)
                SecureField("Repetir contraseña para crear", text: $confirmation)
                Text("Conserva la contraseña: es necesaria para restaurar el archivo. Admite hasta 60 MB de documentos.").font(.caption).foregroundStyle(.secondary)
                Button("Crear respaldo protegido") { exportBackup() }.disabled(password.count < 12 || password != confirmation)
                Button("Abrir respaldo para restaurar") { importing = true }.disabled(password.count < 12)
                if busy { ProgressView("Preparando respaldo…") }
                if let message { Text(message).font(.caption) }
            }
        }.disabled(busy).navigationTitle("Respaldo y restauración")
            .navigationBarBackButtonHidden(busy).interactiveDismissDisabled(busy)
            .fileExporter(isPresented: $exporting, document: document, contentType: .data, defaultFilename: "Marcelito-" + LoanMath.dayKey(.now) + ".marcelito") { result in
                switch result { case .success: message = "Respaldo guardado."; case .failure(let error): message = error.localizedDescription }
                document = FinanceBackupDocument(data: Data())
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .item]) { result in
                guard case .success(let url) = result else { return }
                let secret = password; busy = true; message = nil
                Task {
                    do {
                        let decoded = try await Task.detached(priority: .utility) {
                            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                            guard size > 0, size <= 120_000_000 else { throw LoanError.invalid("El archivo no es un respaldo válido.") }
                            return try FinanceBackup.decrypt(Data(contentsOf: url, options: .mappedIfSafe), password: secret)
                        }.value
                        payload = decoded; confirmRestore = true
                    } catch { message = error.localizedDescription }
                    busy = false
                }
            }
            .confirmationDialog("¿Restaurar el respaldo?", isPresented: $confirmRestore, titleVisibility: .visible) {
                Button("Restaurar este respaldo", role: .destructive) { restore() }
                Button("Cancelar", role: .cancel) { payload = nil }
            } message: { Text("Se reemplazará el libro local por el respaldo del \(payload.map { planningDayLabel($0.createdAt) } ?? "archivo"). Se conserva una copia interna durante la operación para recuperarla si se interrumpe.") }
    }
    private func exportBackup() {
        planning.savePendingPlanChanges(); busy = true; message = nil
        let secret = password
        Task {
            do {
                let data = try await Task.detached(priority: .utility) { try FinanceBackup.encrypt(FinanceBackup.capture(), password: secret) }.value
                document = FinanceBackupDocument(data: data); exporting = true
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
    private func restore() {
        guard let payload else { return }
        planning.savePendingPlanChanges()
        busy = true; message = nil
        Task {
            do {
                try await Task.detached(priority: .utility) { try FinanceBackup.restore(payload) }.value
                self.payload = nil; password = ""; confirmation = ""
                NotificationCenter.default.post(name: .financeBackupRestored, object: nil)
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
}
