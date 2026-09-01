import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

test("el evaluador del corpus destruye el loading task compatible con PDF.js 6", async () => {
  const source = await readFile(new URL("../scripts/evaluate-pdf-corpus.ts", import.meta.url), "utf8");
  assert.match(source, /const loadingTask = pdfjs\.getDocument/);
  assert.match(source, /await loadingTask\.destroy\(\)/);
  assert.doesNotMatch(source, /document\.destroy\(\)/);
});
