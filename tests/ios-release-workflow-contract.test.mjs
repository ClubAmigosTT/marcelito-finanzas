import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { test } from "node:test";

const testsDirectory = dirname(fileURLToPath(import.meta.url));
const workflowPath = resolve(testsDirectory, "..", ".github", "workflows", "ios-testflight.yml");
const workflow = await readFile(workflowPath, "utf8");

test("el release tag bootstrap nunca publica sin la auditoría estricta", () => {
  assert.match(workflow, /endsWith\(github\.ref_name, '-bootstrap'\)/);
  assert.match(workflow, /version="\$\{version%-bootstrap\}"/);

  const bootstrapGate = workflow.indexOf("if [[ \"${CORPUS_CERTIFIER_BOOTSTRAP:-false}\" == \"true\" ]]");
  const certificationGate = workflow.indexOf("--require-row-audit");
  assert.ok(bootstrapGate >= 0, "falta la compuerta explícita de bootstrap");
  assert.ok(certificationGate > bootstrapGate, "la auditoría estricta debe seguir después del bootstrap");
  assert.match(workflow, /--expected-files 22/);
  assert.match(workflow, /--require-independent-proof/);
  assert.match(workflow, /Publicación bloqueada/);
  assert.doesNotMatch(workflow, /MARCELITO_NATIVE_CORPUS_CERTIFIED/);
});

test("TestFlight rechaza una versión de marketing menor a la ya publicada", () => {
  assert.match(workflow, /scripts\/validate-testflight-marketing-version\.mjs/);
  assert.match(workflow, /ASC_ISSUER_ID: \$\{\{ secrets\.APPSTORE_ISSUER_ID \}\}/);
  assert.match(workflow, /ASC_KEY_ID: \$\{\{ secrets\.APPSTORE_API_KEY_ID \}\}/);
  assert.match(workflow, /ASC_PRIVATE_KEY: \$\{\{ secrets\.APPSTORE_API_PRIVATE_KEY \}\}/);
  assert.match(workflow, /ASC_BUNDLE_ID: mx\.marcelito\.personal/);
  const versionGuard = workflow.indexOf("Evitar una versión de marketing obsoleta");
  const xcodegen = workflow.indexOf("Instalar XcodeGen");
  assert.ok(versionGuard >= 0, "falta la compuerta de versión de marketing");
  assert.ok(versionGuard < xcodegen, "la versión debe validarse antes de compilar y subir");
});
