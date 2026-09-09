import test from "node:test";
import assert from "node:assert/strict";
import { parseScreenshotMoney, parseScreenshotText } from "../src/screenshotReader.ts";
import { deduplicateScreenshotCaptures, deduplicateScreenshotTransactions, reconcileScreenshotCaptures } from "../src/screenshotReconciliation.ts";
import type { ScreenshotCapture, Statement, Transaction } from "../src/types.ts";

const capturedAt = "2026-09-08T12:00:00.000Z";

test("el lector BBVA conserva signos, fechas y filas cuyo importe aparece antes del concepto", () => {
  const result = parseScreenshotText({
    fileName: "1-Foto-1.jpg",
    capturedAt,
    text: [
      "Movimientos",
      "BBVA",
      "7 agosto 2026",
      "$ -9.63",
      "Iva rep tarj tit",
      "Movimiento BBVA",
      "Comision cajero red",
      "$ -60.23",
      "6 agosto 2026",
      "Retiro cajero automa...",
      "$ -4,515.83",
      "5 agosto 2026",
      "Spei recibido santan...",
      "$ 4,500.00",
      "Transferencia interbancaria recibida",
    ].join("\n"),
  });

  assert.equal(result.source, "BBVA");
  assert.deepEqual(result.transactions.map((transaction) => transaction.amount), [-9.63, -60.23, -4515.83, 4500]);
  assert.equal(result.transactions[2].descriptionTruncated, true);
  assert.equal(result.transactions[3].kind, "bankTransfer");
  assert.equal(result.transactions[3].flow, "income");
});

test("el lector Santander separa saldo actual de movimientos y reconoce la cuenta enmascarada", () => {
  const result = parseScreenshotText({
    fileName: "3-Foto-3.jpg",
    capturedAt,
    text: [
      "SUPER NOMINA",
      "56**7079",
      "44,460.55 MXN",
      "Saldo actual",
      "Todos Pagos Gastos",
      "lunes 31 de agosto 2026",
      "CIGARROS",
      "-20.00 MXN",
      "sábado 29 de agosto 2026",
      "santander",
      "11,000.00 MXN",
      "viernes 28 de agosto 2026",
      "TRANSFERENCIA A",
      "HERMINIO MIRANDA",
      "-20.00 MXN",
    ].join("\n"),
  });

  assert.equal(result.source, "Santander");
  assert.equal(result.accountKey, "Santander:bank:7079");
  assert.equal(result.balanceSnapshots[0]?.amount, 44460.55);
  assert.deepEqual(result.transactions.map((transaction) => transaction.amount), [-20, 11000, -20]);
  assert.equal(result.transactions[1].validationStatus, "review", "una entrada sin signo debe pedir confirmación de la flecha");

  const ocrVariant = parseScreenshotText({
    fileName: "3-Foto-3.jpg",
    capturedAt,
    text: ["SUPER NOMINA", "56**7079", "CB 44,460.55 xn", "do actual", "lunes 31 de agosto 2026", "CIGARROS", "-20.00 MXN"].join("\n"),
  });
  assert.equal(ocrVariant.balanceSnapshots[0]?.amount, 44460.55, "debe tolerar el texto Santander parcialmente perdido por OCR");
});

test("el lector Amex normaliza compras como egresos y conserva el estado Pendiente", () => {
  const result = parseScreenshotText({
    fileName: "7-Foto-7.jpg",
    capturedAt,
    text: [
      "The Platinum Credit Card American Express =..-51003",
      "8 sep",
      "$405.00",
      "TACOS EL GUERO",
      "Pendiente",
      "7 ELEVEN T957 LA SALLE",
      "$69.50",
      "Pendiente",
      "7 sep",
      "VIVAAEROBUS",
      "$3,465.51",
      "Pendiente",
      "6 sep",
      "7 ELEVEN ALFONSO REYES MEXICO DF",
      "$55.50",
    ].join("\n"),
  });

  assert.equal(result.source, "Amex");
  assert.equal(result.accountKey, "Amex:card:1003");
  assert.deepEqual(result.transactions.map((transaction) => transaction.amount), [-405, -69.5, -3465.51, -55.5]);
  assert.deepEqual(result.transactions.slice(0, 3).map((transaction) => transaction.captureStatus), ["pending", "pending", "pending"]);
  assert.equal(parseScreenshotMoney("$ -12,000.00")?.amount, 12000);
  assert.equal(parseScreenshotMoney("$ -12,000.00")?.negative, true);
});

