import test from "node:test";
import assert from "node:assert/strict";
import { extractTransactions, parseStatementSummary, reconcileStatementImport } from "../src/pdfImport.ts";
import { buildDeduplicationKey, parseDate, periodKeyFromLabel, runTransactionPipeline } from "../src/reconciliation.ts";
import { buildFinanceMetrics } from "../src/finance.ts";
import type { Statement, Transaction } from "../src/types.ts";

const bank = (id: string, source: string, period: string): Statement => ({
  id,
  source,
  period,
  fileName: `${source}-${period}.pdf`,
  importedAt: "2026-08-01T00:00:00.000Z",
  mode: "text",
  transactionCount: 0,
  status: "ready",
  kind: "bank",
});

const card = (id: string, source: string, period: string, debtBalance = 0): Statement => ({
  id,
  source,
  period,
  fileName: `${source}-${period}.pdf`,
  importedAt: "2026-08-01T00:00:00.000Z",
  mode: "text",
  transactionCount: 0,
  status: "ready",
  kind: "card",
  summary: { debtBalance, statementBalance: debtBalance, creditLimit: 100000, creditAvailable: 100000 - debtBalance },
});

const movement = (overrides: Partial<Transaction> & Pick<Transaction, "id" | "date" | "description" | "account" | "amount" | "flow">): Transaction => ({
  category: "Sin categoría",
  ...overrides,
});

test("el parser rechaza encabezados administrativos con importes", () => {
  const text = [
    "Fecha Descripción Cargos Abonos Saldo",
    "01/08/2026 Ciudad de México No. de Serie del Certificado 123,456.78",
    "02/08/2026 TOTAL IMPORTE CARGOS 242,993.00",
    "03/08/2026 estado de cue cuenta clabe 3,000.00",
    "04/08/2026 CARGO SUPERMERCADO 1,200.00",
  ].join("\n");
  const rows = extractTransactions(text, "BBVA", "BBVA agosto 2026.pdf", "bank");
  assert.equal(rows.length, 1);
  assert.equal(rows[0].description, "CARGO SUPERMERCADO");
  assert.equal(rows[0].amount, -1200);
});

test("el pipeline rechaza fechas imposibles aunque tengan importe y descripción", () => {
  const statements = [bank("bbva", "BBVA", "agosto 2026")];
  const result = runTransactionPipeline([
    movement({ id: "bad-date", date: "31 feb 2026", description: "SUPERMERCADO", account: "BBVA", amount: -100, flow: "expense", statementId: "bbva" }),
  ], statements);
  assert.equal(result.transactions.length, 0);
  assert.equal(result.audit.invalidCount, 1);
});

test("el pipeline rechaza importes absurdos de encabezados o identificadores", () => {
  const statements = [bank("bbva", "BBVA", "agosto 2026")];
  const result = runTransactionPipeline([
    movement({ id: "header-number", date: "10 ago 2026", description: "COMPRA", account: "BBVA", amount: -12345678.9, flow: "expense", statementId: "bbva" }),
  ], statements);
  assert.equal(result.transactions.length, 0);
  assert.equal(result.audit.invalidCount, 1);
});

test("la llave dedup conserva compras idénticas del mismo estado y elimina el solapamiento", () => {
  const statements = [bank("bbva-jul", "BBVA", "julio 2026"), bank("bbva-ago", "BBVA", "agosto 2026")];
  const first = movement({ id: "a", date: "10 ago 2026", description: "SUPERMERCADO", account: "BBVA", amount: -100, flow: "expense", statementId: "bbva-jul" });
  const legitimateSameStatement = { ...first, id: "b", statementId: "bbva-jul" };
  const overlapping = { ...first, id: "c", statementId: "bbva-ago" };
  const result = runTransactionPipeline([first, legitimateSameStatement, overlapping], statements);
  assert.equal(result.transactions.length, 2);
  assert.equal(result.audit.duplicateCount, 1);
  assert.equal(buildDeduplicationKey(first), buildDeduplicationKey(overlapping));
});

