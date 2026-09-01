import statementExtractionSchema from "../schemas/statement-extraction.schema.json" with { type: "json" };
import { isAdministrativeDescription, normalizeConcept, parseDate } from "./reconciliation.ts";
import { reconcileStatementImport } from "./pdfImport.ts";
import type {
  ImportResult,
  StatementKind,
  StatementSummary,
  StatementSource,
  Transaction,
  TransactionKind,
} from "./types.ts";

/** Versiona el contrato y las instrucciones, no el modelo del proveedor. */
export const MULTIMODAL_READER_VERSION = "multimodal-reader-2026.09.01.1";
export const MULTIMODAL_READER_PROMPT_VERSION = "statement-reader-v1";
export const MULTIMODAL_READER_MAX_FILE_BYTES = 20 * 1024 * 1024;
export const MULTIMODAL_READER_MAX_ROWS = 2_500;

export type MultimodalStatementRow = {
  date: string;
  description: string;
  amount_cents: number;
  direction: "in" | "out";
  kind: TransactionKind;
  foreign_currency: boolean;
  page: number;
  evidence: string;
  confidence: number;
};

export type MultimodalStatementSummary = {
  previous_balance_cents: number | null;
  statement_balance_cents: number | null;
  debt_balance_cents: number | null;
  new_transactions_cents: number | null;
  payments_cents: number | null;
  credits_cents: number | null;
  payments_credits_cents: number | null;
  new_charges_cents: number | null;
  interest_cents: number | null;
  fees_cents: number | null;
  credit_limit_cents: number | null;
  credit_available_cents: number | null;
  minimum_payment_cents: number | null;
  minimum_plus_msi_cents: number | null;
  payment_for_no_interest_cents: number | null;
  cash_balance_cents: number | null;
  msi_original_deferred_cents: number | null;
  msi_pending_cents: number | null;
  revolving_balance_cents: number | null;
  msi_installments: number | null;
  msi_monthly_load_cents: number | null;
  domestic_transaction_total_cents: number | null;
  domestic_transaction_total_is_credit: boolean | null;
  foreign_transaction_total_cents: number | null;
  deposit_total_cents: number | null;
  withdrawal_total_cents: number | null;
  deposit_count: number | null;
  withdrawal_count: number | null;
};

export type MultimodalStatementExtraction = {
  source: string;
  kind: "bank" | "card" | "unknown";
  account_last4: string | null;
  period_start: string | null;
  period_end: string | null;
  cutoff_date: string | null;
  page_count: number;
  summary: MultimodalStatementSummary;
  rows: MultimodalStatementRow[];
};

export type MultimodalReaderClientOptions = {
  /** A same-origin proxy or authenticated backend endpoint. */
  endpoint: string;
  /** Never send a PDF unless the caller explicitly enables the fallback. */
  enabled?: boolean;
  /** Optional request credential supplied by the hosting environment. */
  authorization?: string;
  timeoutMs?: number;
  signal?: AbortSignal;
  fetchImpl?: typeof fetch;
  model?: string;
};

export type MultimodalReaderRequest = {
  fileName: string;
  sourceFingerprint: string;
  extraction: MultimodalStatementExtraction;
  model?: string;
  readerVersion: typeof MULTIMODAL_READER_VERSION;
  promptVersion: typeof MULTIMODAL_READER_PROMPT_VERSION;
};

export type MultimodalReaderPreflightResult = {
  status: "ready";
  model: string;
  contract: "statement-extraction.v1";
};

export const STATEMENT_EXTRACTION_SCHEMA = statementExtractionSchema;

/**
 * Keeps account grouping stable when a reader returns the institution's full
 * legal name (for example, "BBVA México, S.A.") instead of the short label
 * used by the rest of the ledger. Unknown issuers remain human-readable and
 * are still marked for review by the import UI.
 */
export function normalizeIssuerLabel(value: string) {
  const normalized = normalizeConcept(value);
  if (/american express|\bamex\b/.test(normalized)) return "Amex" as const;
  if (/\bbbva\b/.test(normalized)) return "BBVA" as const;
  if (/\bsantander\b/.test(normalized)) return "Santander" as const;
  return value.trim().replace(/\s+/g, " ").slice(0, 80);
}

