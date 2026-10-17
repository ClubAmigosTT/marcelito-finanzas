import Foundation
import SwiftUI
struct CategoryUndoRecord: Codable {
    let version: UUID
    let rows: [Movement]
    let rules: [String: String]
    let overrides: [String: String]
    let reviews: Data?
    let expectedRows: [Movement]
    let expectedRules: [String: String]
    let expectedOverrides: [String: String]
    let expectedReviews: Data?
}
struct CategoryUndoButton: View {
    @Environment(FinanceStore.self) private var store
    @State private var confirming = false
    @State private var failed = false
    var body: some View {
        if store.categoryUndoCount > 0 {
            Button("Deshacer última clasificación · \(store.categoryUndoCount) movimiento(s)") { confirming = true }
                .font(.caption)
                .confirmationDialog("¿Restaurar las categorías y la regla anterior?", isPresented: $confirming, titleVisibility: .visible) {
                    Button("Deshacer clasificación") { failed = !store.undoLastCategoryChange() }
                } message: { Text("Se conservan los importes y las demás clasificaciones. Esta opción corresponde al último cambio guardado.") }
                .alert("No se pudo deshacer", isPresented: $failed) { Button("Aceptar") {} } message: { Text("El libro cambió después de esa clasificación. Tus datos actuales se conservaron.") }
        }
    }
}