test("el ordinal conserva una segunda compra idéntica legítima entre estados", () => {
  const statements = [bank("bbva-jul", "BBVA", "julio 2026"), bank("bbva-ago", "BBVA", "agosto 2026")];
  const first = movement({ id: "jul-1", date: "10 ago 2026", description: "SUPERMERCADO", account: "BBVA", amount: -100, flow: "expense", statementId: "bbva-jul" });
  const repeated = movement({ id: "ago-1", date: "10 ago 2026", description: "SUPERMERCADO", account: "BBVA", amount: -100, flow: "expense", statementId: "bbva-ago" });
  const legitimateSecond = movement({ id: "ago-2", date: "10 ago 2026", description: "SUPERMERCADO", account: "BBVA", amount: -100, flow: "expense", statementId: "bbva-ago" });
  const result = runTransactionPipeline([first, repeated, legitimateSecond], statements);
  assert.equal(result.transactions.length, 2);
  assert.equal(result.audit.duplicateCount, 1);
  assert.equal(result.transactions.some((transaction) => transaction.id === "ago-2"), true);
});

test("matching excluye traspaso propio y pago de Amex del gasto e ingreso", () => {
  const statements = [bank("santander", "Santander", "agosto 2026"), bank("bbva", "BBVA", "agosto 2026"), card("amex", "Amex", "agosto 2026", 5000)];
  const transactions = [
    movement({ id: "out-transfer", date: "10 ago 2026", description: "TRASPASO A BBVA", account: "Santander", amount: -1000, flow: "expense", statementId: "santander" }),
    movement({ id: "in-transfer", date: "11 ago 2026", description: "TRANSFERENCIA RECIBIDA SANTANDER", account: "BBVA", amount: 1000, flow: "income", statementId: "bbva" }),
    movement({ id: "out-card", date: "12 ago 2026", description: "PAGO DE TARJETA AMEX", account: "Santander", amount: -2500, flow: "expense", statementId: "santander" }),
    movement({ id: "in-card", date: "12 ago 2026", description: "GRACIAS POR SU PAGO", account: "Amex", amount: -2500, flow: "debt", statementId: "amex" }),
    movement({ id: "purchase", date: "13 ago 2026", description: "RESTAURANTE", account: "Amex", amount: -300, flow: "expense", statementId: "amex", category: "Comidas" }),
    movement({ id: "income", date: "14 ago 2026", description: "NOMINA", account: "BBVA", amount: 8000, flow: "income", statementId: "bbva", category: "Ingresos" }),
    movement({ id: "external", date: "15 ago 2026", description: "SPEI RECIBIDO CLIENTE", account: "BBVA", amount: 500, flow: "income", statementId: "bbva", category: "Ingresos" }),
  ];
  const result = runTransactionPipeline(transactions, statements);
  assert.equal(result.audit.internalTransferCount, 1);
  assert.equal(result.audit.cardPaymentCount, 1);
  const metrics = buildFinanceMetrics(transactions, statements, result);
  assert.equal(metrics.consolidatedRealSpend, 300);
  assert.equal(metrics.realIncome, 8500);
  assert.equal(metrics.netFlow, 8200);
});

test("matching usa cuenta, fecha e importe aunque el banco no etiquete el traspaso", () => {
  const statements = [bank("santander", "Santander", "agosto 2026"), bank("bbva", "BBVA", "agosto 2026"), card("amex", "Amex", "agosto 2026", 3000)];
  const transactions = [
    movement({ id: "bank-out", date: "20 ago 2026", description: "OPERACION", account: "Santander", amount: -700, flow: "expense", statementId: "santander" }),
    movement({ id: "bank-in", date: "21 ago 2026", description: "ABONO", account: "BBVA", amount: 700, flow: "income", statementId: "bbva" }),
    movement({ id: "card-in", date: "22 ago 2026", description: "PAGO RECIBIDO", account: "Amex", amount: 1200, flow: "income", statementId: "amex" }),
    movement({ id: "bank-card-out", date: "22 ago 2026", description: "OPERACION", account: "Santander", amount: -1200, flow: "expense", statementId: "santander" }),
    movement({ id: "real", date: "23 ago 2026", description: "SUPERMERCADO", account: "Amex", amount: -250, flow: "expense", statementId: "amex", category: "Alimentos" }),
  ];
  const result = runTransactionPipeline(transactions, statements);
  assert.equal(result.audit.internalTransferCount, 1);
  assert.equal(result.audit.cardPaymentCount, 1);
  const metrics = buildFinanceMetrics(transactions, statements, result);
  assert.equal(metrics.consolidatedRealSpend, 250);
  assert.equal(metrics.realIncome, 0);
});

