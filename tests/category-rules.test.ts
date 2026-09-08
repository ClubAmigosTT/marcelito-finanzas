import assert from "node:assert/strict";
import test from "node:test";
import { deterministicExpenseClassification, isClassifiableExpense } from "../src/categoryRules.ts";

test("la taxonomía separa restaurantes, tiendita y supermercado", () => {
  assert.equal(deterministicExpenseClassification("Taquería Orinoco")?.category, "Restaurantes y bares");
  assert.equal(deterministicExpenseClassification("OXXO 1234")?.category, "Tiendita");
  assert.equal(deterministicExpenseClassification("Walmart Supercenter")?.category, "Despensa / supermercado");
});

test("viaje conserva categoría natural y etiqueta secundaria", () => {
  const hotel = deterministicExpenseClassification("AIRBNB NEW YORK");
  assert.equal(hotel?.category, "Viajes");
  assert.ok(hotel?.tags.includes("viaje"));
  assert.ok(hotel?.tags.includes("extraordinario"));
});

test("proyecto tiene prioridad sobre el comercio", () => {
  const project = deterministicExpenseClassification("Club Amigos - compra de materiales en OXXO");
  assert.equal(project?.category, "Club Amigos / Proyectos");
  assert.deepEqual(project?.tags.filter((tag) => tag === "proyecto"), ["proyecto"]);
});

test("pagos, transferencias, ingresos, reembolsos y MSI quedan fuera de categorías de gasto", () => {
  for (const [flow, kind] of [
    ["debt", "cardPayment"],
    ["transfer", "bankTransfer"],
    ["income", "income"],
    ["income", "refund"],
    ["expense", "msi"],
  ] as const) {
    assert.equal(deterministicExpenseClassification("AMEX PAGO OXXO", flow, kind), undefined);
    assert.equal(isClassifiableExpense(flow, kind), false);
  }
});
