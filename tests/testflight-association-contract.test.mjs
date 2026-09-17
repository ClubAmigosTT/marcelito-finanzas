import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { test } from "node:test";

const testsDirectory = dirname(fileURLToPath(import.meta.url));
const scriptPath = resolve(testsDirectory, "..", "scripts", "associate-testflight-build.mjs");
const script = await readFile(scriptPath, "utf8");

test("la distribución no intenta asociar manualmente un grupo interno con acceso automático", () => {
  assert.match(script, /hasAccessToAllBuilds/);
  assert.match(script, /isInternal && hasAccessToAllBuilds/);
  assert.match(script, /no requiere asociación manual/);
  assert.match(script, /Builds cannot be assigned to this internal group/);
});