test("la identidad de cuenta admite formatos oficiales equivalentes y no cruza una terminación distinta", () => {
  const statement: Statement = {
    id: "statement-santander-format",
    source: "Santander",
    accountKey: "santander:7079",
    kind: "bank",
    period: "agosto 2026",
    fileName: "santander.pdf",
    importedAt: capturedAt,
    mode: "text",
    transactionCount: 1,
    status: "ready",
    reconciliationStatus: "valid",
    reconciliation: { status: "valid", tolerance: 0.05 },
    sourceDetection: { source: "Santander", confidence: 1, status: "verified", evidence: ["SUPER NOMINA"], ignoredBodyMentions: [] },
  };
  const capture = (accountKey: string): ScreenshotCapture => ({
    id: `capture-${accountKey}`,
    source: "Santander",
    accountKey,
    kind: "bank",
    fileNames: ["santander.jpg"],
    sourceFingerprints: [accountKey],
    importedAt: capturedAt,
    readerVersion: "test",
    parserId: "santander-mobile-screenshot-v1",
    status: "provisional",
    transactionCount: 1,
    duplicateCount: 0,
    matchedCount: 0,
    reviewCount: 0,
    warnings: [],
    transactions: [screenshotTransaction({ id: `screen-${accountKey}`, date: "2026-08-29", description: "SPEI RECIBIDO", account: "Santander", accountKey, amount: 11000, flow: "income", sourceCaptureId: `capture-${accountKey}` })],
  });
  const official = screenshotTransaction({ id: "official-format", date: "2026-08-29", description: "SPEI RECIBIDO", account: "Santander", accountKey: "santander:7079", amount: 11000, flow: "income", sourceType: "statement", statementId: statement.id });
  const equivalent = reconcileScreenshotCaptures(deduplicateScreenshotCaptures([capture("Santander:bank:7079")], [statement]), [official], [statement]);
  const different = reconcileScreenshotCaptures(deduplicateScreenshotCaptures([capture("Santander:bank:9999")], [statement]), [official], [statement]);
  assert.equal(equivalent[0].matchedCount, 1);
  assert.equal(different[0].matchedCount, 0);
});

test("la terminación no basta para cruzar una cuenta bancaria con una tarjeta", () => {
  const bankStatement: Statement = {
    id: "statement-bank-same-tail",
    source: "Santander",
    accountKey: "Santander:bank:7079",
    kind: "bank",
    period: "agosto 2026",
    fileName: "santander-bank.pdf",
    importedAt: capturedAt,
    mode: "text",
    transactionCount: 1,
    status: "ready",
    reconciliationStatus: "valid",
    reconciliation: { status: "valid", tolerance: 0.05 },
    sourceDetection: { source: "Santander", confidence: 1, status: "verified", evidence: ["SUPER NOMINA"], ignoredBodyMentions: [] },
  };
  const screenshot = screenshotTransaction({ id: "screen-card-tail", date: "2026-08-29", description: "SPEI RECIBIDO", account: "Santander", accountKey: "Santander:card:7079", amount: 11000, flow: "income", sourceCaptureId: "capture-card-tail" });
  const capture: ScreenshotCapture = {
    id: "capture-card-tail",
    source: "Santander",
    accountKey: "Santander:card:7079",
    kind: "card",
    fileNames: ["card.jpg"],
    sourceFingerprints: ["card-tail"],
    importedAt: capturedAt,
    readerVersion: "test",
    parserId: "santander-mobile-screenshot-v1",
    status: "provisional",
    transactionCount: 1,
    duplicateCount: 0,
    matchedCount: 0,
    reviewCount: 0,
    warnings: [],
    transactions: [screenshot],
  };
  const official = screenshotTransaction({ id: "official-bank-tail", date: "2026-08-29", description: "SPEI RECIBIDO", account: "Santander", accountKey: "Santander:bank:7079", amount: 11000, flow: "income", sourceType: "statement", statementId: bankStatement.id });
  const result = reconcileScreenshotCaptures([capture], [official], [bankStatement]);
  assert.equal(result[0].matchedCount, 0);
});

