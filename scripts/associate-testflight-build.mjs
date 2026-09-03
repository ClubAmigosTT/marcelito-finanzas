import crypto from "node:crypto";

const apiBase = "https://api.appstoreconnect.apple.com";
const required = [
  "ASC_ISSUER_ID",
  "ASC_KEY_ID",
  "ASC_PRIVATE_KEY",
  "ASC_BUNDLE_ID",
  "ASC_BUILD_NUMBER",
];

for (const name of required) {
  if (!String(process.env[name] || "").trim()) {
    throw new Error(`Falta la variable ${name}`);
  }
}

const base64Url = (value) => Buffer.from(value)
  .toString("base64")
  .replace(/=/g, "")
  .replace(/\+/g, "-")
  .replace(/\//g, "_");

const privateKey = String(process.env.ASC_PRIVATE_KEY)
  .replace(/\r\n/g, "\n")
  .replace(/\\n/g, "\n");

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
    key: crypto.createPrivateKey(privateKey),
    dsaEncoding: "ieee-p1363",
  });
  return `${header}.${payload}.${base64Url(signature)}`;
}

async function request(pathOrUrl, options = {}) {
  const url = pathOrUrl.startsWith("http") ? pathOrUrl : `${apiBase}${pathOrUrl}`;
  const response = await fetch(url, {
    ...options,
    headers: {
      Authorization: `Bearer ${makeToken()}`,
      Accept: "application/json",
      ...(options.body ? { "Content-Type": "application/json" } : {}),
      ...(options.headers || {}),
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

const targetBuild = String(process.env.ASC_BUILD_NUMBER).trim();
const appRows = await collection(
  `/v1/apps?filter[bundleId]=${encodeURIComponent(process.env.ASC_BUNDLE_ID)}&limit=200`,
);
const app = appRows[0];
if (!app) {
  throw new Error(`No se encontró la app con bundle ${process.env.ASC_BUNDLE_ID}`);
}

const builds = await collection(
  `/v1/builds?filter[app]=${encodeURIComponent(app.id)}&sort=-uploadedDate&limit=200`,
);
const build = builds.find((item) => String(item.attributes?.version) === targetBuild);
if (!build) {
  throw new Error(`No se encontró el build ${targetBuild} en App Store Connect`);
}

const processingState = build.attributes?.processingState || "DESCONOCIDO";
if (processingState !== "VALID") {
  throw new Error(`El build ${targetBuild} no está listo: ${processingState}`);
}

const groups = await collection(
  `/v1/betaGroups?filter[app]=${encodeURIComponent(app.id)}&limit=200`,
);
const targetName = String(process.env.ASC_TESTFLIGHT_GROUP_NAME || "Marcelito - Pruebas internas");
const selected = [];

for (const group of groups) {
  const relationship = await collection(
    `/v1/betaGroups/${encodeURIComponent(group.id)}/relationships/builds?limit=200`,
  );
  const hasPreviousBuild = relationship.length > 0;
  const isTargetGroup = group.attributes?.name === targetName;
  const isInternal = group.attributes?.isInternalGroup === true;

  // Keep the build visible to every existing tester cohort. This includes the
  // named internal group, all internal groups, and external groups that have
  // already received a previous build. Empty groups are left untouched.
  if (isTargetGroup || isInternal || hasPreviousBuild) {
    selected.push({ group, relationship });
  }
}

if (selected.length === 0) {
  throw new Error(`No hay grupos de TestFlight existentes para publicar el build ${targetBuild}`);
}

let assigned = 0;
const failures = [];
for (const { group, relationship } of selected) {
  const alreadyAssigned = relationship.some((item) => item.id === build.id);
  try {
    if (!alreadyAssigned) {
      await request(`/v1/betaGroups/${encodeURIComponent(group.id)}/relationships/builds`, {
        method: "POST",
        body: JSON.stringify({ data: [{ type: "builds", id: build.id }] }),
      });
      assigned += 1;
    }

    const refreshed = await collection(
      `/v1/betaGroups/${encodeURIComponent(group.id)}/relationships/builds?limit=200`,
    );
    if (!refreshed.some((item) => item.id === build.id)) {
      throw new Error("Apple no confirmó la relación del build con el grupo");
    }
    const audience = group.attributes?.isInternalGroup ? "interno" : "externo";
    console.log(
      `Build ${targetBuild}: ${alreadyAssigned ? "ya estaba asignado" : "asignado"} `
      + `a "${group.attributes?.name || group.id}" (${audience}).`,
    );
  } catch (error) {
    failures.push(`${group.attributes?.name || group.id}: ${error.message}`);
    console.error(`No se pudo asociar el build ${targetBuild} a "${group.attributes?.name || group.id}": ${error.message}`);
  }
}

if (failures.length === selected.length) {
  throw new Error(`Apple no aceptó ninguna asociación: ${failures.join(" | ")}`);
}

console.log(
  `Distribución verificada: build ${targetBuild} VALID, ${selected.length} grupo(s) objetivo, `
  + `${assigned} asociación(es) nuevas.`,
);
if (failures.length > 0) {
  console.warn(`Grupos con revisión pendiente: ${failures.join(" | ")}`);
}
