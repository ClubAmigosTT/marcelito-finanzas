import type { StatementSummary, Transaction } from "../types.ts";
import type { DeterministicParseInput, DeterministicParseResult, DocumentLayoutLine } from "./types.ts";
import { cents, fold, layoutLines, lineText, makeTransaction, moneyAfterLabel, parseIssuerDate, reconcileExactly } from "./shared.ts";

const sectionTitle = "Detalle de movimientos cuenta de cheques";

function parseSummary(text: string): StatementSummary {
  const beforeTable = text.split(/detalle\s+de\s+movimientos\s+cuenta\s+de\s+cheques/i)[0] ?? text;
  return {
    previousBalance: moneyAfterLabel(beforeTable, /saldo inicial|saldo final del periodo anterior/, { last: true }),
    depositTotal: moneyAfterLabel(beforeTable, /^\+?\s*depositos\b/, { last: true }),
    withdrawalTotal: moneyAfterLabel(beforeTable, /^-?\s*retiros\b/, { last: true }),
    cashBalance: moneyAfterLabel(beforeTable, /^=?\s*saldo final\b/, { last: true }),
  };
}

function columnMoney(line: DocumentLayoutLine, from: number, to: number) {
  const tokens = line.words.filter((word) => word.x >= from && word.x < to).map((word) => word.text).join("");
  return cents(tokens);
}

export function parseSantander(input: DeterministicParseInput): DeterministicParseResult {
  const summary = parseSummary(input.text);
  const rows: Transaction[] = [];
  let active = false;
  let rejectedRowCount = 0;
  const rejectedRows: string[] = [];
  let lastBalance: number | undefined;
  let pending: { line: DocumentLayoutLine; date: string; description: string; deposit?: number; withdrawal?: number; balance?: number; confidence: number } | undefined;
  const finish = () => {
    if (!pending) return;
    const directions = [pending.deposit, pending.withdrawal].filter((value) => value !== undefined);
    if (directions.length !== 1 || pending.balance === undefined || !pending.description.trim()) {
      rejectedRowCount += 1;
      rejectedRows.push(`p${pending.line.page}: ${lineText(pending.line)}`);
      pending = undefined;
      return;
    }
    const amountCents = pending.deposit ?? -(pending.withdrawal ?? 0);
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
      sourceText: lineText(pending.line),
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
    if (/^total\b/.test(normalized)) {
      finish();
      const declaredDeposits = columnMoney(line, 0.60, 0.72);
      const declaredWithdrawals = columnMoney(line, 0.72, 0.84);
      if (declaredDeposits !== undefined) summary.depositTotal = declaredDeposits / 100;
      if (declaredWithdrawals !== undefined) summary.withdrawalTotal = declaredWithdrawals / 100;
      active = false;
      continue;
    }
    if (/saldo final del periodo anterior/.test(normalized)) {
      const opening = columnMoney(line, 0.40, 0.99);
      if (opening !== undefined) summary.previousBalance = opening / 100;
      continue;
    }
    const dateWord = line.words.find((word) => word.x < 0.13 && /\d{1,2}[-/]\w{3}[-/]20\d{2}/i.test(word.text.replace(/AG0/gi, "AGO")));
    if (dateWord) {
      finish();
      // Santander OCR can glue the folio to the date (`04-MAY-2026/0283157`).
      // The fixed FECHA column makes the bounded date prefix authoritative;
      // no number outside that column is inspected.
      const dateToken = dateWord.text.replace(/AG0/gi, "AGO").match(/^\d{1,2}[-/]\w{3}[-/]20\d{2}/i)?.[0] ?? dateWord.text;
      const date = parseIssuerDate(dateToken, input.text, input.fileName);
      if (!date) {
        rejectedRowCount += 1;
        rejectedRows.push(`p${line.page}: ${raw}`);
        continue;
      }
      const description = line.words.filter((word) => word.x >= 0.18 && word.x < 0.60).map((word) => word.text).join(" ");
      const deposit = columnMoney(line, 0.60, 0.72);
      const withdrawal = columnMoney(line, 0.72, 0.84);
      const balance = columnMoney(line, 0.84, 0.99);
      const confidence = Math.max(0, Math.min(1, Math.min(...line.words.map((word) => word.confidence))));
      pending = { line, date, description, deposit, withdrawal, balance, confidence };
      continue;
    }
    if (pending) {
      const continuation = line.words.filter((word) => word.x >= 0.18 && word.x < 0.60).map((word) => word.text).join(" ").trim();
      if (continuation) pending.description += ` ${continuation}`;
    }
  }
  finish();
  if (lastBalance !== undefined) summary.cashBalance = lastBalance / 100;
  const reconciliation = reconcileExactly("bank", summary, rows);
  return { parserId: "santander-checking-v1", sourceSection: sectionTitle, transactions: rows, summary, reconciliation, rejectedRowCount, rejectedRows };
}
