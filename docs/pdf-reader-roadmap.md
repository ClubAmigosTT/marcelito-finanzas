# Roadmap del lector de estados al 97%

## Definición de éxito

La meta es **97% de precisión de aceptación automática**: de todos los
documentos que el sistema marca como `valid` y alimentan el libro canónico,
al menos 99 de cada 100 deben coincidir con el estado original en emisor,
periodo, filas, importes, dirección y clasificación. No se promete que OCR
reconozca un porcentaje fijo de caracteres; una lectura incierta se bloquea o queda
provisional.

La unidad de control es el estado de cuenta y la unidad de auditoría es cada
movimiento. Toda aceptación debe conservar evidencia suficiente para llegar
desde el KPI hasta la página, coordenadas y texto que originaron la fila.

## Arquitectura objetivo

1. **Ingesta inmutable**: conservar archivo, hash SHA-256, tamaño, número de
   páginas, fecha de importación y versión del lector. Nunca sobrescribir una
   importación anterior.
2. **Detección de emisor**: puntuar únicamente evidencia institucional del
   encabezado (razón social, dominio, producto y formato); las contrapartes en
   movimientos no pueden cambiar el banco detectado.
3. **Extracción por capas**: usar primero la capa de texto del PDF; si es
   insuficiente, ejecutar OCR visual por página con coordenadas y confianza.
   Mantener cada observación con página, bounding box, método y confianza, y
   persistir un fragmento de origen acotado en cada movimiento aceptado.
4. **Reconstrucción de filas**: anclar por fecha válida, agrupar descripción y
   tomar el importe desde la columna correcta (CARGOS/ABONOS o IMPORTE), nunca
   desde referencias, saldos corridos ni números administrativos.
5. **Validación y normalización**: validar fecha real, importe monetario,
   descripción y dirección; normalizar comercio, moneda, separadores, meses
   OCR y conceptos.
6. **Deduplicación y matching**: generar llave estable por cuenta + fecha +
   importe + concepto normalizado + tipo; después emparejar transferencias
   propias y pagos de tarjeta en ±2 días.
7. **Clasificación**: separar compra, ingreso, reembolso, transferencia,
   pago de tarjeta, interés, comisión, crédito y MSI.
8. **Conciliación**: comparar filas, conteos y totales con el resumen del
   emisor. Una discrepancia bloquea la importación.
9. **Libro canónico**: Resumen, Gastos, Patrimonio y gráficas solo leen esta
   tabla de movimientos conciliados; nunca el texto crudo ni estados parciales.
10. **Puerta de calidad**: estados `pending`, `invalid` o con OCR débil no
    alimentan KPI; se muestran en diagnóstico con el motivo exacto.
    La elegibilidad se reevalúa al abrir el libro con `mode`, confianza media,
    todas las páginas OCR y `requiresReview`, para que un registro persistido
    no pueda saltarse la compuerta por una bandera antigua.
    Un estado `ready` también exige evidencia institucional del emisor con
    estado `verified` o una confirmación humana explícita (`issuerConfirmedByUser`);
    si falta cualquiera de las dos (incluidos registros heredados), la
    migración lo devuelve a revisión y retira sus filas del ledger canónico.
11. **Aislamiento de ejecución**: la extracción PDFKit/Vision se ejecuta en
    una tarea asíncrona fuera del hilo de interfaz; solo el snapshot validado
    vuelve al store para hacer un commit atómico. El indicador de carga cubre
    cada archivo; la reconstrucción automática de arranque usa la misma ruta
    y una cancelación o error no deja filas parciales.

## Fases y criterios de salida

### Fase 0 — Contrato y corpus dorado

- Registrar una muestra por emisor, plantilla, periodo, texto/OCR y casos
  difíciles (solapamiento, pagos Amex, transferencias, encabezados numéricos).
- Guardar expectativas de emisor, tipo, estado, conteos y totales sin incluir
  datos personales en el repositorio.
- Salida: manifiesto versionado y comando reproducible
  `npm run pdf:corpus -- --dir ... --manifest ...`.

### Fase 1 — Texto estructurado

- Implementar detectores de encabezado y regiones de tabla para Santander,
  BBVA y Amex.
- Aplicar reglas de rechazo para RFC, CLABE, certificados, saldos, totales,
  periodos y texto administrativo.
- Salida: 100% de estados con texto que concilian importes y conteos; cero
  encabezados aceptados como movimiento.

### Fase 2 — Normalización contable

- Unificar comercios y conceptos con diccionario determinista y alias
  versionados; conservar descripción original.
