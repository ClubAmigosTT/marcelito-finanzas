import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { execPath } from "node:process";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { tmpdir } from "node:os";
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

test("el constructor del informe sanitizado ejecuta su CLI y muestra uso sin argumentos", () => {
  const result = runVerifier("build-native-device-report.ts");

  assert.equal(result.status, 2);
  assert.match(`${result.stdout}\n${result.stderr}`, /Uso:/);
});

test("el verificador del corpus rechaza manifiestos vencidos, desconocidos o vacíos", async () => {
  const directory = await mkdtemp(resolve(tmpdir(), "marcelito-native-manifest-"));
  try {
    const manifestPath = resolve(directory, "manifest.json");
    const logPath = resolve(directory, "native.log");
    await writeFile(manifestPath, JSON.stringify({
      readerVersion: "ios-reader-old",
      files: [{
        file: "estado.pdf",
        sourceFingerprint: "a".repeat(64),
        source: "BBVA",
        accountKey: "bbva:4922",
        kind: "unknown",
        status: "valid",
        rows: 0,
      }],
    }));
    await writeFile(logPath, "NATIVE_CORPUS_SUMMARY {\"readerVersion\":\"ios-reader-test\",\"files\":\"0\",\"accepted\":\"0\",\"blocked\":\"0\",\"expectedValid\":\"0\",\"expectedPending\":\"0\",\"goldenAutoAccepted\":\"0\",\"goldenFalseAccepted\":\"0\",\"automaticAcceptancePrecision\":\"1\",\"unresolvedOCR\":\"0\",\"goldenRowAuditsPassed\":\"0\",\"goldenRowAuditsExpected\":\"0\",\"goldenRowAuditMismatches\":\"0\",\"independentProofFiles\":\"0\",\"independentProofExpected\":\"0\",\"rowGoldensComplete\":\"false\",\"certified\":\"false\"}\n");
    const result = spawnSync(
      execPath,
      ["--experimental-strip-types", resolve(projectRoot, "scripts", "verify-native-corpus-report.ts"),
        "--log", logPath, "--manifest", manifestPath, "--reader-version", "ios-reader-test", "--require-certified"],
      { cwd: projectRoot, encoding: "utf8" },
    );
    assert.equal(result.status, 1);
    const output = `${result.stdout}\n${result.stderr}`;
    assert.match(output, /readerVersion del manifiesto/);
    assert.match(output, /golden válido no puede conservar kind=unknown/);
    assert.match(output, /golden válido necesita al menos una fila/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
