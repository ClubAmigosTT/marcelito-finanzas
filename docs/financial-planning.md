# Planificación financiera local

## Periodos y poblaciones

- Consumo y presupuesto: mes natural de la fecha del cargo. Día/Semana/Rango filtran la misma población, con inicio inclusivo y fin exclusivo.
- Pagos de tarjeta: ciclo del estado y fecha límite explícita. Efectivo y deuda: sus cortes reales, visibles junto a las cifras; no se trasladan artificialmente al mes actual.
- Ingresos reales: `FinanceStore.realIncomeMovements` (débito, sin transferencias propias, devoluciones ni pagos de tarjeta). Ingreso habitual: varias fuentes confirmadas, mensuales, quincenales, semanales o anuales, convertidas a un promedio mensual con centavos; la detección recurrente solo propone datos.
- Consumo: `netExpenseMovements` más compras MSI confirmadas completas, menos los cargos explícitamente vinculados a esas compras. El libro conciliado conserva fechas, importes, IDs y evidencia originales.
- Gasto personal ordinario: consumo menos extraordinario/viaje y la parte compartida. Viaje se considera extraordinario por defecto, pero la elección explícita del usuario puede incluirlo como ordinario sin alterar el origen. Cobrar una parte compartida no convierte esa parte en consumo personal.

## MSI

Registrar una compra requiere importe original, fecha original confirmada, mensualidad, plazo y cargos vinculados. La última mensualidad conserva los centavos restantes. Una identidad secundaria solo se utiliza si es única en el libro después de una reconstrucción.

El consumo reconoce el principal completo en la fecha de compra. El presupuesto de efectivo reconoce mensualidades, excluyendo el principal financiado de las categorías de caja. El gráfico de consumo utiliza un límite de consumo que agrega el principal de las compras MSI del mes, no sus cuotas.

La deuda existente usa límite menos disponible cuando ambos son confiables, incluyendo diferidos. Sin esos controles, se conserva deuda declarada; si solo existe saldo al corte y principal MSI pendiente explícito, se agregan ambos. No se estima principal desde porcentajes redondeados.

Registrar un plan no prueba que estén registrados todos los MSI de una cuenta. Para conocer su carga mensual se requiere el total impreso con fecha de pago de ese mes o confirmación explícita de que se itemizaron todas las compras. En caso contrario el disponible queda pendiente. Un cargo aislado no prueba el total mensual.

## Presupuesto

- Variables: mediana por categoría de los últimos tres meses naturales completos disponibles (buscando como máximo doce meses) con cobertura de todas las cuentas. Un mes ausente no entra como cero.
- Fijos: gastos configurados y confirmados con importe, frecuencia, categoría y vigencia. Para otros comercios, se conservan los cargos marcados fijos del mes anterior observado (si no hay, del mes seleccionado). Los límites mensuales que el usuario haya guardado por categoría tienen prioridad; fijos y variables mantienen límites independientes.
- Disponible variable = ingreso habitual + arrastre − fijos previstos − exceso observado en fijos por categoría − meta de ahorro − mensualidades MSI. Un cargo fijo ya cubierto por la reserva no se vuelve a restar; su exceso sí reduce el disponible.
- Restante = disponible variable − variable ordinario gastado.
- Diario = restante / días restantes, incluyendo hoy; al terminar el mes no se divide entre cero.
- Ahorro con el plan = ingreso − límites fijos/variables − mensualidades MSI; la meta de ahorro no se resta dos veces.
- Cierre: solo mes terminado y completo, con MSI conocido. El sobrante para proponer ahorro descuenta también extraordinarios y partes compartidas efectivamente pagadas; un cobro marcado manualmente no crea dinero bancario. La asignación confirmada es idempotente y no ejecuta una transferencia bancaria.

Comparaciones de consumo usan ventanas equivalentes. Comparaciones parciales se identifican. Porcentajes de categorías comparan los mismos días del mes y el promedio observado; cambios de posición se muestran en pesos.

## Herramientas y recordatorios

El simulador de contado/MSI no modifica el libro y advierte cuando faltan planes de meses futuros. La recurrencia requiere tres pagos mensuales o cuatro semanales/quincenales, en al menos dos meses, con intervalos compatibles. Al menos 75% debe tener importes dentro del 10% de la mediana; un bono aislado puede quedar fuera de la evidencia del patrón. Se admite un ciclo sin observación si al menos la mitad de los intervalos es directa; no se crean pagos faltantes. Las compras frecuentes sin periodicidad no se sugieren como fijas. Toda sugerencia requiere confirmación.

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

## Period navigation and annual views