const summaryKeys: Array<keyof MultimodalStatementSummary> = [
  "previous_balance_cents",
  "statement_balance_cents",
  "debt_balance_cents",
  "new_transactions_cents",
  "payments_cents",
  "credits_cents",
  "payments_credits_cents",
  "new_charges_cents",
  "interest_cents",
  "fees_cents",
  "credit_limit_cents",
  "credit_available_cents",
  "minimum_payment_cents",
  "minimum_plus_msi_cents",
  "payment_for_no_interest_cents",
  "cash_balance_cents",
  "msi_original_deferred_cents",
  "msi_pending_cents",
  "revolving_balance_cents",
  "msi_installments",
  "msi_monthly_load_cents",
  "domestic_transaction_total_cents",
  "domestic_transaction_total_is_credit",
  "foreign_transaction_total_cents",
  "deposit_total_cents",
  "withdrawal_total_cents",
  "deposit_count",
  "withdrawal_count",
];

const transactionKinds = new Set<TransactionKind>([
  "purchase",
  "cardPayment",
  "bankTransfer",
  "income",
  "credit",
  "refund",
  "msi",
  "interest",
  "fee",
  "other",
]);

class MultimodalReaderError extends Error {
  code: "not_configured" | "request_failed" | "invalid_payload" | "file_too_large";

  constructor(code: MultimodalReaderError["code"], message: string) {
    super(message);
    this.name = "MultimodalReaderError";
    this.code = code;
  }
}

export { MultimodalReaderError };

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function fail(path: string, message: string): never {
  throw new MultimodalReaderError("invalid_payload", `${path}: ${message}`);
}

function stringField(value: unknown, path: string, min = 1, max = 500) {
  if (typeof value !== "string" || value.trim().length < min || value.trim().length > max) {
    fail(path, `se esperaba texto de ${min} a ${max} caracteres`);
  }
  return value.trim();
}

function nullableStringField(value: unknown, path: string, pattern?: RegExp) {
  if (value === null) return null;
  const result = stringField(value, path, 1, 80);
  if (pattern && !pattern.test(result)) fail(path, "formato inválido");
  return result;
}

function integerField(value: unknown, path: string, min: number, max: number) {
  if (typeof value !== "number" || !Number.isInteger(value) || value < min || value > max) {
    fail(path, `se esperaba entero entre ${min} y ${max}`);
  }
  return value;
}

function nullableIntegerField(value: unknown, path: string, min: number, max: number) {
  if (value === null) return null;
  return integerField(value, path, min, max);
}

function booleanField(value: unknown, path: string) {
  if (typeof value !== "boolean") fail(path, "se esperaba booleano");
  return value;
}

function nullableBooleanField(value: unknown, path: string) {
  if (value === null) return null;
  return booleanField(value, path);
}

function confidenceField(value: unknown, path: string) {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > 1) {
    fail(path, "se esperaba confianza entre 0 y 1");
  }
  return value;
}

function isoDateField(value: unknown, path: string, required: boolean) {
  if (value === null && !required) return null;
  const result = stringField(value, path, 10, 10);
  if (!/^20\d{2}-\d{2}-\d{2}$/.test(result) || parseDate(result) === undefined) fail(path, "se esperaba una fecha ISO válida");
  return result;
}

function normalizeSummary(input: unknown): MultimodalStatementSummary {
  if (!isRecord(input)) fail("summary", "se esperaba un objeto");
  const output = {} as MultimodalStatementSummary;
  for (const key of summaryKeys) {
    const value = input[key];
    if (key === "domestic_transaction_total_is_credit") {
      output[key] = nullableBooleanField(value, `summary.${key}`);
    } else if (key === "msi_installments" || key === "deposit_count" || key === "withdrawal_count") {
      output[key] = nullableIntegerField(value, `summary.${key}`, 0, 2_500);
    } else {
      output[key] = nullableIntegerField(value, `summary.${key}`, 0, 1_000_000_000_000);
    }
  }
  return output;
}

