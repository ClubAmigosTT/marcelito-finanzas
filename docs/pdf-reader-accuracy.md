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
- Cuando el estado imprime saldo inicial y saldo final, también se valida
  `saldo inicial + depósitos − retiros = saldo final` dentro de ±$0.05.
- Si el OCR repite un saldo en un gráfico o pierde un dígito, se prueban las
  candidatas del resumen contra esa identidad bancaria y solo se conserva la
  que cuadra; por ejemplo, Santander agosto recupera $55,627.93 frente a un
  gráfico OCR que producía $5,627.93.
- Cuando el estado declara cantidades, se conserva la cobertura de filas
  extraídas/esperadas y cualquier diferencia bloquea la aceptación aunque los
  importes coincidan.
- Estado de tarjeta válido solo si cargos y pagos reconocidos concilian con el resumen disponible.
- Cualquier encabezado, referencia, cuenta, RFC, certificado, saldo o total se descarta como movimiento.
- En estados bancarios, una fila solo conserva el primer importe y, si está
  inmediatamente adyacente, un saldo corrido; folios, referencias, CLABE y
  claves de rastreo posteriores no pueden convertirse en importes. Si OCR
  fusiona los separadores decimales, el importe solo se recupera mediante el
  delta del saldo y siempre se vuelve a comparar contra el total declarado.
- Ningún movimiento individual puede superar el total declarado de depósitos
  o retiros de su estado; esa fila bloquea la conciliación aunque el resto de
  las sumas parezca correcto.
- El lector nativo aplica la misma compuerta durante la conciliación iOS y
  deja el número de filas que la activó en el motivo del estado inválido.
- OCR web sin coordenadas queda provisional. Vision con coordenadas conserva
  página, método y la confianza real de cada observación en cada fila.
- Cada fila también conserva un fragmento de origen acotado y, cuando existe
  OCR visual, sus coordenadas normalizadas. La vista de detalle permite
  inspeccionar esta evidencia sin guardar el PDF completo dentro del libro.
- La certificación exige evidencia completa por fila: método, página, confianza
  finita y fragmento de origen no vacío. Si falta uno de estos campos, la fila
  puede permanecer visible para revisión, pero el estado no cuenta como
  aceptación automática ni como evidencia del 99%.
- El evaluador distingue entre `automaticAcceptancePrecision` (precisión de los
  estados que sí fueron aceptados) y `certified` (certificación completa). Esta
  última solo es verdadera cuando el manifiesto está completo, no quedan PDFs
  `ocr-required`, no hay discrepancias y la precisión supera el objetivo; por
  tanto una corrida que solo procesa los PDFs de texto no puede presentarse como
  certificación total.
- El OCR web conserva confianza media y por página, limita la resolución de cada lienzo para evitar crashes por memoria y rechaza archivos de más de 50 MB con un mensaje recuperable.
- iOS aplica los mismos límites de 50 MB y 80 páginas antes de crear
  imágenes OCR; excederlos produce un error recuperable y no deja datos
  parciales en el libro canónico.
- iOS no confía solo en la longitud de una capa de texto oculta: exige señal
  de fecha y de tabla de movimientos antes de omitir Vision. Así un escaneo
  con metadatos administrativos no se interpreta como un PDF estructurado.
- La capa web aplica la misma decisión estructural: solo conserva lectura
  directa cuando encuentra señal de fechas y encabezado de tabla; una capa
  larga de texto administrativo vuelve a activar OCR visual.
- Al abrir una versión nueva, los estados persistidos con otra versión del
  lector (o sin conciliación registrada) pasan automáticamente a revisión y
  dejan de alimentar el libro canónico hasta reimportar su PDF. Así una
  corrección del parser no queda contaminada por filas históricas antiguas.
- En iOS, la reconstrucción canónica también guarda la revisión del lector que
  la produjo; una actualización de reglas invalida esa marca y reintenta la
  reconstrucción desde los PDFs locales antes de mostrar el dashboard.
- Cada página OCR tiene un límite de 45 segundos; si el motor se atasca, la
  importación termina con un error recuperable y no deja un proceso de OCR
  abierto ni datos parciales.
- En páginas con confianza inferior a 88%, el OCR web hace una segunda pasada
  acotada con contraste mejorado y conserva el resultado de mayor confianza;
  si la conciliación o el conteo no cuadran, el estado sigue bloqueado.
- Vision en iOS aplica la misma estrategia por página: solo genera una imagen
  temporal con contraste cuando la primera pasada es débil y conserva el
  resultado que tenga mayor confianza media.
- iOS reutiliza el contexto de imagen y libera cada página OCR dentro de un
  `autoreleasepool`, limitando la memoria temporal en estados de varias páginas.
- Las páginas sin observaciones Vision se registran explícitamente como 0%
  de confianza; nunca desaparecen del promedio ni de la revisión.
- En iOS, una fila importada sin página, confianza o fragmento de origen
  completo reduce la cobertura de evidencia y bloquea el libro; las filas
  creadas manualmente quedan fuera de este denominador.
- Aunque los totales coincidan, el OCR web queda provisional si la confianza
  media baja de 88% o alguna página baja de 78%; una coincidencia accidental no
  puede convertir una lectura visual débil en un KPI.
- Un estado inválido, pendiente o provisional no alimenta Resumen, Gastos, Patrimonio ni gráficas.

## Corpus dorado

Los valores de control sin datos personales están en `tests/fixtures/pdf-goldens.json` e incluyen los cortes Santander de mayo, julio y agosto, BBVA agosto y los tres cortes Amex. El corpus completo debe conservarse fuera del repositorio y evaluarse por emisor, plantilla y tipo de extracción (texto/OCR). Cada nueva variante de PDF se añade como fixture antes de activar su parser.

