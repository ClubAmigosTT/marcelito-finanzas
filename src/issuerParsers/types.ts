import type { ImportResult, StatementReconciliation, StatementSource, StatementSummary, Transaction } from "../types.ts";

export type DocumentLayoutWord = {
  /** Horizontal position normalized to the page width (0–1). */
  x: number;
  text: string;
  confidence: number;
};

export type DocumentLayoutLine = {
  page: number;
  words: DocumentLayoutWord[];
};

export type DocumentLayoutPage = {
  page: number;
  lines: DocumentLayoutLine[];
};

export type DocumentLayout = {
  pages: DocumentLayoutPage[];
};

export type DeterministicParserId = "santander-checking-v1" | "bbva-movements-v1" | "amex-operations-v1";

export type DeterministicParseInput = {
  source: StatementSource;
  fileName: string;
  mode: ImportResult["mode"];
  text: string;
  layout?: DocumentLayout;
};

export type DeterministicParseResult = {
  parserId: DeterministicParserId;
  sourceSection: string;
  transactions: Transaction[];
  summary: StatementSummary;
  reconciliation: StatementReconciliation;
  rejectedRowCount: number;
  rejectedRows?: string[];
};