- Aplicar deduplicación idempotente y matching entre cuentas propias y tarjetas.
- Si el revisor corrige el emisor o tipo de estado, ofrecer una relectura explícita
  de las filas y del resumen con esa estructura; la corrección no altera la
  compuerta de conciliación ni persiste el texto bruto del PDF.
- Salida: reimportar el mismo archivo no cambia el libro; dos compras idénticas
  legítimas permanecen como dos filas.

### Fase 3 — OCR visual controlado

- Ejecutar Vision en iOS por página, con escala adaptativa, coordenadas y
  confianza real por observación/página.
- Usar correcciones OCR estrictamente acotadas a tokens de fecha (por ejemplo
  `AG0`→`AGO`, `O5/AGO`, `OBIAGO`); nunca sustituir texto globalmente.
- Salida: promedio de página ≥88%, ninguna página <78%, cobertura de filas
  completa y conciliación dentro de ±$0.05; de lo contrario, revisión humana.

### Fase 4 — Conciliación y libro canónico

- Ejecutar siempre: extraer → validar → normalizar → deduplicar → matching →
  clasificar → conciliar → calcular.
- Validar identidades: saldo inicial + ingresos − egresos = saldo final; límite −
  disponible = deuda utilizada; ingresos − gasto real = flujo neto; patrimonio =
  efectivo − deuda.
- Salida: cualquier identidad fuera de tolerancia marca periodo inconsistente y
  bloquea el dashboard ejecutivo.

### Fase 5 — Auditoría y observabilidad

- Mostrar por periodo archivos, páginas, filas extraídas/válidas, duplicados,
  transferencias, pagos de tarjeta, ingresos, gastos, reembolsos, pendientes,
  confianza OCR y diferencias de conciliación.
- Registrar versión del parser, hash del archivo y razones de bloqueo.
- Asociar las huellas SHA-256 de los PDFs a cada corrida de auditoría para
  reproducir un KPI desde su fuente exacta, incluso cuando se reutiliza el
  nombre del archivo.
- Permitir descargar un diagnóstico JSON local con versiones, huellas,
  conciliaciones, motivos de bloqueo y consistencias, sin incluir
  descripciones ni importes individuales.
- Probar explícitamente el umbral que decide entre texto y Vision para evitar
  que capas ocultas administrativas desactiven OCR. La lectura directa exige
  fecha, encabezado de tabla y una fila plausible con importe; también probar
  que estados de texto válidos no se procesen visualmente sin necesidad.
- Salida: cada cifra del dashboard se puede explicar hasta filas y evidencia.

### Fase 6 — Certificación y despliegue

- Ejecutar el corpus completo en macOS/Xcode, incluyendo Vision y simulador.
- Publicar solo si precisión de aceptación ≥97%, cobertura de plantillas 100%,
  cero falsos positivos administrativos y todas las identidades contables
  pasan.
- Mantener canary: nuevas plantillas empiezan en `pending`, se miden durante
  una versión y solo después se habilita su aceptación automática.
- El workflow de iOS se ejecuta en `push`, `pull_request` y manualmente para
  evitar que cambios del lector lleguen a distribución sin compilar y correr
  las pruebas de contrato en macOS. Cada corrida conserva el `.xcresult` de
  Xcode como artefacto, incluso si una prueba falla, para poder diagnosticar
  el PDF, página o regla que rompió la certificación.
- El workflow `web-validate.yml` ejecuta en paralelo tipos, lint, pruebas y
  build del parser web en cada `push` y `pull_request`.
- La corrida nativa admite un modo de publicación explícito mediante
  `MARCELITO_PDF_CORPUS_REQUIRE_CERTIFIED=1`: la calibración puede dejar
  goldens `pending`, pero una certificación no puede pasar mientras exista
  alguno, haya lectura visual sin resolver o la precisión automática sea menor a 97%.
  El resumen emitido por XCTest se valida además con
  `npm run pdf:native:verify -- --log ... --reader-version ... --require-certified`,
  para que la variable de publicación no pueda sustituir al informe real. Si
  se pasa `--manifest`, el verificador también compara el conjunto exacto de
  PDFs e identidades enmascaradas contra las expectativas versionadas.
- El workflow de TestFlight añade una segunda compuerta: exige las variables
  `MARCELITO_NATIVE_CORPUS_CERTIFIED=true` y
  `MARCELITO_NATIVE_CORPUS_READER_VERSION`, que debe coincidir con la revisión
  actual del lector. Si el corpus no se volvió a ejecutar después de una
  modificación, la build no se archiva ni se sube.

## Umbrales y respuesta

