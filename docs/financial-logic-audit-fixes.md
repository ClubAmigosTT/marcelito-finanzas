# Correcciones de lógica financiera — 11 de septiembre de 2026

## Alcance

Implementación local para la app **iOS**. No modifica el motor web, no publica en TestFlight y no certifica el libro real del usuario. Los PDFs originales y las capturas permanecen como fuentes; no se cambian los controles oficiales del parser para hacer cuadrar resultados.

## Decisiones contables explícitas

- Gasto neto = cargos elegibles − reembolsos positivos registrados en el rango. Se admite gasto neto negativo. El reembolso conserva su fecha de registro y su categoría editable; no se inventa una compra original.
- Resumen mensual = mes calendario actual para PDF, captura y manual. Los cortes siguen perteneciendo a las cuentas.
- Gastos, calendario y detalle consumen `netExpenseMovements` y su `expenseContribution`; la clasificación IA sigue recibiendo sólo gastos, no reembolsos.
- Transferencias ambiguas permanecen visibles y en métricas hasta evidencia suficiente o decisión manual. Una referencia compartida/titular y cuentas identificadas son requisitos adicionales al importe/fecha. El puntaje no se presenta como probabilidad.
- Las coincidencias entre screenshots se proponen, pero ambos movimientos se conservan hasta pulsar Aplicar. Se puede volver a revisar desde el menú de la captura.
- Captura contra PDF: cuenta identificada igual, importe compatible, similitud mínima de concepto y separación suficiente entre candidatos. Los casos ambiguos siguen provisionales.
- Saldo oficial y pago exigible no se infieren a partir de un concepto distinto: se conserva el signo del efectivo; MSI pendiente y pago sin intereses quedan pendientes cuando no están declarados. Los totales globales requieren valores de todas las cuentas conocidas.
- Las tendencias de saldos conservan el último saldo oficial por cuenta, sobre un universo constante. No se presentan como estimaciones en tiempo real. El detalle incluye los cortes y las ecuaciones disponibles del resumen oficial.
- Sólo fechas explícitamente cubiertas por las cuentas seleccionadas aportan ceros a los promedios. Las capturas por sí solas no prueban cobertura completa. Días futuros no afectan el total de la semana parcial; una semana incompleta no tiene desviación porcentual definitiva.
- Viaje es etiqueta/indicador, no un sinónimo de Uber o Transporte. La edición manual elimina/agrega la etiqueta de manera consistente.
- Las clasificaciones revisadas se guardan y restauran usando cuenta, fecha, importe y evidencia. Si esa identidad es ambigua, no se propaga a otra fila automáticamente.

## Trazabilidad de la auditoría

- H01: gasto neto compartido y devoluciones con signo.
- H02: mes calendario consistente.
- H03/H04: procedencia en duplicados, decisión explícita y conciliación conservadora.
- H05: matching de capturas y cuentas; sin exclusión por importe/fecha únicamente.
- H06: signo de saldos y ausencia de campos/cuentas.
- H07: eje temporal común y cortes visibles.
- H08: viaje explícito.
- H09/H10: cobertura comprobada, muestra real y días comparables.
- H11: obligaciones oficiales y suma por tarjeta.
- H12: nombres precisos, resto del Top 10 y lista completa; saldos con ecuaciones oficiales, no suma ficticia del Top 10.
- H13: deduplicación PDF con identidad de cuenta y dirección; sin identidad se conserva el documento separado.
- H14: estado provisional, conteo y gasto provisional visibles.

## Migración y límites

La migración `financialLogicVersion = 2` se ejecuta al solicitar la actualización del libro, no al iniciar la app. Reevalúa vínculos automáticos y exclusiones de capturas con los nuevos criterios. No reconstruye filas que una versión anterior ya eliminó de un PDF: para recuperarlas se requiere la relectura del original conservado. Las correcciones manuales anteriores que no tenían un registro individual persistido no pueden reconstruirse con certeza si ya se habían perdido.

Si no se identifica cuenta/periodo exacto, se prioriza mostrar pendiente o conservar una coincidencia para revisión frente a borrar o inventar información. Esto puede aumentar la cantidad de pendientes inicialmente.

## Verificación

- Suite Node: 276 pruebas (271 existentes actualizadas + 5 contratos de las correcciones).
- Nueva suite nativa: `FinancialLogicAuditTests.swift`, 14 casos. Se actualizaron los contratos nativos anteriores para las nuevas reglas de cobertura y duplicados.
- ESLint de código: ejecutar excluyendo `output/**`, que contiene los artefactos de la auditoría anterior y no forma parte de la aplicación.
- Compilación TypeScript/Vite: verificación de no regresión web; **no equivale a compilar iOS**.
- Pendiente obligatorio antes de publicar: compilar y ejecutar XCTest en Xcode/macOS, revisar visualmente el iPhone y validar reimportación contra una exportación privada del libro real. No se afirma que las pruebas nativas se hayan ejecutado en Windows.

Comandos reproducibles:

```text
npm test
node node_modules/eslint/bin/eslint.js . --ignore-pattern output/**
npm run build
# En macOS: generar el proyecto con XcodeGen y ejecutar el esquema MarcelitoTests
# mediante el workflow nativo existente, sin saltar pruebas.
```
