import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

test("el evaluador bloquea un manifiesto dorado incompleto", async () => {
  const directory = await mkdtemp(join(tmpdir(), "marcelito-manifest-"));
  try {
    const manifestPath = join(directory, "manifest.json");
    await writeFile(manifestPath, JSON.stringify({
      readerVersion: "web-reader-2026.08.31.8",
      files: [{ file: "estado.pdf", status: "valid" }],
    }), "utf8");

    const result = spawnSync(
      process.execPath,
      [
        "--experimental-strip-types",
        "scripts/evaluate-pdf-corpus.ts",
        "--dir",
        directory,
        "--manifest",
        manifestPath,
        "--require-manifest",
      ],
      { cwd: process.cwd(), encoding: "utf8" },
    );

    assert.notEqual(result.status, 0);
    const report = JSON.parse(result.stdout) as { manifestSchemaFailures?: string[] };
    assert.ok((report.manifestSchemaFailures?.length ?? 0) >= 4);
    assert.match(result.stdout, /sourceFingerprint SHA-256/);
    assert.match(result.stdout, /accountKey emisor/);
    assert.match(result.stdout, /source identificado/);
    assert.match(result.stdout, /kind válido/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
