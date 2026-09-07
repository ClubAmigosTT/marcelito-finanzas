import test from "node:test";
import assert from "node:assert/strict";
import { parseDeterministicStatement } from "../src/issuerParsers/index.ts";
import type { DocumentLayout, DocumentLayoutLine } from "../src/issuerParsers/types.ts";

const line = (page: number, words: Array<[number, string]>): DocumentLayoutLine => ({
  page,
  words: words.map(([x, text]) => ({ x, text, confidence: 1 })),
});

const layout = (...lines: DocumentLayoutLine[]): DocumentLayout => ({ pages: [{ page: 1, lines }] });

function santanderFixture(opening: string, deposits: string, withdrawals: string, closing: string) {
  const text = [
    "Banco Santander México, S.A.",
    "Cuenta de cheques",
    `Saldo inicial ${opening}`,
    `+ Depósitos ${deposits}`,
    `- Retiros ${withdrawals}`,
    `= Saldo final ${closing}`,
    "Detalle de movimientos cuenta de cheques.",
    "TOTAL",
  ].join("\n");
  return { text, layout: layout(
    line(1, [[0.10, "Detalle de movimientos cuenta de cheques."]]),
    line(1, [[0.06, "FECHA"], [0.14, "FOLIO"], [0.20, "DESCRIPCION"], [0.63, "DEPOSITO"], [0.75, "RETIRO"], [0.88, "SALDO"]]),
    line(1, [[0.06, "01-JUL-2026"], [0.14, "0000001"], [0.20, "ABONO PAGO DE NOMINA"], [0.66, deposits], [0.90, String((Number(opening.replace(/,/g, "")) + Number(deposits.replace(/,/g, ""))).toFixed(2))]]),
    line(1, [[0.06, "02-JUL-2026"], [0.14, "0000002"], [0.20, "PAGO TRANSFERENCIA"], [0.77, withdrawals], [0.90, closing]]),
    line(1, [[0.20, "TOTAL"], [0.66, deposits], [0.77, withdrawals]]),
  ) };
}

test("golden Santander julio concilia al centavo desde la tabla de cheques", () => {
  const input = santanderFixture("87,801.76", "40,833.38", "73,007.21", "55,627.93");
  const parsed = parseDeterministicStatement({ source: "Santander", fileName: "Santander-julio.pdf", mode: "ocr", ...input });
  assert.equal(parsed.parserId, "santander-checking-v1");
  assert.equal(parsed.summary.depositTotal, 40_833.38);
  assert.equal(parsed.summary.withdrawalTotal, 73_007.21);
  assert.equal(parsed.summary.cashBalance, 55_627.93);
  assert.equal(parsed.reconciliation.status, "valid");
  assert.deepEqual(parsed.transactions.map((row) => row.amount), [40_833.38, -73_007.21]);
});

test("golden Santander agosto concilia al centavo desde la tabla de cheques", () => {
  const input = santanderFixture("55,627.93", "36,187.42", "64,161.11", "27,654.24");
  const parsed = parseDeterministicStatement({ source: "Santander", fileName: "Santander-agosto.pdf", mode: "ocr", ...input });
  assert.equal(parsed.summary.depositTotal, 36_187.42);
  assert.equal(parsed.summary.withdrawalTotal, 64_161.11);
  assert.equal(parsed.summary.cashBalance, 27_654.24);
  assert.equal(parsed.reconciliation.status, "valid");
});

