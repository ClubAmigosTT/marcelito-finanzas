import test from "node:test";
import assert from "node:assert/strict";
import { extractTransactions } from "../src/pdfImport.ts";
import { buildDeduplicationKey, runTransactionPipeline } from "../src/reconciliation.ts";
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
    "03/08/2026 CARGO SUPERMERCADO 1,200.00",
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