El manifiesto `tests/fixtures/pdf-corpus-attachments.json` fija los ocho
adjuntos de prueba disponibles mediante SHA-256. No incluye los PDFs: deben
montarse desde la carpeta local de adjuntos al ejecutar la certificación. Los
cuatro escaneos Santander permanecen intencionalmente como `pending` hasta
que Vision confirme emisor, filas y totales. Para esos cuatro cortes el
manifiesto también conserva los controles de saldo anterior, saldo final,
depósitos y retiros; el evaluador los expone como `statementControls` para
comparar una corrida OCR aunque todavía no se acepten sus filas.

Métricas mínimas por versión:

- precisión automática de filas >= 99%;
- 0 encabezados administrativos aceptados como movimientos;
- 100% de estados aceptados conciliados contra importes y conteos;
- 100% de duplicados de solapamiento eliminados sin borrar compras idénticas legítimas;
- 100% de pagos de tarjeta y transferencias propias emparejados cuando existe la contraparte.
- 100% de cobertura de evidencia en las filas aceptadas (página, método,
  confianza y fragmento de origen).

Si una métrica falla, el parser queda en revisión y el dashboard se bloquea hasta corregir la causa.

## Corrida reproducible del corpus

La extracción de texto puede auditarse fuera de la interfaz sin copiar los
PDFs a la aplicación:

```bash
npm run pdf:corpus -- --dir "./estados-validados" --manifest ./corpus.json > corpus-result.json
```

Para una corrida de certificación, el comando debe exigir expectativas
doradas y umbral explícito; falla si falta el manifiesto, hay PDFs sin
describir o la precisión automática queda por debajo de 99%:

```bash
npm run pdf:corpus -- --dir "./estados-validados" --manifest ./corpus.json \
  --require-manifest --target-precision 0.99 > corpus-certification.json
```

El manifiesto opcional fija la versión exacta del lector (`readerVersion`),
huella SHA-256, emisor, tipo, estado de conciliación, número de filas y
totales esperados por archivo. Si la versión del manifiesto no coincide con la
del lector, la certificación falla y obliga a volver a medir el corpus. Si falta un archivo declarado o aparece
duplicado en el manifiesto, la corrida falla. El resultado incluye método
(`pdf-text` u `ocr-required`), confianza del emisor, filas sospechosas,
filas sin evidencia, cobertura de evidencia, cobertura de filas y motivo de
cada bloqueo. También conserva las señales institucionales usadas para
identificar el emisor y las menciones de contrapartes que fueron ignoradas.
Cada archivo incluye además su huella SHA-256 para reproducir la corrida aun
si cambia el nombre del PDF.
Cuando existe manifiesto, también
calcula `automaticAcceptancePrecision`:
aceptaciones correctas divididas entre todas las aceptaciones automáticas
doradas, incluyendo cualquier aceptación falsa. Un archivo no descrito en el
manifiesto se reporta, pero no se cuenta como una aceptación certificada; así
se evita confundir cobertura con precisión.
Si un archivo está dañado, protegido o no puede abrirse, aparece como
`parse-error` y la corrida continúa con los demás archivos; la certificación
falla explícitamente y no puede ocultar ese archivo por una interrupción del
script.

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
La implementación nativa mantiene las mismas invariantes contables que la
capa web: el matching de transferencias y pagos compara la magnitud del
importe (la salida y la entrada tienen signos opuestos), exige una señal
explícita de pago en la tarjeta y usa un ordinal por estado para no borrar una
segunda compra idéntica legítima durante un solapamiento.
Para transferencias entre bancos, el importe/fecha y la cuenta distinta solo
generan un candidato: la aceptación exige semántica de transferencia y una
mención explícita de la cuenta contraparte o del mismo titular. Si esa señal
falta, ambas filas quedan en revisión (y un importe relevante vuelve
provisionales los KPI) en vez de ocultar un ingreso externo coincidente.
También aplica la compuerta OCR por confianza media (88%) y página (78%);
una página débil mantiene el estado en revisión aunque las sumas coincidan.
En OCR visual se corrigen únicamente dentro del token de fecha errores
acotados como `AG0`→`AGO`, `O5/AGO` y `OBIAGO`; esos reemplazos nunca se
aplican a descripciones, referencias o importes.

La corrida reproducible sobre los 8 adjuntos disponibles encontró
4 estados aceptables por texto (los 3 Amex y BBVA agosto) y 4 que requieren OCR
(Santander mayo/julio/agosto y BBVA junio). Un estado marcado como
`ocr-required` no se cuenta como aceptación hasta que Vision/Tesseract extraiga
filas y concilie sus totales.

Como diagnóstico adicional, una corrida local de Tesseract sobre Santander
agosto a 130 dpi produjo confianzas por página de 79%–93% (media aproximada
85.4%). Ese resultado queda por debajo del umbral automático de 88%, por lo que
el bloqueo es intencional: la siguiente calibración debe ejecutarse con Vision
en macOS y contrastarse contra los totales del estado, no relajarse por una
coincidencia parcial.

En la calibración más reciente también se comprobó que una fila OCR sin saldo
corrido ya no arrastra folios o referencias posteriores como importes. Cuando
los separadores se pierden, el parser solo intenta recuperarlos con el delta
del saldo; si las filas no concilian, el documento permanece bloqueado.
Los controles de resumen de Santander aplican la misma recuperación acotada
para importes OCR fusionados de 7–8 dígitos (por ejemplo `6416111` →
`64,161.11`) y vuelven a comprobar la identidad de saldo antes de aceptar.

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