test("golden BBVA agosto usa solo Detalle de Movimientos Realizados", () => {
  const amounts = [-120, 15_000, -13_000, -500, -100, -3_253, 4_500, -4_515.83, -60.23, -9.63, -500];
  const rows = amounts.map((amount, index) => line(2, [
    [0.03, `${String(index + 1).padStart(2, "0")}/AGO`],
    [0.10, `${String(index + 1).padStart(2, "0")}/AGO`],
    [0.18, amount > 0 ? "SPEI RECIBIDO" : "MOVIMIENTO BBVA"],
    [amount > 0 ? 0.70 : 0.64, Math.abs(amount).toLocaleString("en-US", { minimumFractionDigits: 2 })],
  ]));
  const text = [
    "BBVA MEXICO, S.A.",
    "Saldo Anterior 3,589.63",
    "Depósitos / Abonos (+) 2 19,500.00",
    "Retiros / Cargos (-) 9 22,058.69",
    "Saldo Final 1,030.94",
    "Detalle de Movimientos Realizados",
    "Total de Movimientos",
    "TOTAL IMPORTE CARGOS 22,058.69 TOTAL MOVIMIENTOS CARGOS 9",
    "TOTAL IMPORTE ABONOS 19,500.00 TOTAL MOVIMIENTOS ABONOS 2",
  ].join("\n");
  const parsed = parseDeterministicStatement({
    source: "BBVA",
    fileName: "BBVA-agosto.pdf",
    mode: "text",
    text,
    layout: layout(
      line(2, [[0.02, "Detalle de Movimientos Realizados"]]),
      line(2, [[0.03, "OPER"], [0.10, "LIQ"], [0.18, "DESCRIPCION"], [0.64, "CARGOS"], [0.70, "ABONOS"], [0.80, "OPERACION"], [0.92, "LIQUIDACION"]]),
      ...rows,
      line(2, [[0.02, "Total de Movimientos"]]),
    ),
  });
  assert.equal(parsed.parserId, "bbva-movements-v1");
  assert.equal(parsed.summary.depositTotal, 19_500);
  assert.equal(parsed.summary.withdrawalTotal, 22_058.69);
  assert.equal(parsed.summary.cashBalance, 1_030.94);
  assert.equal(parsed.transactions.length, 11);
  assert.equal(parsed.reconciliation.status, "valid");
});

const amex = (options: {
  period: string;
  previous: string;
  paymentsCredits: string;
  newTransactions: string;
  msi: string;
  statementBalance: string;
  minimum: string;
  limit: string;
  available: string;
  pending: string;
  payment?: string;
  credit?: string;
}) => {
  const domesticNet = Number(options.newTransactions.replace(/,/g, "")) - 2 * Number(options.credit?.replace(/,/g, "") ?? 0);
  const domesticSubtotal = Math.abs(domesticNet).toLocaleString("en-US", { minimumFractionDigits: 2 });
  return [
  "American Express The Platinum Credit Card",
  "Saldo Anterior Pagos y Créditos Nuevos Cargos Saldo Actual Pago para no generar intereses Pago Mínimo",
  `${options.previous} - ${options.paymentsCredits} + ${(Number(options.newTransactions.replace(/,/g, "")) + Number(options.msi.replace(/,/g, ""))).toLocaleString("en-US", { minimumFractionDigits: 2 })} = ${options.statementBalance} ${options.minimum}`,
  `Período de Facturación ${options.period}`,
  `Límite de Crédito Límite Disponible\na Agosto 27,2026 ${options.limit} MN ${options.available} MN`,
  `Nuevas transacciones: ${options.newTransactions}`,
  `Total Nuevos Cargos: ${(Number(options.newTransactions.replace(/,/g, "")) + Number(options.msi.replace(/,/g, ""))).toLocaleString("en-US", { minimumFractionDigits: 2 })}`,
  `Total de Plan de Meses sin Intereses ${options.pending} ${options.msi}`,
  "Fecha y Detalle de las operaciones Importe en MN.",
  ...(options.payment ? [`1 de Junio GRACIAS POR SU PAGO EN LINEA ${options.payment}`, "CR"] : []),
  `2 de Junio COMPRA NACIONAL ${(Number(options.newTransactions.replace(/,/g, "")) - Number(options.credit?.replace(/,/g, "") ?? 0)).toLocaleString("en-US", { minimumFractionDigits: 2 })}`,
  ...(options.credit ? [`3 de Junio MONTO A DIFERIR MESES EN AUTOMÁTICO ${options.credit}`, "CR", `Total de las transacciones en $ de CLIENTE ${domesticSubtotal}${domesticNet < 0 ? " CR" : ""}`, `4 de Junio COMPRA MONEDA EXTRANJERA ${options.credit}`, `Peso Colombiano 10,000.00 TC:0.00560`, `Total de Transacciones en Moneda Extranjera de CLIENTE ${options.credit}`] : []),
  ...(options.credit ? [] : ["Total de las transacciones en $ de CLIENTE"]),
  "Transacciones de Meses sin Intereses",
  `27 de Junio MESES EN AUTOMÁTICO EXTRANJERO ${options.msi}`,
  "Total de Meses sin Intereses",
  ].join("\n");
};

