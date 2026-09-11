import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { URL } from "node:url";

const calendarPath = new URL("../apps/ios/Cauce/SpendingCalendar.swift", import.meta.url);
const rootPath = new URL("../apps/ios/Cauce/RootTabView.swift", import.meta.url);

test("Calendario es la quinta herramienta principal", async () => {
  const root = await readFile(rootPath, "utf8");
  assert.match(root, /case calendar/);
  assert.match(root, /SpendingCalendarView\(\)/);
  assert.match(root, /Label\("Calendario", systemImage: "calendar"\)/);
  assert.equal((root.match(/\.tabItem/g) ?? []).length, 5);
});

test("Semana compara siete días equivalentes e incluye días sin movimientos", async () => {
  const source = await readFile(calendarPath, "utf8");
  assert.match(source, /\(0\.\.<7\)\.compactMap/);
  assert.match(source, /dailyMovements\[day, default: \[\]\]/);
  assert.match(source, /averagesByWeekday\(excludingSelectedWeek: true\)/);
  assert.match(source, /actualTotal \/ Decimal\(comparableDayCount\)/);
  assert.match(source, /Comparación acumulada/);
});

test("Histórico permanece estable al cambiar de semana y muestra tendencia", async () => {
  const source = await readFile(calendarPath, "utf8");
  assert.match(source, /historicalBenchmarkByWeekday/);
  assert.match(source, /averagesByWeekday\(excludingSelectedWeek: false\)/);
  assert.match(source, /HistoricalSpendingHeatmap/);
  assert.match(source, /HistoricalWeeklyTrendChart/);
  assert.match(source, /Días más fuera de lo normal/);
  assert.match(source, /historicalMedian/);
});

test("los filtros parten del gasto real conciliado y afectan todas las vistas", async () => {
  const source = await readFile(calendarPath, "utf8");
  assert.match(source, /store\.netExpenseMovements\.filter/);
  assert.match(source, /coveredDays: store\.spendingCoveredDays/);
  assert.match(source, /var category: String\?/);
  assert.match(source, /var account: String\?/);
  assert.match(source, /var expenseType: SpendingCalendarExpenseType\?/);
  assert.match(source, /var reviewStatus: SpendingCalendarReviewStatus\?/);
  assert.match(source, /var merchantQuery/);
  assert.match(source, /spendingMovement\(\$0, matches: filters\)/);
});

test("cada día abre Top 10 y permite editar el movimiento original", async () => {
  const source = await readFile(calendarPath, "utf8");
  assert.match(source, /SpendingDayDetailView/);
  assert.match(source, /Section\(movements\.count > 10 \? "Top 10 montos"/);
  assert.match(source, /SpendingPeriodDetailView/);
  assert.match(source, /Section\("Top 10 montos"\)/);
  assert.match(source, /MovementDetailView\(movement: movement\)/);
  assert.match(source, /private var filteredAllMovements/);
});

test("Calendario usa una composición compacta y comparaciones ejecutivas", async () => {
  const source = await readFile(calendarPath, "utf8");
  assert.match(source, /private var calendarHeader/);
  assert.match(source, /Resumen semanal/);
  assert.match(source, /Lectura automática/);
  assert.match(source, /Mapa de intensidad/);
  assert.match(source, /84 días de gasto diario/);
  assert.match(source, /LineMark\(/);
  assert.match(source, /dash: \[4, 4\]/);
  assert.match(source, /SpatialTapGesture/);
  assert.match(source, /width: \.fixed\(18\)/);
  assert.match(source, /Día más caro/);
  assert.match(source, /Día más barato/);
});
