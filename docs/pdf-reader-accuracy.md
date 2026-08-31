# Lector de estados: criterio de confianza del 99%

El 99% se mide como **precisión de aceptación automática**: de cada 100 filas o estados que el sistema acepta sin intervención, al menos 99 deben coincidir con el estado original. No es una promesa de 99% de caracteres OCR. Una lectura ambigua se rechaza o queda provisional; nunca se convierte en un KPI.

## Flujo obligatorio

1. Extraer: texto del PDF; si no existe, OCR visual por página.
2. Validar: fecha real, descripción con letras, importe monetario y dirección inequívoca.
3. Normalizar: comercio, fechas, separadores decimales y conceptos.
4. Deduplicar: cuenta + fecha + importe + concepto normalizado + tipo; conservar ocurrencias legítimas dentro del mismo estado.
5. Hacer matching: transferencias propias y pagos de tarjeta en una ventana de ±2 días y mismo importe.
6. Clasificar: compra, ingreso, reembolso, transferencia, pago de tarjeta, interés, comisión o MSI.
7. Conciliar: comparar filas contra totales y conteos declarados por el emisor.
8. Calcular: alimentar todos los módulos exclusivamente desde el libro canónico conciliado.

En tarjetas Amex, cuando están disponibles, la conciliación usa además los
subtotales impresos de transacciones nacionales y moneda extranjera. El total
de nuevos cargos puede incluir cuotas MSI o conversiones y no se trata como
gasto real sin separar esas secciones.

## Reglas de aceptación

- Emisor verificado por evidencia institucional del encabezado; nombres dentro de movimientos son contrapartes.
- Estado bancario válido solo si depósitos, retiros y conteos concilian dentro de ±$0.05.
- Cuando el estado declara cantidades, se conserva la cobertura de filas
  extraídas/esperadas y cualquier diferencia bloquea la aceptación aunque los
  importes coincidan.
- Estado de tarjeta válido solo si cargos y pagos reconocidos concilian con el resumen disponible.
- Cualquier encabezado, referencia, cuenta, RFC, certificado, saldo o total se descarta como movimiento.
- OCR web sin coordenadas queda provisional. Vision con coordenadas conserva
  página, método y la confianza real de cada observación en cada fila.
- El OCR web conserva confianza media y por página, limita la resolución de cada lienzo para evitar crashes por memoria y rechaza archivos de más de 50 MB con un mensaje recuperable.
- Aunque los totales coincidan, el OCR web queda provisional si la confianza
  media baja de 88% o alguna página baja de 78%; una coincidencia accidental no
  puede convertir una lectura visual débil en un KPI.
- Un estado inválido, pendiente o provisional no alimenta Resumen, Gastos, Patrimonio ni gráficas.

## Corpus dorado

Los valores de control sin datos personales están en `tests/fixtures/pdf-goldens.json`. El corpus completo debe conservarse fuera del repositorio y evaluarse por emisor, plantilla y tipo de extracción (texto/OCR). Cada nueva variante de PDF se añade como fixture antes de activar su parser.

Métricas mínimas por versión:

- precisión automática de filas >= 99%;
- 0 encabezados administrativos aceptados como movimientos;
- 100% de estados aceptados conciliados contra importes y conteos;
- 100% de duplicados de solapamiento eliminados sin borrar compras idénticas legítimas;
- 100% de pagos de tarjeta y transferencias propias emparejados cuando existe la contraparte.

Si una métrica falla, el parser queda en revisión y el dashboard se bloquea hasta corregir la causa.

## Corrida reproducible del corpus

La extracción de texto puede auditarse fuera de la interfaz sin copiar los
PDFs a la aplicación:

```bash
npm run pdf:corpus -- --dir "./estados-validados" --manifest ./corpus.json > corpus-result.json
```

El manifiesto opcional fija emisor, tipo, estado de conciliación, número de
filas y totales esperados por archivo. Si falta un archivo declarado o aparece
duplicado en el manifiesto, la corrida falla. El resultado incluye método
(`pdf-text` u `ocr-required`), confianza del emisor, filas sospechosas,
cobertura de filas y motivo de cada bloqueo. Cuando existe manifiesto, también
calcula `automaticAcceptancePrecision`:
aceptaciones correctas divididas entre todas las aceptaciones automáticas
doradas, incluyendo cualquier aceptación falsa. Un archivo no descrito en el
manifiesto se reporta, pero no se cuenta como una aceptación certificada; así
se evita confundir cobertura con precisión.

## Última corrida del corpus visual

En la corrida de OCR visual sobre los tres estados más recientes (30-ago-2026):

- BBVA: se reconstruyeron 11 filas; depósitos $19,500.00 y cargos $22,058.69 concilian, por lo que el estado puede aceptarse.
- Amex: el emisor y el resumen se identifican correctamente (pago para no generar intereses $39,966.15 y crédito disponible $99,632.79). En la lectura de texto del PDF, las 105 filas concilian; la lectura OCR visual forzada sigue quedando bloqueada cuando pierde fechas o filas.
- Santander: el emisor y los totales del resumen se identificaron correctamente, pero el OCR de filas no concilia; el estado queda bloqueado.

Por tanto, esta corrida demuestra el bloqueo seguro de lecturas ambiguas, pero **no certifica todavía una tasa de aceptación automática del 99% para OCR**. La certificación requiere ejecutar el corpus completo de estados en macOS/Xcode con Vision y registrar cada estado aceptado, rechazado y corregido.

La extracción de texto del PDF Amex (sin forzar OCR) ya concilia los tres
cortes disponibles (mayo→27-junio, junio→27-julio y julio→27-agosto). Las
lecturas OCR visuales siguen quedando provisionales cuando pierden fechas o
filas; esas diferencias nunca se convierten en gasto provisional.

Las variantes bancarias con fecha corta (`23/JUL`, sin año) también se
normalizan usando el año del periodo del estado, y la lectura OCR de bancos
prefiere las columnas CARGOS/ABONOS antes que el saldo corrido.
En OCR visual se corrigen únicamente dentro del token de fecha errores
acotados como `AG0`→`AGO`, `O5/AGO` y `OBIAGO`; esos reemplazos nunca se
aplican a descripciones, referencias o importes.

La corrida reproducible sobre los 8 adjuntos disponibles encontró
4 estados aceptables por texto (los 3 Amex y BBVA agosto) y 4 que requieren OCR
(Santander mayo/julio/agosto y BBVA junio). Un estado marcado como
`ocr-required` no se cuenta como aceptación hasta que Vision/Tesseract extraiga
filas y concilie sus totales.

## Contrato de lectura en iOS

El proyecto nativo incluye `apps/ios/Tests/ReaderContractTests.swift`. Estas
pruebas se ejecutan en el workflow de macOS después de generar el proyecto con
XcodeGen:

```bash
cd apps/ios
xcodegen generate --spec project.yml
xcodebuild -project Marcelito.xcodeproj -scheme Marcelito \
  -destination "platform=iOS Simulator,name=iPhone 16" test
```

El contrato cubre tres regresiones de alto riesgo: evidencia institucional que
vence a una contraparte (BBVA no se convierte en Santander), créditos Amex que
no se convierten en compras y encabezados administrativos con números que no
se convierten en movimientos. Si falla, el workflow no puede avanzar a una
compilación publicable.
