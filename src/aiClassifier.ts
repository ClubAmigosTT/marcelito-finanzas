import { categories } from "./data.ts";
import { isAdministrativeDescription, normalizeConcept } from "./reconciliation.ts";
import type { Transaction, TransactionKind } from "./types.ts";

/** Versiona únicamente el contrato de enriquecimiento, no el lector de PDFs. */
export const TRANSACTION_CLASSIFIER_VERSION = "transaction-classifier-2026.09.03.1";
export const TRANSACTION_CLASSIFIER_PROMPT_VERSION = "expense-classification-v1";
export const TRANSACTION_CLASSIFIER_MAX_ROWS = 500;

export type TransactionClassificationInput = {
  index: number;
  date: string;
  description: string;
  amount_cents: number;
  category: string;
  flow: Transaction["flow"];
  kind: TransactionKind | "other";
  travel: boolean;
};

export type TransactionClassification = {
  index: number;
  merchant: string;
  category: string;
  recurring: boolean;
  extraordinary: boolean;
  travel: boolean;
  confidence: number;
  reason: string;
  requires_review: boolean;
};

export type TransactionClassificationResponse = {
  classifications: TransactionClassification[];
  model?: string;
  provider: "zen";
  version: typeof TRANSACTION_CLASSIFIER_VERSION;
};

export type TransactionClassifierOptions = {
  /** Same-origin proxy or authenticated backend. Never put a provider key here. */
  endpoint: string;
  enabled?: boolean;
  authorization?: string;
  timeoutMs?: number;
  signal?: AbortSignal;
  fetchImpl?: typeof fetch;
  model?: string;
};

export type TransactionClassifierPreflightResult = {
  status: "ready";
  model: string;
  contract: "transaction-classification.v1";
};

// Only expense categories are valid here. Accounting classes such as income,
// transfer, refund and card payment are deliberately not part of this
// contract; those are decided by the deterministic reconciliation pipeline.
const allowedCategories = new Set(categories);

class TransactionClassifierError extends Error {
  code: "not_configured" | "request_failed" | "invalid_payload";

  constructor(code: TransactionClassifierError["code"], message: string) {
    super(message);
    this.name = "TransactionClassifierError";
    this.code = code;
  }
}

export { TransactionClassifierError };

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function fail(path: string, message: string): never {
  throw new TransactionClassifierError("invalid_payload", `${path}: ${message}`);
}

function stringField(value: unknown, path: string, min: number, max: number) {
  if (typeof value !== "string" || value.trim().length < min || value.trim().length > max) {
    fail(path, `se esperaba texto de ${min} a ${max} caracteres`);
  }
  return value.trim();
}

function booleanField(value: unknown, path: string) {
  if (typeof value !== "boolean") fail(path, "se esperaba booleano");
  return value;
}

function numberField(value: unknown, path: string) {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > 1) {
    fail(path, "se esperaba un número entre 0 y 1");
  }
  return value;
}

function exactFields(value: Record<string, unknown>, fields: string[]) {
  const keys = Object.keys(value);
  return keys.length === fields.length && fields.every((field) => Object.prototype.hasOwnProperty.call(value, field));
}

const classificationFields = [
  "index",
  "merchant",
  "category",
  "recurring",
  "extraordinary",
  "travel",
  "confidence",
  "reason",
  "requires_review",
];

function validIndex(value: unknown, path: string, max: number) {
  if (typeof value !== "number" || !Number.isInteger(value) || value < 0 || value >= max) {
    fail(path, "índice fuera del lote enviado");
  }
  return value;
}

function normalizeCategory(value: string) {
  return [...allowedCategories].find((candidate) => candidate.toLowerCase() === value.toLowerCase());
}

function isClassifiableTransaction(transaction: Transaction) {
  return transaction.flow === "expense"
    && !["cardPayment", "bankTransfer", "refund", "credit"].includes(transaction.kind ?? "other")
    && transaction.description.trim().length >= 3
    && Number.isFinite(transaction.amount)
    && transaction.amount !== 0;
}

/** Rows sent to Zen contain no account number, statement metadata or PDF bytes. */
export function buildClassificationInputs(transactions: Transaction[]): TransactionClassificationInput[] {
  return transactions
    .filter(isClassifiableTransaction)
    .slice(0, TRANSACTION_CLASSIFIER_MAX_ROWS)
    .map((transaction, index) => ({
      index,
      date: transaction.date,
      description: transaction.description.trim().slice(0, 240),
      amount_cents: Math.round(Math.abs(transaction.amount) * 100),
      category: transaction.category,
      flow: transaction.flow,
      kind: transaction.kind ?? "other",
      travel: Boolean(transaction.travelRelated),
    }));
}

