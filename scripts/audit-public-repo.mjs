#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { extname } from "node:path";

const forbiddenExtensions = new Set([
  ".pdf", ".csv", ".tsv", ".xls", ".xlsx", ".sqlite", ".sqlite3", ".db",
  ".p8", ".p12", ".mobileprovision", ".cer", ".pem", ".key",
]);

// These patterns intentionally target credential formats, not ordinary test
// hashes or public configuration names. Values are read only from tracked
// files, so ignored local corpora never enter the audit.
const secretPatterns = [
  { name: "private-key", pattern: /-----BEGIN (?:RSA |EC |OPENSSH |)?PRIVATE KEY-----/i },
  { name: "github-token", pattern: /\b(?:ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]+/ },
  { name: "openai-style-token", pattern: /\bsk-[A-Za-z0-9_-]{20,}/ },
  { name: "aws-access-key", pattern: /\bAKIA[0-9A-Z]{16}\b/ },
  { name: "slack-token", pattern: /\bxox[baprs]-[A-Za-z0-9-]{20,}/ },
];

function trackedFiles() {
  const output = execFileSync("git", ["ls-files", "-z"], { encoding: "utf8" });
  return output.split("\0").filter(Boolean);
}

const failures = [];
for (const file of trackedFiles()) {
  const extension = extname(file).toLowerCase();
  if (forbiddenExtensions.has(extension)) {
    failures.push(`${file}: extensión prohibida (${extension})`);
    continue;
  }

  let text;
  try {
    text = readFileSync(file, "utf8");
  } catch {
    // Binary assets and files that cannot be decoded as UTF-8 are not scanned
    // for token text; their extension and Git tracking status are still checked.
    continue;
  }

  for (const { name, pattern } of secretPatterns) {
    if (pattern.test(text)) failures.push(`${file}: patrón ${name}`);
  }
}

if (failures.length) {
  console.error("Auditoría pública: FALLÓ");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}

console.log(`Auditoría pública: OK (${trackedFiles().length} archivos rastreados, sin documentos financieros ni formatos de clave conocidos).`);
