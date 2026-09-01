/* global AbortController, Buffer, process, fetch, URL, console, setTimeout, clearTimeout */

import { createHash, timingSafeEqual } from "node:crypto";
import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const MAX_FILE_BYTES = 20 * 1024 * 1024;
const MAX_REQUEST_BYTES = 28 * 1024 * 1024;
const SCHEMA_PATH = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "schemas", "statement-extraction.schema.json");
const DEFAULT_PORT = 8787;
const DEFAULT_RATE_LIMIT_PER_MINUTE = 10;
const DEFAULT_MAX_CONCURRENT_REQUESTS = 2;
const DEFAULT_PROVIDER_TIMEOUT_MS = 120_000;

const READER_PROMPT = `Eres un extractor documental financiero. Lee el PDF completo, incluyendo las páginas renderizadas cuando el texto esté desordenado. Devuelve exclusivamente el JSON que cumple el esquema indicado.

Reglas obligatorias:
- Identifica el emisor por encabezado, razón social, dominio o logotipo institucional. Nunca uses una marca mencionada solo dentro de una operación para decidir el banco.
- Extrae únicamente filas que pertenezcan a la tabla de movimientos del periodo. Una fila requiere fecha válida, descripción comercial válida, importe monetario válido y dirección clara (in o out).
- No conviertas en movimientos encabezados, pies, referencias, cuentas, CLABE, RFC, certificados, folios, autorizaciones, fechas de corte, saldos, subtotales, totales, límites, crédito disponible ni texto administrativo.
- No inventes ni corrijas importes. Los importes son centavos enteros absolutos; la dirección determina el signo. Si un dato no se puede leer con seguridad, usa null en el resumen o no incluyas la fila.
- Conserva página y un fragmento breve y literal de evidencia de la fila. La evidencia no puede ser una explicación inventada.
- Clasifica cada fila como purchase, cardPayment, bankTransfer, income, credit, refund, msi, interest, fee u other. Un pago de una cuenta bancaria a una tarjeta es cardPayment; una transferencia entre cuentas propias es bankTransfer; un reembolso es refund; ninguno de ellos es gasto ordinario.
- En estados bancarios, lee los totales declarados de depósitos/retiros y sus conteos. En tarjetas, lee saldo/deuda, límite, disponible, pago mínimo, pago para no generar intereses y MSI si aparecen. Los importes del resumen también son centavos enteros.
- Si un subtotal está impreso como crédito (CR), conserva domestic_transaction_total_is_credit=true. No sumes dos veces subtotales y totales.
- Devuelve todas las propiedades requeridas por el esquema; usa null cuando un campo no esté impreso o no sea legible. No añadas propiedades adicionales.`;

const PREFLIGHT_EXPECTED = {
  source: "PREFLIGHT BANK",
  kind: "bank",
  account_last4: "0000",
  period_start: "2026-01-01",
  period_end: "2026-01-31",
  cutoff_date: "2026-01-31",
  page_count: 1,
  description: "PREFLIGHT TEST MOVEMENT",
  date: "2026-01-15",
  amount_cents: 1234,
};

const PREFLIGHT_PROMPT = `Esta es una prueba técnica sin datos financieros reales. El PDF sintético contiene una sola fila de prueba. Lee esa fila y devuelve exclusivamente el JSON que cumple el esquema indicado.

Para que la prueba sea válida, devuelve exactamente estos valores: source="PREFLIGHT BANK", kind="bank", account_last4="0000", period_start="2026-01-01", period_end="2026-01-31", cutoff_date="2026-01-31", page_count=1. Todas las propiedades de summary deben ser null. Devuelve una sola fila: date="2026-01-15", description="PREFLIGHT TEST MOVEMENT", amount_cents=1234, direction="out", kind="purchase", foreign_currency=false, page=1, evidence que contenga "PREFLIGHT TEST MOVEMENT" y confidence mayor o igual a 0.90. No inventes filas ni importes.`;

