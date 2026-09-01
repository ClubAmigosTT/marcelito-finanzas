/* global Buffer, process, fetch, URL, console */

import { createHash, timingSafeEqual } from "node:crypto";
import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const MAX_FILE_BYTES = 20 * 1024 * 1024;
const MAX_REQUEST_BYTES = 28 * 1024 * 1024;
const SCHEMA_PATH = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "schemas", "statement-extraction.schema.json");
const DEFAULT_PORT = 8787;

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

/** Lightweight server-side guard. The client performs the full canonical
 * validator; this second boundary prevents a direct caller from receiving an
 * obviously malformed or administrative model response. */
function validateModelShape(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("model_invalid_shape");
  if (typeof value.source !== "string" || !value.source.trim()) throw new Error("model_invalid_shape");
  if (!(["bank", "card", "unknown"].includes(value.kind))) throw new Error("model_invalid_shape");
  if (!Number.isInteger(value.page_count) || value.page_count < 1 || value.page_count > 200) throw new Error("model_invalid_shape");
  if (!value.summary || typeof value.summary !== "object" || Array.isArray(value.summary)) throw new Error("model_invalid_shape");
  if (!Array.isArray(value.rows) || value.rows.length > 2500) throw new Error("model_invalid_shape");
  for (const row of value.rows) {
    if (!row || typeof row !== "object" || Array.isArray(row)) throw new Error("model_invalid_shape");
    if (typeof row.date !== "string" || !/^20\d{2}-\d{2}-\d{2}$/.test(row.date)) throw new Error("model_invalid_shape");
    if (typeof row.description !== "string" || row.description.trim().length < 3 || administrativeRowPattern.test(row.description)) throw new Error("model_invalid_shape");
    if (!Number.isInteger(row.amount_cents) || row.amount_cents < 1 || row.amount_cents > 1_000_000_000_000) throw new Error("model_invalid_shape");
    if (!(["purchase", "cardPayment", "bankTransfer", "income", "credit", "refund", "msi", "interest", "fee", "other"].includes(row.kind))) throw new Error("model_invalid_shape");
    if (!(["in", "out"].includes(row.direction)) || !Number.isInteger(row.page) || row.page < 1 || row.page > value.page_count) throw new Error("model_invalid_shape");
    if (["income", "credit", "refund"].includes(row.kind) && row.direction !== "in") throw new Error("model_invalid_shape");
    if (["purchase", "msi", "interest", "fee"].includes(row.kind) && row.direction !== "out") throw new Error("model_invalid_shape");
    if (typeof row.evidence !== "string" || row.evidence.trim().length < 3 || typeof row.confidence !== "number" || row.confidence < 0 || row.confidence > 1) throw new Error("model_invalid_shape");
  }
  return value;
}

async function callProvider({ pdf, fileName, env, fetchImpl, schema }) {
  const apiKey = String(env.OPENAI_API_KEY ?? "").trim();
  const model = String(env.OPENAI_STATEMENT_MODEL ?? "").trim();
  if (!apiKey || !model) throw new Error("provider_not_configured");
  const response = await fetchImpl("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: {
      authorization: `Bearer ${apiKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
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
          { type: "input_text", text: READER_PROMPT },
        ],
      }],
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
    }),
  });
  let body;
  try {
    body = await response.json();
  } catch {
    throw new Error("provider_invalid_response");
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
  return createServer(async (req, res) => {
    const headers = corsHeaders(req, env);
    if (req.method === "OPTIONS") {
      res.writeHead(headers["access-control-allow-origin"] ? 204 : 403, headers);
      res.end();
      return;
    }
    const pathname = new URL(req.url ?? "/", "http://localhost").pathname;
    if (req.method === "GET" && pathname === "/health") {
      json(res, 200, { status: "ok", configured: Boolean(env.OPENAI_API_KEY && env.OPENAI_STATEMENT_MODEL && env.STATEMENT_READER_TOKEN) }, headers);
      return;
    }
    if (req.method !== "POST" || pathname !== "/api/statement-reader") {
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
    let payload;
    try {
      payload = JSON.parse(await readBody(req));
    } catch (error) {
      json(res, error?.message === "request_too_large" ? 413 : 400, { error: "invalid_request" }, headers);
      return;
    }
    try {
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
  });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const port = Number(process.env.PORT ?? DEFAULT_PORT);
  const server = createStatementReaderServer();
  server.listen(port, "0.0.0.0", () => {
    console.log(`statement reader listening on ${port}`);
  });
}