test("un SPEI saliente sin contraparte propia se conserva como gasto real", () => {
  const statements = [bank("bbva", "BBVA", "agosto 2026")];
  const transactions = [movement({ id: "spei-out", date: "24 ago 2026", description: "SPEI ENVIADO A TERCERO", account: "BBVA", amount: -1800, flow: "expense", statementId: "bbva" })];
  const result = runTransactionPipeline(transactions, statements);
  assert.equal(result.transactions[0]?.kind, "purchase");
  assert.equal(result.transactions[0]?.flow, "expense");
  assert.equal(buildFinanceMetrics(transactions, statements, result).consolidatedRealSpend, 1800);
});

test("un depósito bancario positivo se reconoce como ingreso real", () => {
  const statements = [bank("bbva", "BBVA", "agosto 2026")];
  const transactions = extractTransactions("24/08/2026 DEPÓSITO NÓMINA 8,000.00 10,000.00", "BBVA", "BBVA agosto 2026.pdf", "bank");
  const result = runTransactionPipeline(transactions, statements);
  assert.equal(result.transactions[0]?.kind, "income");
  assert.equal(result.transactions[0]?.flow, "income");
  assert.equal(buildFinanceMetrics(transactions, statements, result).realIncome, 8000);
});

test("un traspaso que menciona una cuenta propia queda fuera aunque falte su PDF", () => {
  const statements = [bank("santander", "Santander", "agosto 2026"), bank("bbva", "BBVA", "agosto 2026")];
  const transactions = [movement({ id: "to-bbva", date: "24 ago 2026", description: "TRASPASO A BBVA", account: "Santander", amount: -1800, flow: "expense", statementId: "santander" })];
  const result = runTransactionPipeline(transactions, statements);
  assert.equal(result.transactions[0]?.kind, "bankTransfer");
  assert.equal(result.transactions[0]?.flow, "transfer");
  assert.equal(buildFinanceMetrics(transactions, statements, result).consolidatedRealSpend, 0);
});

test("un reembolso reduce gasto sin convertirse en ingreso", () => {
  const statements = [card("amex", "Amex", "agosto 2026", 400)];
  const transactions = [
    movement({ id: "purchase", date: "10 ago 2026", description: "HOTEL", account: "Amex", amount: -500, flow: "expense", statementId: "amex", category: "Viajes" }),
    movement({ id: "refund", date: "12 ago 2026", description: "DEVOLUCION HOTEL", account: "Amex", amount: 200, flow: "income", kind: "refund", statementId: "amex", category: "Viajes" }),
  ];
  const result = runTransactionPipeline(transactions, statements);
  const metrics = buildFinanceMetrics(transactions, statements, result);
  assert.equal(metrics.consolidatedRealSpend, 300);
  assert.equal(metrics.realIncome, 0);
  assert.equal(result.audit.refundAmount, 200);
});

test("gasto del periodo usa la fecha del movimiento y no suma todos los PDFs", () => {
  const statements = [card("amex-jul", "Amex", "julio 2026", 1000), card("amex-ago", "Amex", "agosto 2026", 900)];
  const transactions = [
    movement({ id: "jul", date: "20 jul 2026", description: "VIAJE", account: "Amex", amount: -500, flow: "expense", statementId: "amex-jul", category: "Viajes" }),
    movement({ id: "ago", date: "20 ago 2026", description: "COMIDA", account: "Amex", amount: -200, flow: "expense", statementId: "amex-ago", category: "Comidas" }),
  ];
  const metrics = buildFinanceMetrics(transactions, statements);
  assert.equal(metrics.currentMonthSpend, 200);
  assert.equal(metrics.consolidatedRealSpend, 700);
  assert.equal(metrics.debtTotal, 900);
});

test("un estado sin filas válidas usa el resumen solo como respaldo de tarjeta", () => {
  const statements: Statement[] = [{
    ...card("amex-ago", "Amex", "agosto 2026", 1200),
    summary: { debtBalance: 1200, newTransactions: 900, newCharges: 1000, payments: 400, creditLimit: 10000, creditAvailable: 8800 },
  }];
  const metrics = buildFinanceMetrics([], statements);
  assert.equal(metrics.totalNewCharges, 1000);
  assert.equal(metrics.totalRealPayments, 400);
  assert.equal(metrics.debtTotal, 1200);
  assert.equal(metrics.isProvisional, true);
});

