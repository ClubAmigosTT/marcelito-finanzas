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

La selección de saldo usa una identidad de cuenta enmascarada cuando el
encabezado la ofrece (`emisor:últimos4`). Solo se conservan los últimos cuatro
dígitos; el número completo nunca entra al modelo ni al diagnóstico. Si falta o
es ambiguo, se usa el fallback emisor+tipo y no se adivina una cuenta.

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
  que cuadra; los ejemplos públicos usan valores sintéticos.
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
- En Santander, cuando Vision entrega un saldo corrido por fila, el lector
  compara el importe con la variación entre saldos consecutivos. Solo repara
  un desvío menor o igual a $2, o una magnitud claramente mal escalada que
  siga dentro del rango del saldo; si no existe saldo anterior/final confiable
  conserva el importe visual y deja que la conciliación bloquee el estado.
- La lectura Vision de Santander calibra `DEPÓSITO`, `RETIRO` y `SALDO` con la
  geometría de los encabezados cuando están presentes. Si el recorte no trae
  encabezado, usa los límites de la plantilla conocida; en ambos casos el
  saldo corrido queda fuera de la columna de movimientos. Los tres anclajes
  deben pertenecer a la misma página y línea visual y acompañarse de `FECHA` y
  `DESCRIPCIÓN`; nunca se mezclan etiquetas de un resumen o de otra página para
  fabricar una calibración.
- El resultado de esa calibración se persiste como `ocrColumnsCalibrated` y se
  incluye en el reporte de importación; `false` siempre mantiene el estado en
  revisión aunque los totales coincidan.
- La comparación de esos tres encabezados tolera espacios internos insertados
  por Vision, pero no corrige palabras de las filas ni del resto del PDF.
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
- La frontera de cálculo aplica la misma regla fuera de la interfaz: si una
  fila vinculada a un estado carece de esa trazabilidad, el estado completo se
  excluye del libro canónico y ningún KPI puede agregarlo, incluso si un
  llamador entrega un pipeline preconstruido. Las filas manuales sin estado
  asociado no entran en ese denominador.
- El evaluador distingue entre `automaticAcceptancePrecision` (precisión de los
  estados que sí fueron aceptados) y `certified` (certificación completa). Esta
  última solo es verdadera cuando el manifiesto está completo, no quedan PDFs
  `ocr-required`, no hay discrepancias y la precisión supera el objetivo; por
  tanto una corrida que solo procesa los PDFs de texto no puede presentarse como
  certificación total. También reporta `goldenCoverage`: la proporción de
  goldens marcados como válidos que fueron aceptados automáticamente. La
  certificación exige cobertura 1.0 además de precisión ≥99%, evitando que un
  lector alcance el objetivo simplemente bloqueando documentos válidos.
- El OCR web conserva confianza media y por página, limita la resolución de cada lienzo para evitar crashes por memoria y rechaza archivos de más de 50 MB con un mensaje recuperable. También guarda tamaño y número de páginas del PDF junto a su huella para reproducir la ingesta.
- iOS aplica los mismos límites de 50 MB y 80 páginas antes de crear
  imágenes OCR; excederlos produce un error recuperable y no deja datos
  parciales en el libro canónico.
- iOS no confía solo en la longitud de una capa de texto oculta: exige señal
  de fecha, encabezado de tabla y al menos una fila plausible (fecha + importe)
  antes de omitir Vision. Así un escaneo con metadatos administrativos no se
  interpreta como un PDF estructurado.
- La capa web aplica la misma decisión estructural: solo conserva lectura
  directa cuando encuentra fechas, encabezado de tabla y una fila plausible;
  una capa larga de texto administrativo o un encabezado sin filas vuelve a
  activar OCR visual.
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
- Esa compuerta se vuelve a evaluar al abrir el libro: un registro persistido
  como `ready` con OCR débil se devuelve a revisión aunque conserve una bandera
  antigua `requiresReview=false`. La elegibilidad no depende de un único campo
  editable.
- Un estado inválido, pendiente o provisional no alimenta Resumen, Gastos, Patrimonio ni gráficas.
- Un estado `ready` solo alimenta el libro canónico si `sourceDetection.status`
  es `verified`, con confianza institucional de al menos 99%, evidencia no
  vacía y el mismo emisor que se guardará en el estado, o si el usuario confirmó
  explícitamente un emisor conocido.