function normalizeRow(input: unknown, index: number, pageCount: number): MultimodalStatementRow {
  if (!isRecord(input)) fail(`rows[${index}]`, "se esperaba un objeto");
  const parsedDate = isoDateField(input.date, `rows[${index}].date`, true);
  if (!parsedDate) fail(`rows[${index}].date`, "la fecha es obligatoria");
  const date = parsedDate;
  const description = stringField(input.description, `rows[${index}].description`, 3, 240);
  if (isAdministrativeDescription(description)) fail(`rows[${index}].description`, "parece texto administrativo, no una transacción");
  const amount_cents = integerField(input.amount_cents, `rows[${index}].amount_cents`, 1, 1_000_000_000_000);
  const direction = input.direction === "in" || input.direction === "out" ? input.direction : fail(`rows[${index}].direction`, "debe ser in u out");
  const kind = typeof input.kind === "string" && transactionKinds.has(input.kind as TransactionKind)
    ? input.kind as TransactionKind
    : fail(`rows[${index}].kind`, "tipo de movimiento no permitido");
  const directionMustBeIn = new Set<TransactionKind>(["income", "credit", "refund"]);
  const directionMustBeOut = new Set<TransactionKind>(["purchase", "msi", "interest", "fee"]);
  if (directionMustBeIn.has(kind) && direction !== "in") fail(`rows[${index}].direction`, `${kind} debe ser una entrada`);
  if (directionMustBeOut.has(kind) && direction !== "out") fail(`rows[${index}].direction`, `${kind} debe ser una salida`);
  const foreign_currency = booleanField(input.foreign_currency, `rows[${index}].foreign_currency`);
  const page = integerField(input.page, `rows[${index}].page`, 1, pageCount);
  const evidence = stringField(input.evidence, `rows[${index}].evidence`, 3, 500);
  const confidence = confidenceField(input.confidence, `rows[${index}].confidence`);
  return { date, description, amount_cents, direction, kind, foreign_currency, page, evidence, confidence };
}

/**
 * Validates and normalizes untrusted model output before any financial
 * calculation. This intentionally does not try to “repair” a malformed row:
 * a row with no defensible evidence is quarantined instead of guessed.
 */
export function validateMultimodalExtraction(input: unknown): MultimodalStatementExtraction {
  if (!isRecord(input)) throw new MultimodalReaderError("invalid_payload", "La respuesta del lector no es un objeto");
  const source = stringField(input.source, "source", 1, 80);
  if (isAdministrativeDescription(source)) fail("source", "parece texto administrativo, no un emisor");
  const kind = input.kind === "bank" || input.kind === "card" || input.kind === "unknown"
    ? input.kind
    : fail("kind", "tipo de estado no permitido");
  const account_last4 = nullableStringField(input.account_last4, "account_last4", /^\d{4}$/);
  const period_start = isoDateField(input.period_start, "period_start", false);
  const period_end = isoDateField(input.period_end, "period_end", false);
  const cutoff_date = isoDateField(input.cutoff_date, "cutoff_date", false);
  if (period_start && period_end && period_start > period_end) fail("period", "period_start es posterior a period_end");
  const page_count = integerField(input.page_count, "page_count", 1, 200);
  const summary = normalizeSummary(input.summary);
  if (!Array.isArray(input.rows) || input.rows.length > MULTIMODAL_READER_MAX_ROWS) fail("rows", `se esperaban hasta ${MULTIMODAL_READER_MAX_ROWS} filas`);
  const rows = input.rows.map((row, index) => normalizeRow(row, index, page_count));
  return { source, kind, account_last4, period_start, period_end, cutoff_date, page_count, summary, rows };
}

function centsToAmount(value: number | null) {
  return value === null ? undefined : value / 100;
}

