import test from "node:test";
import assert from "node:assert/strict";
import { detectSource, detectSourceEvidence, extractTransactions, gateOcrReconciliation, parseImportedTransactions, parseStatementSummary, reconcileStatementImport, shouldUseOCR } from "../src/pdfImport.ts";
import { buildDeduplicationKey, parseDate, periodKeyFromLabel, runTransactionPipeline } from "../src/reconciliation.ts";
import { buildFinanceMetrics } from "../src/finance.ts";
import { canonicalLedgerFingerprint, createAuditRun } from "../src/audit.ts";
import { prepareStoredLedger, prepareStoredStatements } from "../src/statementMigration.ts";
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

test("los encabezados administrativos parametrizados nunca se convierten en movimientos", () => {
  const administrativeLabels = [
    "Ciudad de México",
    "No. de Serie del Certificado",
    "TOTAL IMPORTE CARGOS",
    "DEL AL",
    "fecha de corte",
    "número de cuenta",
    "RFC ABC123456789",
    "cuenta CLABE",
    "saldo disponible",
    "total del periodo",
    "periodo de facturación",
    "estado de cuenta",
    "saldo final",
  ];
  const text = [
    "Fecha Descripción Cargos Abonos Saldo",
    ...administrativeLabels.map((label, index) => {
      const day = String(index + 1).padStart(2, "0");
      const amount = `${index + 1},${String((index + 1) * 137).padStart(3, "0")}.00`;
      return `${day}/08/2026 ${label} ${amount}`;
    }),
    "28/08/2026 CARGO SUPERMERCADO REAL 245.90",
  ].join("\n");

  const rows = extractTransactions(text, "BBVA", "BBVA agosto 2026.pdf", "bank");
  assert.equal(rows.length, 1);
  assert.equal(rows[0].description, "CARGO SUPERMERCADO REAL");
  assert.equal(rows[0].amount, -245.9);
});

test("la compuerta OCR se conserva al recalcular la vista de revisión", () => {
  const base = reconcileStatementImport("bank", { depositTotal: 100, withdrawalTotal: 0 }, [
    movement({ id: "ocr-income", date: "01 ago 2026", description: "NOMINA", account: "BBVA", amount: 100, flow: "income" }),
  ]);
  assert.equal(base.status, "valid");
  const gated = gateOcrReconciliation(base, "ocr", 0.91, [0.91, 0.71]);
  assert.equal(gated.status, "pending");
  assert.match(gated.reason ?? "", /OCR provisional/);
  assert.equal(gateOcrReconciliation(base, "text", 0.1).status, "valid");
});

test("una capa de texto administrativo larga no desactiva el OCR visual", () => {
  const hiddenLayer = `${"RFC DIRECCION CERTIFICADO SALDO METADATOS ".repeat(30)}\nEstado de cuenta\nNúmero de cuenta 1234567890`;
  assert.equal(shouldUseOCR(hiddenLayer), true);
});

test("una tabla estructurada larga conserva la lectura directa", () => {
  const table = `${"Información del estado ".repeat(30)}\nDetalle de Movimientos Realizados\n23/JUL 22/JUL SUPERMERCADO 120.00 3,469.63`;
  assert.equal(shouldUseOCR(table), false);
});