test("los perfiles toleran artefactos de flecha y banners sin convertirlos en movimientos", () => {
  const santander = parseScreenshotText({
    fileName: "4-Foto-4.jpg",
    capturedAt,
    text: [
      "SUPER NOMINA",
      "6**7079",
      "martes 08 de septiembre 2026",
      "-1,300.00 MXN",
      "V Retiro sin tarjeta",
      "VW TRANSFERENCIA A HERMINIO MI.",
      "-40.00 MXN",
      "viernes 04 de septiembre 2026",
      "2468293 RFC",
      "-12,000.00 MXN",
      "v",
      "AEC810901298",
      "o,",
      "jueves 03 de septiembre 2026",
    ].join("\n"),
  });
  assert.deepEqual(santander.transactions.map((transaction) => transaction.description), ["Retiro sin tarjeta", "TRANSFERENCIA A HERMINIO MI.", "2468293 RFC AEC810901298"]);

  const amex = parseScreenshotText({
    fileName: "6-Foto-6.jpg",
    capturedAt,
    text: [
      "The Platinum Credit Card American Express =..-51003",
      "5 sep",
      "TOKS MUNDO E TLALNEPANTLA — $137.50",
      "$6,000 M.N. POR REFERIR",
      "Podrás recibir $6,000 M.N. en cashback*",
      "por cada amigo que invites a Amex.",
      "Refiere Amigos",
      "4 sep",
      "MERCADOPAGO*ANANA Benito",
      "$214.00 >",
    ].join("\n"),
  });
  assert.deepEqual(amex.transactions.map((transaction) => transaction.amount), [-137.5, -214]);
  assert.equal(amex.transactions.some((transaction) => transaction.description.toLowerCase().includes("referir")), false);
});

test("un estado oficial pendiente no puede confirmar una observación OCR", () => {
  const statement: Statement = {
    id: "statement-pending",
    source: "BBVA",
    accountKey: "BBVA:bank:1234",
    kind: "bank",
    period: "agosto 2026",
    fileName: "bbva.pdf",
    importedAt: capturedAt,
    mode: "text",
    transactionCount: 1,
    status: "review",
    reconciliationStatus: "pending",
    reconciliation: { status: "pending", tolerance: 0.05 },
    sourceDetection: { source: "BBVA", confidence: 0.85, status: "review", evidence: ["selección manual"], ignoredBodyMentions: [] },
  };
  const screenshot = screenshotTransaction({ id: "screen-pending", date: "2026-08-29", description: "SPEI RECIBIDO", account: "BBVA", accountKey: "BBVA:bank:1234", amount: 11000, flow: "income", sourceCaptureId: "capture-pending" });
  const capture: ScreenshotCapture = {
    id: "capture-pending",
    source: "BBVA",
    accountKey: "BBVA:bank:1234",
    kind: "bank",
    fileNames: ["bbva.jpg"],
    sourceFingerprints: ["pending"],
    importedAt: capturedAt,
    readerVersion: "test",
    parserId: "bbva-mobile-screenshot-v1",
    status: "provisional",
    transactionCount: 1,
    duplicateCount: 0,
    matchedCount: 0,
    reviewCount: 0,
    warnings: [],
    transactions: [screenshot],
  };
  const official = screenshotTransaction({ id: "official-pending", date: "2026-08-29", description: "SPEI RECIBIDO", account: "BBVA", accountKey: "BBVA:bank:1234", amount: 11000, flow: "income", sourceType: "statement", statementId: statement.id });
  const result = reconcileScreenshotCaptures([capture], [official], [statement]);
  assert.equal(result[0].matchedCount, 0);
  assert.equal(result[0].transactions[0].captureStatus, "review");
});

function screenshotTransaction(overrides: Partial<Transaction> & Pick<Transaction, "id" | "date" | "description" | "account" | "amount" | "flow">): Transaction {
  return {
    category: "Por revisar",
    sourceType: "screenshot",
    captureStatus: "displayed",
    confidence: 0.9,
    ...overrides,
    extractionEvidence: overrides.extractionEvidence ?? { method: "screenshot-ocr", page: 1, confidence: 0.9, sourceText: overrides.description },
  };
}

test("dos screenshots solapados forman una unión y una captura repetida queda marcada como duplicada", () => {
  const first = screenshotTransaction({ id: "first", date: "2026-08-29", description: "SPEI ENVIADO SANTANDER", account: "BBVA", accountKey: "BBVA:bank:1234", amount: -11000, flow: "expense", sourceCaptureId: "capture-a" });
  const overlap = screenshotTransaction({ id: "overlap", date: "2026-08-29", description: "SPEI ENVIADO SANTANDER", account: "BBVA", accountKey: "BBVA:bank:1234", amount: -11000, flow: "expense", sourceCaptureId: "capture-b" });
  const secondPeriod = screenshotTransaction({ id: "second-period", date: "2026-08-31", description: "RETIRO SIN TARJETA", account: "BBVA", accountKey: "BBVA:bank:1234", amount: -1900, flow: "expense", sourceCaptureId: "capture-b" });
  const sameImage = screenshotTransaction({ id: "same-image", date: "2026-08-29", description: "SPEI ENVIADO SANTANDER", account: "BBVA", accountKey: "BBVA:bank:1234", amount: -11000, flow: "expense", sourceCaptureId: "capture-b", extractionEvidence: { method: "screenshot-ocr", page: 1, confidence: 0.9, sourceText: "SPEI ENVIADO SANTANDER" } });
  const result = deduplicateScreenshotTransactions([first, overlap, secondPeriod, sameImage]);

  assert.equal(result.duplicateCount, 1);
  assert.equal(result.canonical.length, 3);
  assert.equal(result.transactions.find((transaction) => transaction.id === "overlap")?.duplicateOf, "first");
  assert.equal(result.transactions.find((transaction) => transaction.id === "same-image")?.duplicateOf, undefined);
});

