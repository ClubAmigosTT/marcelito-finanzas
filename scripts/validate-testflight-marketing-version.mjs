import crypto from "node:crypto";
import { pathToFileURL } from "node:url";

const apiBase = "https://api.appstoreconnect.apple.com";

/**
 * Parse the numeric version format accepted by CFBundleShortVersionString.
 * Returning null keeps malformed App Store Connect data from influencing the
 * comparison silently.
 */
export function parseMarketingVersion(value) {
  const text = String(value ?? "").trim();
  if (!/^\d+(?:\.\d+){0,2}$/.test(text)) return null;
  const parts = text.split(".").map(Number);
  return parts.every((part) => Number.isSafeInteger(part) && part >= 0) ? parts : null;
}

/** Compare two Apple marketing versions numerically, padding missing parts. */
export function compareMarketingVersions(left, right) {
  const a = parseMarketingVersion(left);
  const b = parseMarketingVersion(right);
  if (!a || !b) throw new Error(`Versión de marketing inválida: ${String(!a ? left : right)}`);
  const length = Math.max(a.length, b.length);
  for (let index = 0; index < length; index += 1) {
    const difference = (a[index] ?? 0) - (b[index] ?? 0);
    if (difference !== 0) return difference > 0 ? 1 : -1;
  }
  return 0;
}

export function highestMarketingVersion(versions) {
  return versions
    .map((version) => String(version ?? "").trim())
    .filter((version) => parseMarketingVersion(version))
    .reduce((highest, version) => (
      !highest || compareMarketingVersions(version, highest) > 0 ? version : highest
    ), null);
}

const base64Url = (value) => Buffer.from(value)
  .toString("base64")
  .replace(/=/g, "")
  .replace(/\+/g, "-")
  .replace(/\//g, "_");

function makeToken() {
  const now = Math.floor(Date.now() / 1000);
  const header = base64Url(JSON.stringify({
    alg: "ES256",
    kid: process.env.ASC_KEY_ID,
    typ: "JWT",
  }));
  const payload = base64Url(JSON.stringify({
    iss: process.env.ASC_ISSUER_ID,
    iat: now - 30,
    exp: now + 540,
    aud: "appstoreconnect-v1",
  }));
  const signer = crypto.createSign("SHA256");
  signer.update(`${header}.${payload}`);
  signer.end();
  const signature = signer.sign({
    key: crypto.createPrivateKey(String(process.env.ASC_PRIVATE_KEY)
      .replace(/\r\n/g, "\n")
      .replace(/\\n/g, "\n")),
    dsaEncoding: "ieee-p1363",
  });
  return `${header}.${payload}.${base64Url(signature)}`;
}

async function request(pathOrUrl) {
  const url = pathOrUrl.startsWith("http") ? pathOrUrl : `${apiBase}${pathOrUrl}`;
  const response = await fetch(url, {
    headers: {
      Authorization: `Bearer ${makeToken()}`,
      Accept: "application/json",
    },
  });
  const body = await response.text();
  let parsed;
  try {
    parsed = body ? JSON.parse(body) : null;
  } catch {
    parsed = body;
  }
  if (!response.ok) {
    const detail = typeof parsed === "string" ? parsed : JSON.stringify(parsed);
    throw new Error(`HTTP ${response.status}: ${detail.slice(0, 500)}`);
  }
  return parsed;
}

async function collection(path) {
  const rows = [];
  let next = path;
  while (next) {
    const page = await request(next);
    rows.push(...(page?.data || []));
    next = page?.links?.next || null;
  }
  return rows;
}

export async function validateMarketingVersion({
  targetVersion = process.env.TARGET_MARKETING_VERSION,
  bundleId = process.env.ASC_BUNDLE_ID,
} = {}) {
  const required = ["ASC_ISSUER_ID", "ASC_KEY_ID", "ASC_PRIVATE_KEY"];
  for (const name of required) {
    if (!String(process.env[name] || "").trim()) throw new Error(`Falta la variable ${name}`);
  }
  if (!bundleId?.trim()) throw new Error("Falta la variable ASC_BUNDLE_ID");
  if (!parseMarketingVersion(targetVersion)) {
    throw new Error(`TARGET_MARKETING_VERSION inválida: ${String(targetVersion)}`);
  }

  const apps = await collection(
    `/v1/apps?filter[bundleId]=${encodeURIComponent(bundleId)}&limit=200`,
  );
  const app = apps[0];
  if (!app) throw new Error(`No se encontró la app con bundle ${bundleId}`);

  const builds = await collection(
    `/v1/builds?filter[app]=${encodeURIComponent(app.id)}&sort=-uploadedDate&limit=200`,
  );
  const existingVersions = builds.map((build) => build.attributes?.version);
  const highest = highestMarketingVersion(existingVersions);
  if (highest && compareMarketingVersions(targetVersion, highest) < 0) {
    throw new Error(
      `La versión ${targetVersion} es menor que la versión ${highest} ya existente en `
      + `App Store Connect para ${bundleId}. Usa una versión igual (otro build) o superior.`,
    );
  }

  return {
    bundleId,
    targetVersion,
    highestExistingVersion: highest,
    accepted: true,
  };
}

async function main() {
  const result = await validateMarketingVersion();
  console.log(JSON.stringify(result));
}

const invokedPath = process.argv[1];
const invokedUrl = invokedPath ? pathToFileURL(invokedPath).href : undefined;
if (invokedUrl && import.meta.url === invokedUrl) {
  await main();
}