test("el respaldo de resumen no duplica estados solapados del mismo emisor", () => {
  const base = card("amex-ago-1", "Amex", "agosto 2026", 1200);
  const statements: Statement[] = [
    { ...base, importedAt: "2026-08-02T00:00:00.000Z", summary: { newCharges: 1000, debtBalance: 1200 } },
    { ...base, id: "amex-ago-2", importedAt: "2026-08-03T00:00:00.000Z", summary: { newCharges: 1000, debtBalance: 1200 } },
  ];
  const metrics = buildFinanceMetrics([], statements);
  assert.equal(metrics.totalNewCharges, 1000);
  assert.equal(metrics.analyticsPeriods[0]?.spend, 1000);
});

test("una identidad de saldo fuera de tolerancia marca el periodo como inconsistente", () => {
  const statements: Statement[] = [{
    ...bank("bbva-ago", "BBVA", "agosto 2026"),
    transactionCount: 1,
    summary: { previousBalance: 1000, cashBalance: 999 },
  }];
  const transactions = [movement({ id: "expense", date: "10 ago 2026", description: "CARGO SUPERMERCADO", account: "BBVA", amount: -100, flow: "expense", statementId: "bbva-ago", category: "Alimentos" })];
  const metrics = buildFinanceMetrics(transactions, statements);
  assert.equal(metrics.consistencyChecks.some((check) => check.id === "cash-bbva-ago" && !check.passed), true);
  assert.equal(metrics.isProvisional, true);
});

test("el parser acepta fechas OCR y BBVA usa el primer importe, no el saldo corrido", () => {
  const text = [
    "Periodo DEL 15/07/2026 AL 14/08/2026",
    "Saldo Anterior 3,589.63",
    "Depósitos / Abonos (+) 2 19,500.00",
    "Retiros / Cargos (-) 2 220.00",
    "23/JUL 22/JUL FACEBK 120.00 3,469.63 3,469.63",
    "27/JUL 27/JUL SPEI RECIBIDONVIO 19,380.00 22,849.63 22,849.63",
    "16-JUL-2026 17-JUL-2026 CARGO TELEFONO 60.00",
  ].join("\n");
  const rows = extractTransactions(text, "BBVA", "BBVA agosto.pdf", "bank");
  assert.deepEqual(rows.map((row) => [row.date, row.amount, row.description]), [
    ["23 jul 2026", -120, "FACEBK"],
    ["27 jul 2026", 19380, "SPEI RECIBIDONVIO"],
    ["16 jul 2026", -60, "CARGO TELEFONO"],
  ]);
  assert.equal(parseDate("16-JUL-2026"), new Date(2026, 6, 16).getTime());
  assert.equal(parseDate("23/JUL", "DEL 15/07/2026 AL 14/08/2026"), new Date(2026, 6, 23).getTime());
  assert.equal(periodKeyFromLabel("DEL 15/07/2026 AL 14/08/2026"), "2026-08");
});

test("un prefijo numérico del comercio no se convierte en año", () => {
  const [row] = extractTransactions("20 de Junio 125TH FINEST DELI INC 101.77", "Amex", "amex junio 2026.pdf", "card");
  assert.equal(row.date, "20 jun 2026");
  assert.equal(row.amount, -101.77);
  assert.match(row.description, /125TH FINEST/);
});

test("monto a diferir CR se registra como crédito y no como gasto", () => {
  const [row] = extractTransactions("27 de Junio MONTO A DIFERIR MESES EN AUTOMÁTICO 27,537.69 CR", "Amex", "amex junio 2026.pdf", "card");
  assert.equal(row.kind, "credit");
  assert.equal(row.flow, "income");
  assert.equal(row.amount, 27537.69);
});

test("monto a diferir sigue siendo crédito cuando CR cae en la línea siguiente", () => {
  const [row] = extractTransactions("27 de Junio MONTO A DIFERIR MESES EN AUTOMÁTICO 27,537.69\nCR", "Amex", "amex junio 2026.pdf", "card");
  assert.equal(row.kind, "credit");
  assert.equal(row.flow, "income");
  assert.equal(row.amount, 27537.69);
});

test("el resumen Amex conserva deuda comprometida, pago MSI y saldo pendiente", () => {
  const summary = parseStatementSummary([
    "0.00 - 27,537.69 + 37,213.42 = 9,675.73 1,350.00",
    "Pago Mínimo más meses sin intereses:$10,529.23",
    "Nuevas transacciones: 28,034.19",
    "Total Nuevos Cargos: 37,213.42",
    "Límite de Crédito 150,000.00 99,632.79",
    "Total de Plan de Meses sin Intereses 10,401.06 16,382.40",
  ].join("\n"), "card");
  assert.equal(summary.minimumPlusMsi, 10529.23);
  assert.equal(summary.msiPending, 10401.06);
  assert.equal(summary.msiMonthlyLoad, 16382.4);
});