| Señal | Umbral | Acción |
| --- | ---: | --- |
| Diferencia de total/conteo | > $0.05 o cualquier conteo distinto | Bloquear estado |
| Importe absurdo | ≥ $100,000,000 o identificador no monetario | Rechazar fila |
| Confianza OCR media | < 88% | Provisional |
| Confianza mínima de página | < 78% | Provisional |
| Cobertura de filas | < 100% cuando el estado declara conteo | Bloquear estado |
| Cobertura de evidencia | < 100% en filas importadas aceptables | Bloquear aceptación automática |
| Identidad contable | Fuera de tolerancia | Marcar periodo inconsistente |
| Precisión automática del corpus | < 97% | Detener publicación |

## Estado actual

El repositorio ya implementa las fases 1–5 para la capa web y el contrato de
lectura iOS, incluyendo pruebas de encabezados, duplicados legítimos,
transferencias, pagos Amex, MSI, conteos BBVA, confianza por página y fechas
OCR. En los ocho adjuntos disponibles, cuatro estados de texto concilian y
cuatro estados escaneados quedan correctamente bloqueados hasta Vision.

Las actualizaciones del lector también invalidan de forma segura los estados
persistidos con una revisión anterior: quedan visibles en auditoría, pero en
cuarentena hasta que se vuelvan a importar. Esto evita que una corrección de
extracción se mezcle con filas heredadas de una versión defectuosa.

La frontera de seguridad también valida el emisor: un estado guardado como
`ready` sin evidencia institucional verificada (por ejemplo, una etiqueta
inferida solo por el nombre del archivo) se marca `pending` y sus movimientos
se retiran de los KPI hasta reimportarlo o confirmar manualmente un emisor
conocido. El filtro del libro canónico repite
esta comprobación para protegerse de datos programáticos o migraciones
antiguas que hubieran persistido un estado incorrectamente listo. Si el usuario
confirma manualmente el banco mostrado, se conserva una marca separada y el
evento no se considera aceptación automática en la medición de precisión.

La certificación final del 97% queda pendiente de ejecutar el corpus completo
en macOS/Xcode con Vision; el entorno Windows no dispone de `xcodebuild` ni del
framework Vision. Hasta completar esa corrida, los estados OCR no deben
alimentar KPI productivos.

Mientras se prepara esa corrida, el evaluador web admite `--ocr --ocr-dpi`
para ejecutar una medición local reproducible con `pdftoppm` y Tesseract.js.
Esta ruta sirve para detectar errores de emisor, filas y conciliación en los
escaneos privados y guarda confianza media y por página en el reporte JSON;
deliberadamente no puede cambiar `certified` a `true` ni sustituye la prueba
Vision nativa. En la corrida de los ocho adjuntos disponibles a 220 DPI, los
cuatro Santander fueron identificados y conciliaron sus controles, con
confianza OCR media de 88–90% y mínima por página de 78%; aun así permanecen
provisionales hasta repetir el mismo corpus con Vision nativa. Esto confirma
que el umbral de publicación está actuando como compuerta y no como una cifra
decorativa.

La última revisión nativa añade una reparación conservadora para Santander:
cuando Vision conserva el saldo corrido de dos filas consecutivas, un importe
con separador decimal perdido solo se corrige si coincide con el delta del
saldo (o con un desvío menor o igual a $2). Sin saldos confiables, la fila no
se adivina y la conciliación mantiene el estado bloqueado. Esta regla ya tiene
prueba de contrato. La misma reparación cubre confusiones OCR con un `1`
inicial espurio (`160.00`→`60.00` y `1693.00`→`693.00`) únicamente cuando
los centavos coinciden exactamente con el delta del saldo. También existe un
fallback de idiomas en Vision: si el dispositivo no admite las etiquetas
regionales `es-MX`/`en-US`, reintenta con `es`/`en` y finalmente con el catálogo
predeterminado, sin saltarse las validaciones de filas ni la conciliación.
En Amex, las filas OCR ahora se anclan al inicio de la tabla y no al encabezado
de portada repetido. Para compras en moneda extranjera se toma el importe local
en la columna monetaria alineada a la derecha, incluso cuando la línea de
moneda/tipo de cambio aparece después o cuando Vision devuelve toda la fila como
una sola observación. Nunca se usa el importe de origen (por ejemplo,
`183,600.00` COP no puede convertirse en un cargo de `183,600.00` MXN cuando el
estado declara `1,031.17` MXN). La regla cuenta con fixtures nativos que cubren
portada con fecha, compra nacional, fila extranjera tokenizada y fila extranjera
completa; una fila solo se libera después de conciliar con los totales del
emisor.
runner nativo de corpus (`NativeCorpusContractTests`)
que recibe `MARCELITO_PDF_CORPUS_DIR`, procesa los ocho PDFs con
`PDFDocument + Vision`, verifica los estados de texto y emite un informe
`NATIVE_CORPUS_REPORT`; falta ejecutarlo contra los cuatro escaneos en
macOS/Xcode para cerrar la certificación.
El runner nativo ya contrasta los controles de saldo inicial, saldo final,
depósitos y retiros del resumen incluso cuando una lectura escaneada permanece
`pending`; solo difiere la aserción de sumas de filas hasta que Vision
reconstruye movimientos válidos.
El verificador del reporte nativo exige además huella SHA-256, emisor, tipo,
estado y conteo de filas por PDF, comparados con el manifiesto; un resumen
agregado sin trazabilidad completa no puede certificar la corrida. También
comprueba que la fuente esté `verified`, que su confianza esté entre 0 y 1 y
que `requiresReview` sea un booleano explícito.
El evaluador web también contrasta en los estados Amex de texto el límite,
crédito disponible, deuda comprometida, pago para no generar intereses, mínimo
más MSI y principal MSI pendiente; estos controles son independientes de las
filas para evitar que una deuda mal extraída pase por una conciliación parcial.