test("goldens Amex concilian nuevas transacciones y distinguen pagos, moneda extranjera y MSI", () => {
  const cases = [
    { expected: 28_034.19, text: amex({ period: "Del 28 de Mayo al 27 de Junio de 2026", previous: "0.00", paymentsCredits: "27,537.69", newTransactions: "28,034.19", msi: "9,179.23", statementBalance: "9,675.73", minimum: "1,350.00", limit: "108,000.00", available: "79,965.81", pending: "18,358.46", credit: "27,537.69" }) },
    { expected: 46_711.63, text: amex({ period: "Del 28 de Junio al 27 de Julio de 2026", previous: "9,675.73", paymentsCredits: "34,405.21", newTransactions: "46,711.63", msi: "15,036.56", statementBalance: "36,?", minimum: "1,500.00", limit: "108,000.00", available: "67,659.39", pending: "17,189.73", payment: "34,405.21" }).replace("36,?", "36,?" ) },
    { expected: 33_177.48, text: amex({ period: "Del 28 de Julio al 27 de Agosto de 2026", previous: "23,150.88", paymentsCredits: "32,744.61", newTransactions: "33,177.48", msi: "16,382.40", statementBalance: "39,966.15", minimum: "3,197.29", limit: "150,000.00", available: "99,632.79", pending: "10,401.06", payment: "23,150.88", credit: "9,593.73" }) },
  ];
  // The middle fixture intentionally omits a valid balance equation; its
  // transaction control must still reconcile independently to the issuer's
  // declared "Nuevas transacciones" amount.
  for (const item of cases) {
    const parsed = parseDeterministicStatement({ source: "Amex", fileName: "Amex.pdf", mode: "text", text: item.text });
    assert.equal(parsed.summary.newTransactions, item.expected);
    assert.equal(parsed.reconciliation.extractedChargeTotal, item.expected);
    assert.equal(parsed.reconciliation.status, "valid", parsed.reconciliation.reason);
    assert.ok(parsed.transactions.some((row) => row.kind === "msi"));
  }
  const latest = parseDeterministicStatement({ source: "Amex", fileName: "Amex-julio-agosto.pdf", mode: "text", text: cases[2].text });
  assert.equal(latest.summary.paymentForNoInterest, 39_966.15);
  assert.equal(latest.summary.debtBalance, 50_367.21);
  assert.ok(latest.transactions.some((row) => row.kind === "cardPayment"));
  assert.ok(latest.transactions.some((row) => row.foreignCurrency));
});

test("ningún parser acepta números globales ni filas fuera de su sección", () => {
  const parsed = parseDeterministicStatement({
    source: "BBVA",
    fileName: "fuera-de-tabla.pdf",
    mode: "text",
    text: "BBVA MEXICO, S.A.\n01/AGO 01/AGO COMPRA 99,999.99\nSaldo Final 1,000.00",
    layout: layout(line(1, [[0.03, "01/AGO"], [0.10, "01/AGO"], [0.18, "COMPRA"], [0.64, "99,999.99"]])),
  });
  assert.equal(parsed.transactions.length, 0);
  assert.equal(parsed.reconciliation.status, "invalid");
});