function mapSummary(summary: MultimodalStatementSummary): StatementSummary {
  const mapped: StatementSummary = {};
  for (const key of summaryKeys) {
    const value = summary[key];
    if (value === null || value === undefined) continue;
    if (key === "domestic_transaction_total_is_credit") {
      mapped.domesticTransactionTotalIsCredit = value as boolean;
      continue;
    }
    const target = key
      .replace(/_cents$/, "")
      .replace(/_([a-z])/g, (_match, letter: string) => letter.toUpperCase()) as keyof StatementSummary;
    const amount = key === "msi_installments" || key === "deposit_count" || key === "withdrawal_count"
      ? value as number
      : centsToAmount(value as number);
    if (amount !== undefined) (mapped as unknown as Record<string, unknown>)[target] = amount;
  }
  return mapped;
}

function transactionFlow(kind: TransactionKind) {
  if (kind === "bankTransfer") return "transfer" as const;
  if (kind === "cardPayment") return "debt" as const;
  if (kind === "income" || kind === "credit" || kind === "refund") return "income" as const;
  return "expense" as const;
}

function categoryFor(kind: TransactionKind) {
  if (kind === "refund") return "Reembolsos";
  if (kind === "income") return "Ingresos";
  if (kind === "cardPayment") return "Pago de tarjeta";
  if (kind === "bankTransfer") return "Transferencia interna";
  return "Sin categoría";
}

function mapRows(extraction: MultimodalStatementExtraction, fileName: string): Transaction[] {
  const fileKey = normalizeConcept(fileName).replace(/\s+/g, "-").slice(0, 40) || "estado";
  return extraction.rows.map((row, index) => {
    const amount = row.amount_cents / 100 * (row.direction === "in" ? 1 : -1);
    return {
      id: `multimodal-${fileKey}-${index + 1}`,
      date: row.date,
      description: row.description,
      account: extraction.source,
      category: categoryFor(row.kind),
      amount,
      flow: transactionFlow(row.kind),
      kind: row.kind,
      foreignCurrency: row.foreign_currency,
      confidence: row.confidence,
      extractionEvidence: {
        method: "multimodal",
        page: row.page,
        confidence: row.confidence,
        sourceText: row.evidence,
      },
      normalizedDescription: normalizeConcept(row.description),
      validationStatus: "valid",
    };
  });
}

/**
 * Converts an accepted contract into the app's ImportResult, but deliberately
 * runs the issuer totals through the existing reconciliation gate first.
 * A “valid” model response therefore remains provisional until the same
 * deterministic accounting checks as local extraction pass.
 */
export function extractionToImportResult(
  extractionInput: unknown,
  file: Pick<File, "name" | "size">,
  options: { sourceFingerprint?: string; model?: string } = {},
): ImportResult {
  const extraction = validateMultimodalExtraction(extractionInput);
  const source = normalizeIssuerLabel(extraction.source) as StatementSource;
  const transactions = mapRows({ ...extraction, source }, file.name);
  const kind: StatementKind = extraction.kind;
  const summary = mapSummary(extraction.summary);
  const reconciliation = reconcileStatementImport(kind, summary, transactions);
  const dates = [extraction.period_start, extraction.period_end, extraction.cutoff_date].filter(Boolean) as string[];
  const period = dates.length >= 2 ? `${dates[0]} – ${dates[1]}` : dates[0] ?? file.name;
  const averageConfidence = transactions.length
    ? transactions.reduce((sum, transaction) => sum + (transaction.confidence ?? 0), 0) / transactions.length
    : 0;
  return {
    source,
    accountKey: extraction.account_last4 ? `${source}:${extraction.account_last4}` : undefined,
    sourceDetection: {
      source,
      confidence: 0.85,
      status: "review",
      evidence: [
        `emisor declarado por lector multimodal: ${extraction.source}`,
        "pendiente de contraste institucional por el usuario",
      ],
      ignoredBodyMentions: [],
    },
    kind,
    period,
    fileName: file.name,
    sourceFingerprint: options.sourceFingerprint,
    fileSizeBytes: file.size,
    pageCount: extraction.page_count,
    readerVersion: MULTIMODAL_READER_VERSION,
    extractionProvider: "multimodal",
    extractionModel: options.model,
    extractionPromptVersion: MULTIMODAL_READER_PROMPT_VERSION,
    // Keep the existing import flow compatible; the provenance/evidence
    // method tells the audit UI that this was the multimodal provider.
    mode: "text",
    transactions,
    summary,
    reconciliation,
    ocrConfidence: averageConfidence,
    ocrPageConfidences: [],
  };
}