/** Validates the model response and normalizes only enrichment fields. */
export function validateTransactionClassification(
  input: unknown,
  expectedRows: TransactionClassificationInput[],
): TransactionClassification[] {
  if (!isRecord(input) || !exactFields(input, ["classifications"])) fail("root", "propiedades inesperadas");
  if (!Array.isArray(input.classifications) || input.classifications.length !== expectedRows.length) {
    fail("classifications", "debe devolver exactamente una clasificación por fila");
  }
  const seen = new Set<number>();
  return input.classifications.map((item, index) => {
    if (!isRecord(item) || !exactFields(item, classificationFields)) fail(`classifications[${index}]`, "propiedades inesperadas");
    const rowIndex = validIndex(item.index, `classifications[${index}].index`, expectedRows.length);
    if (seen.has(rowIndex)) fail(`classifications[${index}].index`, "índice duplicado");
    seen.add(rowIndex);
    const merchant = stringField(item.merchant, `classifications[${index}].merchant`, 2, 120);
    if (isAdministrativeDescription(merchant)) fail(`classifications[${index}].merchant`, "parece texto administrativo");
    const rawCategory = stringField(item.category, `classifications[${index}].category`, 2, 40);
    const category = normalizeCategory(rawCategory);
    if (!category) fail(`classifications[${index}].category`, "categoría de gasto no permitida");
    return {
      index: rowIndex,
      merchant,
      category,
      recurring: booleanField(item.recurring, `classifications[${index}].recurring`),
      extraordinary: booleanField(item.extraordinary, `classifications[${index}].extraordinary`),
      travel: booleanField(item.travel, `classifications[${index}].travel`),
      confidence: numberField(item.confidence, `classifications[${index}].confidence`),
      reason: stringField(item.reason, `classifications[${index}].reason`, 2, 240),
      requires_review: booleanField(item.requires_review, `classifications[${index}].requires_review`),
    };
  }).sort((left, right) => left.index - right.index);
}

function secureEndpoint(endpoint: string) {
  try {
    const base = typeof location !== "undefined" ? location.origin : "http://localhost";
    const parsed = new URL(endpoint, base);
    return parsed.protocol === "https:"
      || (parsed.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(parsed.hostname));
  } catch {
    return false;
  }
}

export function classifierEndpoint(endpoint: string) {
  const base = typeof location !== "undefined" ? location.origin : "http://localhost";
  const parsed = new URL(endpoint, base);
  const pathname = parsed.pathname.replace(/\/+$/, "");
  const classifierPath = /\/api\/(?:statement-reader|transaction-classifier)(?:\/preflight)?$/i.test(pathname)
    ? pathname.replace(/\/api\/(?:statement-reader|transaction-classifier)(?:\/preflight)?$/i, "/api/transaction-classifier")
    : `${pathname}/api/transaction-classifier`;
  parsed.pathname = classifierPath;
  parsed.search = "";
  parsed.hash = "";
  return parsed.toString();
}

function classifierPreflightEndpoint(endpoint: string) {
  const base = typeof location !== "undefined" ? location.origin : "http://localhost";
  const parsed = new URL(endpoint, base);
  const pathname = parsed.pathname.replace(/\/+$/, "");
  const classifierPath = /\/api\/(?:statement-reader|transaction-classifier)(?:\/preflight)?$/i.test(pathname)
    ? pathname.replace(/\/api\/(?:statement-reader|transaction-classifier)(?:\/preflight)?$/i, "/api/transaction-classifier")
    : `${pathname}/api/transaction-classifier`;
  parsed.pathname = `${classifierPath}/preflight`;
  parsed.search = "";
  parsed.hash = "";
  return parsed.toString();
}

function abortable(options: TransactionClassifierOptions) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), options.timeoutMs ?? 45_000);
  const externalAbort = () => controller.abort(options.signal?.reason);
  if (options.signal) {
    if (options.signal.aborted) externalAbort();
    else options.signal.addEventListener("abort", externalAbort, { once: true });
  }
  return { controller, timeout, externalAbort };
}

function unwrap(body: unknown) {
  if (!isRecord(body)) return body;
  if ("classifications" in body) return { classifications: body.classifications };
  if ("data" in body) return body.data;
  return body;
}

function optionalModel(value: unknown) {
  return typeof value === "string" && value.trim().length > 0 && value.trim().length <= 120 ? value.trim() : undefined;
}

function validateResponseMetadata(body: unknown) {
  if (!isRecord(body)) return;
  // The proxy is the only supported provider boundary. Keep compatibility
  // with a gateway that omits metadata, but never label a contradictory
  // provider/version as a Zen result.
  if (body.provider !== undefined && body.provider !== "zen") fail("root.provider", "proveedor no permitido");
  if (body.version !== undefined && body.version !== TRANSACTION_CLASSIFIER_VERSION) fail("root.version", "versión de clasificador incompatible");
}