// A tiny in-memory PDF used only by the authenticated provider preflight. It
// contains a synthetic movement (12.34) and is never returned to the caller.
// Keeping a real text object here proves the provider can ingest a PDF and
// recover a row, rather than merely echoing the expected empty response.
const PREFLIGHT_TEXT = "BT\n/F1 12 Tf\n72 720 Td\n(PREFLIGHT BANK) Tj\n0 -20 Td\n(FECHA DESCRIPCION IMPORTE) Tj\n0 -20 Td\n(15/ENE/2026 PREFLIGHT TEST MOVEMENT 12.34) Tj\nET\n";

function createPreflightPdf() {
  const objects = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
    `<< /Length ${Buffer.byteLength(PREFLIGHT_TEXT, "utf8")} >>\nstream\n${PREFLIGHT_TEXT}endstream`,
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
  ];
  let document = "%PDF-1.4\n";
  const offsets = [0];
  objects.forEach((object, index) => {
    offsets.push(Buffer.byteLength(document, "utf8"));
    document += `${index + 1} 0 obj\n${object}\nendobj\n`;
  });
  const xrefOffset = Buffer.byteLength(document, "utf8");
  document += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  for (let index = 1; index < offsets.length; index += 1) {
    document += `${String(offsets[index]).padStart(10, "0")} 00000 n \n`;
  }
  document += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xrefOffset}\n%%EOF\n`;
  return Buffer.from(document, "utf8");
}

const PREFLIGHT_PDF = createPreflightPdf();

function json(res, status, body, extraHeaders = {}) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    ...extraHeaders,
  });
  res.end(payload);
}

function requestOrigin(req) {
  const value = req.headers.origin;
  return typeof value === "string" ? value : "";
}

function corsHeaders(req, env) {
  const allowed = String(env.STATEMENT_READER_ALLOWED_ORIGIN ?? "").trim();
  const origin = requestOrigin(req);
  if (!allowed || !origin || origin !== allowed) return { vary: "Origin" };
  return {
    "access-control-allow-origin": origin,
    "access-control-allow-methods": "POST, OPTIONS",
    "access-control-allow-headers": "content-type, authorization, x-reader-token",
    "access-control-max-age": "600",
    vary: "Origin",
  };
}

function constantTimeEqual(actual, expected) {
  const left = Buffer.from(String(actual ?? ""));
  const right = Buffer.from(String(expected ?? ""));
  return left.length === right.length && timingSafeEqual(left, right);
}

function positiveInt(value, fallback, maximum = Number.MAX_SAFE_INTEGER) {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? Math.min(parsed, maximum) : fallback;
}

function requestKey(req) {
  // Do not trust a caller-provided forwarded-for header for quota identity.
  // The reverse proxy can still enforce its own per-user limits upstream.
  return req.socket?.remoteAddress ?? "unknown";
}

function consumeRateLimit(state, key, limit, now = Date.now()) {
  const windowMs = 60_000;
  const current = state.get(key);
  if (!current || now - current.startedAt >= windowMs) {
    state.set(key, { startedAt: now, count: 1 });
    return true;
  }
  if (current.count >= limit) return false;
  current.count += 1;
  return true;
}

function authorized(req, env) {
  const expected = String(env.STATEMENT_READER_TOKEN ?? "");
  if (!expected) return false;
  const bearer = typeof req.headers.authorization === "string"
    ? req.headers.authorization.replace(/^Bearer\s+/i, "").trim()
    : "";
  const headerToken = typeof req.headers["x-reader-token"] === "string" ? req.headers["x-reader-token"].trim() : "";
  return constantTimeEqual(bearer || headerToken, expected);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > MAX_REQUEST_BYTES) {
        reject(new Error("request_too_large"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function decodePdf(value) {
  if (typeof value !== "string" || value.length === 0) throw new Error("pdf_missing");
  const base64 = value.replace(/^data:application\/pdf;base64,/i, "");
  if (base64.length > Math.ceil(MAX_FILE_BYTES * 4 / 3) + 8 || !/^[A-Za-z0-9+/]*={0,2}$/.test(base64)) throw new Error("pdf_invalid");
  const buffer = Buffer.from(base64, "base64");
  // Reject arbitrary binary uploads before they reach the model. The local
  // reader accepts encrypted/odd PDFs separately, but every remote request
  // must at least carry the PDF magic header and stay within the size cap.
  if (buffer.length < 5 || buffer.length > MAX_FILE_BYTES || buffer.subarray(0, 5).toString("ascii") !== "%PDF-") throw new Error("pdf_invalid");
  return buffer;
}

function extractOutputText(body) {
  if (typeof body?.output_text === "string" && body.output_text.trim()) return body.output_text;
  const chunks = [];
  for (const item of Array.isArray(body?.output) ? body.output : []) {
    for (const content of Array.isArray(item?.content) ? item.content : []) {
      if (typeof content?.text === "string") chunks.push(content.text);
    }
  }
  return chunks.join("\n");
}

function parseModelJson(value) {
  const cleaned = String(value ?? "").trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");
  if (!cleaned) throw new Error("model_empty");
  try {
    return JSON.parse(cleaned);
  } catch {
    // Some compatible Responses proxies wrap the JSON in a short preamble.
    const start = cleaned.indexOf("{");
    const end = cleaned.lastIndexOf("}");
    if (start >= 0 && end > start) return JSON.parse(cleaned.slice(start, end + 1));
    throw new Error("model_invalid_json");
  }
}

const administrativeRowPattern = /(?:ciudad\s+de\s+m[eé]xico|serie\s+del\s+certificado|total\s+(?:importe|de\s+las\s+transacciones|de\s+movimientos)|fecha\s+de\s+corte|n[uú]mero\s+de\s+cuenta|no\.?\s+de\s+cuenta|cuenta\s+clabe|rfc|saldo\s+(?:inicial|anterior|final|disponible)?|periodo\s+de\s+facturaci[oó]n)/i;

const summaryFields = [
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

const rowFields = ["date", "description", "amount_cents", "direction", "kind", "foreign_currency", "page", "evidence", "confidence"];

function hasOnlyFields(value, fields) {
  const keys = Object.keys(value);
  return keys.length === fields.length && fields.every((field) => Object.prototype.hasOwnProperty.call(value, field));
}

function validIsoDate(value) {
  if (typeof value !== "string" || !/^20\d{2}-\d{2}-\d{2}$/.test(value)) return false;
  const date = new Date(`${value}T00:00:00.000Z`);
  return !Number.isNaN(date.valueOf()) && date.toISOString().slice(0, 10) === value;
}

function validNullableCents(value) {
  return value === null || (Number.isInteger(value) && value >= 0 && value <= 1_000_000_000_000);
}

function shouldRetryWithoutStructuredOutput(response, body) {
  // A few OpenAI-compatible gateways implement PDF input but reject the
  // optional Structured Outputs envelope. Retry once without that envelope;
  // validateModelShape below remains mandatory, so this never relaxes the
  // contract that reaches the app.
  if (![400, 404, 422].includes(response.status)) return false;
  const details = JSON.stringify(body ?? {}).toLowerCase();
  return /(?:json[_ -]?schema|response[_ -]?format|structured[_ -]?output|text\.format|unsupported|unknown\s+parameter)/.test(details);
}

/** Lightweight server-side guard. The client performs the full canonical
 * validator; this second boundary prevents a direct caller from receiving an
 * obviously malformed or administrative model response. */
function validateModelShape(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("model_invalid_shape");
  if (!hasOnlyFields(value, ["source", "kind", "account_last4", "period_start", "period_end", "cutoff_date", "page_count", "summary", "rows"])) throw new Error("model_invalid_shape");
  if (typeof value.source !== "string" || !value.source.trim() || value.source.trim().length > 80 || administrativeRowPattern.test(value.source)) throw new Error("model_invalid_shape");
  if (!(["bank", "card", "unknown"].includes(value.kind))) throw new Error("model_invalid_shape");
  if (value.account_last4 !== null && (typeof value.account_last4 !== "string" || !/^\d{4}$/.test(value.account_last4))) throw new Error("model_invalid_shape");
  for (const key of ["period_start", "period_end", "cutoff_date"]) {
    if (value[key] !== null && !validIsoDate(value[key])) throw new Error("model_invalid_shape");
  }
  if (value.period_start && value.period_end && value.period_start > value.period_end) throw new Error("model_invalid_shape");
  if (!Number.isInteger(value.page_count) || value.page_count < 1 || value.page_count > 200) throw new Error("model_invalid_shape");
  if (!value.summary || typeof value.summary !== "object" || Array.isArray(value.summary) || !hasOnlyFields(value.summary, summaryFields)) throw new Error("model_invalid_shape");
  for (const key of summaryFields) {
    const summaryValue = value.summary[key];
    if (key === "domestic_transaction_total_is_credit") {
      if (summaryValue !== null && typeof summaryValue !== "boolean") throw new Error("model_invalid_shape");
    } else if (["msi_installments", "deposit_count", "withdrawal_count"].includes(key)) {
      if (summaryValue !== null && (!Number.isInteger(summaryValue) || summaryValue < 0 || summaryValue > 2_500)) throw new Error("model_invalid_shape");
    } else if (!validNullableCents(summaryValue)) {
      throw new Error("model_invalid_shape");
    }
  }
  if (!Array.isArray(value.rows) || value.rows.length > 2500) throw new Error("model_invalid_shape");
  for (const row of value.rows) {
    if (!row || typeof row !== "object" || Array.isArray(row) || !hasOnlyFields(row, rowFields)) throw new Error("model_invalid_shape");
    if (!validIsoDate(row.date)) throw new Error("model_invalid_shape");
    if (typeof row.description !== "string" || row.description.trim().length < 3 || administrativeRowPattern.test(row.description)) throw new Error("model_invalid_shape");
    if (!Number.isInteger(row.amount_cents) || row.amount_cents < 1 || row.amount_cents > 1_000_000_000_000) throw new Error("model_invalid_shape");
    if (!(["purchase", "cardPayment", "bankTransfer", "income", "credit", "refund", "msi", "interest", "fee", "other"].includes(row.kind))) throw new Error("model_invalid_shape");
    if (!(["in", "out"].includes(row.direction)) || !Number.isInteger(row.page) || row.page < 1 || row.page > value.page_count) throw new Error("model_invalid_shape");
    if (["income", "credit", "refund"].includes(row.kind) && row.direction !== "in") throw new Error("model_invalid_shape");
    if (["purchase", "msi", "interest", "fee"].includes(row.kind) && row.direction !== "out") throw new Error("model_invalid_shape");
    if (typeof row.foreign_currency !== "boolean" || typeof row.evidence !== "string" || row.evidence.trim().length < 3 || row.evidence.length > 500 || typeof row.confidence !== "number" || !Number.isFinite(row.confidence) || row.confidence < 0 || row.confidence > 1) throw new Error("model_invalid_shape");
  }
  return value;
}

function validatePreflightExtraction(value) {
  validateModelShape(value);
  const normalizedSource = String(value.source).trim().toUpperCase();
  const normalizedDescription = String(value.rows[0]?.description ?? "").trim().toUpperCase();
  const summaryIsEmpty = summaryFields.every((key) => value.summary[key] === null);
  const row = value.rows.length === 1 ? value.rows[0] : undefined;
  const evidence = String(row?.evidence ?? "").toUpperCase();
  if (
    normalizedSource !== PREFLIGHT_EXPECTED.source
    || value.kind !== PREFLIGHT_EXPECTED.kind
    || value.account_last4 !== PREFLIGHT_EXPECTED.account_last4
    || value.period_start !== PREFLIGHT_EXPECTED.period_start
    || value.period_end !== PREFLIGHT_EXPECTED.period_end
    || value.cutoff_date !== PREFLIGHT_EXPECTED.cutoff_date
    || value.page_count !== PREFLIGHT_EXPECTED.page_count
    || !summaryIsEmpty
    || !row
    || row.date !== PREFLIGHT_EXPECTED.date
    || normalizedDescription !== PREFLIGHT_EXPECTED.description
    || row.amount_cents !== PREFLIGHT_EXPECTED.amount_cents
    || row.direction !== "out"
    || row.kind !== "purchase"
    || row.foreign_currency !== false
    || row.page !== 1
    || !evidence.includes(PREFLIGHT_EXPECTED.description)
    || row.confidence < 0.9
  ) {
    throw new Error("preflight_contract_not_proven");
  }
  return value;
}

async function callProvider({ pdf, fileName, env, fetchImpl, schema, prompt = READER_PROMPT }) {
  const apiKey = String(env.STATEMENT_READER_API_KEY ?? env.OPENAI_API_KEY ?? "").trim();
  const model = String(env.STATEMENT_READER_MODEL ?? env.OPENAI_STATEMENT_MODEL ?? "").trim();
  const endpoint = String(env.STATEMENT_READER_PROVIDER_URL ?? "https://api.openai.com/v1/responses").trim();
  let providerUrl;
  try {
    providerUrl = new URL(endpoint);
  } catch {
    throw new Error("provider_not_configured");
  }
  if (providerUrl.protocol !== "https:") throw new Error("provider_not_configured");
  if (!apiKey || !model) throw new Error("provider_not_configured");
  const requestBody = (includeStructuredOutput) => ({
    model,
    store: false,
    input: [{
      role: "user",
      content: [
        {
          type: "input_file",
          filename: fileName,
          file_data: `data:application/pdf;base64,${pdf.toString("base64")}`,
        },
        {
          type: "input_text",
          text: includeStructuredOutput
            ? prompt
            : `${prompt}\n\nCompatibilidad: devuelve el objeto JSON directamente, sin Markdown, sin comentarios y sin propiedades fuera del contrato.`,
        },
      ],
    }],
    ...(includeStructuredOutput ? {
      text: {
        format: {
          type: "json_schema",
          name: "statement_extraction",
          strict: true,
          // `$schema`/`$id` are useful repository metadata but are not part
          // of the provider's strict response grammar. Keep `$defs`/`$ref`,
          // which Structured Outputs supports, and strip only those hints.
          schema: Object.fromEntries(Object.entries(schema).filter(([key]) => key !== "$schema" && key !== "$id")),
        },
      },
    } : {}),
  });
  const requestProvider = async (includeStructuredOutput) => {
    const controller = new AbortController();
    const timeout = setTimeout(
      () => controller.abort(),
      positiveInt(env.STATEMENT_READER_PROVIDER_TIMEOUT_MS, DEFAULT_PROVIDER_TIMEOUT_MS, 300_000),
    );
    try {
      return await fetchImpl(providerUrl, {
        method: "POST",
        headers: {
          authorization: `Bearer ${apiKey}`,
          "content-type": "application/json",
        },
        body: JSON.stringify(requestBody(includeStructuredOutput)),
        signal: controller.signal,
      });
    } catch (error) {
      if (error?.name === "AbortError") throw new Error("provider_timeout");
      throw error;
    } finally {
      clearTimeout(timeout);
    }
  };

  let response;
  let body;
  try {
    response = await requestProvider(true);
    body = await response.json();
  } catch (error) {
    if (error?.message === "provider_timeout") throw error;
    throw new Error("provider_invalid_response");
  }
  if (!response.ok && shouldRetryWithoutStructuredOutput(response, body)) {
    try {
      response = await requestProvider(false);
      body = await response.json();
    } catch (error) {
      if (error?.message === "provider_timeout") throw error;
      throw new Error("provider_invalid_response");
    }
  }
  if (!response.ok) {
    const errorType = typeof body?.error?.type === "string" ? body.error.type : "provider_error";
    throw new Error(`provider_${errorType}`);
  }
  return { extraction: validateModelShape(parseModelJson(extractOutputText(body))), model };
}

/**
 * Creates the isolated PDF reader proxy. It has no persistence and never
 * returns the source document; only the validated extraction crosses back to
 * the client. Set STATEMENT_READER_TOKEN and an exact allowed origin before
 * exposing it outside localhost.
 */
export function createStatementReaderServer({ env = process.env, fetchImpl = fetch, schema = JSON.parse(readFileSync(SCHEMA_PATH, "utf8")) } = {}) {
  const rateState = new Map();
  let activeRequests = 0;
  return createServer(async (req, res) => {
    const headers = corsHeaders(req, env);
    if (req.method === "OPTIONS") {
      res.writeHead(headers["access-control-allow-origin"] ? 204 : 403, headers);
      res.end();
      return;
    }
    const pathname = new URL(req.url ?? "/", "http://localhost").pathname;
    if (req.method === "GET" && pathname === "/health") {
      json(res, 200, {
        status: "ok",
        configured: Boolean(
          (env.STATEMENT_READER_API_KEY || env.OPENAI_API_KEY)
          && (env.STATEMENT_READER_MODEL || env.OPENAI_STATEMENT_MODEL)
          && env.STATEMENT_READER_TOKEN,
        ),
      }, headers);
      return;
    }
    const isExtractionRoute = req.method === "POST" && pathname === "/api/statement-reader";
    const isPreflightRoute = req.method === "POST" && pathname === "/api/statement-reader/preflight";
    if (!isExtractionRoute && !isPreflightRoute) {
      json(res, 404, { error: "not_found" }, headers);
      return;
    }
    if (!headers["access-control-allow-origin"] && requestOrigin(req)) {
      json(res, 403, { error: "origin_not_allowed" }, headers);
      return;
    }
    if (!authorized(req, env)) {
      json(res, 401, { error: "unauthorized" }, headers);
      return;
    }
    const rateLimit = positiveInt(env.STATEMENT_READER_MAX_REQUESTS_PER_MINUTE, DEFAULT_RATE_LIMIT_PER_MINUTE, 1_000);
    if (!consumeRateLimit(rateState, requestKey(req), rateLimit)) {
      json(res, 429, { error: "rate_limited" }, { ...headers, "retry-after": "60" });
      return;
    }
    const maxConcurrent = positiveInt(env.STATEMENT_READER_MAX_CONCURRENT_REQUESTS, DEFAULT_MAX_CONCURRENT_REQUESTS, 50);
    if (activeRequests >= maxConcurrent) {
      json(res, 429, { error: "reader_busy" }, { ...headers, "retry-after": "10" });
      return;
    }
    activeRequests += 1;
    let payload;
    try {
      try {
        const rawBody = await readBody(req);
        payload = rawBody.trim() ? JSON.parse(rawBody) : {};
      } catch (error) {
        json(res, error?.message === "request_too_large" ? 413 : 400, { error: "invalid_request" }, headers);
        return;
      }
      try {
        if (isPreflightRoute) {
          // The preflight proves provider transport, PDF input support and
          // strict JSON output without uploading a user's document.
          const result = await callProvider({
            pdf: PREFLIGHT_PDF,
            fileName: "marcelito-reader-preflight.pdf",
            env,
            fetchImpl,
            schema,
            prompt: PREFLIGHT_PROMPT,
          });
          validatePreflightExtraction(result.extraction);
          json(res, 200, {
            status: "ready",
            model: result.model,
            contract: "statement-extraction.v1",
          }, headers);
          return;
        }
        if (!payload || typeof payload !== "object" || typeof payload.fileName !== "string" || payload.fileName.length < 1 || payload.fileName.length > 240) throw new Error("request_invalid");
        const pdf = decodePdf(payload.pdfBase64);
        const result = await callProvider({ pdf, fileName: path.basename(payload.fileName), env, fetchImpl, schema });
        const sourceFingerprint = createHash("sha256").update(pdf).digest("hex");
        json(res, 200, { ...result, sourceFingerprint }, headers);
      } catch (error) {
        const code = error?.message ?? "reader_failed";
        const status = code === "provider_not_configured" ? 503 : code.startsWith("provider_") ? 502 : code.startsWith("pdf_") ? 400 : 422;
        // Do not echo model/provider details or source text. A request id can be
        // added by the reverse proxy for operational tracing without logging the
        // financial document.
        json(res, status, { error: status === 503 ? "reader_not_configured" : status === 502 ? "provider_unavailable" : "reader_rejected" }, headers);
      }
    } finally {
      activeRequests -= 1;
    }
  });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const port = Number(process.env.PORT ?? DEFAULT_PORT);
  const server = createStatementReaderServer();
  server.listen(port, "0.0.0.0", () => {
    console.log(`statement reader listening on ${port}`);
  });
}
