import type { StatementSummary, Transaction } from "../types.ts";
import type { DeterministicParseInput, DeterministicParseResult, DocumentLayoutLine } from "./types.ts";
import { cents, fold, layoutLines, lineText, makeTransaction, money, moneyAfterLabel, parseIssuerDate, reconcileExactly } from "./shared.ts";

const sectionTitle = "Detalle de Movimientos Realizados";
const sectionEnd = "Total de Movimientos";

function parseSummary(text: string): StatementSummary {
  const afterTotal = text.split(/total\s+de\s+movimientos/i).slice(1).join("\n");
  const depositLine = afterTotal.split(/\r?\n/).find((line) => /total\s+importe\s+abonos/i.test(fold(line)));
  const withdrawalLine = afterTotal.split(/\r?\n/).find((line) => /total\s+importe\s+cargos/i.test(fold(line)));
  const count = (line: string | undefined, label: "abonos" | "cargos") => Number(fold(line ?? "").match(new RegExp(`total movimientos ${label} (\\d+)`))?.[1]);
  return {
    previousBalance: moneyAfterLabel(text, /saldo anterior/, { before: /detalle de movimientos realizados/i }),
    cashBalance: moneyAfterLabel(text, /saldo final/, { before: /detalle de movimientos realizados/i }),
    depositTotal: money(depositLine?.match(/total\s+importe\s+abonos\s+([\d,.]+)/i)?.[1]),
    withdrawalTotal: money(withdrawalLine?.match(/total\s+importe\s+cargos\s+([\d,.]+)/i)?.[1]),
    depositCount: Number.isFinite(count(depositLine, "abonos")) ? count(depositLine, "abonos") : undefined,
    withdrawalCount: Number.isFinite(count(withdrawalLine, "cargos")) ? count(withdrawalLine, "cargos") : undefined,
  };
}

function columnMoney(line: DocumentLayoutLine, from: number, to: number) {
  const tokens = line.words.filter((word) => word.x >= from && word.x < to).map((word) => word.text).join("");
  return cents(tokens);
}

export function parseBBVA(input: DeterministicParseInput): DeterministicParseResult {
  const summary = parseSummary(input.text);
  const rows: Transaction[] = [];
  let active = false;
  let rejectedRowCount = 0;
  for (const line of layoutLines(input.layout)) {
    const raw = lineText(line);
    const normalized = fold(raw);
    if (!active && normalized.includes(fold(sectionTitle))) {
      active = true;
      continue;
    }
    if (!active) continue;
    if (normalized.includes(fold(sectionEnd))) {
      active = false;
      continue;
    }
    const dateWord = line.words.find((word) => word.x < 0.09 && /^\d{1,2}[-/]\w{3}$/i.test(word.text));
    if (!dateWord) continue;
    const date = parseIssuerDate(dateWord.text, input.text, input.fileName);
    const description = line.words.filter((word) => word.x >= 0.16 && word.x < 0.60).map((word) => word.text).join(" ").trim();
    const charge = columnMoney(line, 0.60, 0.68);
    const deposit = columnMoney(line, 0.68, 0.76);
    if (!date || !description || (charge === undefined) === (deposit === undefined)) {
      rejectedRowCount += 1;
      continue;
    }
    const amountCents = deposit ?? -(charge ?? 0);
    const confidence = Math.max(0, Math.min(1, Math.min(...line.words.map((word) => word.confidence))));
    rows.push(makeTransaction({
      parser: "bbva-movements-v1",
      fileName: input.fileName,
      index: rows.length,
      date,
      description,
      account: "BBVA",
      amountCents,
      kind: /spei|transfer|traspaso/i.test(description) ? "bankTransfer" : amountCents > 0 ? "income" : "purchase",
      page: line.page,
      mode: input.mode,
      confidence,
      sourceText: raw,
    }));
  }
  const reconciliation = reconcileExactly("bank", summary, rows);
  return { parserId: "bbva-movements-v1", sourceSection: sectionTitle, transactions: rows, summary, reconciliation, rejectedRowCount };
}
