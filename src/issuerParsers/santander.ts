import type { StatementSummary, Transaction } from "../types.ts";
import type { DeterministicParseInput, DeterministicParseResult, DocumentLayoutLine, TemplateMatch } from "./types.ts";
import { cents, fold, layoutLines, lineBounds, lineText, makeTransaction, moneyAfterLabel, parseIssuerDate, reconcileExactly } from "./shared.ts";
import { isWithinColumn, matchSantanderCheckingTemplate } from "./templates.ts";

const sectionTitle = "Detalle de movimientos cuenta de cheques";
const administrativeRow = /(?:clave\s+de\s+rastreo|\bref(?:erencia)?\b|\brfc\b|\bclabe\b|certificado|pagina\s+\d+\s+de\s+\d+|saldo\s+final\s+del\s+periodo\s+anterior)/i;

function parseSummary(text: string): StatementSummary {
  const beforeTable = text.split(/detalle\s+de\s+movimientos\s+cuenta\s+de\s+cheques/i)[0] ?? text;
  return {
    previousBalance: moneyAfterLabel(beforeTable, /saldo inicial|saldo final del periodo anterior/, { last: true }),
    depositTotal: moneyAfterLabel(beforeTable, /^\+?\s*depositos\b/, { last: true }),
    withdrawalTotal: moneyAfterLabel(beforeTable, /^-?\s*retiros\b/, { last: true }),
    cashBalance: moneyAfterLabel(beforeTable, /^=?\s*saldo final\b/, { last: true }),
  };
}

function columnMoney(line: DocumentLayoutLine, template: TemplateMatch, key: "DEPOSITO" | "RETIRO" | "SALDO") {
  const bounds = template.columns?.[key];
  if (!bounds) return undefined;
  // A cell can be split by OCR (for example `1,` + `200.00`), therefore the
  // amount is reconstructed from only its calibrated column tokens. Values
  // from the balance, folio, reference or description areas never enter here.
  const tokens = line.words.filter((word) => isWithinColumn(word, bounds)).map((word) => word.text).join("");
  // Santander prints two decimal places in every movement and control cell.
  // Treat a lost separator (`3000`) as unreadable rather than guessing MXN
  // versus cents. This is a row-level rejection, never a global rewrite.
  if (!/[.,]\d{2}$/.test(tokens.replace(/\s+/g, ""))) return undefined;
  return cents(tokens);
}

function descriptionText(line: DocumentLayoutLine, template: TemplateMatch) {
  const bounds = template.columns?.DESCRIPCION;
  if (!bounds) return "";
  return line.words
    .filter((word) => isWithinColumn(word, bounds))
    .map((word) => word.text)
    .join(" ")
    .replace(/\s+/g, " ")
    .trim();
}