export async function requestTransactionClassifierPreflight(
  options: Pick<TransactionClassifierOptions, "endpoint" | "authorization" | "timeoutMs" | "signal" | "fetchImpl"> & { enabled?: boolean },
): Promise<TransactionClassifierPreflightResult> {
  if (!options.enabled) throw new TransactionClassifierError("not_configured", "El preflight requiere confirmación explícita");
  if (!options.endpoint.trim() || !secureEndpoint(options.endpoint)) throw new TransactionClassifierError("not_configured", "El preflight requiere HTTPS o un proxy local");
  const fetchImpl = options.fetchImpl ?? fetch;
  const request = abortable({ ...options, endpoint: options.endpoint });
  try {
    const headers: Record<string, string> = { "content-type": "application/json" };
    if (options.authorization) headers.authorization = options.authorization;
    const response = await fetchImpl(classifierPreflightEndpoint(options.endpoint), {
      method: "POST",
      headers,
      body: "{}",
      signal: request.controller.signal,
    });
    const body = await response.json().catch(() => undefined);
    if (!response.ok) {
      const message = isRecord(body) && typeof body.error === "string" ? body.error : `HTTP ${response.status}`;
      throw new TransactionClassifierError("request_failed", `El clasificador no está listo: ${message}`);
    }
    const model = isRecord(body) ? optionalModel(body.model) : undefined;
    if (!isRecord(body) || body.status !== "ready" || body.contract !== "transaction-classification.v1" || !model) {
      throw new TransactionClassifierError("invalid_payload", "El proveedor no confirmó el contrato del clasificador");
    }
    return { status: "ready", model, contract: "transaction-classification.v1" };
  } catch (error) {
    if (error instanceof TransactionClassifierError) throw error;
    if (error instanceof DOMException && error.name === "AbortError") throw new TransactionClassifierError("request_failed", "El preflight agotó el tiempo de espera");
    throw new TransactionClassifierError("request_failed", error instanceof Error ? error.message : "Falló el preflight");
  } finally {
    clearTimeout(request.timeout);
    options.signal?.removeEventListener("abort", request.externalAbort);
  }
}

export async function requestTransactionClassification(
  transactions: Transaction[],
  options: TransactionClassifierOptions,
): Promise<TransactionClassificationResponse> {
  if (!options.enabled) throw new TransactionClassifierError("not_configured", "La clasificación con Zen requiere confirmación explícita");
  if (!options.endpoint.trim() || !secureEndpoint(options.endpoint)) throw new TransactionClassifierError("not_configured", "El clasificador requiere HTTPS o un proxy local");
  const inputs = buildClassificationInputs(transactions);
  if (!inputs.length) return { classifications: [], provider: "zen", version: TRANSACTION_CLASSIFIER_VERSION };
  const fetchImpl = options.fetchImpl ?? fetch;
  const request = abortable(options);
  try {
    const headers: Record<string, string> = { "content-type": "application/json" };
    if (options.authorization) headers.authorization = options.authorization;
    const response = await fetchImpl(classifierEndpoint(options.endpoint), {
      method: "POST",
      headers,
      body: JSON.stringify({
        rows: inputs,
        classifierVersion: TRANSACTION_CLASSIFIER_VERSION,
        promptVersion: TRANSACTION_CLASSIFIER_PROMPT_VERSION,
      }),
      signal: request.controller.signal,
    });
    const body = await response.json().catch(() => undefined);
    if (!response.ok) {
      const message = isRecord(body) && typeof body.error === "string" ? body.error : `HTTP ${response.status}`;
      throw new TransactionClassifierError("request_failed", `No se pudieron clasificar los gastos: ${message}`);
    }
    validateResponseMetadata(body);
    const classifications = validateTransactionClassification(unwrap(body), inputs);
    return {
      classifications,
      provider: "zen",
      version: TRANSACTION_CLASSIFIER_VERSION,
      model: isRecord(body) ? optionalModel(body.model) : undefined,
    };
  } catch (error) {
    if (error instanceof TransactionClassifierError) throw error;
    if (error instanceof DOMException && error.name === "AbortError") throw new TransactionClassifierError("request_failed", "La clasificación agotó el tiempo de espera");
    throw new TransactionClassifierError("request_failed", error instanceof Error ? error.message : "Falló la clasificación");
  } finally {
    clearTimeout(request.timeout);
    options.signal?.removeEventListener("abort", request.externalAbort);
  }
}

/** Applies only enrichment fields; accounting identity is intentionally immutable. */
export function applyTransactionClassifications(transactions: Transaction[], response: TransactionClassificationResponse) {
  if (response.provider !== "zen" || response.version !== TRANSACTION_CLASSIFIER_VERSION) return transactions;
  const inputs = buildClassificationInputs(transactions);
  const byIndex = new Map(response.classifications.map((item) => [item.index, item]));
  let classifiableIndex = 0;
  return transactions.map((transaction) => {
    const classifiable = isClassifiableTransaction(transaction);
    if (!classifiable || classifiableIndex >= inputs.length) return transaction;
    const classification = byIndex.get(classifiableIndex);
    classifiableIndex += 1;
    if (!classification) return transaction;
    return {
      ...transaction,
      category: classification.category,
      merchantNormalized: normalizeConcept(classification.merchant) || transaction.normalizedDescription,
      classificationProvider: "zen" as const,
      classificationConfidence: classification.confidence,
      classificationReason: classification.reason,
      recurring: classification.recurring,
      extraordinary: classification.extraordinary,
      travelRelated: classification.travel,
      confidence: Math.max(transaction.confidence ?? 0, classification.confidence),
      validationStatus: classification.requires_review ? "review" as const : transaction.validationStatus,
    };
  });
}