- El predicado de elegibilidad de iOS aplica las mismas condiciones y además
  rechaza `Desconocido` y tipos `unknown`; así una actualización nativa no puede
  reintroducir una ruta de fallback que la capa web ya bloqueó.
- Web e iOS agrupan saldos por esa misma identidad enmascarada, por lo que dos
  cuentas Santander (o dos tarjetas del mismo emisor) conservan su saldo más
  reciente de forma independiente.
  Estados antiguos o inferidos por nombre de archivo se migran a `pending`, se
  muestran en auditoría y sus filas quedan en cuarentena hasta confirmar el PDF.
- Si el banco mostrado es conocido pero la evidencia automática es provisional,
  el usuario puede confirmarlo de forma explícita. Esa liberación se guarda
  como `issuerConfirmedByUser` y no se cuenta como aceptación automática del
  corpus del 99%.
- Reimportar los mismos bytes no borra esa confirmación humana: se conserva
  únicamente cuando coinciden la huella SHA-256, el emisor y el tipo de estado;
  si cualquiera cambia, el documento vuelve a revisión.

## Corpus dorado

Los valores de control sintéticos están en `tests/fixtures/pdf-goldens.json` e incluyen varias plantillas bancarias y de tarjeta. El corpus real debe conservarse fuera del repositorio y evaluarse por emisor, plantilla y tipo de extracción (texto/OCR). Cada nueva variante de PDF se añade como fixture sintético antes de activar su parser.

El manifiesto `tests/fixtures/pdf-corpus-attachments.json` fija los adjuntos
de prueba disponibles mediante SHA-256 (actualmente son ocho; cualquier
estado adicional debe añadirse al manifiesto antes de certificar). No incluye los PDFs: deben
montarse desde la carpeta local de adjuntos al ejecutar la certificación. Los
campos `accountKey` del manifiesto solo contienen `emisor:últimos4` y permiten
detectar que un reimport no mezcle dos cuentas del mismo banco; nunca se
persisten números completos.
Algunas plantillas escaneadas permanecen intencionalmente como `pending` hasta
que Vision confirme emisor, filas y totales. El manifiesto conserva controles
de saldo, depósitos, retiros y deuda únicamente con valores sintéticos.

Cada corrida puede conservarse como evidencia auditable pasando `--out` al
evaluador. El archivo incluye la versión exacta del lector, huellas SHA-256,
estado por PDF, filas con evidencia faltante, precisión de aceptación y la
bandera `certified`:

```bash
npm run pdf:corpus -- --dir <carpeta> \
  --manifest tests/fixtures/pdf-corpus-attachments.json \
  --require-manifest --target-precision 0.99 --out artifacts/pdf-corpus.json
```

Para diagnosticar escaneos sin capa de texto se puede ejecutar el mismo
evaluador con OCR local. `pdftoppm` renderiza cada página y Tesseract.js usa el
mismo parser y las mismas reglas de conciliación que la aplicación; el reporte
conserva confianza media y confianza de cada página, pero nunca convierte esa
corrida en certificación nativa:

```bash
npm run pdf:corpus -- --ocr --ocr-dpi 220 \
  --dir <carpeta> --manifest tests/fixtures/pdf-corpus-attachments.json \
  --out artifacts/pdf-corpus-ocr.json
```

Para evitar olvidar el manifiesto, la resolución o el destino del informe,
el repositorio incluye un atajo equivalente:

```bash
npm run pdf:corpus:diagnose -- --dir <carpeta>
```

Guarda el resultado en `artifacts/pdf-corpus-ocr.json` (una carpeta local
ignorada por Git). El informe sigue marcando `certified=false` hasta ejecutar
Vision nativa; este comando solo automatiza el diagnóstico reproducible de
texto y OCR local.

Se puede indicar una ruta explícita con `--pdftoppm <ruta>` o con la variable
`MARCELITO_PDFTOPPM`. Los PNG y el modelo OCR se eliminan al terminar; el JSON
no guarda el texto completo del estado. En modo `--ocr`, un estado marcado como
`pending` en el manifiesto solo se considera promovido si produce filas,
concilia sus controles y supera la compuerta de confianza. La bandera
`certified` sigue siendo `false` hasta ejecutar Vision y el corpus real en
macOS/Xcode.

