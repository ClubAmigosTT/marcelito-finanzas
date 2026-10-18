import SwiftUI
import UniformTypeIdentifiers
import PDFKit

func loanMoney(_ amount: Decimal) -> String { amount.formatted(.currency(code: "MXN").locale(Locale(identifier: "es_MX")).precision(.fractionLength(2))) }
private func loanUDIS(_ amount: Decimal) -> String { amount.formatted(.number.locale(Locale(identifier: "es_MX")).precision(.fractionLength(2))) + " UDIS" }
private struct LoanImportDraft: Identifiable { var id: String { statement.id }; let statement: LoanStatement }

struct LoanAccountsView: View {
    @Environment(FinanceStore.self) private var store
    @State private var importing = false
    @State private var reading = false
    @State private var draft: LoanImportDraft?
    @State private var error: String?
    @State private var notice: String?
    var body: some View {
        List {
            if let error = store.loanLedger.loadError { Section { Text(error).foregroundStyle(Color.marcelitoDanger) } }
            Section("Tus préstamos") {
                if store.loanLedger.state.accounts.isEmpty { Text("Agrega tu estado ITAM para ver cuotas, abonos y saldo pendiente.").foregroundStyle(.secondary) }
                ForEach(store.loanLedger.state.accounts) { account in
                    NavigationLink { LoanAccountDetailView(accountID: account.id) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(account.name).font(.headline)
                            if let snapshot = account.latest {
                                Text("Capital: \(loanUDIS(snapshot.principalRemaining))").font(.subheadline)
                                Text("Estado al \(planningDayLabel(snapshot.asOf)) · \(snapshot.overdue.count) cuotas vencidas").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Button { importing = true } label: { Label("Agregar estado de préstamo ITAM", systemImage: "doc.badge.plus") }.disabled(reading || store.loanLedger.loadError != nil)
            }
            Section {
                NavigationLink("Valor de la UDI · conversión a pesos") { LoanQuoteView() }
                if let quote = store.loanLedger.quote() { Text("1 UDI = \(quote.value.formatted(.number.precision(.fractionLength(6)))) MXN · \(planningDayLabel(quote.date))").font(.caption).foregroundStyle(.secondary) }
                else { Text("Falta un valor de UDI con fecha para incluir el préstamo en el patrimonio y estimar sus cuotas en pesos.").font(.caption).foregroundStyle(.secondary) }
            }
            Section {
                Text("Los abonos se leen del estado. El calendario no reduce tu deuda al pasar el tiempo. Las cifras siguen vigentes al corte del documento.").font(.caption).foregroundStyle(.secondary)
            }
            if reading { ProgressView("Leyendo y conciliando el préstamo…") }
            if let notice { Text(notice).font(.subheadline) }
        }.navigationTitle("Préstamos").scrollContentBackground(.hidden).background(MarcelitoAmbientBackground())
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
                switch result { case .success(let url): Task { await read(url) }; case .failure(let failure): error = failure.localizedDescription }
            }
            .sheet(item: $draft) { draft in
                NavigationStack {
                    List {
                        Section("Estado ITAM · \(planningDayLabel(draft.statement.asOf))") {
                            LabeledContent("Cuotas leídas", value: String(draft.statement.installments.count))
                            LabeledContent("Capital pendiente", value: loanUDIS(draft.statement.principalRemaining))
                            LabeledContent("Interés vencido sin pagar", value: loanUDIS(draft.statement.accruedUnpaidInterest))
                            LabeledContent("Cuotas vencidas", value: String(draft.statement.overdue.count))
                            Text("Cuotas y abonos conciliados con los totales del PDF.").font(.caption).foregroundStyle(.secondary)
                        }
                        Section {
                            Button("Guardar préstamo") {
                                do { let added = try store.loanLedger.importStatement(draft.statement); notice = added ? "Préstamo guardado. Revisa sus abonos para vincularlos con el banco." : "Este estado ya estaba guardado. No se duplicaron cuotas ni abonos."; self.draft = nil }
                                catch { self.error = error.localizedDescription; self.draft = nil }
                            }.fontWeight(.semibold)
                        }
                    }.navigationTitle("Revisar préstamo").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { self.draft = nil } } }
                }
            }
            .alert("Revisa el préstamo", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("Aceptar", role: .cancel) { error = nil } } message: { Text(error ?? "") }
    }
    @MainActor private func read(_ url: URL) async {
        guard !reading else { return }; reading = true; notice = nil
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() }; reading = false }
        do {
            let statement = try await PDFExtractionCoordinator.shared.perform {
                let statement = try LoanPDFReader.read(url)
                try LoanPDFReader.preservePDF(url, statement: statement)
                return statement
            }
            try Task.checkCancellation(); draft = LoanImportDraft(statement: statement)
        } catch { self.error = error.localizedDescription }
    }
}

