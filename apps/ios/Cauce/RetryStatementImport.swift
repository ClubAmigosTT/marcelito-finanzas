import SwiftUI
import UniformTypeIdentifiers
struct RetryStatementImport: View {
    @Environment(FinanceStore.self) private var store
    let fileName: String
    @State private var selecting = false
    @State private var running = false
    @State private var status = ""
    @State private var progress = 0
    @State private var task: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading) {
            if running {
                ProgressView(value: Double(progress), total: 100)
                Text(status).font(.caption)
                Button("Cancelar reintento") { task?.cancel() }
            } else {
                Button("Seleccionar y reintentar solo este archivo") { selecting = true }
                Text(fileName).font(.caption2).foregroundStyle(.secondary)
                if !status.isEmpty { Text(status).font(.caption) }
            }
        }.font(.subheadline)
            .fileImporter(isPresented: $selecting, allowedContentTypes: [.pdf]) { result in
                guard case .success(let url) = result else { return }
                running = true; progress = 0
                task = Task { @MainActor in
                    do {
                        let summary = try await store.importPDFAsync(from: url, stage: { status = $0 }, progress: { fraction, message in
                            guard running else { return }
                            status = message; progress = max(progress, Int(fraction * 100))
                        })
                        status = "\(summary.imported) movimientos incorporados · \(summary.source)."
                        store.runAutomaticAuditIfNeeded(trigger: "import.retry")
                    } catch is CancellationError { status = "Reintento cancelado. Se conservó el libro anterior." }
                    catch { status = error.localizedDescription }
                    running = false; task = nil
                }
            }.onDisappear { task?.cancel() }
    }
}
