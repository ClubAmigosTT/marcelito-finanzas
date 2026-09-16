import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { execPath } from "node:process";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { test } from "node:test";

const testsDirectory = dirname(fileURLToPath(import.meta.url));
const projectRoot = resolve(testsDirectory, "..");

function runVerifier(scriptName) {
  return spawnSync(
    execPath,
    ["--experimental-strip-types", resolve(projectRoot, "scripts", scriptName)],
    { cwd: projectRoot, encoding: "utf8" },
  );
}

test("el verificador nativo de dispositivo ejecuta su CLI y muestra uso sin argumentos", () => {
  const result = runVerifier("verify-native-device-report.ts");

  assert.equal(result.status, 2);
  assert.match(`${result.stdout}\n${result.stderr}`, /Uso:/);
});

test("el verificador nativo de corpus ejecuta su CLI y muestra uso sin argumentos", () => {
  const result = runVerifier("verify-native-corpus-report.ts");

  assert.equal(result.status, 2);
  assert.match(`${result.stdout}\n${result.stderr}`, /Uso:/);
});
