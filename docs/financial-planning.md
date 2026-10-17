# Planificación financiera local

## Periodos y poblaciones

- Consumo y presupuesto: mes natural de la fecha del cargo. Día/Semana/Rango filtran la misma población, con inicio inclusivo y fin exclusivo.
- Pagos de tarjeta: ciclo del estado y fecha límite explícita. Efectivo y deuda: sus cortes reales, visibles junto a las cifras; no se trasladan artificialmente al mes actual.
- Ingresos reales: `FinanceStore.realIncomeMovements` (débito, sin transferencias propias, devoluciones ni pagos de tarjeta). Ingreso habitual: dato confirmado del onboarding, mensual o quincenal × 2; detección recurrente solo propone datos.
- Consumo: `netExpenseMovements` más compras MSI confirmadas completas, menos los cargos explícitamente vinculados a esas compras. El libro conciliado conserva fechas, importes, IDs y evidencia originales.
- Gasto personal ordinario: consumo menos extraordinario/viaje y la parte compartida. Viaje se considera extraordinario por defecto, pero la elección explícita del usuario puede incluirlo como ordinario sin alterar el origen. Cobrar una parte compartida no convierte esa parte en consumo personal.

## MSI

Registrar una compra requiere importe original, fecha original confirmada, mensualidad, plazo y cargos vinculados. La última mensualidad conserva los centavos restantes. Una identidad secundaria solo se utiliza si es única en el libro después de una reconstrucción.

El consumo reconoce el principal completo en la fecha de compra. El presupuesto de efectivo reconoce mensualidades, excluyendo el principal financiado de las categorías de caja. El gráfico de consumo utiliza un límite de consumo que agrega el principal de las compras MSI del mes, no sus cuotas.

La deuda existente usa límite menos disponible cuando ambos son confiables, incluyendo diferidos. Sin esos controles, se conserva deuda declarada; si solo existe saldo al corte y principal MSI pendiente explícito, se agregan ambos. No se estima principal desde porcentajes redondeados.

Registrar un plan no prueba que estén registrados todos los MSI de una cuenta. Para conocer su carga mensual se requiere el total impreso con fecha de pago de ese mes o confirmación explícita de que se itemizaron todas las compras. En caso contrario el disponible queda pendiente. Un cargo aislado no prueba el total mensual.

## Presupuesto

- Variables: mediana por categoría de los últimos tres meses naturales completos disponibles (buscando como máximo doce meses) con cobertura de todas las cuentas. Un mes ausente no entra como cero.
- Fijos: cargos marcados fijos del mes anterior observado (si no hay, del mes seleccionado). Propuestas editables; fijos y variables de la misma categoría tienen límites independientes.
- Disponible variable = ingreso habitual + arrastre − fijos − meta de ahorro − mensualidades MSI.
- Restante = disponible variable − variable ordinario gastado.
- Diario = restante / días restantes, incluyendo hoy; al terminar el mes no se divide entre cero.
- Ahorro con el plan = ingreso − límites fijos/variables − mensualidades MSI; la meta de ahorro no se resta dos veces.
- Cierre: solo mes terminado y completo, con MSI conocido. El sobrante para proponer ahorro descuenta también extraordinarios y partes compartidas efectivamente pagadas; un cobro marcado manualmente no crea dinero bancario. La asignación confirmada es idempotente y no ejecuta una transferencia bancaria.

Comparaciones de consumo usan ventanas equivalentes. Comparaciones parciales se identifican. Porcentajes de categorías comparan los mismos días del mes y el promedio observado; cambios de posición se muestran en pesos.

## Herramientas y recordatorios

El simulador de contado/MSI no modifica el libro y advierte cuando faltan planes de meses futuros. Los recurrentes requieren tres observaciones, cadencia mensual/quincenal e importes dentro del 10% de la mediana; requieren confirmación para convertirse en fijos.

Metas muestran una fecha estimada por ahorro observado (ingreso real menos consumo total) de meses completos, repartido entre metas según sus aportaciones; o por aportación confirmada cuando no hay historial. No suponen rendimientos.

Frescura utiliza la fecha cubierta por el estado, no la fecha de importación. Recordatorios locales requieren permiso del usuario: después del corte, tres días antes del pago y 80% del límite variable antes del día 20. Identificadores de alertas evitan repeticiones mensuales.

Fecha límite y tasa ordinaria anual se leen solo con etiquetas explícitas; el CAT no se usa como tasa. Metadatos de pago manuales pertenecen a un estado específico. La lectura de texto seleccionable de las primeras dos páginas no ejecuta OCR ni reescribe movimientos. Sin saldo revolvente/tasa/mínimo no se muestran intereses estimados.

## Persistencia y límites

`marcelito.planning.v1` mantiene ingresos, planes, etiquetas, cuentas por cobrar, metas y condiciones de pago aparte del libro, con copia previa en `.backup`. No sobrescribe una planificación corrupta o de esquema futuro. Categorías manuales ITAM se conservan en el libro y se presentan como Educación; reglas nuevas y clasificadores usan Educación.

El libro, las categorías y las decisiones de conciliación permanecen como fuente financiera. Los nuevos cálculos son proyecciones; ningún flujo ejecuta pagos, cobros o transferencias reales.

La inspección visual interactiva del simulador requiere la Mac desbloqueada. Las pruebas nativas de cálculo y persistencia se ejecutan independientemente de ese acceso.

## Multiple income sources and statement freshness

- Confirmed income has named sources with monthly or twice-monthly frequency and an optional bank label. The monthly plan sums each source; actual deposits still come only from the canonical ledger.
- An old single total remains an editable `Ingreso habitual` source with a stable identity. The optional source array decodes old v1 data without loss. Every save preserves the prior backup and writes an equivalent monthly aggregate for older builds. Removing all sources means unconfigured income, not a fabricated zero or restoration of the old total.
- Recurring payroll suggestions normalize changing numeric folios and explicit pay-period labels only when the descriptor identifies payroll. Banks remain separate, own transfers remain excluded, and every suggestion requires confirmation. Confirmed suggestion identities prevent adding the same suggestion twice.
- Gastos initially opens the latest month with eligible expense or income evidence (or the current month for an empty book). A deliberate user date selection is preserved during imports. Month selection keeps the current month available and labels partial coverage. No historical value is presented as the current month's actual spend.
- Inicio keeps the current budget separate from a historical summary, identifies the latest loaded date, and links directly to the latest month's movements. When the current month is empty, remaining and pace are withheld; the interface explains the statement/capture update model once instead of repeating error-like empty states.
