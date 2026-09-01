const DEFAULT_TIMEOUT_MS = 120_000;

function secureEndpoint(value) {
  let parsed;
  try {
    parsed = new URL(String(value ?? "").trim());
  } catch {
    throw new Error("La URL del lector no es válida.");
  }
  const local = ["localhost", "127.0.0.1", "[::1]"].includes(parsed.hostname);
  if (parsed.protocol !== "https:" && !(parsed.protocol === "http:" && local)) {
    throw new Error("La URL del lector debe usar HTTPS (o localhost durante desarrollo).");
  }
  parsed.search = "";
  parsed.hash = "";
  return parsed;
}

function endpointPath(endpoint) {
  const path = endpoint.pathname.replace(/\/+$/, "");
  return path || "/api/statement-reader";
}

async function fetchJson(url, init, fetchImpl, timeoutMs) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetchImpl(url, { ...init, signal: controller.signal });
    let body;
    try {
      body = await response.json();
    } catch {
      throw new Error(`El lector devolvió una respuesta no JSON (HTTP ${response.status}).`);
    }
    return { response, body };
  } catch (error) {
    if (error?.name === "AbortError") throw new Error("La comprobación del lector agotó el tiempo de espera.");
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

/**
 * Verifies an already deployed reader without uploading a user document.
 * Health proves that server-side secrets exist; the synthetic preflight proves
 * PDF ingestion and the extraction contract. No secret is returned or logged.
 */
export async function verifyReaderDeployment({ endpoint, token, fetchImpl = fetch, timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
  if (!String(token ?? "").trim()) throw new Error("Falta STATEMENT_READER_TOKEN.");
  const parsedEndpoint = secureEndpoint(endpoint);
  const readerPath = endpointPath(parsedEndpoint);
  const healthUrl = new URL("/health", parsedEndpoint.origin).toString();
  const preflightUrl = `${parsedEndpoint.origin}${readerPath}/preflight`;
  const health = await fetchJson(healthUrl, { method: "GET", headers: { accept: "application/json" } }, fetchImpl, timeoutMs);
  if (!health.response.ok || health.body?.status !== "ok" || health.body?.configured !== true) {
    throw new Error("El servicio del lector no está configurado (health no confirmó configured=true).");
  }
  const preflight = await fetchJson(preflightUrl, {
    method: "POST",
    headers: {
      authorization: `Bearer ${String(token).trim()}`,
      "content-type": "application/json",
    },
    body: "{}",
  }, fetchImpl, timeoutMs);
  const model = typeof preflight.body?.model === "string" ? preflight.body.model.trim() : "";
  if (!preflight.response.ok || preflight.body?.status !== "ready" || preflight.body?.contract !== "statement-extraction.v1" || !model) {
    throw new Error("El preflight no confirmó PDF + contrato JSON del proveedor.");
  }
  return { health: { status: "ok", configured: true }, preflight: { status: "ready", model, contract: "statement-extraction.v1" } };
}

if (process.argv[1] && new URL(`file://${process.argv[1].replace(/\\/g, "/")}`).pathname.endsWith("/verify-reader-deployment.mjs")) {
  const endpoint = process.env.STATEMENT_READER_URL ?? process.env.VITE_STATEMENT_READER_URL;
  const token = process.env.STATEMENT_READER_TOKEN;
  if (!endpoint || !token) {
    console.error("Uso: STATEMENT_READER_URL=https://... STATEMENT_READER_TOKEN=... npm run reader:verify");
    process.exitCode = 2;
  } else {
    try {
      const result = await verifyReaderDeployment({ endpoint, token });
      console.log(`Lector listo: ${result.preflight.model} · contrato ${result.preflight.contract}`);
    } catch (error) {
      console.error(error instanceof Error ? error.message : "No se pudo verificar el lector.");
      process.exitCode = 1;
    }
  }
}
