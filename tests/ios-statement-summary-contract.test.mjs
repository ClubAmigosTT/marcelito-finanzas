import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const sectionsPath = new URL("../apps/ios/Cauce/Sections.swift", import.meta.url);

test("las cifras detectadas conservan sus etiquetas cuando contienen un valor", async () => {
  const source = await readFile(sectionsPath, "utf8");

  assert.match(source, /LabeledContent\(title\)[\s\S]*formatted\(\.currency\(code: "MXN"\)\)/);
  assert.doesNotMatch(source, /TextField\(title, text: decimalBinding/);
});

test("las cuentas bancarias muestran un resumen propio sin campos de tarjeta", async () => {
  const source = await readFile(sectionsPath, "utf8");

  assert.match(source, /Section\("Resumen del periodo bancario"\)[\s\S]*"Saldo inicial"[\s\S]*"Depósitos \/ abonos"[\s\S]*"Retiros \/ cargos"[\s\S]*"Saldo final"/);
  assert.match(source, /Section\("Estado detectado"\)[\s\S]*"Periodo"[\s\S]*"Movimientos"[\s\S]*"Conciliación"/);
});
