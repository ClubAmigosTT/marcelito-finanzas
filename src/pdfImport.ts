import type { ImportResult, SourceDetection, StatementKind, StatementReconciliation, StatementSource, StatementSummary, Transaction, TransactionKind } from "./types.ts";
import type { PDFDocumentProxy } from "pdfjs-dist";
import { isAdministrativeDescription, normalizeConcept } from "./reconciliation.ts";

const monthNames = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"];
const monthTokenPattern = "enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|setiembre|octubre|noviembre|diciembre|ene|feb|mar|abr|may|jun|jul|ago|ag0|sep|set|oct|nov|dic";

type PdfTextItem = { str: string; transform: number[] };

function rebuildLines(items: unknown[]) {
  const rows: { y: number; parts: { x: number; text: string }[] }[] = [];
  (items as PdfTextItem[]).forEach((item) => {
    if (!item.str?.trim() || !Array.isArray(item.transform)) return;
    const x = item.transform[4] ?? 0;
    const y = item.transform[5] ?? 0;
    let row = rows.find((candidate) => Math.abs(candidate.y - y) < 2.2);
    if (!row) {
      row = { y, parts: [] };
      rows.push(row);
    }
    row.parts.push({ x, text: item.str.trim() });
  });
  return rows
    .sort((a, b) => b.y - a.y)
    .map((row) => row.parts.sort((a, b) => a.x - b.x).map((part) => part.text).join(" "))
    .join("\n");
}

function normalizeAmount(value: string) {
  let clean = value.replace(/[$\s]/g, "").trim();
  const comma = clean.lastIndexOf(",");
  const dot = clean.lastIndexOf(".");
  if (comma >= 0 && dot >= 0) {
    clean = comma > dot
      ? clean.replace(/\./g, "").replace(",", ".")
      : clean.replace(/,/g, "");
  } else if (comma >= 0) {
    const decimals = clean.length - comma - 1;
    clean = decimals === 1 || decimals === 2 ? clean.replace(",", ".") : clean.replace(/,/g, "");
  }
  const parsed = Number.parseFloat(clean);
  return Number.isFinite(parsed) ? parsed : 0;
}

function normalizeText(value: string) {
  return value
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase();
}

/**
 * Returns the issuer from institutional evidence only. A bank name inside a
 * transaction description (for example "SPEI RECIBIDO SANTANDER" on a BBVA
 * statement) is a counterparty, not the issuer of the document.
 */
export function detectSourceEvidence(text: string, fileName: string): SourceDetection {
  const normalizedFileName = normalizeText(fileName);
  const filenameSource: StatementSource | undefined = /\bbbva\b|bancomer/.test(normalizedFileName)
    ? "BBVA"
    : /american express|\bamex\b/.test(normalizedFileName)
      ? "Amex"
      : /\bsantander\b/.test(normalizedFileName)
        ? "Santander"
        : undefined;

  const normalizedLines = normalizeText(text)
    .split(/\n+/)
    .map((line) => line.replace(/\s+/g, " ").trim())
    .filter(Boolean);
  const institutionalLines: string[] = [];
  let tableStart = normalizedLines.length;
  for (const line of normalizedLines.slice(0, 120)) {
    // The movement table is deliberately excluded from issuer detection.
    if (/detalle\s+de\s+movimientos|movimientos\s+realizados|fecha\s+(?:folio\s+)?descripcion|fecha\s+y\s+detalle/.test(line)) {
      tableStart = institutionalLines.length;
      break;
    }
    institutionalLines.push(line);
  }
  const institutional = institutionalLines.join(" ");
  const body = normalizedLines.slice(tableStart).join(" ");
  // OCR can place the issuer's legal footer after the movement table. It is
  // still authoritative evidence because these markers identify the bank,
  // while generic brand mentions in the body remain counterparty text.
  const fullNormalized = normalizeText(text);
  const knownBodyMentions = ["Santander", "BBVA", "Amex"].filter((name) => {
    const marker = normalizeText(name);
    return body.includes(marker) && filenameSource !== name;
  });
  const result = (source: StatementSource, confidence: number, evidence: string[]): SourceDetection => ({
    source,
    confidence,
    status: confidence >= 0.99 ? "verified" : confidence > 0 ? "review" : "unknown",
    evidence,
    ignoredBodyMentions: knownBodyMentions,
  });

  // Prefer issuer legal names, domains, and other stable header markers over
  // short brand mentions that can legitimately occur in a transfer row.
  if (/grupo\s+financiero\s+santander|santander\.com/.test(institutional)
    || /grupo\s+financiero\s+santander|banco\s+santander\s+m(?:e|é)xico[^\n]{0,140}institucion\s+de\s+banca\s+multiple|santander\.com/.test(fullNormalized)) {
    return result("Santander", filenameSource === "Santander" ? 0.999 : 0.998, ["encabezado institucional Santander", ...(filenameSource === "Santander" ? ["nombre de archivo Santander"] : [])]);
  }
  if (/grupo\s+financiero\s+bbva|bbva\.mx|bba830831lj2/.test(institutional)
    || /grupo\s+financiero\s+bbva|bbva\s+m(?:e|é)xico[^\n]{0,140}institucion\s+de\s+banca\s+multiple|bbva\.mx/.test(fullNormalized)) {
    return result("BBVA", filenameSource === "BBVA" ? 0.999 : 0.998, ["encabezado institucional BBVA", ...(filenameSource === "BBVA" ? ["nombre de archivo BBVA"] : [])]);
  }
  if (/american\s+express|the\s+platinum\s+credit\s+card/.test(institutional)
    || /americanexpress\.com\.mx|american\s+express[^\n]{0,90}(?:company|the\s+platinum\s+credit\s+card)/.test(fullNormalized)) {
    return result("Amex", filenameSource === "Amex" ? 0.999 : 0.998, ["encabezado institucional Amex", ...(filenameSource === "Amex" ? ["nombre de archivo Amex"] : [])]);
  }

  // A standalone brand in the institutional zone is acceptable when the PDF
  // omits its legal name, but never search the complete transaction body.
  if (/\bbbva\b|bancomer/.test(institutional)) return result("BBVA", filenameSource === "BBVA" ? 0.98 : 0.96, ["marca BBVA en encabezado", ...(filenameSource === "BBVA" ? ["nombre de archivo BBVA"] : [])]);
  if (/\bsantander\b/.test(institutional)) return result("Santander", filenameSource === "Santander" ? 0.98 : 0.96, ["marca Santander en encabezado", ...(filenameSource === "Santander" ? ["nombre de archivo Santander"] : [])]);
  const otherBanks: Array<[string, RegExp]> = [
    ["Banorte", /\bbanorte\b/],
    ["HSBC", /\bhsbc\b/],
    ["Scotiabank", /\bscotiabank\b/],
    ["Citibanamex", /\bcitibanamex\b|\bbanamex\b/],
    ["Inbursa", /\binbursa\b/],
    ["Banco Azteca", /banco azteca/],
    ["Banco del Bajío", /banco del bajio/],
    ["Mifel", /\bmifel\b/],
    ["INVEX", /\binvex\b/],
    ["Hey Banco", /hey banco/],
    ["Nu", /\bnu(?: mexico| banco)?\b/],
    ["Klar", /\bklar\b/],
    ["Rappi", /\brappi\b/],
    ["Ualá", /\buala\b/],
  ];
  const detected = otherBanks.find(([, marker]) => marker.test(institutional))?.[0];
  if (detected) return result(detected, filenameSource === detected ? 0.98 : 0.95, [`marca ${detected} en encabezado`]);
  if (filenameSource) return result(filenameSource, 0.9, ["nombre de archivo; falta evidencia institucional"]);
  return result("Desconocido", 0, []);
}