- Gastos supports day, Monday-based week, natural month, natural year, and inclusive custom ranges (internally end-exclusive). Arrows and horizontal swipes shift by the selected unit; custom ranges shift by their complete calendar-day length.
- Month/year stepping starts at the first day of the period. January 31, leap days, December/January, and daylight-saving changes cannot skip a month or alter a selected week's length. Vertical or small diagonal drags do not trigger period changes.
- Date selection uses a dedicated sheet, including an explicit year selector and Spanish month list. The year view filters actual charge dates from January 1 through December 31 and shows recorded monthly bars and month drilldowns. Missing months display missing-data labels, never assumed zeroes.
- Inicio's recorded activity can browse months or years independently of the explicitly current-month budget. Ver movimientos opens exactly that period in Gastos.
- Presupuesto supports month navigation plus an annual overview with each month's recorded spending and explicitly saved plan. The annual overview does not multiply the current income into purported historical income or invent monthly plans. Swipe navigation is restricted to the header so sliders remain editable.
- Patrimonio's evolution supports movable 6/12-month windows or a selected calendar year. Current balance metrics retain the latest cutoff dates and current historical comparison. Separate chart series prevent drawing a line across missing monthly positions.

## Configuración de ingresos y gastos fijos

- Presupuesto conserva tres pestañas internas siempre accesibles: Plan, Ingresos y Gastos fijos. Las cinco pestañas principales se mantienen visibles. Ingresos reutiliza las fuentes guardadas y permite agregar, editar y eliminar varias fuentes; los depósitos reales siguen separados.
- Ingresos permite elegir un depósito elegible por banco y búsqueda, aunque no haya suficientes meses para una sugerencia. El formulario conserva el importe real y exige confirmar frecuencia y nombre; guardar no crea depósitos. Las sugerencias de nómina revisan también la descripción bancaria original, sin confundir el producto bancario Super Nómina con un pago salarial. Cada propuesta abre sus depósitos de evidencia.
- Cada gasto fijo guarda nombre, importe de la parte personal, frecuencia, categoría, comercio/cuenta opcional, primer mes y último mes opcional. La reserva mensual equivale a importe × 12/12, × 24/12, × 52/12 o × 1/12 para mensual, quincenal, semanal o anual, con redondeo a centavos. Las frecuencias semanal y anual son reservas promedio, no un calendario exacto de pagos.
- La asociación al comercio se limita al banco y a la identidad de comercio o destinatario. Una descripción SPEI genérica sin destinatario no se propone como comercio vinculable. Los cargos MSI, pagos de tarjetas y traspasos propios quedan fuera de la detección.
- Las propuestas usan solo cargos ordinarios personales del último año. Exigen el patrón de fechas e importes descrito arriba y cercanía a los últimos datos de esa cuenta. Muestran solo los cargos que respaldan el patrón, con su importe y fecha. No convierten el gasto mensual de un comercio irregular en una supuesta cuota fija. Los abonos de préstamo derivados tampoco se ofrecen para reservarlos de nuevo.
- Se puede descartar una propuesta con «No es un gasto fijo» y restaurar las descartadas; esta preferencia no cambia categorías ni presupuestos. El selector manual de comercio permite buscar y filtrar por banco. Los gastos fijos ya confirmados se mantienen aunque no cumplan los criterios nuevos de sugerencia.
- Nada se guarda automáticamente. Al confirmar, el gasto entra a los meses de su vigencia y sus cargos se separan de los variables. Las excepciones manuales por movimiento y las categorías del libro se conservan. La propuesta de variables excluye el comercio confirmado para el mes que se está planificando, sin cambiar clasificaciones de meses anteriores.
- La reserva confirmada sustituye la inferencia del mismo comercio y evita sumarlo dos veces. Los límites mensuales manuales por categoría prevalecen. Editar o quitar un gasto no borra movimientos, etiquetas, fuentes de ingreso ni presupuestos; para terminarlo conservando su vigencia anterior, se define el último mes.
- `fixedExpenses` es opcional en el esquema v1: los datos anteriores siguen cargando. Las escrituras conservan la copia previa; se rechazan duplicados de comercio, importes no positivos, categorías de ingreso/transferencia y vigencias invertidas. No se sobrescriben datos corruptos o de esquema futuro.
- `dismissedRecurringExpenseKeys` también es opcional y conserva compatibilidad con los registros anteriores. `bash scripts/test-ios-recurring.sh` ejecuta las pruebas del detector Foundation sin requerir un simulador.
- La detección y las identidades de comercio se reutilizan mientras el libro y las etiquetas no cambien; editar sliders no vuelve a recorrer el libro ni ejecuta una escritura por cargo.