Las promociones logradas por Tesseract local se reportan como
`diagnosticOcrAccepted`, pero se excluyen de `automaticAcceptancePrecision`:
la métrica del 99% solo cuenta aceptaciones automáticas del lector de texto o
de Vision nativa. Así una corrida diagnóstica no convierte OCR local en una
certificación ni lo cuenta erróneamente como falso positivo.

El reporte diferencia `nativeVisionRequired` de `nativeOCRPending`: el primero
también cuenta los PDFs procesados por OCR local, porque ese diagnóstico no
puede sustituir Vision. Cada archivo incluye `qualityGate.statusBefore`,
`qualityGate.statusAfter` y `qualityGate.applied`, y el nivel superior expone
`certificationBlockers` para que una corrida parcial no parezca certificada.
El verificador nativo además revisa el `NATIVE_CORPUS_REPORT` por archivo y
rechaza reportes truncados, duplicados o con una identidad de cuenta que no
coincida con el `accountKey` dorado. También compara `status` y, cuando el
golden ya fue promovido a válido, el número exacto de `rows`; un cambio de
promoción o de conteo exige actualizar el golden de forma explícita.

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
del lector, la certificación falla y obliga a volver a medir el corpus. Cuando
se usa `--require-manifest`, cada entrada también debe tener hash, cuenta
enmascarada, emisor, tipo y estado; un golden válido debe declarar sus filas.
Si falta un archivo declarado o aparece
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

## Ejemplo reproducible del corpus público

La corrida del manifiesto sintético procesa varias plantillas de banco y
tarjeta. Los estados que no tienen una capa de texto o cuyas filas no
concilian quedan como `ocr-required`/`pending`; solo los estados con evidencia
completa y sumas verificadas pueden alimentar el libro canónico. Esta sección
no contiene resultados ni identificadores de estados financieros reales.

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
aplican a descripciones, referencias o importes. En filas Santander, un
importe con un `1` inicial espurio (por ejemplo `160.00` cuando el saldo
confirma `60.00`) solo se repara si los centavos restantes coinciden
exactamente con el delta del saldo corrido; una deriva genérica no se corrige.

La corrida reproducible sobre los 8 adjuntos disponibles encontró
4 estados aceptables por texto (los 3 Amex y BBVA agosto) y 4 que requieren OCR
(Santander mayo/junio/julio/agosto). Un estado marcado como
`ocr-required` no se cuenta como aceptación hasta que Vision/Tesseract extraiga
filas y concilie sus totales.

Como diagnóstico adicional, una corrida local de Tesseract puede producir
confianzas por página inferiores al umbral automático de 88%. En ese caso el
bloqueo es intencional: la calibración debe ejecutarse con Vision en macOS y
contrastarse contra los totales declarados, no relajarse por una coincidencia
parcial.

En la calibración más reciente también se comprobó que una fila OCR sin saldo
corrido ya no arrastra folios o referencias posteriores como importes. Cuando
los separadores se pierden, el parser solo intenta recuperarlos con el delta
del saldo; si las filas no concilian, el documento permanece bloqueado.
Los controles de resumen bancario aplican la misma recuperación acotada para
importes OCR fusionados de 7–8 dígitos y vuelven a comprobar la identidad de
saldo antes de aceptar.

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

El contrato nativo también incluye un fixture de observaciones Vision con
coordenadas normalizadas. Verifica que el lector tome el retiro/depósito de
las columnas de movimiento y no el saldo corrido; así una modificación de los
umbrales de columnas falla en CI antes de tocar el corpus de estados reales.

Cuando se ejecuta `NativeCorpusContractTests` con el corpus real, además del
detalle `NATIVE_CORPUS_REPORT` se emite `NATIVE_CORPUS_SUMMARY`. Esa salida
resume aceptaciones automáticas, bloqueos, falsos positivos, precisión,
documentos OCR aún pendientes y la bandera `certified`; esta última permanece
en `false` mientras existan goldens pendientes o cualquier estado OCR sin
resolver. El workflow de CI ejecuta el contrato nativo sintético, pero no puede
montar los PDFs privados; por eso la corrida con
`MARCELITO_PDF_CORPUS_REQUIRE_CERTIFIED=1` debe hacerse manualmente en un
macOS que tenga el corpus local.

El contrato cubre tres regresiones de alto riesgo: evidencia institucional que
vence a una contraparte (BBVA no se convierte en Santander), créditos Amex que
no se convierten en compras y encabezados administrativos con números que no
se convierten en movimientos. Si falla, el workflow no puede avanzar a una
compilación publicable.
