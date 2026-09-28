import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { URL } from "node:url";

const sectionsPath = new URL("../apps/ios/Cauce/Sections.swift", import.meta.url);
const rootTabPath = new URL("../apps/ios/Cauce/RootTabView.swift", import.meta.url);
const modelsPath = new URL("../apps/ios/Cauce/Models.swift", import.meta.url);

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

test("Gastos resume todo el libro real y conserva las categorías manuales entre cortes", async () => {
  const source = await readFile(sectionsPath, "utf8");
  const expensesStart = source.indexOf("struct ExpensesView");
  const expensesEnd = source.indexOf("private struct ExpenseTrendPoint", expensesStart);
  const expenses = source.slice(expensesStart, expensesEnd);

  assert.ok(expensesStart >= 0 && expensesEnd > expensesStart);
  assert.equal((source.match(/store\.netExpenseMovements/g) ?? []).length, 2);
  assert.doesNotMatch(expenses, /currentPeriodExpenseMovements/);
  assert.match(expenses, /Gasto neto conciliado\. Lo que sigue pendiente de clasificar aparece separado arriba/);
  assert.match(expenses, /expenseContribution/);
});

test("el detalle de pendientes en Gastos muestra beneficiario y descripción bancaria", async () => {
  const source = await readFile(sectionsPath, "utf8");
  const detailStart = source.indexOf("struct MovementDetailView");
  const reviewStart = source.indexOf("private struct ExpenseMerchantReviewView");
  const reviewEnd = source.indexOf("private struct ExpenseCategorySelection", reviewStart);
  const detail = source.slice(detailStart, reviewStart);
  const review = source.slice(reviewStart, reviewEnd);

  assert.ok(detailStart >= 0 && reviewStart > detailStart);
  assert.ok(reviewStart >= 0 && reviewEnd > reviewStart);
  assert.match(detail, /currentMovement\.hasTransferOrSpeiDescriptor/);
  assert.match(detail, /No indicado en el estado/);
  assert.match(detail, /Text\(currentMovement\.originalBankDescription\)/);
  assert.match(review, /if movement\.hasTransferOrSpeiDescriptor/);
  assert.match(review, /Destinatario.*no indicado en el estado/);
  assert.match(review, /movement\.summaryDisplayTitle/);
  assert.match(review, /Text\(movement\.originalBankDescription\)/);
});

test("Cuentas conserva un acceso superior para asignar y editar movimientos", async () => {
  const source = await readFile(sectionsPath, "utf8");
  const accountsStart = source.indexOf("struct AccountsView");
  const accountsEnd = source.indexOf("private struct AccountTrendPoint", accountsStart);
  const accounts = source.slice(accountsStart, accountsEnd);

  assert.ok(accountsStart >= 0 && accountsEnd > accountsStart);
  assert.match(accounts, /ToolbarItem\(placement: \.topBarLeading\)/);
  assert.match(accounts, /Label\("Ajustes", systemImage: "slider\.horizontal\.3"\)/);
  assert.match(accounts, /\.sheet\(isPresented: \$isMovementManagementPresented\)/);
  assert.match(accounts, /MovementsView\(\)/);
});

test("calidad distingue conciliación de comercios por enriquecer en Cuentas", async () => {
  const [sections, root] = await Promise.all([
    readFile(sectionsPath, "utf8"),
    readFile(rootTabPath, "utf8"),
  ]);

  assert.match(sections, /store\.ledgerQuality\.reviewMovementCount > 0/);
  assert.match(sections, /LedgerQualityBanner\(store: store\)/);
  assert.match(root, /store\.ledgerQuality\.reviewMovementCount > 0/);
  assert.match(root, /Movimientos bloqueados por fila:/);
  assert.match(root, /Por enriquecer en el libro:/);
});

test("Resumen muestra ritmo de gasto con periodos equivalentes y barras semanales", async () => {
  const [root, models] = await Promise.all([
    readFile(rootTabPath, "utf8"),
    readFile(modelsPath, "utf8"),
  ]);
  const chartStart = root.indexOf("struct SpendingPaceMetrics");
  const chartEnd = root.indexOf("private struct DecisionCallout", chartStart);
  const pace = root.slice(chartStart, chartEnd);

  assert.ok(chartStart >= 0 && chartEnd > chartStart);
  assert.match(root, /SpendingPaceSection\(store: store\)/);
  assert.match(models, /var net: Double \{ income - expense \}/);
  assert.match(pace, /Text\("Ritmo de gasto"\)/);
  assert.match(pace, /BarMark\(/);
  assert.match(pace, /weeklySpend/);
  assert.match(pace, /vs mismo periodo del mes anterior/);
  assert.match(pace, /Promedio diario/);
  assert.match(pace, /Proyección del mes/);
  assert.match(pace, /if let dailyAverage = metrics\.dailyAverage,[\s\S]*let projectedMonth = metrics\.projectedMonth/);
  assert.match(pace, /hasObservedRows \|\| isCovered/);
  assert.match(pace, /Promedio y proyección disponibles cuando el periodo esté completo/);
  assert.match(pace, /store\.spendingCoveredDays\(\)/);
  assert.match(pace, /store\.netExpenseMovements/);
  assert.match(pace, /Aún no hay suficiente información para calcular tu ritmo de gasto/);
});

test("las métricas y categorías exponen Top 10 editable por movimiento", async () => {
  const [sections, root] = await Promise.all([
    readFile(sectionsPath, "utf8"),
    readFile(rootTabPath, "utf8"),
  ]);
  const metricStart = root.indexOf("struct MetricDetailSheet");
  const metricEnd = root.indexOf("struct SpendingPaceWeek", metricStart);
  const metricDetail = root.slice(metricStart, metricEnd);

  assert.ok(metricStart >= 0 && metricEnd > metricStart);
  assert.match(metricDetail, /Text\("Top 10 de montos"\)/);
  assert.match(metricDetail, /prefix\(10\)/);
  assert.match(metricDetail, /MovementDetailView\(movement: movement\)/);
  assert.match(metricDetail, /currentPeriodExpenseMovements \+ store\.currentPeriodIncomeMovements/);
  assert.match(sections, /Array\(movements\.sorted[\s\S]*\.prefix\(10\)\)/);
});