test("el solapamiento también detecta un concepto recortado por OCR", () => {
  const complete = screenshotTransaction({ id: "complete", date: "2026-09-05", description: "ATRAC GRAN RECINTO TLALNEPANTLA DE", account: "Amex", accountKey: "Amex:card:1003", amount: -80, flow: "expense", sourceCaptureId: "capture-complete" });
  const clipped = screenshotTransaction({ id: "clipped", date: "2026-09-05", description: "ATRAC GRAN RECINTO", account: "Amex", accountKey: "Amex:card:1003", amount: -80, flow: "expense", sourceCaptureId: "capture-clipped" });
  const result = deduplicateScreenshotTransactions([complete, clipped]);
  assert.equal(result.duplicateCount, 1);
  assert.equal(result.transactions[1].duplicateOf, "complete");
});

test("la conciliación confirma una captura contra el estado oficial sin sustituir ni mezclar cuentas", () => {
  const statement: Statement = {
    id: "statement-santander-aug",
    source: "Santander",
    accountKey: "Santander:bank:7079",
    kind: "bank",
    period: "agosto 2026",
    fileName: "santander-agosto.pdf",
    importedAt: capturedAt,
    mode: "text",
    transactionCount: 1,
    status: "ready",
    reconciliationStatus: "valid",
    reconciliation: { status: "valid", tolerance: 0.05 },
    sourceDetection: { source: "Santander", confidence: 1, status: "verified", evidence: ["SUPER NOMINA"], ignoredBodyMentions: [] },
  };
  const screenshot = screenshotTransaction({ id: "screen-1", date: "2026-08-29", description: "SPEI RECIBIDO SANTANDER", account: "Santander", accountKey: "Santander:bank:7079", amount: 11000, flow: "income", sourceCaptureId: "capture-1" });
  const unmatchedOtherAccount = screenshotTransaction({ id: "screen-2", date: "2026-08-29", description: "SPEI RECIBIDO SANTANDER", account: "Santander", accountKey: "Santander:bank:9999", amount: 11000, flow: "income", sourceCaptureId: "capture-1" });
  const capture: ScreenshotCapture = {
    id: "capture-1",
    source: "Santander",
    accountKey: "Santander:bank:7079",
    kind: "bank",
    fileNames: ["3-Foto-3.jpg"],
    sourceFingerprints: ["fingerprint-1"],
    importedAt: capturedAt,
    readerVersion: "test",
    parserId: "santander-mobile-screenshot-v1",
    status: "provisional",
    transactionCount: 2,
    duplicateCount: 0,
    matchedCount: 0,
    reviewCount: 0,
    warnings: [],
    transactions: [screenshot, unmatchedOtherAccount],
  };
  const official = screenshotTransaction({ id: "official-1", date: "2026-08-29", description: "SPEI RECIBIDO SANTANDER", account: "Santander", accountKey: "Santander:bank:7079", amount: 11000, flow: "income", sourceType: "statement", statementId: statement.id, extractionEvidence: { method: "pdf-text", page: 1, confidence: 1, sourceText: "SPEI RECIBIDO SANTANDER" } });
  const deduplicated = deduplicateScreenshotCaptures([capture], [statement]);
  const result = reconcileScreenshotCaptures(deduplicated, [official], [statement]);

  assert.equal(result[0].matchedCount, 1);
  assert.equal(result[0].status, "partially-reconciled");
  assert.equal(result[0].transactions[0].matchedTransactionId, "official-1");
  assert.equal(result[0].transactions[0].captureStatus, "confirmed");
  assert.equal(result[0].transactions[1].matchedTransactionId, undefined, "la cuenta enmascarada evita cruzar otra cuenta");
  assert.equal(result[0].transactions[1].captureStatus, "review");
});
