import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { URL } from "node:url";

const sectionsPath = new URL("../apps/ios/Cauce/Sections.swift", import.meta.url);

test("los selectores iOS vinculan cada categoría con el valor que se guarda", async () => {
  const source = await readFile(sectionsPath, "utf8");
  const explicitStringTags = source.match(/Text\(option\)\.tag\(option\)/g) ?? [];

  assert.ok(explicitStringTags.length >= 2, "los selectores de alta y edición deben declarar tags String");
  assert.match(source, /store\.updateCategory\(for: movement, to: \$0\)/);
  assert.match(source, /La categoría se guarda al seleccionarla/);
  assert.match(source, /Text\(movement\.category\)/);
  assert.match(source, /Guardado como/);
});

test("la pantalla ofrece reglas locales y reporta solo cambios realmente aplicados por IA", async () => {
  const source = await readFile(sectionsPath, "utf8");

  assert.match(source, /Aplicar reglas automáticas/);
  assert.ok(source.includes("de \\(eligible) gastos clasificados"));
  assert.match(source, /let updated = store\.applyAIClassifications\(result\.classifications\)/);
  assert.ok(source.includes("Quedan \\(remaining) por revisar"));
  assert.match(source, /stage: "categories\.ai"/);
  assert.equal(source.includes("Se actualizaron \\(classifications.count)"), false);
});