function cleanDescription(value: string) {
  return value
    // These are issuer metadata fields, not a merchant description. They are
    // deliberately removed only from the first field marker through the end
    // of its line; an ordinary name that happens to contain a number survives.
    .replace(/\b(?:rfc|ref(?:erencia)?|clabe|certificado|clave\s+de\s+rastreo)\b.*$/i, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function dateToken(line: DocumentLayoutLine, template: TemplateMatch) {
  const bounds = template.columns?.FECHA;
  if (!bounds) return undefined;
  return line.words
    .filter((word) => isWithinColumn(word, bounds))
    .map((word) => word.text.replace(/AG0/gi, "AGO").match(/^\d{1,2}[-/]\w{3}[-/]20\d{2}/i)?.[0])
    .find((value): value is string => Boolean(value));
}

function rejected(templateMatch: TemplateMatch, summary: StatementSummary): DeterministicParseResult {
  return {
    parserId: "santander-checking-v1",
    sourceSection: sectionTitle,
    transactions: [],
    summary,
    reconciliation: {
      status: "invalid",
      tolerance: 0,
      extractedMovementCount: 0,
      reason: `Plantilla Santander en revisión: ${templateMatch.reason}`,
    },
    rejectedRowCount: 0,
    rejectedRows: [templateMatch.reason],
    templateMatch,
  };
}

/**
 * Santander's extractor is intentionally template-first. A document whose
 * title/header/geometry do not match v1 has no generic text fallback and
 * cannot influence any financial projection.
 */
export function parseSantander(input: DeterministicParseInput): DeterministicParseResult {
  const summary = parseSummary(input.text);
  const templateMatch = matchSantanderCheckingTemplate(input.layout, input.text);
  if (templateMatch.status !== "matched") return rejected(templateMatch, summary);

  const rows: Transaction[] = [];
  let active = false;
  let rejectedRowCount = 0;
  const rejectedRows: string[] = [];
  let lastBalance: number | undefined;
  let pending: {
    line: DocumentLayoutLine;
    date: string;
    description: string;
    deposit?: number;
    withdrawal?: number;
    balance?: number;
    confidence: number;
  } | undefined;

  const finish = () => {
    if (!pending) return;
    const directions = [pending.deposit, pending.withdrawal].filter((value) => value !== undefined);
    // A selected row requires exactly one movement column and an independent
    // running-balance control. The SALDO is evidence only: it cannot become a
    // transaction amount even when it happens to make totals look plausible.
    if (directions.length !== 1 || pending.balance === undefined || !pending.description.trim() || administrativeRow.test(pending.description)) {
      rejectedRowCount += 1;
      rejectedRows.push(`p${pending.line.page}: ${lineText(pending.line)}`);
      pending = undefined;
      return;
    }
    const amountCents = pending.deposit ?? -(pending.withdrawal ?? 0);
    const evidence = lineText(pending.line);
    rows.push(makeTransaction({
      parser: "santander-checking-v1",
      fileName: input.fileName,
      index: rows.length,
      date: pending.date,
      description: pending.description,
      account: "Santander",
      amountCents,
      kind: /transfer|traspaso|spei/i.test(pending.description) ? "bankTransfer" : amountCents > 0 ? "income" : "purchase",
      page: pending.line.page,
      mode: input.mode,
      confidence: pending.confidence,
      sourceText: evidence,
      bounds: lineBounds(pending.line),
      selectedColumn: pending.deposit !== undefined ? "DEPÓSITO" : "RETIRO",
      selectionReason: "fecha ancla; importe leído solo de la columna calibrada; saldo reservado como control",
      template: { id: templateMatch.templateId, version: templateMatch.templateVersion, alignmentScore: templateMatch.alignmentScore },
    }));
    lastBalance = pending.balance;
    pending = undefined;
  };

  for (const line of layoutLines(input.layout)) {
    const raw = lineText(line);
    const normalized = fold(raw);
    if (!active && normalized.includes(fold(sectionTitle))) {
      active = true;
      continue;
    }
    if (!active) continue;
    if (/^total\b/.test(normalized) || /^saldo final del periodo\b/.test(normalized)) {
      finish();
      const declaredDeposits = columnMoney(line, templateMatch, "DEPOSITO");
      const declaredWithdrawals = columnMoney(line, templateMatch, "RETIRO");
      if (declaredDeposits !== undefined) summary.depositTotal = declaredDeposits / 100;
      if (declaredWithdrawals !== undefined) summary.withdrawalTotal = declaredWithdrawals / 100;
      active = false;
      continue;
    }
    if (/saldo final del periodo anterior/.test(normalized)) {
      const opening = columnMoney(line, templateMatch, "SALDO");
      if (opening !== undefined) summary.previousBalance = opening / 100;
      continue;
    }
    const token = dateToken(line, templateMatch);
    if (token) {
      finish();
      const date = parseIssuerDate(token, input.text, input.fileName);
      if (!date) {
        rejectedRowCount += 1;
        rejectedRows.push(`p${line.page}: ${raw}`);
        continue;
      }
      const description = cleanDescription(descriptionText(line, templateMatch));
      const deposit = columnMoney(line, templateMatch, "DEPOSITO");
      const withdrawal = columnMoney(line, templateMatch, "RETIRO");
      const balance = columnMoney(line, templateMatch, "SALDO");
      const confidence = Math.max(0, Math.min(1, Math.min(...line.words.map((word) => word.confidence))));
      pending = { line, date, description, deposit, withdrawal, balance, confidence };
      continue;
    }
    if (pending) {
      // Continuations only extend the description. They cannot contribute a
      // date or numeric value, so references/CLABE/RFC never create a row.
      const continuation = cleanDescription(descriptionText(line, templateMatch));
      if (continuation && !administrativeRow.test(continuation)) pending.description += ` ${continuation}`;
    }
  }
  finish();
  if (lastBalance !== undefined) summary.cashBalance = lastBalance / 100;
  const reconciliation = reconcileExactly("bank", summary, rows);
  return {
    parserId: "santander-checking-v1",
    sourceSection: sectionTitle,
    transactions: rows,
    summary,
    reconciliation,
    rejectedRowCount,
    rejectedRows,
    templateMatch,
  };
}