export function detectSource(text: string, fileName: string): StatementSource {
  return detectSourceEvidence(text, fileName).source;
}

function detectStatementKind(text: string, source: StatementSource): StatementKind {
  if (source === "Amex") return "card";
  if (source === "Santander" || source === "BBVA") return "bank";
  const normalized = normalizeText(text);
  const cardMarkers = [
    "tarjeta de credito", "tarjetahabiente", "credito disponible",
    "limite de credito", "linea de credito", "pago minimo", "saldo deudor",
    "credit card", "mastercard", "visa credit",
  ];
  const bankMarkers = [
    "cuenta de cheques", "cuenta de ahorro", "cuenta clabe", "estado de cuenta nomina",
    "super nomina", "depositos", "retiros", "saldo final", "saldo disponible", "cuenta corriente",
    "banorte", "hsbc", "scotiabank", "citibanamex", "banamex", "inbursa", "banco azteca",
    "banco del bajio", "mifel", "invex", "hey banco", "nu mexico", "nu banco", "klar", "rappi", "uala",
  ];
  const cardScore = cardMarkers.filter((marker) => normalized.includes(marker)).length;
  const bankScore = bankMarkers.filter((marker) => normalized.includes(marker)).length;
  if (cardScore >= 2 && cardScore >= bankScore) return "card";
  if (bankScore >= 2) return "bank";
  return "unknown";
}