test("un encabezado de tabla sin filas plausibles fuerza OCR", () => {
  const administrative = `${"RFC DIRECCION CERTIFICADO SALDO ".repeat(30)}\nDetalle de Movimientos Realizados\nPeriodo 16-JUL-2026 AL 15-AGO-2026\nNo. de Cuenta 1575694922`;
  assert.equal(shouldUseOCR(administrative), true);
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

test("el pipeline rechaza un movimiento individual mayor que el total declarado del estado", () => {
  const statement = {
    ...bank("bbva", "BBVA", "agosto 2026"),
    summary: { depositTotal: 1_000, withdrawalTotal: 500 },
  };
  const result = runTransactionPipeline([
    movement({ id: "ocr-merged", date: "10 ago 2026", description: "DEPOSITO NOMINA", account: "BBVA", amount: 2_500, flow: "income", statementId: "bbva" }),
  ], [statement]);
  assert.equal(result.transactions.length, 0);
  assert.equal(result.audit.invalidCount, 1);
});

test("el pipeline rechaza una dirección incompatible con el signo del importe", () => {
  const statements = [bank("bbva", "BBVA", "agosto 2026")];
  const result = runTransactionPipeline([
    movement({ id: "wrong-sign-expense", date: "10 ago 2026", description: "SUPERMERCADO", account: "BBVA", amount: 100, flow: "expense", statementId: "bbva" }),
    movement({ id: "wrong-sign-income", date: "11 ago 2026", description: "NOMINA", account: "BBVA", amount: -100, flow: "income", statementId: "bbva" }),
  ], statements);
  assert.equal(result.transactions.length, 0);
  assert.equal(result.audit.invalidCount, 2);
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

test("matching exige evidencia de cuenta propia además de cuenta, fecha e importe", () => {
  const statements = [bank("santander", "Santander", "agosto 2026"), bank("bbva", "BBVA", "agosto 2026"), card("amex", "Amex", "agosto 2026", 3000)];
  const transactions = [
    movement({ id: "bank-out", date: "20 ago 2026", description: "SPEI A BBVA", account: "Santander", amount: -700, flow: "expense", statementId: "santander" }),
    movement({ id: "bank-in", date: "21 ago 2026", description: "ABONO SPEI SANTANDER", account: "BBVA", amount: 700, flow: "income", statementId: "bbva" }),
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

test("una coincidencia externa de importe y fecha no se oculta como transferencia propia", () => {
  const statements = [bank("santander", "Santander", "agosto 2026"), bank("bbva", "BBVA", "agosto 2026")];
  const transactions = [
    movement({ id: "purchase", date: "20 ago 2026", description: "PAGO A PROVEEDOR", account: "Santander", amount: -700, flow: "expense", statementId: "santander" }),
    movement({ id: "external", date: "21 ago 2026", description: "DEPOSITO CLIENTE", account: "BBVA", amount: 700, flow: "income", statementId: "bbva" }),
  ];
  const result = runTransactionPipeline(transactions, statements);
  assert.equal(result.audit.internalTransferCount, 0);
  assert.equal(buildFinanceMetrics(transactions, statements, result).consolidatedRealSpend, 700);
  assert.equal(buildFinanceMetrics(transactions, statements, result).realIncome, 700);
});

test("una coincidencia ambigua relevante queda en revisión y vuelve provisionales los KPI", () => {
  const statements = [bank("santander", "Santander", "agosto 2026"), bank("bbva", "BBVA", "agosto 2026")];
  const transactions = [
    movement({ id: "large-out", date: "20 ago 2026", description: "PAGO A PROVEEDOR", account: "Santander", amount: -2500, flow: "expense", statementId: "santander" }),
    movement({ id: "large-in", date: "21 ago 2026", description: "DEPOSITO CLIENTE", account: "BBVA", amount: 2500, flow: "income", statementId: "bbva" }),
  ];
  const result = runTransactionPipeline(transactions, statements);
  assert.equal(result.audit.relevantReviewCount, 2);
  assert.equal(result.audit.periods.find((period) => period.key === "2026-08")?.reviewCount, 2);
  assert.equal(result.transactions.every((row) => row.validationStatus === "review"), true);
  assert.equal(buildFinanceMetrics(transactions, statements, result).isProvisional, true);
});

test("matching no convierte un crédito de tarjeta en pago sin evidencia", () => {
  const statements = [
    bank("bbva", "BBVA", "agosto 2026"),
    card("amex", "Amex", "agosto 2026", 5000),
  ];
  const rows = [
    movement({
      id: "bank-charge",
      date: "10 ago 2026",
      description: "PAGO A PROVEEDOR",
      account: "BBVA",
      amount: -1000,
      flow: "expense",
      statementId: "bbva",
    }),
    movement({
      id: "card-adjustment",
      date: "10 ago 2026",
      description: "AJUSTE POSITIVO",
      account: "Amex",
      amount: 1000,
      flow: "income",
      kind: "credit",
      statementId: "amex",
    }),
  ];
  const result = runTransactionPipeline(rows, statements);
  assert.equal(result.audit.cardPaymentCount, 0);
  assert.equal(result.transactions.find((row) => row.id === "card-adjustment")?.kind, "credit");
  assert.equal(result.transactions.find((row) => row.id === "bank-charge")?.reconciledAs, undefined);
  const metrics = buildFinanceMetrics(rows, statements, result);
  assert.equal(metrics.consolidatedRealSpend, 1000);
});

test("un SPEI saliente sin contraparte propia se conserva como gasto real", () => {
  const statements = [bank("bbva", "BBVA", "agosto 2026")];
  const transactions = [movement({ id: "spei-out", date: "24 ago 2026", description: "SPEI ENVIADO A TERCERO", account: "BBVA", amount: -1800, flow: "expense", statementId: "bbva" })];
  const result = runTransactionPipeline(transactions, statements);
  assert.equal(result.transactions[0]?.kind, "purchase");
  assert.equal(result.transactions[0]?.flow, "expense");
  assert.equal(buildFinanceMetrics(transactions, statements, result).consolidatedRealSpend, 1800);
});

test("el parser no excluye un SPEI saliente a tercero como si fuera interno", () => {
  const [row] = extractTransactions("24/08/2026 SPEI ENVIADO A TERCERO 1,800.00 5,000.00", "BBVA", "BBVA agosto 2026.pdf", "bank");
  assert.equal(row.kind, "purchase");
  assert.equal(row.flow, "expense");
  assert.equal(row.amount, -1800);
});

test("un traspaso textual a tercero queda como egreso hasta encontrar una contraparte propia", () => {
  const [row] = extractTransactions("24/08/2026 TRASPASO A TERCERO 1,800.00 5,000.00", "Santander", "Santander agosto 2026.pdf", "bank");
  assert.equal(row.kind, "purchase");
  assert.equal(row.flow, "expense");
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
  const repaired = extractTransactions([
    "05/AG0 TIENDA DE PRUEBA 125.00 1,030.94",
    "OBIAGO NOMINA EMPRESA 1,000.00 2,030.94",
  ].join("\n"), "BBVA", "BBVA agosto 2026.pdf", "bank");
  assert.deepEqual(repaired.map((row) => [row.date, row.amount]), [
    ["05 ago 2026", -125],
    ["07 ago 2026", 1000],
  ]);
});

test("el estado BBVA completo reconstruye sus 11 filas y concilia los totales", () => {
  const text = [
    "Periodo DEL 15/07/2026 AL 14/08/2026",
    "Saldo Anterior 3,589.63",
    "Depósitos / Abonos (+) 2 19,500.00",
    "Retiros / Cargos (-) 9 22,058.69",
    "Saldo Final 1,030.94",
    "Detalle de Movimientos Realizados",
    "23/JUL 22/JUL FACEBK *XR4NKVVF52 120.00 3,469.63 3,469.63",
    "27/JUL 27/JUL SPEI RECIBIDONVIO 15,000.00 18,469.63 18,469.63",
    "29/JUL 29/JUL SPEI ENVIADO STP 13,000.00 5,469.63 5,369.63",
    "30/JUL 30/JUL SPEI ENVIADO STP 500.00",
    "30/JUL 29/JUL TELEF MOVIS MC INSURGE 100.00 4,869.63 4,869.63",
    "03/AGO 04/AGO PAGO CUENTA DE TERCERO 3,253.00 1,616.63 4,869.63",
    "05/AGO 05/AGO SPEI RECIBIDOSANTANDER 4,500.00 6,116.63 6,116.63",
    "06/AGO 06/AGO RETIRO CAJERO AUTOMATICO 4,515.83 1,600.80 1,530.94",
    "07/AGO 06/AGO COMISION CAJERO RED 60.23",
    "07/AGO 06/AGO IVA REP TARJ TIT 9.63 1,530.94 1,530.94",
    "10/AGO 10/AGO SPEI ENVIADO STP 500.00 1,030.94 1,030.94",
  ].join("\n");
  const rows = extractTransactions(text, "BBVA", "BBVA agosto.pdf", "bank");
  const summary = parseStatementSummary(text, "bank");
  assert.equal(rows.length, 11);
  assert.equal(rows.filter((row) => row.amount > 0).length, 2);
  assert.equal(rows.filter((row) => row.amount < 0).length, 9);
  assert.equal(rows.find((row) => row.description.includes("RECIBIDOSANTANDER"))?.amount, 4500);
  assert.equal(reconcileStatementImport("bank", summary, rows).status, "valid");
  assert.equal(rows.every((row) => row.extractionEvidence?.method === "pdf-text"), true);
});

test("la relectura con tipo corregido reconstruye filas y conserva evidencia", () => {
  const text = [
    "Detalle de Movimientos",
    "05/AGO COMPRA DE PRUEBA 125.00 1,030.94",
    "07/AGO NOMINA EMPRESA 1,000.00 2,030.94",
  ].join("\n");
  const rows = parseImportedTransactions(text, "BBVA", "estado-corregido.pdf", "bank", "text");
  assert.deepEqual(rows.map((row) => [row.date, row.amount, row.description]), [
    ["05 ago 2026", -125, "COMPRA DE PRUEBA"],
    ["07 ago 2026", 1000, "NOMINA EMPRESA"],
  ]);
  assert.equal(rows.every((row) => row.extractionEvidence?.method === "pdf-text"), true);
});

test("una fila bancaria sin saldo no usa referencias posteriores como importe", () => {
  const rows = extractTransactions([
    "30/JUL 30/JUL SPEI ENVIADO STP 500.00",
    "2206260binance Referencia 0065112336 646",
    "00646180191200273736",
    "MBAN01002607300065112336 Marcelo Andres Diaz Sanchez",
  ].join("\n"), "BBVA", "BBVA agosto.pdf", "bank");
  assert.deepEqual(rows.map((row) => [row.description, row.amount]), [["SPEI ENVIADO STP", -500]]);
});

test("OCR no convierte la terminación de una tarjeta en un cargo", () => {
  const rows = extractTransactions(
    "17-ABR-2026 (0000100 CONSUMO LOCAL AJENO TERMINACION 8934 174BR26 21600 2983603",
    "Santander",
    "Santander mayo 2026.pdf",
    "bank",
  );
  assert.deepEqual(rows.map((row) => [row.description, row.amount]), [["(0000100 CONSUMO LOCAL AJENO TERMINACION 8934 174BR26", -21600]]);
});

test("OCR corrige 21600 a 216.00 cuando el saldo confirma el separador perdido", () => {
  const rows = extractTransactions([
    "Saldo inicial 30,052.03",
    "17-ABR-2026 CONSUMO LOCAL TERMINACION 8934 21600 29,836.03",
  ].join("\n"), "Santander", "Santander mayo 2026.pdf", "bank");
  assert.equal(rows[0]?.amount, -216);
});

test("cada fila conserva página y fragmento de evidencia cuando el PDF trae sentinelas", () => {
  const rows = extractTransactions([
    "__PDF_PAGE_2__",
    "01/08/2026 SUPERMERCADO 120.00 880.00",
    "__PDF_PAGE_3__",
    "02/08/2026 NOMINA 5,000.00 5,880.00",
  ].join("\n"), "BBVA", "BBVA agosto.pdf", "bank");
  assert.deepEqual(rows.map((row) => row.extractionEvidence?.page), [2, 3]);
  assert.equal(rows.every((row) => (row.extractionEvidence?.sourceText?.length ?? 0) > 0), true);
});

test("la auditoría mide cobertura de evidencia y no acepta filas opacas como trazables", () => {
  const statement = bank("bbva-evidence", "BBVA", "agosto 2026");
  const rows = [
    movement({
      id: "evidence-ok",
      statementId: statement.id,
      date: "01 ago 2026",
      description: "SUPERMERCADO",
      account: "BBVA",
      amount: -120,
      flow: "expense",
      extractionEvidence: { method: "pdf-text", page: 2, confidence: 0.96, sourceText: "01/AGO SUPERMERCADO 120.00" },
    }),
    movement({
      id: "evidence-missing",
      statementId: statement.id,
      date: "02 ago 2026",
      description: "FARMACIA",
      account: "BBVA",
      amount: -80,
      flow: "expense",
      extractionEvidence: { method: "pdf-text", confidence: 0.96 },
    }),
  ];
  const result = runTransactionPipeline(rows, [statement]);
  assert.equal(result.audit.missingEvidenceCount, 1);
  assert.equal(result.audit.evidencePercent, 50);
  assert.equal(result.audit.criticalIssues.some((issue) => issue.includes("sin evidencia completa")), true);
  const audit = createAuditRun(
    result,
    [{ ...statement, reconciliationStatus: "valid", reconciliation: { status: "valid", tolerance: 0.05 } }],
    result.transactions,
    "import",
  );
  assert.equal(audit.status, "blocked");
  assert.equal(audit.issueCount, 1);
});

test("Santander selecciona el cargo o abono y no el saldo corrido", () => {
  const text = [
    "BANCO SANTANDER MEXICO GRUPO FINANCIERO SANTANDER",
    "Saldo inicial 10,000.00",
    "Depósitos 1 5,000.00",
    "Retiros 1 60.00",
    "Detalle de movimientos",
    "16-JUL-2026 17-JUL-2026 CARGO TELCEL 60.00 9,940.00",
    "17-JUL-2026 17-JUL-2026 NOMINA 5,000.00 14,940.00",
  ].join("\n");
  const rows = extractTransactions(text, "Santander", "Santander julio 2026.pdf", "bank");
  assert.deepEqual(rows.map((row) => [row.description, row.amount]), [
    ["CARGO TELCEL", -60],
    ["NOMINA", 5000],
  ]);
});

test("Santander elige el saldo inicial que cuadra cuando el OCR duplica el gráfico", () => {
  const text = [
    "Banco Santander México, S.A., Institución de Banca Múltiple, Grupo Financiero Santander México",
    "Saldo promedio 50,129.64 — Saldoinicial 55,627.93",
    "+ Depósitos 36,187.42",
    "− Retiros 64,161.11",
    "= Saldo final 27,654.24",
    "Gráfico cuenta de cheques",
    "Otroscargos $64,161.11 Saldo inicial $5,627.93",
    "Detalle de movimientos",
    "16-JUL-2026 PAGO TRANSFERENCIA SPEI 64,161.11 55,597.93",
    "17-JUL-2026 NOMINA 36,187.42 27,654.24",
  ].join("\n");
  const summary = parseStatementSummary(text, "bank");
  assert.equal(summary.previousBalance, 55_627.93);
  assert.equal(reconcileStatementImport("bank", summary, extractTransactions(text, "Santander", "Santander agosto 2026.pdf", "bank")).status, "valid");
});

test("Santander tolera que OCR lea RETIROS como RETROS sin perder el total", () => {
  const summary = parseStatementSummary([
    "Banco Santander México, S.A., Institución de Banca Múltiple",
    "Saldo inicial 37,075.03",
    "+ Depósitos 49,222.45",
    "- Retros 61,676.00",
    "= Saldo final 24,621.48",
    "Detalle de movimientos",
  ].join("\n"), "bank");
  assert.equal(summary.depositTotal, 49_222.45);
  assert.equal(summary.withdrawalTotal, 61_676);
  assert.equal(summary.cashBalance, 24_621.48);
});

test("Santander recupera separadores fusionados en los controles del resumen", () => {
  const summary = parseStatementSummary([
    "Banco Santander México, S.A., Institución de Banca Múltiple",
    "Saldo inicial 5562793",
    "+ Depósitos 3618742",
    "- Retros 6416111",
    "= Saldo final 2765424",
    "Detalle de movimientos",
  ].join("\n"), "bank");
  assert.equal(summary.previousBalance, 55_627.93);
  assert.equal(summary.depositTotal, 36_187.42);
  assert.equal(summary.withdrawalTotal, 64_161.11);
  assert.equal(summary.cashBalance, 27_654.24);
});

test("Santander recupera un separador OCR fusionado usando el delta del saldo", () => {
  const rows = extractTransactions([
    "Banco Santander México, S.A., Institución de Banca Múltiple",
    "Saldo inicial 13,986.03",
    "+ Depósitos 1 16,334.80",
    "- Retiros 0 0.00",
    "= Saldo final 30,320.83",
    "Detalle de movimientos",
    "29-ABR-2026 0000000 ABONO PAGO DE NOMINA 1,633,480 30,320.83",
  ].join("\n"), "Santander", "Santander mayo 2026.pdf", "bank");
  assert.equal(rows.length, 1);
  assert.equal(rows[0]?.amount, 16_334.80);
});

test("Amex separa compras y pagos sin convertir el pago en gasto", () => {
  const text = [
    "American Express",
    "Nuevas transacciones 2,500.00",
    "28 de Julio HOTEL 2,500.00",
    "29 de Julio GRACIAS POR SU PAGO 3,000.00",
  ].join("\n");
  const rows = extractTransactions(text, "Amex", "Amex julio 2026.pdf", "card");
  assert.equal(rows.find((row) => row.description === "HOTEL")?.amount, -2500);
  const payment = rows.find((row) => row.description.includes("GRACIAS POR SU PAGO"));
  assert.equal(payment?.kind, "cardPayment");
  assert.equal(payment?.flow, "debt");
  assert.equal(payment?.amount, -3000);
});

test("BBVA no se convierte en Santander por una contraparte dentro de movimientos", () => {
  const text = [
    "Estado de Cuenta",
    "BBVA MEXICO, S.A., INSTITUCION DE BANCA MULTIPLE, GRUPO FINANCIERO BBVA MEXICO",
    "www.bbva.mx",
    "Periodo DEL 15/07/2026 AL 14/08/2026",
    "Detalle de Movimientos Realizados",
    "05/AGO SPEI RECIBIDO SANTANDER 4,500.00 6,116.63",
  ].join("\n");

  assert.equal(detectSource(text, "estado-7A3F.pdf"), "BBVA");
  assert.equal(detectSource(text, "BBVA agosto.pdf"), "BBVA");
  const evidence = detectSourceEvidence(text, "estado-7A3F.pdf");
  assert.equal(evidence.status, "verified");
  assert.equal(evidence.confidence >= 0.99, true);
  assert.deepEqual(evidence.ignoredBodyMentions, ["Santander"]);
});

test("la evidencia legal de BBVA gana aunque Santander aparezca antes de la tabla", () => {
  const text = [
    "BBVA México, Institución de Banca Múltiple, Grupo Financiero BBVA México",
    "Transferencia recibida de Santander",
    "Estado de cuenta",
    "Detalle de Movimientos Realizados",
    "05/AGO SPEI RECIBIDO SANTANDER 4,500.00 6,116.63",
  ].join("\n");

  const evidence = detectSourceEvidence(text, "estado-renombrado.pdf");
  assert.equal(evidence.source, "BBVA");
  assert.equal(evidence.status, "verified");
});

test("una mención de Santander solo en el cuerpo no basta para identificar el emisor", () => {
  const text = [
    "Estado de Cuenta",
    "Detalle de Movimientos Realizados",
    "05/AGO SPEI RECIBIDO SANTANDER 4,500.00 6,116.63",
  ].join("\n");

  assert.equal(detectSource(text, "estado-7A3F.pdf"), "Desconocido");
});

test("la razón social Santander gana a una contraparte BBVA del resumen", () => {
  const text = [
    "Banco Santander México, S.A., Grupo Financiero Santander México",
    "Estado de cuenta nómina",
    "Retiros 64,161.11",
    "20-JUL-2026 PAGO TRANSF RAPIDA SANTANDER Transferencia a BBVA MEXICO 500.00",
    "BBVA MEXICO, S.A. recibe la transferencia",
  ].join("\n");

  const evidence = detectSourceEvidence(text, "Estado de cuenta agosto 2026.pdf");
  assert.equal(evidence.source, "Santander");
  assert.equal(evidence.status, "verified");
});

test("un prefijo numérico del comercio no se convierte en año", () => {
  const [row] = extractTransactions("20 de Junio 125TH FINEST DELI INC 101.77", "Amex", "amex junio 2026.pdf", "card");
  assert.equal(row.date, "20 jun 2026");
  assert.equal(row.amount, -101.77);
  assert.match(row.description, /125TH FINEST/);
});

test("el OCR con días imposibles no crea movimientos", () => {
  const rows = extractTransactions("75 de Agosto COMERCIO 48.00\n15 de Agosto COMERCIO 50.00", "Amex", "Amex agosto 2026.pdf", "card");
  assert.deepEqual(rows.map((row) => row.amount), [-50]);
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

test("el formato real de controles Amex no confunde la fecha con límite o disponible", () => {
  const summary = parseStatementSummary([
    "American Express / The Platinum Credit Card",
    "23,150.88 - 32,744.61 + 49,559.88 = 39,966.15 3,197.29",
    "Límite de Crédito Límite Disponible",
    "a Agosto 27,2026 150,000.00 MN 99,632.79 MN",
    "Pago para no generar intereses 39,966.15",
    "Pago mínimo más meses sin intereses 19,579.69",
  ].join("\n"), "card");

  assert.equal(summary.creditLimit, 150_000);
  assert.equal(summary.creditAvailable, 99_632.79);
  assert.equal(summary.statementBalance, 39_966.15);
  assert.equal(summary.paymentForNoInterest, 39_966.15);
  assert.equal(summary.minimumPlusMsi, 19_579.69);
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

test("la conciliación bancaria también valida el saldo inicial contra el saldo final", () => {
  const summary = parseStatementSummary([
    "Saldo Anterior 100.00",
    "Depósitos / Abonos (+) 1 500.00",
    "Retiros / Cargos (-) 1 200.00",
    "Saldo Final 999.00",
  ].join("\n"), "bank");
  const rows = extractTransactions([
    "01/08/2026 NOMINA 500.00 600.00",
    "02/08/2026 COMPRA 200.00 400.00",
  ].join("\n"), "BBVA", "bbva agosto.pdf", "bank");
  const reconciliation = reconcileStatementImport("bank", summary, rows);
  assert.equal(reconciliation.status, "invalid");
  assert.match(reconciliation.reason ?? "", /saldo final/);
});

test("los totales BBVA explícitos prevalecen sobre datos de gráficas posteriores", () => {
  const summary = parseStatementSummary([
    "Depósitos 19,500.00",
    "Retiros 4,515.83",
    "Distribución de tus movimientos 20%",
    "TOTAL IMPORTE CARGOS 22,058.69 TOTAL MOVIMIENTOS CARGOS 9",
    "TOTAL IMPORTE ABONOS 19,500.00 TOTAL MOVIMIENTOS ABONOS 2",
  ].join("\n"), "bank");
  assert.equal(summary.depositTotal, 19500);
  assert.equal(summary.withdrawalTotal, 22058.69);
  assert.equal(summary.depositCount, 2);
  assert.equal(summary.withdrawalCount, 9);
});

test("la zona de resumen Amex ignora el identificador de cuenta y conserva la ecuación", () => {
  const summary = parseStatementSummary([
    "Saldo Actual / AEC810901298",
    "Pagos y Nuevos Cargos",
    "Saldo Anterior",
    "23,150.88|- 32,744.61|+ 49,559.88|= 39,966.15 3,197.29",
    "Interés Financiero: 0.00",
    "Fecha y Detalle de las operaciones Importe en MN.",
    "27 de Agosto COMPRA 1,000.00",
  ].join("\n"), "card");
  assert.equal(summary.statementBalance, 39966.15);
  assert.equal(summary.paymentForNoInterest, 39966.15);
  assert.equal(summary.minimumPayment, 3197.29);
  assert.equal(summary.interest, 0);
});

test("la conciliación de tarjeta usa nuevas transacciones antes que el total con MSI", () => {
  const summary = parseStatementSummary([
    "Nuevas transacciones: 100.00",
    "Total Nuevos Cargos: 500.00",
  ].join("\n"), "card");
  const rows = extractTransactions("01/08/2026 COMPRA 100.00", "Amex", "Amex agosto 2026.pdf", "card");
  assert.equal(reconcileStatementImport("card", summary, rows).status, "valid");
});

test("la conciliación Amex usa subtotales nacional y extranjero como gasto real", () => {
  const summary = parseStatementSummary([
    "Nuevas transacciones: 33,177.48",
    "Total Nuevos Cargos: 49,559.88",
    "Total de las transacciones en $ de CLIENTE 13,990.02",
    "Total de Transacciones en Moneda Extranjera de CLIENTE 9,593.73",
  ].join("\n"), "card");
  const rows = extractTransactions([
    "01/08/2026 COMPRA NACIONAL 13,990.02",
    "02/08/2026 COMPRA EXTRANJERA Dólar 9,593.73",
  ].join("\n"), "Amex", "Amex agosto 2026.pdf", "card");
  assert.equal(reconcileStatementImport("card", summary, rows).status, "valid");
});

test("la conciliación Amex descuenta créditos del subtotal doméstico y rechaza guías fechadas", () => {
  const summary = parseStatementSummary([
    "Nuevas transacciones: 33,177.48",
    "Total Nuevos Cargos: 49,559.88",
    "Total de las transacciones en $ de CLIENTE 13,990.02",
    "Total de Transacciones en Moneda Extranjera de CLIENTE 9,593.73",
  ].join("\n"), "card");
  const rows = extractTransactions([
    "27 de Agosto americanexpress.com.mx Servicio al cliente 800 504 040 3,197.29",
    "01/08/2026 COMPRA NACIONAL 23,583.75",
    "27/08/2026 MONTO A DIFERIR MESES EN AUTOMÁTICO 9,593.73 CR",
    "02/08/2026 COMPRA EXTRANJERA Dólar 9,593.73",
  ].join("\n"), "Amex", "Amex agosto 2026.pdf", "card");
  const reconciliation = reconcileStatementImport("card", summary, rows);
  assert.equal(reconciliation.status, "valid");
  assert.equal(reconciliation.extractedCreditTotal, 9593.73);
});

test("la conciliación Amex respeta un subtotal doméstico marcado como CR", () => {
  const summary = parseStatementSummary([
    "Nuevas transacciones: 28,034.19",
    "Total Nuevos Cargos: 37,213.42",
    "Total de las transacciones en $ de CLIENTE 27,041.19 CR",
    "Total de Transacciones en Moneda Extranjera de CLIENTE 27,537.69",
  ].join("\n"), "card");
  assert.equal(summary.domesticTransactionTotalIsCredit, true);
  const rows = extractTransactions([
    "01/06/2026 COMPRA NACIONAL 496.50",
    "27/06/2026 MONTO A DIFERIR MESES EN AUTOMÁTICO 27,537.69 CR",
    "02/06/2026 COMPRA EXTRANJERA Dólar 27,537.69",
  ].join("\n"), "Amex", "Amex junio 2026.pdf", "card");
  assert.equal(reconcileStatementImport("card", summary, rows).status, "valid");
});

test("la frontera de secciones Amex conserva como extranjeras las filas posteriores al subtotal", () => {
  const rows = extractTransactions([
    "01/08/2026 COMPRA NACIONAL 100.00",
    "Total de las transacciones en $ de CLIENTE 100.00",
    "02/08/2026 COMPRA EN EL EXTRANJERO 50.00",
    "Peso Colombiano 9,000.00 TC:0.00555",
    "Total de Transacciones en Moneda Extranjera de CLIENTE 50.00",
  ].join("\n"), "Amex", "Amex agosto 2026.pdf", "card");
  assert.deepEqual(rows.map((row) => row.foreignCurrency), [false, true]);
});

test("las secciones Amex de MSI no se convierten en compras del periodo", () => {
  const rows = extractTransactions([
    "__PDF_PAGE_1__",
    "Fecha y Detalle de las operaciones Importe en MN.",
    "01 de Agosto COMPRA REAL 100.00",
    "Transacciones de Meses sin Intereses",
    "02 de Agosto CUOTA MSI 2,000.00",
    "Resumen de Meses sin Intereses",
    "03 de Agosto SALDO MSI 8,000.00",
  ].join("\n"), "Amex", "Amex agosto 2026.pdf", "card");
  assert.equal(rows.length, 1);
  assert.equal(rows[0].description, "COMPRA REAL");
});

test("los conteos declarados bloquean una importación que perdió filas aunque los importes cuadren", () => {
  const summary = parseStatementSummary([
    "Depósitos / Abonos (+) 2 500.00",
    "Retiros / Cargos (-) 1 100.00",
  ].join("\n"), "bank");
  const rows = extractTransactions([
    "01/08/2026 DEPÓSITO 500.00 1,500.00",
    "02/08/2026 CARGO 100.00 1,400.00",
  ].join("\n"), "BBVA", "BBVA agosto 2026.pdf", "bank");
  const reconciliation = reconcileStatementImport("bank", summary, rows);
  assert.equal(reconciliation.status, "invalid");
  assert.equal(reconciliation.expectedMovementCount, 3);
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

test("un estado conciliado pero pendiente de revisión no alimenta los KPI", () => {
  const statements: Statement[] = [{
    ...bank("bbva-review", "BBVA", "agosto 2026"),
    status: "review",
    reconciliationStatus: "valid",
    reconciliation: { status: "valid", tolerance: 0.05 },
  }];
  const transactions = [movement({
    id: "reviewed-later",
    date: "10 ago 2026",
    description: "SUPERMERCADO",
    account: "BBVA",
    amount: -1200,
    flow: "expense",
    statementId: "bbva-review",
    category: "Alimentos",
  })];
  const metrics = buildFinanceMetrics(transactions, statements);
  assert.equal(metrics.consolidatedRealSpend, 0);
  assert.equal(metrics.dataQuality.critical, true);
  assert.equal(metrics.isProvisional, true);
  const pipeline = runTransactionPipeline(transactions, statements);
  const audit = createAuditRun(pipeline, statements, [], "import");
  assert.equal(audit.status, "blocked");
  assert.equal(audit.reconciledStatementCount, 0);
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

test("la auditoría es determinista respecto al orden de importación", () => {
  const statements = [{ ...bank("bbva-ago", "BBVA", "agosto 2026"), sourceFingerprint: "bbb" }];
  const rows = [
    movement({ id: "salary", date: "01 ago 2026", description: "NOMINA", account: "BBVA", amount: 10000, flow: "income", statementId: "bbva-ago", category: "Ingresos" }),
    movement({ id: "food", date: "02 ago 2026", description: "SUPERMERCADO", account: "BBVA", amount: -1200, flow: "expense", statementId: "bbva-ago", category: "Alimentos" }),
  ];
  const first = runTransactionPipeline(rows, statements);
  const reversed = runTransactionPipeline(rows.slice().reverse(), statements);
  assert.equal(canonicalLedgerFingerprint(first.transactions), canonicalLedgerFingerprint(reversed.transactions));
  const firstAudit = createAuditRun(first, statements, first.transactions, "startup");
  const secondAudit = createAuditRun(reversed, statements, reversed.transactions, "startup");
  assert.equal(firstAudit.ledgerFingerprint, secondAudit.ledgerFingerprint);
  assert.equal(firstAudit.canonicalMovementCount, secondAudit.canonicalMovementCount);
  assert.deepEqual(firstAudit.sourceFingerprints, ["bbb"]);
});

test("la auditoría bloquea un estado pendiente aunque no queden filas canónicas", () => {
  const statements: Statement[] = [{
    ...bank("bbva-ago", "BBVA", "agosto 2026"),
    reconciliationStatus: "pending",
    reconciliation: { status: "pending", tolerance: 0.05, reason: "falta el total del estado" },
  }];
  const pipeline = runTransactionPipeline([], statements);
  const audit = createAuditRun(pipeline, statements, pipeline.transactions, "startup");
  assert.equal(audit.status, "blocked");
  assert.equal(audit.reconciledStatementCount, 0);
  assert.match(audit.message ?? "", /pendientes/);
});

test("un resumen histórico bloqueado no contamina deuda, gasto ni patrimonio", () => {
  const statements: Statement[] = [
    {
      ...card("amex-historico", "Amex", "junio 2026", 999_999),
      status: "review",
      reconciliationStatus: "invalid",
      reconciliation: { status: "invalid", tolerance: 0.05, reason: "filas heredadas no concilian" },
      summary: {
        debtBalance: 999_999,
        newCharges: 999_999,
        statementBalance: 999_999,
        creditLimit: 150_000,
        creditAvailable: 0,
      },
    },
    {
      ...card("amex-actual", "Amex", "28/07/2026 AL 27/08/2026", 50_367.21),
      reconciliationStatus: "valid",
      reconciliation: { status: "valid", tolerance: 0.05 },
      summary: {
        debtBalance: 50_367.21,
        statementBalance: 39_966.15,
        creditLimit: 150_000,
        creditAvailable: 99_632.79,
      },
    },
  ];
  const inheritedRows = [movement({
    id: "legacy-absurd",
    date: "15 jun 2026",
    description: "COMPRA HEREDADA",
    account: "Amex",
    amount: -999_999,
    flow: "expense",
    statementId: "amex-historico",
  })];

  const metrics = buildFinanceMetrics(inheritedRows, statements);
  assert.equal(metrics.consolidatedRealSpend, 0);
  assert.equal(metrics.totalNewCharges, 0);
  assert.ok(Math.abs((metrics.debtTotal ?? 0) - 50_367.21) < 0.001);
  assert.equal(metrics.isProvisional, true);
  assert.equal(metrics.dataQuality.critical, true);
});

test("una versión anterior del lector queda en cuarentena al abrir el libro", () => {
  const current = {
    ...bank("bbva-current", "BBVA", "agosto 2026"),
    readerVersion: "web-reader-test",
    status: "ready" as const,
    reconciliationStatus: "valid" as const,
    reconciliation: { status: "valid" as const, tolerance: 0.05 },
    sourceDetection: { source: "BBVA" as const, confidence: 1, status: "verified" as const, evidence: ["BBVA"], ignoredBodyMentions: [] },
  };
  const previous = {
    ...bank("bbva-previous", "BBVA", "julio 2026"),
    readerVersion: "web-reader-legacy",
    status: "ready" as const,
    reconciliationStatus: "valid" as const,
    reconciliation: { status: "valid" as const, tolerance: 0.05 },
  };

  const prepared = prepareStoredStatements([current, previous], "web-reader-test");
  assert.equal(prepared[0]?.status, "ready");
  assert.equal(prepared[0]?.reconciliationStatus, "valid");
  assert.equal(prepared[1]?.status, "review");
  assert.equal(prepared[1]?.reconciliationStatus, "pending");
  assert.match(prepared[1]?.reconciliation?.reason ?? "", /web-reader-legacy/);
});

test("un estado listo sin emisor verificado queda en cuarentena aunque concilie", () => {
  const statement = {
    ...bank("bbva-unverified", "BBVA", "agosto 2026"),
    readerVersion: "web-reader-current",
    status: "ready" as const,
    reconciliationStatus: "valid" as const,
    reconciliation: { status: "valid" as const, tolerance: 0.05 },
  };
  const [prepared] = prepareStoredStatements([statement], "web-reader-current");
  assert.equal(prepared?.status, "review");
  assert.equal(prepared?.reconciliationStatus, "pending");
  assert.match(prepared?.reconciliation?.reason ?? "", /evidencia institucional/);
  const ledger = prepareStoredLedger([statement], [movement({
    id: "unverified-row",
    date: "10 ago 2026",
    description: "COMPRA",
    account: "BBVA",
    amount: -100,
    flow: "expense",
    statementId: statement.id,
  })], "web-reader-current");
  assert.equal(ledger.quarantinedMovementCount, 1);
  assert.equal(ledger.transactions.length, 0);
});

test("una confirmación humana explícita conserva un estado conocido sin evidencia automática", () => {
  const statement = {
    ...bank("bbva-confirmed", "BBVA", "agosto 2026"),
    readerVersion: "web-reader-current",
    status: "ready" as const,
    reconciliationStatus: "valid" as const,
    reconciliation: { status: "valid" as const, tolerance: 0.05 },
    sourceDetection: { source: "BBVA" as const, confidence: 0.90, status: "review" as const, evidence: ["nombre de archivo"], ignoredBodyMentions: [] },
    issuerConfirmedByUser: true,
  };
  const ledger = prepareStoredLedger([statement], [movement({
    id: "confirmed-row",
    date: "10 ago 2026",
    description: "COMPRA CONFIRMADA",
    account: "BBVA",
    amount: -100,
    flow: "expense",
    statementId: statement.id,
  })], "web-reader-current");
  assert.equal(ledger.quarantinedMovementCount, 0);
  assert.equal(ledger.statements[0]?.status, "ready");
});

test("la cuarentena de versión también bloquea las cifras del estado antiguo", () => {
  const legacyStatement = {
    ...bank("bbva-legacy", "BBVA", "agosto 2026"),
    readerVersion: "web-reader-legacy",
    status: "ready" as const,
    reconciliationStatus: "valid" as const,
    reconciliation: { status: "valid" as const, tolerance: 0.05 },
    summary: { cashBalance: 88_833 },
  };
  const [prepared] = prepareStoredStatements([legacyStatement], "web-reader-current");
  const metrics = buildFinanceMetrics([
    movement({
      id: "legacy-expense",
      date: "10 ago 2026",
      description: "COMPRA HEREDADA",
      account: "BBVA",
      amount: -88_833,
      flow: "expense",
      statementId: "bbva-legacy",
    }),
  ], [prepared]);

  assert.equal(metrics.consolidatedRealSpend, 0);
  assert.equal(metrics.cashAvailable, undefined);
  assert.equal(metrics.isProvisional, true);
});

test("la migración elimina filas PDF obsoletas y conserva movimientos manuales", () => {
  const legacyStatement = {
    ...bank("bbva-legacy", "BBVA", "agosto 2026"),
    readerVersion: "web-reader-legacy",
    status: "ready" as const,
    reconciliationStatus: "valid" as const,
    reconciliation: { status: "valid" as const, tolerance: 0.05 },
  };
  const legacyRow = movement({
    id: "legacy-pdf-row",
    date: "10 ago 2026",
    description: "IMPORTE HEREDADO",
    account: "BBVA",
    amount: -88_833,
    flow: "expense",
    statementId: legacyStatement.id,
  });
  const manualRow = movement({
    id: "manual-row",
    date: "11 ago 2026",
    description: "Ajuste manual",
    account: "Efectivo",
    amount: -50,
    flow: "expense",
  });

  const prepared = prepareStoredLedger([legacyStatement], [legacyRow, manualRow], "web-reader-current");
  assert.equal(prepared.quarantinedMovementCount, 1);
  assert.deepEqual(prepared.transactions.map((row) => row.id), ["manual-row"]);
  assert.deepEqual(prepared.quarantinedStatementIds, [legacyStatement.id]);
  assert.equal(prepared.statements[0]?.status, "review");
  assert.equal(prepared.statements[0]?.reconciliationStatus, "pending");
});

test("la migración conserva filas del lector actual que esperan revisión OCR", () => {
  const currentPending = {
    ...bank("bbva-ocr", "BBVA", "agosto 2026"),
    readerVersion: "web-reader-current",
    status: "review" as const,
    reconciliationStatus: "pending" as const,
    reconciliation: { status: "pending" as const, tolerance: 0.05, reason: "OCR provisional" },
  };
  const ocrRow = movement({
    id: "ocr-row",
    date: "10 ago 2026",
    description: "COMPRA OCR",
    account: "BBVA",
    amount: -120,
    flow: "expense",
    statementId: currentPending.id,
  });

  const prepared = prepareStoredLedger([currentPending], [ocrRow], "web-reader-current");
  assert.equal(prepared.quarantinedMovementCount, 0);
  assert.deepEqual(prepared.transactions.map((row) => row.id), ["ocr-row"]);
  assert.equal(prepared.statements[0]?.reconciliationStatus, "pending");
  assert.equal(prepared.statements[0]?.reconciliation?.reason, "OCR provisional");
});

test("la auditoría conserva el conteo de filas PDF heredadas en cuarentena", () => {
  const pipeline = runTransactionPipeline([], []);
  const audit = createAuditRun(
    pipeline,
    [],
    [],
    "startup",
    { quarantinedMovementCount: 3 },
  );
  assert.equal(audit.quarantinedMovementCount, 3);
  assert.equal(audit.trigger, "startup");
});