function toBase64(buffer: ArrayBuffer) {
  let binary = "";
  const bytes = new Uint8Array(buffer);
  const chunkSize = 0x8000;
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + chunkSize));
  }
  return btoa(binary);
}

async function fingerprintBuffer(buffer: ArrayBuffer) {
  if (!globalThis.crypto?.subtle) {
    throw new MultimodalReaderError("request_failed", "Este dispositivo no puede verificar la identidad del PDF");
  }
  const digest = await globalThis.crypto.subtle.digest("SHA-256", buffer);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function unwrapExtraction(body: unknown): unknown {
  if (!isRecord(body)) return body;
  if ("extraction" in body) return body.extraction;
  if ("data" in body) return body.data;
  return body;
}

function isSecureReaderEndpoint(endpoint: string) {
  try {
    const base = typeof location !== "undefined" ? location.origin : "http://localhost";
    const parsed = new URL(endpoint, base);
    if (parsed.protocol === "https:") return true;
    return parsed.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(parsed.hostname);
  } catch {
    return false;
  }
}

function validSha256(value: unknown) {
  return typeof value === "string" && /^[a-f0-9]{64}$/i.test(value) ? value.toLowerCase() : undefined;
}

function optionalModel(value: unknown) {
  return typeof value === "string" && value.trim().length > 0 && value.trim().length <= 120
    ? value.trim()
    : undefined;
}

function preflightEndpoint(endpoint: string) {
  const base = typeof location !== "undefined" ? location.origin : "http://localhost";
  const parsed = new URL(endpoint, base);
  parsed.pathname = `${parsed.pathname.replace(/\/+$/, "")}/preflight`;
  parsed.search = "";
  parsed.hash = "";
  return parsed.toString();
}

/**
 * Verifies the configured provider with a synthetic PDF containing one known
 * row. This is an explicit operator check: no user file is read and no
 * financial data crosses the network. A successful result proves that the
 * proxy accepted a real PDF input and returned the exact contract the client
 * expects.
 */
export async function requestMultimodalReaderPreflight(
  options: Pick<MultimodalReaderClientOptions, "endpoint" | "authorization" | "timeoutMs" | "signal" | "fetchImpl"> & { enabled?: boolean },
): Promise<MultimodalReaderPreflightResult> {
  if (!options.enabled) throw new MultimodalReaderError("not_configured", "El preflight requiere confirmación explícita");
  const endpoint = options.endpoint.trim();
  if (!endpoint || !isSecureReaderEndpoint(endpoint)) {
    throw new MultimodalReaderError("not_configured", "El preflight requiere HTTPS o un proxy local");
  }
  const fetchImpl = options.fetchImpl ?? fetch;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), options.timeoutMs ?? 30_000);
  const externalAbort = () => controller.abort(options.signal?.reason);
  if (options.signal) {
    if (options.signal.aborted) externalAbort();
    else options.signal.addEventListener("abort", externalAbort, { once: true });
  }
  try {
    const headers: Record<string, string> = { "content-type": "application/json" };
    if (options.authorization) headers.authorization = options.authorization;
    const response = await fetchImpl(preflightEndpoint(endpoint), {
      method: "POST",
      headers,
      body: "{}",
      signal: controller.signal,
    });
    let body: unknown;
    try {
      body = await response.json();
    } catch {
      throw new MultimodalReaderError("request_failed", "El preflight devolvió una respuesta no válida");
    }
    if (!response.ok) {
      const message = isRecord(body) && typeof body.error === "string" ? body.error : `HTTP ${response.status}`;
      throw new MultimodalReaderError("request_failed", `El lector avanzado no está listo: ${message}`);
    }
    const model = isRecord(body) ? optionalModel(body.model) : undefined;
    if (!isRecord(body) || body.status !== "ready" || body.contract !== "statement-extraction.v1" || !model) {
      throw new MultimodalReaderError("invalid_payload", "El proveedor no confirmó el contrato del lector");
    }
    return { status: "ready", model, contract: "statement-extraction.v1" };
  } catch (error) {
    if (error instanceof MultimodalReaderError) throw error;
    if (error instanceof Error && error.name === "AbortError") throw new MultimodalReaderError("request_failed", "El preflight agotó el tiempo de espera");
    throw new MultimodalReaderError("request_failed", error instanceof Error ? error.message : "Falló el preflight");
  } finally {
    clearTimeout(timeout);
    options.signal?.removeEventListener("abort", externalAbort);
  }
}