La capa multimodal opcional ya está implementada en
`server/statement-reader.mjs`. Recibe el PDF completo en un proxy autenticado,
exige el contrato JSON estricto y devuelve únicamente la extracción validada y
su huella. La aplicación no la activa por defecto: requiere configurar
`VITE_STATEMENT_READER_URL` y una autorización temporal. La plantilla
`.env.example` muestra los nombres de variables sin contener secretos; la
certificación de precisión sigue pendiente de ejecutar el proxy con un modelo
visual y un corpus privado.
El proxy aplica además la misma compuerta de confianza visual que el cliente:
media de filas ≥88% y media mínima por página ≥78%; por eso un modelo no puede
declarar `mode: "text"` para eludir una lectura multimodal débil. La pantalla
de revisión conserva ese estado como `review` y el libro canónico lo vuelve a
comprobar antes de calcular cualquier cifra.
La ejecución está encapsulada en `apps/ios/scripts/run-native-corpus.sh`, que
conserva el `.xcresult` y el log para que cada calibración sea reproducible.
El runner puede ejecutar el verificador automáticamente con
`MARCELITO_PDF_CORPUS_VERIFY=1` y hacer que la corrida falle si no está
certificada con `MARCELITO_PDF_CORPUS_REQUIRE_CERTIFIED=1`.
En Santander, si Vision no identifica los tres anclajes de columna, el lector
puede reconstruir filas para diagnóstico con el layout conservador, pero la
importación queda provisional y no puede autoalimentar los KPI. La calibración
solo se considera válida si los anclajes monetarios aparecen junto con `FECHA`
y `DESCRIPCIÓN` en la misma página y línea visual; tampoco se combinan
etiquetas de resúmenes o páginas distintas.

## Endurecimientos añadidos en la revisión actual

- El contrato multimodal exige que el fragmento de evidencia contenga el
  importe literal de la fila además del comercio. El proxy y el cliente aplican
  la misma regla, por lo que una respuesta que copia bien el nombre pero elige
  un saldo, folio o referencia queda bloqueada.
- Una relectura multimodal conserva el emisor institucional verificado por el
  lector local cuando el proveedor confunde una contraparte (por ejemplo,
  Santander mencionado dentro de un SPEI de un estado BBVA). El desacuerdo se
  conserva como evidencia de diagnóstico y no se oculta.
- Vision para Amex calcula la posición de cada importe aun cuando devuelve la
  fila completa en una sola observación. Prioriza el importe MXN antes o
  después del marcador de moneda; si falta el importe local, descarta la fila
  en vez de convertir pesos colombianos, dólares o el tipo de cambio en gasto.
- La revisión incrementa la `readerVersion`, por lo que una actualización no
  reutiliza silenciosamente filas producidas por una regla anterior: los PDFs
  se reconstruyen y los estados no conciliados permanecen en cuarentena.

## Checklist de aceptación antes de decir “97%”

1. Cada PDF del manifiesto tiene un resultado y una huella distinta; ningún
   duplicado cuenta como cobertura.
2. Cada fila aceptada coincide con golden en fecha, importe, dirección,
   comercio normalizado, tipo y página; la evidencia contiene descripción e
   importe.
3. Sumas y conteos del emisor concilian dentro de $0.05; los estados que no
   concilian no alimentan ninguna pantalla.
4. Las identidades de flujo, patrimonio, deuda y saldo de efectivo pasan.
5. La precisión de aceptación automática es ≥97%, la cobertura de archivos es
   100% y no existen falsos positivos administrativos.
6. La versión certificada del dispositivo coincide exactamente con la versión
   del lector que se va a publicar.
