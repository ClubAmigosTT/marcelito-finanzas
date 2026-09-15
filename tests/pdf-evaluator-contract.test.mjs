/* global URL */

import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

test("el evaluador del corpus destruye el loading task compatible con PDF.js 6", async () => {
  const source = await readFile(new URL("../scripts/evaluate-pdf-corpus.ts", import.meta.url), "utf8");
  assert.match(source, /const loadingTask = pdfjs\.getDocument/);
  assert.match(source, /await loadingTask\.destroy\(\)/);
  assert.doesNotMatch(source, /document\.destroy\(\)/);
});

test("el evaluador normaliza OCR con las dimensiones de página, nunca con una caja de palabra", async () => {
  const source = await readFile(new URL("../scripts/evaluate-pdf-corpus.ts", import.meta.url), "utf8");
  assert.match(source, /const viewport = page\.getViewport\(\{ scale: 1 \}\)/);
  assert.match(source, /pageSizes\.push\(\{ width: viewport\.width, height: viewport\.height \}\)/);
  assert.match(source, /const pixelsPerPoint = dpi \/ 72/);
  assert.match(source, /const rasterWidth = pageSize\.width \* pixelsPerPoint/);
  assert.match(source, /const rasterHeight = pageSize\.height \* pixelsPerPoint/);
  assert.match(source, /rebuildOcrLayout\(result\.data\.tsv, index \+ 1, rasterWidth, rasterHeight\)/);
  assert.doesNotMatch(source, /split\(\/\\r\?\\n\/\)\[1\].*\[8\]/);
});