test("los totales bancarios declarados bloquean una importación que no concilia", () => {
  const summary = parseStatementSummary([
    "Saldo Anterior 100.00",
    "Depósitos / Abonos (+) 1 500.00",
    "Retiros / Cargos (-) 1 200.00",
    "Saldo Final 400.00",
  ].join("\n"), "bank");
  const rows = extractTransactions("01/08/2026 COMPRA 100.00 400.00", "BBVA", "bbva agosto.pdf", "bank");
  const reconciliation = reconcileStatementImport("bank", summary, rows);
  assert.equal(reconciliation.status, "invalid");
});

test("un estado marcado como inválido bloquea el gasto aunque existan filas heredadas", () => {
  const statements: Statement[] = [{
    ...bank("bbva-ago", "BBVA", "agosto 2026"),
    reconciliationStatus: "invalid",
    reconciliation: { status: "invalid", tolerance: 0.05, reason: "totales no concilian" },
  }];
  const transactions = [movement({ id: "legacy", date: "10 ago 2026", description: "SUPERMERCADO", account: "BBVA", amount: -2500, flow: "expense", statementId: "bbva-ago" })];
  const pipeline = runTransactionPipeline(transactions, statements);
  const metrics = buildFinanceMetrics(transactions, statements, pipeline);
  assert.equal(metrics.consolidatedRealSpend, 0);
  assert.equal(metrics.isProvisional, true);
  assert.equal(metrics.dataQuality.critical, true);
});

test("el último corte se elige por fecha de cierre y no por orden de importación", () => {
  const statements: Statement[] = [
    { ...bank("santander-may", "Santander", "16/05/2026 AL 15/06/2026"), summary: { cashBalance: 24621.48 } },
    { ...bank("santander-ago", "Santander", "16/07/2026 AL 15/08/2026"), importedAt: "2026-08-20T00:00:00.000Z", summary: { cashBalance: 27654.24 } },
    { ...card("amex-ago", "Amex", "28/07/2026 AL 27/08/2026", 50367.21), summary: { statementBalance: 50367.21, debtBalance: 50367.21, creditLimit: 150000, creditAvailable: 99632.79 } },
  ];
  const metrics = buildFinanceMetrics([], statements);
  assert.equal(metrics.cashAvailable, 27654.24);
  assert.ok(Math.abs((metrics.debtTotal ?? 0) - 50367.21) < 0.001);
  assert.ok(Math.abs((metrics.liquidPatrimony ?? 0) - (-22712.97)) < 0.001);
});

test("una cuenta bancaria y una tarjeta del mismo emisor conservan sus saldos", () => {
  const statements: Statement[] = [
    { ...bank("santander-bank", "Santander", "agosto 2026"), summary: { cashBalance: 27654.24 } },
    { ...card("santander-card", "Santander", "agosto 2026", 5000), summary: { statementBalance: 4800, debtBalance: 5000, creditLimit: 10000, creditAvailable: 5000 } },
  ];
  const metrics = buildFinanceMetrics([], statements);
  assert.equal(metrics.cashAvailable, 27654.24);
  assert.equal(metrics.debtTotal, 5000);
  assert.equal(metrics.liquidPatrimony, 22654.24);
});

test("los tres saldos de prueba producen efectivo y patrimonio auditables", () => {
  const statements: Statement[] = [
    { ...bank("santander-ago", "Santander", "15/08/2026"), summary: { cashBalance: 27654.24 } },
    { ...bank("bbva-ago", "BBVA", "31/08/2026"), summary: { cashBalance: 1030.94 } },
    { ...card("amex-ago", "Amex", "27/08/2026", 50367.21), summary: { debtBalance: 50367.21, creditLimit: 150000, creditAvailable: 99632.79 } },
  ];
  const metrics = buildFinanceMetrics([], statements);
  assert.equal(metrics.cashAvailable, 28685.18);
  assert.ok(Math.abs((metrics.debtTotal ?? 0) - 50367.21) < 0.001);
  assert.ok(Math.abs((metrics.liquidPatrimony ?? 0) - (-21682.03)) < 0.001);
});
