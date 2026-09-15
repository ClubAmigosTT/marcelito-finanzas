import type { ImportResult, StatementReconciliation, StatementSource, StatementSummary, Transaction } from "../types.ts";

/**
 * Shared OCR contract. Both the browser (Tesseract) and iOS (Vision) express
 * geometry in the same bottom-left normalized coordinate space. A reader may
 * retain derived visual lines, but it must not discard these word-level
 * observations before template matching or evidence construction.
 */
export type NormalizedBox = {
  x: number;
  y: number;
  width: number;
  height: number;
};

export type OCRObservation = {
  page: number;
  text: string;
  bounds: NormalizedBox;
  confidence: number;
  readingOrder: number;
  engine: "tesseract" | "vision" | "pdf-text";
};

export type DocumentLayoutWord = {
  /** Horizontal position normalized to the page width (0–1). */
  x: number;
  text: string;
  confidence: number;
  /** Bottom-left normalized bounds. Optional for legacy synthetic fixtures. */
  y?: number;
  width?: number;
  height?: number;
  /** Stable source order inside the page, never inferred from text alone. */
  readingOrder?: number;
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
  /** Word-level OCR/text evidence retained while the import is being read. */
  observations?: OCRObservation[];
};

export type TemplateMatch = {
  templateId: string;
  templateVersion: string;
  status: "matched" | "review";
  alignmentScore: number;
  reason: string;
  calibratedPages: number[];
  inheritedPages: number[];
  /** Dynamic document-specific zones, derived from the detected header. */
  columns?: Partial<Record<"FECHA" | "DESCRIPCION" | "DEPOSITO" | "RETIRO" | "SALDO", NormalizedBox>>;
};

export type DeterministicParserId = "santander-checking-v1" | "bbva-movements-v1" | "amex-operations-v1" | "rappicard-operations-v1";

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
  templateMatch?: TemplateMatch;
};