function detectPeriod(text: string, fileName: string) {
  const normalized = text.normalize("NFD").replace(/[\u0300-\u036f]/g, "");
  const periodMatch = normalized.match(/period(?:o|os)\s*(?:de\s+facturacion)?\s*[:-]?\s*([^\n]{8,80})/i);
  if (periodMatch?.[1]) return periodMatch[1].replace(/\s+/g, " ").trim();

  // Scanned PDFs often have no text layer. Their filename is still useful
  // context, so expose a readable month/year instead of the raw slug.
  const normalizedFileName = fileName.normalize("NFD").replace(/[\u0300-\u036f]/g, "");
  const filePeriods = Array.from(normalizedFileName.matchAll(/(?:enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|setiembre|octubre|noviembre|diciembre|ene|feb|mar|abr|may|jun|jul|ago|sep|set|oct|nov|dic)[^\d]{0,8}(20\d{2})/gi));
  const filePeriod = filePeriods.at(-1)?.[0];
  if (filePeriod) return filePeriod.replace(/[_-]+/g, " ").replace(/\s+/g, " ").trim();
  const numericPeriod = normalizedFileName.match(/20(\d{2})[-_. ](0?[1-9]|1[0-2])(?:\D|$)/);
  if (numericPeriod) return `${monthNames[Number(numericPeriod[2]) - 1]} 20${numericPeriod[1]}`;
  const reversedNumericPeriod = normalizedFileName.match(/(?:^|\D)(0?[1-9]|1[0-2])[-_. ]20(\d{2})(?:\D|$)/);
  if (reversedNumericPeriod) return `${monthNames[Number(reversedNumericPeriod[1]) - 1]} 20${reversedNumericPeriod[2]}`;

  const fileLabel = fileName
    .replace(/\.pdf$/i, "")
    .replace(/[_-]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  return fileLabel || "Periodo no identificado";
}

function findSummaryAmount(text: string, labels: string[]) {
  const normalized = text.normalize("NFD").replace(/[\u0300-\u036f]/g, "");
  const label = labels.join("|");
  const match = normalized.match(new RegExp(`(?:${label})[^\\d$-]{0,90}((?<![A-Za-z])-?\\s*\\$?(?:(?:\\d{1,3}(?:[ ,.\\u00a0]\\d{3})+|\\d+)(?:[.,]\\d{1,2})?))`, "i"));
  const raw = match?.[1];
  // Long bare integers immediately after a label are usually account,
  // certificate or reference numbers (e.g. “Saldo Actual / AEC810901298”),
  // never monetary values. Require separators/currency or a short integer.
  if (!raw || (/^\s*\d{7,}\s*$/.test(raw) && !/[.,$]/.test(raw))) return undefined;
  return normalizeAmount(raw);
}

function findLastSummaryAmount(text: string, labels: string[]) {
  const normalized = text.normalize("NFD").replace(/[\u0300-\u036f]/g, "");
  const label = labels.join("|");
  const money = "-?\\s*\\$?(?:(?:\\d{1,3}(?:[ ,.\\u00a0]\\d{3})+|\\d+)(?:[.,]\\d{1,2})?)";
  const matches = Array.from(normalized.matchAll(new RegExp(`(?:${label})[^\\d$-]{0,90}(${money})`, "gi")));
  const value = matches.at(-1)?.[1];
  return value ? normalizeAmount(value) : undefined;
}

function findLastClosingBalance(text: string) {
  const normalized = text.normalize("NFD").replace(/[\u0300-\u036f]/g, "");
  const money = "-?\\s*\\$?(?:(?:\\d{1,3}(?:[ ,.\\u00a0]\\d{3})+|\\d+)(?:[.,]\\d{1,2})?)";
  const matches = Array.from(normalized.matchAll(new RegExp(`saldo\\s+final(?!\\s+del\\s+periodo\\s+anterior)[^\\d$-]{0,90}(${money})`, "gi")));
  const value = matches.at(-1)?.[1];
  return value ? normalizeAmount(value) : undefined;
}

const summaryMoneyPattern = /(?<![A-Za-z0-9])[-+]?\s*\$?(?:\d{1,3}(?:[ ,.\u00a0]\d{3})+(?:[.,]\d{1,2})?|\d+(?:[.,]\d{1,2})?)(?![A-Za-z0-9])/g;

function lineMoneyValues(line: string) {
  return Array.from(line.matchAll(summaryMoneyPattern)).map((match) => ({ raw: match[0], value: normalizeAmount(match[0]) })).filter((item) => item.value !== 0 && Math.abs(item.value) < 100_000_000);
}

function parseStatementSummary(text: string, kind: StatementKind): StatementSummary {
  const summary: StatementSummary = {};
  // Card PDFs repeat labels and account identifiers on every movement page.
  // The first summary zone (before the movement table) is the only safe
  // source for balances, credit line and payment amounts; table totals are
  // handled separately below.
  const normalizedForScope = text.normalize("NFD").replace(/[\u0300-\u036f]/g, "");
  const firstMovementMarker = normalizedForScope.search(/fecha\s+y\s+detalle|detalle\s+de\s+movimientos|movimientos\s+realizados/i);
  const cardSummaryText = kind === "card" && firstMovementMarker >= 0
    ? text.slice(0, firstMovementMarker)
    : text;
  // Bank statements have different summary vocabulary and often place bare
  // operation counts next to “Abonos/Cargos”. Do not populate card-only
  // fields from those incidental numbers; the bank-specific totals below are
  // the only values that feed cash reconciliation.
  const values: Array<[keyof StatementSummary, number | undefined]> = kind === "card"
    ? [
      ["previousBalance", findSummaryAmount(cardSummaryText, ["saldo final del periodo anterior", "saldo anterior", "saldo previo", "saldo inicial"])],
      ["statementBalance", findSummaryAmount(cardSummaryText, ["saldo nuevo", "saldo al corte", "saldo actual", "saldo deudor"])],
      ["newTransactions", findSummaryAmount(cardSummaryText, ["nuevas transacciones", "compras nuevas"])],
      ["payments", findSummaryAmount(cardSummaryText, ["pagos realizados", "pagos efectuados"])],
      ["credits", findSummaryAmount(cardSummaryText, ["pagos y creditos", "creditos", "abonos"])],
      ["newCharges", findSummaryAmount(cardSummaryText, ["nuevos cargos", "total de cargos"])],
      // “Pago para no generar intereses” is a header label, not the interest
      // charge. Parse the issuer's explicit financial-interest row below.
      ["interest", undefined],
      ["fees", findSummaryAmount(cardSummaryText, ["comisiones", "comision"])],
      ["creditLimit", findSummaryAmount(cardSummaryText, ["limite de credito", "linea de credito"])],
      ["creditAvailable", findSummaryAmount(cardSummaryText, ["credito disponible", "disponible para compras"])],
      ["minimumPayment", findSummaryAmount(cardSummaryText, ["pago minimo"])],
      ["minimumPlusMsi", findSummaryAmount(cardSummaryText, ["pago minimo mas meses sin intereses", "pago minimo mas msi"])],
      ["paymentForNoInterest", findSummaryAmount(cardSummaryText, ["pago para no generar intereses", "pago para no generar interes"])],
      ["msiPending", findSummaryAmount(cardSummaryText, ["msi pendientes", "saldo msi", "principal diferido"])],
      ["revolvingBalance", findSummaryAmount(cardSummaryText, ["saldo revolvente", "saldo revolvente al corte"])],
    ]
    : [["previousBalance", findSummaryAmount(text, ["saldo final del periodo anterior", "saldo anterior", "saldo previo", "saldo inicial"])]];
  values.forEach(([key, value]) => {
    if (value !== undefined) (summary as unknown as Record<string, number | undefined>)[key] = value;
  });
  if (kind !== "card") {
    // Bank summaries usually show the opening balance before the closing
    // balance. Pick the last closing value so an older cutoff cannot win.
    const cashBalance = findLastClosingBalance(text) ?? findLastSummaryAmount(text, ["saldo disponible", "saldo actual", "saldo al corte"]);
    if (cashBalance !== undefined) summary.cashBalance = cashBalance;

    const normalizedLines = text.normalize("NFD").replace(/[\u0300-\u036f]/g, "").split(/\n+/).map((line) => line.replace(/\s+/g, " ").trim()).filter(Boolean);
    const summaryLines: string[] = [];
    for (const line of normalizedLines) {
      if (/detalle\s+de\s+movimientos|^fecha\b.*(?:descripcion|detalle)/i.test(line)) break;
      summaryLines.push(line);
    }
    summaryLines.forEach((line) => {
      const normalizedLine = line.toLowerCase();
      // The BBVA statement repeats deposits/charges in a percentage chart
      // later in the PDF. Those values are not the declared period totals.
      const aggregateLabelIndex = normalizedLine.search(/dep.?sitos?|retiros?|abonos?|cargos?/);
      const percentIndex = normalizedLine.indexOf("%");
      if (/porcentaje|objetados|certificado|vencimiento|inversion|producto/.test(normalizedLine)
        || /otros\s+cargos|otros\s+abonos/.test(normalizedLine)
        || (percentIndex >= 0 && aggregateLabelIndex >= 0 && percentIndex > aggregateLabelIndex)) return;
      const valuesInLine = lineMoneyValues(line);
      if (!valuesInLine.length) return;
      // Counts are often printed next to the amount (e.g. “2 19,500.00”).
      // Prefer a token with a decimal/thousands separator over a bare count.
      const monetaryToken = valuesInLine.filter((item) => /[.,$]/.test(item.raw))[0] ?? valuesInLine.at(-1);
      const monetaryValue = monetaryToken?.value;
      if (monetaryValue === undefined) return;
      const isDeposit = /dep.?sitos?|abonos?|total importe abonos?/.test(normalizedLine) && !/retiros?|cargos?/.test(normalizedLine);
      const isWithdrawal = /retiros?|cargos?|total importe cargos?/.test(normalizedLine) && !/dep.?sitos?|abonos?/.test(normalizedLine);
      if (isDeposit) {
        summary.depositTotal = monetaryValue;
        const count = normalizedLine.match(/total movimientos abonos?\s+(\d{1,4})\b/)?.[1]
          ?? normalizedLine.match(/dep.?sitos?\s*\/\s*abonos?[^\d]{0,20}(\d{1,4})\s+(?=(?:\$?\s*)?\d{1,3}(?:[,.]\d{3})*[.,]\d{2}\b)/)?.[1];
        if (count) summary.depositCount = Number(count);
      }
      if (isWithdrawal) {
        summary.withdrawalTotal = monetaryValue;
        const count = normalizedLine.match(/total movimientos cargos?\s+(\d{1,4})\b/)?.[1]
          ?? normalizedLine.match(/retiros?\s*\/\s*cargos?[^\d]{0,20}(\d{1,4})\s+(?=(?:\$?\s*)?\d{1,3}(?:[,.]\d{3})*[.,]\d{2}\b)/)?.[1];
        if (count) summary.withdrawalCount = Number(count);
      }
    });
    // BBVA prints the authoritative totals after the movement table. Prefer
    // those explicit labels over chart/summary values (and over OCR fragments
    // such as a bare `64` from “Retiros 64,161.11”).
    const bankNormalized = normalizeText(text);
    const explicitTotal = (label: string) => {
      const match = bankNormalized.match(new RegExp(`${label}[^\\d$-]{0,80}((?:\\d{1,3}(?:[.,]\\d{3})+|\\d+)[.,]\\d{2})`, "i"));
      return match?.[1] ? normalizeAmount(match[1]) : undefined;
    };
    const explicitDepositTotal = explicitTotal("total\\s+importe\\s+abonos?");
    const explicitWithdrawalTotal = explicitTotal("total\\s+importe\\s+cargos?");
    if (explicitDepositTotal !== undefined) summary.depositTotal = explicitDepositTotal;
    if (explicitWithdrawalTotal !== undefined) summary.withdrawalTotal = explicitWithdrawalTotal;
    const explicitDepositCount = bankNormalized.match(/total\s+movimientos\s+abonos?[^\d]{0,20}(\d{1,4})\b/i)?.[1];
    const explicitWithdrawalCount = bankNormalized.match(/total\s+movimientos\s+cargos?[^\d]{0,20}(\d{1,4})\b/i)?.[1];
    if (explicitDepositCount) summary.depositCount = Number(explicitDepositCount);
    if (explicitWithdrawalCount) summary.withdrawalCount = Number(explicitWithdrawalCount);
  }

  const normalized = text.normalize("NFD").replace(/[\u0300-\u036f]/g, "");
  const moneyToken = "(?:\\d{1,3}(?:[ ,.\\u00a0]\\d{3})+|\\d+)(?:[.,]\\d{1,2})?";
  const decimalMoneyToken = "(?<!\\d)(?:\\d{1,3}(?:[ ,.\\u00a0]\\d{3})+|\\d+)[.,]\\d{2}(?!\\d)";
  const parseToken = (value: string) => normalizeAmount(value.replace(/[^0-9,.-]/g, ""));
  const firstLabeledAmount = (label: string, scopedText = normalized) => {
    const scopedNormalized = scopedText.normalize("NFD").replace(/[\u0300-\u036f]/g, "");
    const match = scopedNormalized.match(new RegExp(`(?:${label})(?![a-z])\\s*:?[^\\d$-]{0,32}(-?\\s*\\$?${moneyToken})`, "i"));
    return match?.[1] ? parseToken(match[1]) : undefined;
  };

  if (kind === "card") {
    // Amex prints the core balance as:
    // previous balance - payments/credits + new charges = statement balance minimum.
    const equation = cardSummaryText.normalize("NFD").replace(/[\u0300-\u036f]/g, "").match(new RegExp(`(${moneyToken})[\\s|]*-[\\s|]*(${moneyToken})[\\s|]*\\+[\\s|]*(${moneyToken})[\\s|]*=[\\s|]*(${moneyToken})\\s+(${moneyToken})`, "i"));
    if (equation) {
      summary.previousBalance = parseToken(equation[1]);
      summary.paymentsCredits = parseToken(equation[2]);
      summary.newCharges = parseToken(equation[3]);
      summary.statementBalance = parseToken(equation[4]);
      summary.paymentForNoInterest = parseToken(equation[4]);
      summary.minimumPayment = parseToken(equation[5]);
    }
    if (!equation) {
      // OCR may insert vertical bars between the arithmetic columns. Keep a
      // literal fallback over the raw summary zone so the card balance is not
      // replaced by an account/reference number elsewhere on the page.
      const fallback = cardSummaryText.match(/((?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2})\s*\|?\s*-\s*((?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2})\s*\|?\s*\+\s*((?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2})\s*\|?\s*=\s*((?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2})\s+((?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2})/);
      if (fallback) {
        summary.previousBalance = parseToken(fallback[1]);
        summary.paymentsCredits = parseToken(fallback[2]);
        summary.newCharges = parseToken(fallback[3]);
        summary.statementBalance = parseToken(fallback[4]);
        summary.paymentForNoInterest = parseToken(fallback[4]);
        summary.minimumPayment = parseToken(fallback[5]);
      }
    }

    const newTransactions = firstLabeledAmount("nuevas transacciones|compras nuevas", cardSummaryText);
    if (newTransactions !== undefined) summary.newTransactions = newTransactions;
    // Do not match the phrase “pago para no generar intereses” from the
    // header; the issuer's labeled financial-interest row is authoritative.
    const interest = cardSummaryText.match(/inter[eé]s\s+financiero[^0-9$-]{0,20}([-+]?\s*\$?(?:\d{1,3}(?:,\d{3})+|\d+)(?:[.,]\d{1,2})?)/i)?.[1]
      ? parseToken(cardSummaryText.match(/inter[eé]s\s+financiero[^0-9$-]{0,20}([-+]?\s*\$?(?:\d{1,3}(?:,\d{3})+|\d+)(?:[.,]\d{1,2})?)/i)![1])
      : firstLabeledAmount("inter[eé]s\\s+del\\s+periodo", cardSummaryText);
    if (interest !== undefined) summary.interest = interest;
    const fees = firstLabeledAmount("comision(?:es)?", cardSummaryText);
    if (fees !== undefined) summary.fees = fees;

    // The transaction table is the reliable source for real card payments;
    // the equation only gives the combined "pagos y créditos" number.
    const paymentMatches = Array.from(normalized.matchAll(new RegExp(`gracias\\s+por\\s+su\\s+pago[^\\d$-]{0,32}(${moneyToken})`, "gi")))
      .map((match) => parseToken(match[1]))
      .filter((value) => value > 0);
    if (paymentMatches.length) {
      summary.payments = paymentMatches.reduce((total, value) => total + value, 0);
      if (summary.paymentsCredits !== undefined) {
        summary.credits = Math.max(0, summary.paymentsCredits - summary.payments);
      }
    }

    const creditSection = cardSummaryText.normalize("NFD").replace(/[\u0300-\u036f]/g, "").match(new RegExp(`limite\\s+de\\s+credito[\\s\\S]{0,220}?(${decimalMoneyToken})[\\s\\S]{0,70}?(${decimalMoneyToken})`, "i"));
    if (creditSection) {
      summary.creditLimit = parseToken(creditSection[1]);
      summary.creditAvailable = parseToken(creditSection[2]);
    }

    // Amex's MSI table ends with the remaining principal followed by the
    // aggregate monthly installment load (for example “Total de Plan ...
    // 10,401.06 16,382.40”). These are future obligations, not new spend.
    const msiTotal = normalized.match(new RegExp(`total\\s+de\\s+plan\\s+de\\s+meses\\s+sin\\s+intereses[^\\d$-]{0,40}(${decimalMoneyToken})[^\\d$-]{0,30}(${decimalMoneyToken})`, "i"));
    if (msiTotal) {
      summary.msiPending = parseToken(msiTotal[1]);
      summary.msiMonthlyLoad = parseToken(msiTotal[2]);
    } else {
      const monthlyTotal = normalized.match(new RegExp(`total\\s+de\\s+meses\\s+sin\\s+intereses[^\\d$-]{0,40}(${decimalMoneyToken})`, "i"));
      if (monthlyTotal) summary.msiMonthlyLoad = parseToken(monthlyTotal[1]);
    }

    // Amex also prints the totals for the domestic and foreign sections. Keep
    // them as independent controls; the global “Nuevos cargos” can include
    // MSI installments and is not an equivalent to the movement table.
    const domesticSectionTotal = normalized.match(new RegExp(`total\\s+de\\s+las\\s+transacciones\\s+en\\s+\\$[^\\d]{0,100}(${decimalMoneyToken})`, "i"));
    const foreignSectionTotal = normalized.match(new RegExp(`total\\s+de\\s+transacciones\\s+en\\s+moneda\\s+extranjera[^\\d]{0,100}(${decimalMoneyToken})`, "i"));
    if (domesticSectionTotal) summary.domesticTransactionTotal = parseToken(domesticSectionTotal[1]);
    if (foreignSectionTotal) summary.foreignTransactionTotal = parseToken(foreignSectionTotal[1]);
  }
  return summary;
}

export { parseStatementSummary };

function transactionKindForReconciliation(transaction: Transaction) {
  const kind = transaction.kind;
  if (kind) return kind;
  const normalized = normalizeText(`${transaction.description} ${transaction.category}`);
  if (/gracias por su pago|pago.*(?:tarjeta|credito|amex)|tarjeta.*pago|abono.*(?:tarjeta|credito)/.test(normalized)) return "cardPayment";
  if (/transfer|traspaso|spei/.test(normalized)) return "bankTransfer";
  if (/devolucion|reembolso|bonificacion|refund/.test(normalized)) return "refund";
  if (/monto a diferir/.test(normalized)) return "credit";
  if (/msi|meses sin intereses|meses en automatico|diferid/.test(normalized)) return "msi";
  return transaction.flow === "income" ? "credit" : "purchase";
}

function sumAbsolute(values: number[]) {
  return values.reduce((total, value) => total + Math.abs(value), 0);
}

/**
 * Compares extracted rows with totals printed by the issuer. Invalid imports
 * are kept out of the ledger; pending imports remain visible but provisional.
 */
export function reconcileStatementImport(kind: StatementKind, summary: StatementSummary | undefined, transactions: Transaction[]): StatementReconciliation {
  const tolerance = 0.05;
  if (!summary) return { status: "pending", tolerance, extractedMovementCount: transactions.length, reason: "El estado no contiene un resumen de totales" };

  if (kind === "bank") {
    const extractedDepositTotal = sumAbsolute(transactions.filter((transaction) => transaction.amount > 0).map((transaction) => transaction.amount));
    const extractedWithdrawalTotal = sumAbsolute(transactions.filter((transaction) => transaction.amount < 0).map((transaction) => transaction.amount));
    const expectedDeposit = summary.depositTotal;
    const expectedWithdrawal = summary.withdrawalTotal;
    const missingTotals = expectedDeposit === undefined || expectedWithdrawal === undefined;
    if (missingTotals) {
      return { status: "pending", tolerance, extractedDepositTotal, extractedWithdrawalTotal, extractedMovementCount: transactions.length, reason: "No se pudieron leer depósitos y retiros declarados" };
    }
    const depositDifference = extractedDepositTotal - expectedDeposit;
    const withdrawalDifference = extractedWithdrawalTotal - expectedWithdrawal;
    const countMismatch = (summary.depositCount !== undefined && summary.depositCount !== transactions.filter((transaction) => transaction.amount > 0).length)
      || (summary.withdrawalCount !== undefined && summary.withdrawalCount !== transactions.filter((transaction) => transaction.amount < 0).length);
    const invalid = transactions.length === 0 && (expectedDeposit > tolerance || expectedWithdrawal > tolerance)
      || Math.abs(depositDifference) > tolerance
      || Math.abs(withdrawalDifference) > tolerance
      || countMismatch;
    return {
      status: invalid ? "invalid" : "valid",
      tolerance,
      extractedDepositTotal,
      extractedWithdrawalTotal,
      extractedMovementCount: transactions.length,
      reason: invalid ? `Las filas no concilian con el resumen (depósitos ${depositDifference.toFixed(2)}, retiros ${withdrawalDifference.toFixed(2)})` : undefined,
    };
  }

  if (kind === "card") {
    const charges = transactions.filter((transaction) => transaction.amount < 0 && !["cardPayment", "bankTransfer", "refund", "credit"].includes(transactionKindForReconciliation(transaction)));
    const payments = transactions.filter((transaction) => transactionKindForReconciliation(transaction) === "cardPayment");
    const extractedChargeTotal = sumAbsolute(charges.map((transaction) => transaction.amount));
    const extractedPaymentTotal = sumAbsolute(payments.map((transaction) => transaction.amount));
    const domesticCharges = charges.filter((transaction) => !transaction.foreignCurrency);
    const foreignCharges = charges.filter((transaction) => transaction.foreignCurrency);
    const extractedDomesticChargeTotal = sumAbsolute(domesticCharges.map((transaction) => transaction.amount));
    const extractedForeignChargeTotal = sumAbsolute(foreignCharges.map((transaction) => transaction.amount));
    // “Nuevos cargos”/“Nuevas transacciones” may include deferred credits or
    // MSI installments. When the issuer exposes domestic + foreign subtotals,
    // those are the authoritative real-spend control; otherwise prefer
    // “Nuevas transacciones” and use newCharges only as a fallback.
    const sectionDeclaredCharges = summary.domesticTransactionTotal !== undefined && summary.foreignTransactionTotal !== undefined
      ? summary.domesticTransactionTotal + summary.foreignTransactionTotal
      : undefined;
    const declaredCharges = sectionDeclaredCharges ?? summary.newTransactions ?? summary.newCharges;
    if (declaredCharges === undefined) return { status: "pending", tolerance, extractedChargeTotal, extractedDomesticChargeTotal, extractedForeignChargeTotal, extractedPaymentTotal, extractedMovementCount: transactions.length, reason: "El estado no contiene total de cargos" };
    const chargeDifference = extractedChargeTotal - declaredCharges;
    const paymentDifference = summary.payments !== undefined ? extractedPaymentTotal - summary.payments : 0;
    const sectionDifferences: string[] = [];
    if (summary.domesticTransactionTotal !== undefined) {
      const difference = extractedDomesticChargeTotal - summary.domesticTransactionTotal;
      if (Math.abs(difference) > tolerance) sectionDifferences.push(`nacionales ${difference.toFixed(2)}`);
    }
    if (summary.foreignTransactionTotal !== undefined) {
      const difference = extractedForeignChargeTotal - summary.foreignTransactionTotal;
      if (Math.abs(difference) > tolerance) sectionDifferences.push(`moneda extranjera ${difference.toFixed(2)}`);
    }
    const invalid = transactions.length === 0 && declaredCharges > tolerance
      || Math.abs(chargeDifference) > tolerance
      || (summary.payments !== undefined && Math.abs(paymentDifference) > tolerance)
      || sectionDifferences.length > 0;
    return {
      status: invalid ? "invalid" : "valid",
      tolerance,
      extractedChargeTotal,
      extractedDomesticChargeTotal,
      extractedForeignChargeTotal,
      extractedPaymentTotal,
      extractedMovementCount: transactions.length,
      reason: invalid ? `Las filas no concilian con cargos/pagos del estado (cargos ${chargeDifference.toFixed(2)}, pagos ${paymentDifference.toFixed(2)}${sectionDifferences.length ? `, secciones ${sectionDifferences.join("; ")}` : ""})` : undefined,
    };
  }
  return { status: "pending", tolerance, extractedMovementCount: transactions.length, reason: "Tipo de estado no identificado" };
}

function guessCategory(description: string) {
  const value = normalizeText(description);
  const rules: Array<[string, RegExp]> = [
    ["Viajes", /airbnb|booking|expedia|hotel|hospedaje|aeromexico|aerobus|volaris|vivaaerobus|american airlines|united airlines|delta air|iberia|vuelo|flight|travel|renta de auto|car rental|airport|aeropuerto|equipaje|luggage/],
    ["Transporte", /uber|didi|cabify|taxi|metrobus|metrotap|nyct paygo|njtransit|nyc ferry|subway|mta |train |estacionamiento|estac |parking|parco |gasolina|pemex|shell|\bbp\b|gulf|mobil|caseta|autopista|toll|ecobici|mueve|transporte/],
    ["Salud", /farmacia|farmacias|hospital|clinica|doctor|consultorio|dent|dental|laboratorio|salud|medic/],
    ["Comidas", /restaurant|rest |rest\.|taquer|taco|sushi|cafe|coffee|starbucks|burger|pizza|pub|bar |comida|food|flauta|ramen|krispy|pan |pastel|helado|neveria|churro|frutos prohibidos|grill|deli|pantry|wine|beer|chicken|cocina|parrilla|guac time|chipotle|dos toros|dunkin|italian|crepes|sanborns|cerv|mariscos|exquisito|faunna|terraza|los gueros|guero|harp helu|serena horneando|tierra garat|malachy|sophie|lovejoy|smokejazz|smoke and gift|metropolis|mandarin mo|social|goldbergs|marta tap|hana group|tst\*|shreeji|jimmys|primavera|saio la octava|pickle|fogoncito|burger king|aifa|asador/],
    ["Alimentos", /walmart|superama|soriana|costco|chedraui|la comer|city market|sam'?s|sams |oxxo|7 eleven|seven eleven|extra k|extra |super |mercado\s|grocery|market|mkt |frutos|abarrotes|cvs|pharmacy|wholefds|whole foods|queens mkt|convenience|meadowland|mart corp|7-eleven/],
    ["Entretenimiento", /cinemex|cinepolis|cine |cinemas|teatro|spotify|netflix|disney|hbo|prime video|apple music|xbox|playstation|nintendo|steam|videojuego|club deportivo|entret |jazz|museum|museo|amnh|guggenheim|aquarium|acuario|zoo|attraction|atraccion|ticket|boletos|show|concierto|club |soccer|summit one|world of coca|circo|stadium|rounders|empire hall|hard rock|salon de perreo|asdeporte/],
    ["Educación", /universidad|escuela|colegio|curso|udemy|coursera|domestika|libros|libreria/],
    ["Mascotas", /veterin|petco|pet shop|mascota|mundo animal/],
    ["Hogar", /ikea|home depot|ferreter|muebles|hogar|limpieza|decoracion|mantenimiento/],
    ["Servicios", /canva|telcel|at&t|movistar|izzi|totalplay|cfe|luz |agua |internet|seguro|asegur|suscripcion|membresia|adobe|microsoft|google storage|apple\.com\/bill|apple\.com\/mx|paypal|stripe|holafly|wi-fi onboard|wifi onboard/],
    ["Compras", /amazon|shein|mercadolibre|mercado libre|mercadopago|lumen|steren|bout|tienda|shop|store|ropa|zapateria|departamental|old navy|fanatics|thriftland|miniso/],
    ["Finanzas", /comision|interes|cajero|retiro|anualidad|financ|keepcash|meses sin intereses|meses en automatico|meses automatico|monto a diferir|diferid/],
  ];
  const match = rules.find(([, marker]) => marker.test(value));
  if (match) return match[0];
  return "Sin categoría";
}

function inferImportedKind(description: string, amount: number, isCredit: boolean, statementKind: StatementKind, explicitOwnTransfer = false): TransactionKind {
  const value = normalizeText(description);
  if (/monto a diferir/.test(value) && amount > 0) return "credit";
  if (/msi|meses sin intereses|meses en automatico|diferir|diferid/.test(value)) return "msi";
  if (/interes|interes moratorio/.test(value)) return "interest";
  if (/comision|anualidad/.test(value)) return "fee";
  if (/devolucion|reembolso|bonificacion/.test(value) && amount > 0) return "refund";
  if (/gracias por su pago|pago en linea|pago.*(tarjeta|amex|credito|recibido)|tarjeta.*pago|abono.*(tarjeta|credito|recibido)|american express/.test(value)) return "cardPayment";
  if (/transfer|traspaso/.test(value)) return explicitOwnTransfer ? "bankTransfer" : amount > 0 ? "income" : "purchase";
  // Positive bank rows are real income (deposit, payroll or external SPEI),
  // whereas positive card rows are issuer-side credits and must not inflate
  // income. Keep the two ledgers semantically separate from import time.
  if (isCredit || amount > 0) return statementKind === "card" ? "credit" : "income";
  return "purchase";
}

export function extractTransactions(text: string, source: StatementSource, fileName: string, kind: StatementKind): Transaction[] {
  const lines = text.split(/\n+/).map((line) => line.replace(/\s+/g, " ").trim()).filter(Boolean);
  const results: Transaction[] = [];
  // Bank OCR commonly emits 16-JUL-2026 or 23/JUL, while Amex's text
  // layer uses “20 de Junio 2026”. Keep the optional year narrow so a
  // merchant such as “125TH FINEST” cannot be swallowed as year 125.
  const datePattern = new RegExp(
    `^(?:(\\d{1,2})\\s*(?:de\\s*)?(${monthTokenPattern})(?:\\s*(?:de\\s*)?((?:20\\d{2}|\\d{2})(?!\\d)))?|(?:(\\d{1,2})[-/.](\\d{1,2})[-/.](20\\d{2}|\\d{2}))|(?:(20\\d{2})[-/.](\\d{1,2})[-/.](\\d{1,2}))|(?:(\\d{1,2})[-/](${monthTokenPattern})(?:[-/](20\\d{2}|\\d{2}))?))`,
    "i",
  );
  const amountPattern = /(?<![A-Za-z0-9])[-+]?\s*\$?(?:\d{1,3}(?:[ ,.\u00a0]\d{3})+(?:[.,]\d{1,2})?|\d+(?:[.,]\d{1,2})?)(?:\s*CR)?(?![A-Za-z0-9])/gi;
  const importKey = normalizeText(fileName).replace(/[^a-z0-9]+/g, "-").slice(0, 28) || "estado";
  const inferredYear = fileName.match(/20\d{2}/)?.[0] ?? text.match(/20\d{2}/)?.[0] ?? String(new Date().getFullYear());
  let previousRunningBalance = kind === "bank"
    ? findSummaryAmount(text, ["saldo final del periodo anterior", "saldo anterior", "saldo inicial"])
    : undefined;
  const monthIndex = (token: string) => {
    const value = normalizeText(token).replace(/^ag0?$/, "ago");
    const full = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"];
    const index = full.findIndex((month) => month.startsWith(value) || value.startsWith(month.slice(0, 3)));
    if (value.startsWith("sep") || value.startsWith("set")) return 8;
    return index >= 0 ? index : 0;
  };
  const formatDate = (match: RegExpMatchArray) => {
    const yearValue = (value?: string) => value ? (value.length === 2 ? `20${value}` : value) : inferredYear;
    if (match[1] && match[2]) return `${match[1]} ${monthNames[monthIndex(match[2])]} ${yearValue(match[3])}`;
    if (match[4] && match[5] && match[6]) return `${match[4]} ${monthNames[Math.max(0, Number(match[5]) - 1)]} ${yearValue(match[6])}`;
    if (match[7] && match[8] && match[9]) return `${match[9]} ${monthNames[Math.max(0, Number(match[8]) - 1)]} ${match[7]}`;
    if (match[10] && match[11]) return `${match[10]} ${monthNames[monthIndex(match[11])]} ${yearValue(match[12])}`;
    return "Sin fecha";
  };

  // A PDF text layer may put the merchant, RFC/reference and amount on
  // separate lines. Reassemble each date-anchored row before extracting it.
  const rows: string[] = [];
  let pending = "";
  const breakPhrases = [
    "estado de cuenta", "fecha y detalle", "resumen de cuenta", "paga desde",
    "este no es un documento", "total de las transacciones", "total de transacciones",
    "total de movimientos", "periodo de facturacion", "fecha de corte", "pagina ",
    "ciudad de mexico", "serie del certificado", "total importe", "numero de cuenta",
    "no de cuenta", "numero de cliente", "no de cliente", "cuenta clabe", "rfc",
    "saldo inicial", "saldo anterior", "saldo final", "saldo disponible", "del al",
  ];
  let skipCardSection = false;
  for (const line of lines) {
    const normalized = normalizeText(line);
    // OCR recognition is page-oriented. A page boundary must terminate the
    // previous row; otherwise the first header/summary number on the next
    // page can be appended to a real transaction.
    if (/^__pdf_page_\d+__$/.test(normalized)) {
      if (pending) rows.push(pending);
      pending = "";
      continue;
    }
    // Amex repeats a date/detail table for regular purchases, then prints
    // separate MSI tables. MSI installments are future obligations and must
    // never become new spend rows. Resume only at the next movement header.
    if (kind === "card" && /transacciones de meses sin intereses|resumen de meses sin intereses|consolidado de compras en meses sin intereses|descripcion de compras en meses sin intereses/.test(normalized)) {
      if (pending) rows.push(pending);
      pending = "";
      skipCardSection = true;
      continue;
    }
    if (skipCardSection && /fecha\s+y\s+detalle|detalle\s+de\s+movimientos|movimientos\s+realizados/.test(normalized)) {
      skipCardSection = false;
      continue;
    }
    if (skipCardSection) continue;
    // Tesseract frequently confuses a leading zero with O/B/I in compact
    // bank dates (O5/AGO, O7/AGO, OBIAGO). Repair only this tightly bounded
    // prefix; never rewrite numbers inside merchant descriptions.
    const dateLine = line
      .replace(/^(\d{1,2})HUL\b/i, "$1/JUL")
      .replace(/^O(?=\d\s*\/)/i, "0")
      .replace(/^O[B8](?:I)?(?=\s*\/?\s*AGO\b)/i, "07/");
    const startsWithDate = datePattern.test(dateLine);
    const breaks = breakPhrases.some((phrase) => normalized.includes(phrase))
      || /^(?:del\s+al|total\b|saldo\b|periodo\b|fecha\s+de\s+corte|rfc\b|clabe\b)/.test(normalized);
    if (startsWithDate) {
      if (pending) rows.push(pending);
      pending = dateLine;
    } else if (pending && !breaks) {
      pending += ` ${line}`;
    } else if (breaks && pending) {
      rows.push(pending);
      pending = "";
    }
  }
  if (pending) rows.push(pending);

  rows.forEach((line, index) => {
    const date = line.match(datePattern);
    if (!date) return;
    const dayToken = date[1] ?? date[4] ?? date[9] ?? date[10];
    const dayNumber = Number(dayToken);
    if (!Number.isInteger(dayNumber) || dayNumber < 1 || dayNumber > 31) return;
    const tail = line.slice(date[0].length).trim();
    const allCandidates = Array.from(tail.matchAll(amountPattern)).map((match) => {
      const index = match.index ?? 0;
      const before = tail.slice(0, index);
      // OCR frequently joins the last digit of a time with the following
      // amount (e.g. “15:20:49 100.00” -> “49 100.00”). Recover the amount
      // suffix instead of dropping the whole token or using the running
      // balance as the transaction amount.
      const joinedAmount = /:\s*$/.test(before) ? match[0].match(/\s(\$?\d{1,3}(?:[,.]\d{3})*[.,]\d{2})$/) : undefined;
      const raw = joinedAmount?.[1] ?? match[0];
      const adjustedIndex = joinedAmount ? index + match[0].lastIndexOf(raw) : index;
      return { raw, index: adjustedIndex, value: normalizeAmount(raw) };
    }).filter((candidate) => candidate.value !== 0 && Math.abs(candidate.value) < 100_000_000);
    // Prefer tokens that look like money. This prevents terminal numbers in
    // merchant names (store IDs, references and route numbers) from winning.
    const candidates = allCandidates.filter((candidate) => /[.,]\d{1,2}|\$|\bCR\b/i.test(candidate.raw));
    const usableCandidates = candidates.length ? candidates : allCandidates;
    if (!usableCandidates.length) return;
    const normalizedLine = normalizeText(line);
    const bankLike = kind === "bank" || /deposito|retiro|saldo|cuenta de cheques|cuenta de ahorro|abono|cargo/.test(normalizedLine);
    const foreignCurrency = /dolar|euro|peso colombiano|tipo de cambio|\btc\b/.test(normalizedLine);
    // Bank rows often finish with a running balance. Select the preceding
    // amount so the balance is not recorded as a purchase.
    const amount = foreignCurrency
      ? (usableCandidates.filter((candidate) => {
        const currencyIndex = tail.search(/d[oó]lar|euro|peso(?:s)?\s+colombiano?s?|tipo\s+de\s+cambio|\btc\b/i);
        return currencyIndex < 0 || candidate.index < currencyIndex;
      }).at(-1) ?? usableCandidates[0])
      : bankLike && usableCandidates.length > 1
        ? usableCandidates[0]
        : usableCandidates[usableCandidates.length - 1];
    let amountValue = amount.value;
    if (bankLike) {
      // Bank rows expose a running balance immediately after the movement
      // amount. When OCR misreads the amount (for example 160.00 instead of
      // 60.00), the balance delta is the authoritative correction. If a row
      // has no balance, reset the chain rather than guessing across it.
      const runningBalance = usableCandidates.length > 1 ? usableCandidates[1] : undefined;
      if (runningBalance && previousRunningBalance !== undefined) {
        const delta = runningBalance.value - previousRunningBalance;
        if (Number.isFinite(delta) && Math.abs(delta) > 0 && Math.abs(delta) < 100_000_000
          // A running-balance delta can repair a one- or two-cent OCR typo,
          // but must not replace a valid amount when the OCR balance itself
          // drifted (common on scanned BBVA statements).
          && Math.abs(Math.abs(delta) - Math.abs(amountValue)) > 0.05
          && Math.abs(Math.abs(delta) - Math.abs(amountValue)) <= 2) {
          amountValue = Math.abs(delta);
        }
        previousRunningBalance = runningBalance.value;
      } else if (!runningBalance) {
        previousRunningBalance = undefined;
      }
    }
    const rawDescription = tail.slice(0, amount.index).trim();
    // Foreign Amex rows include currency and exchange-rate metadata before
    // the local amount. Keep the merchant name and discard that metadata.
    const description = rawDescription
      // BBVA prints operation and settlement dates before the merchant. They
      // are already represented by `date`, so do not pollute merchant keys.
      .replace(/^\d{1,2}[-/]\w+(?:[-/](?:20)?\d{2})?(?:\s+\d{1,2}[-/]\w+(?:[-/](?:20)?\d{2})?)?\s+/i, "")
      .replace(/\s+(?:d[oó]lar(?:es)?(?:\s+u\.s\.a\.)?|euro?s?|peso(?:s)?\s+colombiano?s?|tipo\s+de\s+cambio).*$/i, "")
      .replace(/\s+/g, " ")
      .trim();
    if (!description || description.length < 3 || isAdministrativeDescription(description)) return;
    // Amex transaction amounts are always printed with cents. A bare integer
    // in a merchant name (for example “7 ELEVEN ... 2514”) is an OCR/store
    // identifier, not a charge; reject it instead of creating a large false
    // expense. Bank rows retain integer amounts when their direction is clear.
    if (kind === "card" && !/[.,$]/.test(amount.raw) && !/\bcr\b/i.test(amount.raw)) return;
    const normalizedDescription = normalizeConcept(description);
    const isRefund = /devolucion|reembolso|bonificacion/.test(normalizedDescription);
    const isCardPayment = /gracias por su pago|pago de tarjeta|pago.*(?:tarjeta|credito|recibido)|tarjeta.*pago|abono.*(?:tarjeta|credito|recibido)/.test(normalizedDescription);
    const isIncome = /nomina|sueldo|salario|deposito|abono|ingreso|recibid|transferencia recibida|spei recibido/.test(normalizedDescription);
    const isTransfer = /transfer|traspaso|spei|entre cuentas|clabe/.test(normalizedDescription);
    const explicitOwnTransfer = /entre cuentas|cuenta propia|mismo titular|traspaso interno/.test(normalizedDescription);
    // In text-layer PDFs the issuer sometimes places “CR” on the next line;
    // the explicit Amex “monto a diferir” concept is already an issuer-side
    // credit, so do not make recognition depend on that line break.
    const isDeferredCredit = kind === "card" && /monto a diferir/.test(normalizedDescription);
    const isCredit = /\bcr\b/i.test(amount.raw) || isRefund || isIncome || isDeferredCredit;
    const directionSignal = kind === "card"
      || (bankLike && usableCandidates.length > 1)
      || isRefund
      || isCardPayment
      || isIncome
      || isTransfer
      || /\b(?:cargo|retiro|compra|consumo|domiciliacion|pago|deposito|abono|nomina|sueldo|salario|credito|devolucion|reembolso|comision|interes|cobro)\b/.test(normalizedDescription)
      || amount.raw.includes("-")
      || amount.raw.includes("+")
      || /\bcr\b/i.test(amount.raw);
    // Text extraction has no column coordinates. When a bank row carries no
    // signed amount or semantic direction, retaining it would turn a PDF
    // heading into a financial event, so send it to review by rejecting it.
    if (!directionSignal) return;
    const cardCredit = kind === "card" && isCredit && !isCardPayment;
    const flow: Transaction["flow"] = isRefund || isIncome || isDeferredCredit || cardCredit ? "income" : isCardPayment ? "debt" : explicitOwnTransfer ? "transfer" : "expense";
    const value = Math.round(amountValue * 100) / 100 * (flow === "income" ? 1 : -1);
    const importedKind = inferImportedKind(description, value, isCredit, kind, explicitOwnTransfer);
    const category = importedKind === "cardPayment" || importedKind === "bankTransfer" ? "Transferencia" : guessCategory(description);
    const travelRelated = /viaje|hotel|hospedaje|aerolinea|vuelo|avion|transporte|uber|taxi|metro|renta de auto|destino|equipaje|airbnb|aeropuerto/i.test(normalizedDescription);
    results.push({
      id: `import-${importKey}-${index}-${value}`,
      date: formatDate(date),
      description: description.slice(0, 54),
      account: source,
      category,
      amount: value,
      flow,
      kind: importedKind,
      travelRelated,
      foreignCurrency: kind === "card" ? foreignCurrency : undefined,
      confidence: category === "Sin categoría" ? 0.62 : 0.92,
      extractionEvidence: {
        method: "pdf-text",
        confidence: category === "Sin categoría" ? 0.78 : 0.95,
      },
    });
  });

  // Do not silently drop valid rows from a busy month. The review UI limits
  // the visible page, but every parsed transaction remains available in the
  // ledger and can be refined later.
  return results;
}

async function recognizePdfText(document: PDFDocumentProxy, onProgress: (value: number, label: string) => void) {
  onProgress(82, "Preparando reconocimiento visual");
  const { createWorker } = await import("tesseract.js");
  const worker = await createWorker("spa", 1, {
    logger: ({ progress }) => {
      const normalized = Math.max(0, Math.min(1, progress));
      onProgress(82 + Math.round(normalized * 6), "Preparando reconocimiento visual");
    },
  });
  const pages: string[] = [];

  try {
    for (let pageNumber = 1; pageNumber <= document.numPages; pageNumber += 1) {
      const page = await document.getPage(pageNumber);
      const viewport = page.getViewport({ scale: 2 });
      const canvas = window.document.createElement("canvas");
      canvas.width = Math.ceil(viewport.width);
      canvas.height = Math.ceil(viewport.height);
      const context = canvas.getContext("2d", { willReadFrequently: true });
      if (!context) throw new Error("No se pudo preparar el lienzo para OCR");

      await page.render({ canvas: null, canvasContext: context, viewport }).promise;
      const result = await worker.recognize(canvas);
      // Keep explicit page sentinels so row reconstruction cannot cross page
      // boundaries or blend a movement with the following page's summary.
      pages.push(`__PDF_PAGE_${pageNumber}__\n${result.data.text}`);
      onProgress(88 + Math.round((pageNumber / document.numPages) * 10), `Reconociendo página ${pageNumber} de ${document.numPages}`);
      canvas.width = 0;
      canvas.height = 0;
    }
  } finally {
    await worker.terminate();
  }

  return pages.join("\n");
}

export async function inspectPdf(file: File, onProgress: (value: number, label: string) => void): Promise<ImportResult> {
  onProgress(12, "Abriendo el estado de cuenta");
  const [pdfjs, workerModule] = await Promise.all([
    import("pdfjs-dist"),
    import("pdfjs-dist/build/pdf.worker.min.mjs?url"),
  ]);
  pdfjs.GlobalWorkerOptions.workerSrc = workerModule.default;
  const buffer = await file.arrayBuffer();
  const document = await pdfjs.getDocument({ data: buffer }).promise;
  const pageTexts: string[] = [];

  for (let pageNumber = 1; pageNumber <= document.numPages; pageNumber += 1) {
    const page = await document.getPage(pageNumber);
    const content = await page.getTextContent();
    pageTexts.push(rebuildLines(content.items));
    onProgress(12 + Math.round((pageNumber / document.numPages) * 58), `Leyendo pagina ${pageNumber} de ${document.numPages}`);
  }

  const extractedText = pageTexts.join("\n");
  const mode = extractedText.replace(/\s/g, "").length > 500 ? "text" : "ocr";
  const text = mode === "ocr"
    ? await recognizePdfText(document, onProgress)
    : extractedText;
  const sourceDetection = detectSourceEvidence(text, file.name);
  const source = sourceDetection.source;
  const kind = detectStatementKind(text, source);
  onProgress(98, mode === "ocr" ? "Conciliando movimientos reconocidos" : "Conciliando cargos y pagos");

  const parsed = extractTransactions(text, source, file.name, kind).map((transaction) => ({
    ...transaction,
    // The parser is shared by text and OCR input. Preserve the actual method
    // selected by inspectPdf so diagnostics never call an OCR row "text".
    extractionEvidence: {
      ...(transaction.extractionEvidence ?? { confidence: transaction.confidence ?? 0.75 }),
      method: mode === "ocr" ? "ocr" as const : "pdf-text" as const,
    },
  }));
  const summary = parseStatementSummary(text, kind);
  const reconciliation = reconcileStatementImport(kind, summary, parsed);
  onProgress(100, "Listo para revisar");

  return {
    source,
    sourceDetection,
    kind,
    period: detectPeriod(text, file.name),
    fileName: file.name,
    mode,
    transactions: parsed,
    summary,
    reconciliation,
  };
}