struct LoanQuoteView: View {
    @Environment(FinanceStore.self) private var store
    @State private var amount = ""
    @State private var date = Date.now
    @State private var message: String?
    var body: some View {
        List {
            Section("Valor oficial con fecha") {
                Link("Consultar UDI en Banxico", destination: URL(string: "https://www.banxico.org.mx/SieInternet/consultarDirectorioInternetAction.do?accion=consultarCuadro&idCuadro=CP150&locale=es")!)
                TextField("Pesos por UDI · p. ej. 8.123456", text: $amount).keyboardType(.decimalPad)
                DatePicker("Fecha del valor", selection: $date, in: ...Date.now, displayedComponents: .date)
                Button("Guardar valor confirmado") {
                    do { guard let value = LoanMath.udiInput(amount) else { throw LoanError.invalid("Escribe el valor oficial de la UDI.") }; try store.loanLedger.setQuote(value: value, date: date); message = "Valor guardado con su fecha." }
                    catch { message = error.localizedDescription }
                }
            }
            Section {
                Text("Copia el valor y la fecha publicados por Banxico. No usamos el tipo de cambio de un pago antiguo como valor actual. Las cuotas futuras en pesos son estimaciones; su importe depende de la UDI al pagar.").font(.caption).foregroundStyle(.secondary)
                if let quote = store.loanLedger.quote() { Text("Guardado: \(quote.value.formatted(.number.precision(.fractionLength(6)))) MXN · \(planningDayLabel(quote.date))").font(.subheadline) }
                if let message { Text(message) }
            }
        }.navigationTitle("Valor de UDI").scrollContentBackground(.hidden).background(MarcelitoAmbientBackground())
            .onAppear { if let quote = store.loanLedger.quote() { amount = NSDecimalNumber(decimal: quote.value).stringValue; date = quote.date } }
    }
}
struct LoanAccountDetailView: View {
    @Environment(FinanceStore.self) private var store
    let accountID: String
    @State private var month = Date.now
    @State private var extra = ""
    @State private var error: String?
    private var account: LoanAccount? { store.loanLedger.state.accounts.first { $0.id == accountID } }
    var body: some View {
        List {
            if let statement = account?.latest {
                summary(statement)
                plan(statement)
                Section("Abonos reales · vincula con tu banco") {
                    ForEach(statement.receipts) { receipt in
                        NavigationLink { LoanReceiptDetailView(accountID: accountID, receiptID: receipt.id) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack { Text(planningDayLabel(receipt.date)); Spacer(); Text(loanMoney(receipt.total)) }
                                Text("Folio \(receipt.folio) · \(store.loanSpendingProjection.payments.values.contains(where: { $0.receiptID == receipt.id }) ? "Vinculado al banco" : "Por vincular")").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Calendario de cuotas · UDIS") {
                    ForEach(statement.installments) { installment in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text("Cuota \(installment.number) · \(planningDayLabel(installment.dueDate))"); Spacer(); Text(loanUDIS(installment.total)) }.font(.subheadline)
                            Text(statement.status(installment)).font(.caption).foregroundStyle(.secondary)
                            if statement.paid(installment) > 0 { Text("Abonado: \(loanUDIS(statement.paid(installment))) · Restan: \(loanUDIS(statement.remaining(installment)))").font(.caption2).foregroundStyle(.secondary) }
                        }.padding(.vertical, 3)
                    }
                }
                Section {
                    NavigationLink("Ver estado original") { LoanOriginalPDFView(statement: statement) }
                    Text("\(account?.statements.count ?? 0) estados conservados. El más reciente determina el saldo; reimportar un PDF no duplica pagos.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { Text(error).foregroundStyle(Color.marcelitoDanger) }
        }.navigationTitle(account?.name ?? "Préstamo").scrollContentBackground(.hidden).background(MarcelitoAmbientBackground())
            .onChange(of: month) { _, _ in loadExtra() }.onAppear { loadExtra() }
    }
    private func summary(_ statement: LoanStatement) -> some View {
        Section("Estado al \(planningDayLabel(statement.asOf))") {
            LabeledContent("Capital pendiente", value: loanUDIS(statement.principalRemaining))
            LabeledContent("Interés vencido sin pagar", value: loanUDIS(statement.accruedUnpaidInterest))
            if let quote = store.loanLedger.quote() {
                LabeledContent("Deuda reconocida · estimación MXN", value: "~" + loanMoney(LoanMath.rounded(statement.recognizedDebt * quote.value)))
                Text("UDI del \(planningDayLabel(quote.date)). Capital e intereses vencidos confirmados; no incluye intereses futuros ni cargos no informados.").font(.caption).foregroundStyle(.secondary)
            } else { NavigationLink("Falta el valor de UDI para convertir a pesos") { LoanQuoteView() } }
            if let next = statement.installments.first(where: { $0.dueDate > statement.asOf && statement.remaining($0) > 0 }) {
                LabeledContent("Cuota siguiente al corte", value: loanUDIS(statement.remaining(next)))
                Text(planningDayLabel(next.dueDate)).font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Cuotas vencidas", value: String(statement.overdue.count))
            LabeledContent("Cuotas vencidas pendientes", value: loanUDIS(statement.overdueTotal))
            Text("El monto para ponerte al corriente debe confirmarse con ITAM: el estado no detalla intereses moratorios ni cargos adicionales.").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Intereses futuros y plan completo") {
                LabeledContent("Intereses del plan pendientes", value: loanUDIS(statement.scheduledInterestRemaining))
                LabeledContent("Total de cuotas pendientes", value: loanUDIS(statement.scheduledTotalRemaining))
                Text("Incluye intereses futuros. No es un monto de liquidación.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func plan(_ statement: LoanStatement) -> some View {
        Section("Reserva para el presupuesto") {
            DatePicker("Mes", selection: $month, displayedComponents: .date)
            let dues = statement.installments.filter { Calendar.current.isDate($0.dueDate, equalTo: month, toGranularity: .month) }.reduce(Decimal(0)) { $0 + $1.total }
            LabeledContent("Cuota programada · \(FinancePeriod.month(month).label)", value: loanUDIS(dues))
            TextField("Extra para ponerte al corriente · MXN", text: $extra).keyboardType(.decimalPad)
            Button("Guardar abono adicional previsto") {
                do { guard let value = parsePlanningAmount(extra) else { throw LoanError.invalid("Escribe un importe en pesos.") }; try store.loanLedger.setCatchUp(value, accountID: accountID, month: month); error = nil }
                catch { self.error = error.localizedDescription }
            }
            Text("Reserva la cuota y este extra. Guardarlo no registra un pago ni reduce tu saldo. Los abonos confirmados que superen la reserva también descuentan del disponible.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func loadExtra() { extra = NSDecimalNumber(decimal: store.loanLedger.state.catchUp[accountID + "|" + LoanMath.monthKey(month)] ?? 0).stringValue }
}

struct LoanReceiptDetailView: View {
    @Environment(FinanceStore.self) private var store
    let accountID: String
    let receiptID: String
    @State private var selected: Movement?
    @State private var error: String?
    private var receipt: LoanReceipt? { store.loanLedger.receipts(accountID).first { $0.id == receiptID } }
    private var link: LoanBankLink? { store.loanLedger.state.links.first { $0.receiptID == receiptID } }
    var body: some View {
        List {
            if let receipt {
                Section("Abono del \(planningDayLabel(receipt.date))") {
                    LabeledContent("Importe total", value: loanMoney(receipt.total))
                    LabeledContent("Capital", value: loanMoney(receipt.principal))
                    LabeledContent("Intereses", value: loanMoney(receipt.interest))
                    LabeledContent("Folio", value: receipt.folio)
                    Text("Aplicado a cuotas: " + receipt.installments.map(String.init).joined(separator: ", ")).font(.caption)
                }
                if let link {
                    Section("Vínculo bancario") {
                        if store.loanSpendingProjection.payments.values.contains(where: { $0.receiptID == receiptID }) {
                            Text("Confirmado. El capital reduce deuda; solo los intereses cuentan como consumo. El presupuesto reserva el abono completo una vez.").font(.subheadline)
                            if let row = store.movements.first(where: { $0.id == link.movementID || FinanceStore.loanBankIdentity($0) == link.identity }) { NavigationLink { MovementDetailView(movement: row) } label: { Text(row.title + " · " + loanMoney(abs(row.amount))) } }
                        } else { Text("El movimiento o su evidencia cambiaron. Revisa el vínculo antes de volver a excluir el capital del gasto.").font(.subheadline).foregroundStyle(Color.marcelitoAmber) }
                        Button("Desvincular abono", role: .destructive) { do { try store.loanLedger.unlink(receiptID) } catch { self.error = error.localizedDescription } }
                    }
                } else {
                    Section("Selecciona el cargo que corresponde a este abono") {
                        let candidates = store.loanBankCandidates(for: receipt)
                        if candidates.isEmpty { Text("No hay un cargo de débito con importe y fecha compatibles. Sube el estado de la cuenta desde la que pagaste.").font(.subheadline).foregroundStyle(.secondary) }
                        ForEach(candidates) { row in
                            Button { selected = row } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(row.account) · \(planningDayLabel(row.date)) · \(loanMoney(abs(row.amount)))").font(.headline)
                                    Text(row.rawDescription ?? row.title).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text("Coincidir por importe y fecha solo genera sugerencias. Confirma el beneficiario y el comprobante; no todos los cargos ITAM son abonos de préstamo.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(Color.marcelitoDanger) }
        }.navigationTitle("Detalle del abono").scrollContentBackground(.hidden).background(MarcelitoAmbientBackground())
            .confirmationDialog("¿Este cargo pagó el préstamo ITAM?", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), titleVisibility: .visible) {
                Button("Confirmar vínculo") {
                    do { if let receipt, let selected { try store.confirmLoanPayment(accountID: accountID, receipt: receipt, movement: selected) }; selected = nil }
                    catch { self.error = error.localizedDescription; selected = nil }
                }
                Button("Cancelar", role: .cancel) { selected = nil }
            } message: { Text("Se conservarán el movimiento, su categoría y la descripción bancaria. El capital dejará de contarse como consumo; los intereses permanecerán en gastos.") }
    }
}
private struct LoanOriginalPDFView: UIViewRepresentable {
    let statement: LoanStatement
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true
        if let url = try? LoanPDFReader.directory().appendingPathComponent(statement.id + ".pdf") { view.document = PDFDocument(url: url) }
        return view
    }
    func updateUIView(_ uiView: PDFView, context: Context) {}
}

/// Shared entry point also explains why a total is unavailable instead of hiding a loan.
struct LoanPositionSection: View {
    @Environment(FinanceStore.self) private var store
    var body: some View {
        if !store.loanLedger.state.accounts.isEmpty || store.loanLedger.loadError != nil {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(store.loanLedger.state.accounts) { account in
                    if let statement = account.latest {
                        NavigationLink { LoanAccountDetailView(accountID: account.id) } label: {
                            LoanProgressCard(name: account.name, statement: statement, quote: store.loanLedger.quote())
                        }.buttonStyle(.plain)
                    }
                }
                if store.loanLedger.quote() == nil {
                    NavigationLink("Completar valor de UDI para calcular tu posición") { LoanQuoteView() }.font(.subheadline)
                }
                if let error = store.loanLedger.loadError { Text(error).font(.caption).foregroundStyle(Color.marcelitoDanger) }
            }
        }
    }
}

/// Same shape as the credit card summary: what has been paid, what is owed
/// today and what is still scheduled, with progress measured on principal.
private struct LoanProgressCard: View {
    let name: String
    let statement: LoanStatement
    let quote: LoanUDIQuote?

    private func mxn(_ udis: Decimal) -> String {
        quote.map { planningMoney(LoanMath.rounded(udis * $0.value)) } ?? loanUDIS(udis)
    }

    var body: some View {
        let principalPaid = statement.allocations.reduce(Decimal(0)) { $0 + $1.principalUDIS }
        let paidMXN = statement.allocations.reduce(Decimal(0)) { $0 + $1.mxn }
        let originalPrincipal = principalPaid + statement.principalRemaining
        let fraction = originalPrincipal > 0 ? NSDecimalNumber(decimal: principalPaid / originalPrincipal).doubleValue : 0
        let pendingInstallments = statement.installments.filter { statement.remaining($0) > Decimal(string: "0.05")! }.count
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(name).font(.headline)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.bottom, 2)
            PositionMetricRow(title: "Llevas pagado", value: planningMoney(paidMXN))
            PositionMetricRow(title: "Debes hoy", value: mxn(statement.recognizedDebt))
            PositionMetricRow(title: "Te falta por pagar", value: mxn(statement.scheduledTotalRemaining))
            PositionUtilizationBar(fraction: fraction, accessibilityName: "Capital pagado")
            Text("\(Int((fraction * 100).rounded()))% del capital pagado · \(pendingInstallments) cuotas por pagar")
                .font(.caption).foregroundStyle(.secondary)
            Text(quote.map { "Al \(planningDayLabel(statement.asOf)) · UDI del \(planningDayLabel($0.date)). \"Te falta\" incluye intereses programados; no moratorios." }
                 ?? "Al \(planningDayLabel(statement.asOf)) · en UDIS hasta tener el valor de la UDI.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .marcelitoCard(fill: Color.marcelitoCreamSoft.opacity(0.75), radius: 16, padding: 14)
    }
}