/**
 * Calls a backend proxy that owns the provider credential. The browser sends
 * the original PDF only after an explicit opt-in; no API key is ever bundled
 * into the web/iOS clients.
 */
export async function requestMultimodalExtraction(file: File, options: MultimodalReaderClientOptions): Promise<MultimodalReaderRequest> {
  if (!options.enabled) throw new MultimodalReaderError("not_configured", "El lector avanzado requiere confirmación explícita");
  const endpoint = options.endpoint.trim();
  if (!endpoint) throw new MultimodalReaderError("not_configured", "No hay un endpoint seguro configurado");
  if (!isSecureReaderEndpoint(endpoint)) throw new MultimodalReaderError("not_configured", "El lector avanzado requiere HTTPS o un proxy local");
  if (file.size > MULTIMODAL_READER_MAX_FILE_BYTES) throw new MultimodalReaderError("file_too_large", "El PDF supera el límite de 20 MB");
  const buffer = await file.arrayBuffer();
  const localFingerprint = await fingerprintBuffer(buffer);
  const fetchImpl = options.fetchImpl ?? fetch;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), options.timeoutMs ?? 120_000);
  const externalAbort = () => controller.abort(options.signal?.reason);
  if (options.signal) {
    if (options.signal.aborted) externalAbort();
    else options.signal.addEventListener("abort", externalAbort, { once: true });
  }
  try {
    const headers: Record<string, string> = { "content-type": "application/json" };
    if (options.authorization) headers.authorization = options.authorization;
    const response = await fetchImpl(endpoint, {
      method: "POST",
      headers,
      body: JSON.stringify({
        fileName: file.name,
        pdfBase64: toBase64(buffer),
        readerVersion: MULTIMODAL_READER_VERSION,
        promptVersion: MULTIMODAL_READER_PROMPT_VERSION,
      }),
      signal: controller.signal,
    });
    let body: unknown;
    try {
      body = await response.json();
    } catch {
      throw new MultimodalReaderError("request_failed", "El lector avanzado devolvió una respuesta no válida");
    }
    if (!response.ok) {
      const message = isRecord(body) && typeof body.error === "string" ? body.error : `HTTP ${response.status}`;
      throw new MultimodalReaderError("request_failed", `No se pudo leer el PDF: ${message}`);
    }
    const remoteFingerprint = isRecord(body) ? validSha256(body.sourceFingerprint) : undefined;
    if (!remoteFingerprint || remoteFingerprint !== localFingerprint) {
      throw new MultimodalReaderError("invalid_payload", "La respuesta no corresponde al PDF seleccionado");
    }
    const extraction = validateMultimodalExtraction(unwrapExtraction(body));
    return {
      fileName: file.name,
      sourceFingerprint: remoteFingerprint,
      extraction,
      model: options.model ?? (isRecord(body) ? optionalModel(body.model) : undefined),
      readerVersion: MULTIMODAL_READER_VERSION,
      promptVersion: MULTIMODAL_READER_PROMPT_VERSION,
    };
  } catch (error) {
    if (error instanceof MultimodalReaderError) throw error;
    if (error instanceof DOMException && error.name === "AbortError") throw new MultimodalReaderError("request_failed", "La lectura avanzada agotó el tiempo de espera");
    throw new MultimodalReaderError("request_failed", error instanceof Error ? error.message : "Falló la lectura avanzada");
  } finally {
    clearTimeout(timeout);
    options.signal?.removeEventListener("abort", externalAbort);
  }
}
