# Instrucciones para Luna: lector Rappi verificable en iOS

## Objetivo y alcance

Implementar la lectura fiable de los seis estados Rappi proporcionados y preparar el lector para variaciones futuras. Trabajar por etapas con evidencia de ejecución. Preservar los parsers y las reglas de aceptación de American Express, BBVA y Santander. No flexibilizar conciliación, inventar movimientos ni modificar importes para alcanzar un total.

Este documento acompaña la implementación actual en la rama de trabajo. No es una certificación de PDFKit/Vision: esa parte debe ejecutarse en macOS, simulador y un iPhone físico. No crear otra tarea ni publicar automáticamente por leer estas instrucciones. Respetar la autorización vigente de la conversación para commits, GitHub y TestFlight.

## Punto de partida verificado

Luna debe continuar desde este estado y no desde una build anterior:

- Rama: `codex/testflight-rappi-current-2026-09-15`.
- Head publicado en TestFlight: `dfb79c4225738f3ab890b5be5e20e53ac2838b46`.
- Base funcional del lector: `c58d51a` (preserva la confianza OCR real de cada fila Rappi también en la ruta nativa y fija la versión `.2`). El head publicado añade las compuertas de versión y distribución de TestFlight.
- Tag de entrega visible: `ios-v1.0.112-bootstrap`, apuntando exactamente a `dfb79c4`.
- Workflow de GitHub Actions: [iOS TestFlight 35164923657](https://github.com/ClubAmigosTT/marcelito-finanzas/actions/runs/35164923657).
- TestFlight: versión `1.0.112`, build `210`, estado `VALID`, disponible automáticamente para el grupo interno `Marcelito - Pruebas internas`.
- Versión del lector que debe aparecer en los informes: `ios-reader-deterministic-2026.09.17.1`.
- Versión web equivalente: `web-reader-deterministic-2026.09.16.2`.
- Validaciones de código en verde sobre el head documentado: [Web Reader Validate](https://github.com/ClubAmigosTT/marcelito-finanzas/actions/runs/35096875411) y [iOS Validate](https://github.com/ClubAmigosTT/marcelito-finanzas/actions/runs/35096875442).
- Auditoría local repetida el 16-sep-2026: `328/328` pruebas públicas, TypeScript, build Vite y auditoría pública en verde; la corrida privada web de los seis Rappi devolvió `6/6` válidos, `0` filas rechazadas, `0` fallas de manifiesto y `nativeOCRPending: 0`.

El build 210 es el bootstrap actualmente visible para instalar/probar el certificador; contiene la normalización de prefijos de procesador, la separación de evidencia, la confianza por fila, el visor móvil y la normalización de fechas OCR localizadas antes del puente Swift. Usa la versión nativa `.3` y el motor compartido `.2`. El build 209 (`1.0.110`) queda como histórico inmediato; el build 204 (`1.0.6`) también es histórico porque App Store Connect ya tenía una versión de marketing `1.0.106`.

La revisión publicada en el build 210 contiene la recuperación de filas Rappi cuando Vision detecta solo parte de las líneas horizontales, la deduplicación por región/importe, la evidencia por página y zona, la separación entre conciliación y enriquecimiento, el visor móvil y la corrección para no mandar créditos/pagos con signo válido a revisión por comparar signo contra magnitud. También separa la confianza financiera de fecha/importe de la confianza general del comercio, conserva la confianza financiera mínima de cada fila OCR, deja conservadora la inferencia de importes sin signo, normaliza fechas OCR localizadas antes del puente Swift y separa prefijos de procesador únicamente de la identidad visible/reglas. Todavía no se debe declarar certificación nativa completa: falta ejecutar los seis PDFs privados con PDFKit/Vision en macOS y confirmar el flujo completo en un iPhone físico.

Antes de compilar, Luna debe comprobar `git status`, el commit que contiene las versiones `2026.09.16.2` y cualquier cambio posterior fuera de `docs/`, `package.json`, `.github/workflows/ios-testflight.yml`, `scripts/verify-native-*.ts` y las pruebas de contrato. Una build posterior requiere volver a ejecutar la validación completa. El build histórico 202 correspondía al tag `ios-v1.0.4-bootstrap`; no usarlo para verificar esta corrección.

No subir los PDFs, capturas ni un reporte con comercios/importes reales al repositorio. El manifiesto privado y los informes detallados deben permanecer fuera del repositorio público o dentro de rutas ignoradas.

## Cambios ya incorporados en esta rama

- La ruta OCR Rappi conserva la lectura de página completa aun cuando la detección por bandas encuentra algunas filas; las alternativas se deduplican por importe y posición vertical, preservando compras iguales en posiciones distintas.
- Cada fila OCR puede transportar un marcador privado de página y caja normalizada. `MovementExtractionEvidence` conserva `page`, `bounds`, `sourceText`, método, confianza y `sameVisualRow`; el visor usa esa evidencia para abrir el PDF en el origen.
- La selección Rappi empareja cada conjunto de filas con el resumen que le corresponde. No se prueba una lectura contra controles de otra fuente.
- El fallback textual rechaza una línea con más de un importe firmado; nunca elige globalmente el último número. La lectura por columnas/OCR es la vía de recuperación para una fila ambigua.
- La normalización web conserva `rawDescription` antes de quitar anotaciones de moneda extranjera y separa `normalizedMerchant`/`displayMerchant`; las filas aplanadas solo se separan cuando aparece una segunda pareja completa de fechas.
- La normalización Rappi separa prefijos de procesador (`MERPAGO*`, `CLIP MX*`, `BPK*`, `D LOCAL*`, `PAYU*`, `PAYPAL*`, `CONEKTA*`, `PGB*` y `COM RAP*`) únicamente del identificador de reglas y del nombre visible. El texto original permanece intacto. Un alias fuerte conserva confianza alta; un identificador opaco con dígitos o menos de cuatro caracteres queda como comercio por confirmar. La tabla de alias sigue siendo explícita y no se aplica a Amex, BBVA ni Santander.
- Las categorías nuevas para abreviaturas compactadas son de alta señal únicamente (`CAFETERIA`, `SAZONJAROCHO`, `MEZCALERIA`, `BARBACOA`, `REST...`, `CASADETONO`, `MCDONALDS`, etc.). Un nombre legible sin evidencia de categoría sigue en `Otros / Por revisar`; no se rellena con una categoría inventada.
- Una descripción pendiente no bloquea una fila financieramente válida; una lectura OCR débil, una columna sin calibrar o una fila visual rechazada sí deja el estado en cuarentena y fuera del libro canónico.
- La ruta OCR de Rappi conserva diagnóstico por cada fila visual no seleccionada. Si no existe una fila geométrica con fecha e importe, se registra `rappi.visual-row-not-reconstructed`; si existe pero no puede convertirse en movimiento, se registra `rappi.visual-row-rejected`. Esto impide que una conciliación de totales esconda una fila perdida.
- La confianza OCR de Rappi separa los tokens financieros (fechas e importe) de la confianza general de la observación. En web y nativo la confianza financiera mínima de la fila viaja hasta `MovementExtractionEvidence`; un nombre de comercio débil puede entrar como enriquecimiento pendiente cuando la fila financiera es confiable, mientras una fecha o importe débil sigue bloqueando la importación automática.
- La detección visual de filas combina las reglas horizontales impresas con anclas independientes de fecha. Si sobreviven solo algunas reglas, las bandas faltantes se recuperan por fecha y las bandas solapadas se deduplican antes de invocar Vision.
- La inspección PDF web aplica `gateOcrReconciliation` antes de mostrar el resultado como guardable: una conciliación aritmética con OCR de baja confianza queda provisional y no puede entrar al libro hasta revisión.
- La extracción web de Rappi prueba primero si la capa de texto seleccionable completa concilia con sus controles impresos. Solo si esa prueba falla se activa OCR; la heurística genérica no puede reemplazar una tabla Rappi completa por una lectura OCR más débil. Esta excepción queda aislada de American Express, BBVA y Santander.
- La suite nativa prueba la misma frontera: una tabla Rappi seleccionable que concilia evita Vision y una fila faltante no pasa el probe. El caso usa datos sintéticos, no PDFs privados.
- La ruta nativa reconstruye Rappi por geometría de columnas antes de recurrir a Vision: dos fechas en la banda izquierda, descripción en la banda central e importe firmado en la banda derecha. También conserva un marcador de página/caja para abrir el origen y permite reabrir una segunda tabla de tarjeta después de un total intermedio.
- El evaluador privado del corpus usa la misma compuerta para no convertir un reporte OCR débil en una certificación; `qualityGate.applied` solo es verdadero cuando la compuerta cambia el resultado.
- El lector se versionó para forzar la reconstrucción de estados previos después de instalar la nueva build. La reconstrucción reemplaza filas de forma atómica y conserva el PDF original.
- El dashboard iOS separa estados conciliados, movimientos bloqueados y movimientos por enriquecer. Los bloqueados no entran al libro financiero; los comercios inciertos sí pueden entrar si fecha, importe, signo y conciliación son confiables.
- La revisión web muestra la etiqueta de comercio/categoría por confirmar, el texto original de la fila cuando existe enriquecimiento pendiente y la confianza/página/método de extracción; el título visible nunca sustituye la evidencia almacenada.
- El manifiesto privado compartido conserva `readerVersion` para iOS y `webReaderVersion` para el evaluador web; no se debe cambiar una versión para ocultar una discrepancia.

## Hechos y límites del diagnóstico

En la sesión del 15 de septiembre de 2026, los seis PDFs se procesaron mediante PDF.js, `rebuildPdfText`, `rebuildPdfLayout` y `parseDeterministicStatement` del repositorio. Los seis devolvieron conciliación válida. Una extracción independiente con pdfplumber confirmó los conteos y las sumas impresas. Esto no certifica PDFKit, Vision ni el comportamiento de iOS.

| Identificador anonimizado | Periodo de referencia | Filas esperadas | Conteo de la captura histórica | Estado en captura |
| --- | --- | ---: | ---: | --- |
| rappi-01 | julio | 17 | 17 | Verde |
| rappi-02 | junio | 112 | 111 | Por revisar |
| rappi-03 | abril | 147 | 147 | Verde |
| rappi-04 | documento sin periodo publicado | 138 | 137 | Por revisar |
| rappi-05 | agosto | 13 | 13 | Verde |
| rappi-06 | marzo | 108 | 107 | Por revisar |

La columna de captura conserva el diagnóstico de la versión antigua que originó el reporte; no es el resultado de esta rama. Esos conteos sugirieron pérdida neta de una fila en tres documentos, pero no identificaron la fila exacta ni descartaron una combinación de omisiones y duplicaciones. Las explicaciones sobre compras extranjeras, duplicados y cortes de página fueron hipótesis. El evaluador actual debe ser la fuente de verdad para la regresión, y cada diferencia nativa debe quedar explicada por fila y página.

El evaluador web privado actual devuelve los seis estados como válidos, con 17, 112, 147, 138, 13 y 108 movimientos respectivamente, sin filas rechazadas. La corrección `51a195b` prueba primero la capa de texto y los seis casos actuales quedan como `pdf-text`; OCR permanece como recuperación si el texto no concilia. Esto explica la diferencia entre la captura antigua y la lectura actual: la ruta anterior enviaba innecesariamente estos PDFs densos a OCR, donde se perdía una fila en algunos documentos. La capa de categorías Rappi redujo de forma medible las filas de gasto sin categoría frente al reporte anterior, manteniendo en revisión los descriptores que no prueban el comercio. El head `2d1cf1b` además separa el cálculo de confianza de fecha/importe de la confianza general del texto y evita reconstruir filas completas para cada métrica de página; esto mantiene el gate financiero conservador sin penalizar un comercio débil por sí solo:

| Identificador | Antes de reglas Rappi | Tras reglas iniciales | Actual | Reducción total |
| --- | ---: | ---: | ---: | ---: |
| rappi-01 | 4 | 0 | 0 | 100% |
| rappi-02 | 44 | 26 | 26 | 40.9% |
| rappi-03 | 60 | 33 | 26 | 56.7% |
| rappi-04 | 37 | 15 | 12 | 67.6% |
| rappi-05 | 4 | 1 | 1 | 75.0% |
| rappi-06 | 41 | 25 | 23 | 43.9% |
| **Total** | **190** | **100** | **88** | **53.7%** |

La métrica cuenta únicamente gastos; pagos de tarjeta y devoluciones no se etiquetan como categorías de gasto. La identidad de comercio tuvo cobertura 100% en las seis corridas (`rawDescription`, `normalizedMerchant` y `displayMerchant` presentes). En la corrida actual, 93 filas conservaron un prefijo de procesador en el texto original y 0 lo muestran en `displayMerchant`; dos filas con identificador opaco quedaron marcadas para confirmar. Los límites privados actuales son 0, 26, 33, 15, 1 y 25; si alguna cifra aumenta, el manifiesto bloquea la regresión. La versión web `.2` y la nativa `.3` propagan la confianza mínima real de los tokens financieros de cada fila OCR —incluidas las líneas de continuación— en vez de asignar una constante global. El build 209 ya pasó compilación, firma, subida, procesamiento y distribución interna de Apple; la certificación nativa del corpus sigue pendiente hasta ejecutar PDFKit/Vision con los seis PDFs y confirmar el resultado en un iPhone físico.

Los documentos incluyen compras repetidas legítimas, dos secciones de tarjeta y anotaciones de moneda extranjera. Son casos obligatorios de prueba; su presencia no demuestra por sí sola la causa del fallo.

## No confundir el diagnóstico OCR web con la certificación nativa

`scripts/evaluate-pdf-corpus.ts --ocr` usa `pdftoppm` y el OCR local disponible como diagnóstico. En la corrida anterior produjo `0/6` aceptaciones porque ese OCR pierde controles y columnas en estos PDFs; eso es una señal de revisión, no permiso para volver a elegir «el último número» ni para modificar importes hasta conciliar. Con `51a195b`, el informe web sin `--ocr` prueba primero el texto seleccionable y devuelve `nativeOCRPending: 0` para estos seis casos; esto valida la ruta web, pero no certifica PDFKit/Vision. La ruta nativa que se debe certificar sigue siendo PDFKit + Vision en iOS/macOS cuando el conjunto de texto no sea suficiente, con filas por geometría y controles del mismo conjunto.

Si Luna obtiene un resultado distinto, debe registrar por separado: `pdf-text`, OCR local de diagnóstico y `vision-ocr` nativo. Nunca combinar esos resultados en un único conteo ni marcar como certificado un informe que no tenga `NATIVE_CORPUS_REPORT` de Vision.

## Preparación

1. Leer instrucciones locales, `git status`, historial y rama actual. Preservar cambios ajenos. No partir de una versión antigua por asumir una rama de esta conversación.
2. Leer `docs/rappicard-reader.md`, `apps/ios/README.md`, los parsers y los runners de pruebas antes de editar.
3. Localizar los seis adjuntos en el entorno disponible. En la máquina de origen están en el directorio de adjuntos de esta conversación. En macOS hay que proporcionar una copia privada accesible al runner; no asumir que una ruta Windows existe allí.
4. Guardar originales, texto extraído, imágenes, hashes y comparaciones fila por fila exclusivamente fuera del repositorio público o bajo directorios ignorados como `private-corpus/` y `artifacts/`. Las imágenes también contienen información privada aunque `.gitignore` ignore los PDF.
5. Preparar un manifiesto compatible con los verificadores existentes. Publicar solo expectativas anonimizadas: emisor, tipo, conteo, conciliación, método esperado, calibración requerida y límites de rechazo/categoría. Los importes reales, comercios y fechas concretas permanecen privados.

## Mapa inicial del código

- `src/pdfImport.ts`: extracción PDF.js, `rebuildPdfText`, `rebuildPdfLayout`.
- `src/issuerParsers/rappi.ts` e `index.ts`: parser determinista web.
- `src/issuerParsers/types.ts`: contrato de geometría; revisar qué coordenadas faltan.
- `src/merchantNormalization.ts`: identidad de comercios.
- `apps/ios/Cauce/Models.swift`: `extractPDF`, `applyPDFExtraction`, `parseRappiText`, `reconciledRappiSelection`, `rappiOCRMovementLines`, `rappiTableRowRegions`, `rappiVisualRowObservations` y `ocrObservations`.
- `apps/ios/Cauce/Sections.swift`: estados de importación y acceso a evidencia.
- `apps/ios/Tests/`: pruebas nativas y corpus; localizar los nombres actuales.
- `apps/ios/scripts/run-native-corpus.sh`, `scripts/verify-native-corpus-report.ts`, `scripts/verify-native-device-report.ts`: ejecución y verificación existentes.

## Etapa 1: reproducir y localizar la divergencia

Ejecutar el corpus completo con el código actual en macOS/iOS antes de cambiar el lector. Guardar por documento y por página: filas candidatas, aceptadas y rechazadas, método, motivo, controles leídos y diferencias de conciliación. Comparar las filas nativas contra una referencia privada revisada visualmente; el parser web no es la única autoridad.

Registrar versión del lector, commit, build e iOS. Si la versión actual ya pasa, comprobar relectura de documentos almacenados y versión instalada antes de atribuirlo al parser.

Revisar específicamente estos riesgos observados en el diagnóstico, confirmando que sigan corregidos:

- `ocrObservations` debe conservar la pasada completa aunque existan filas visuales; la selección final queda al agrupador/deduplicador.
- `rappiTableRowRegions` debe combinar líneas horizontales parciales con anclas independientes de fecha y deduplicar bandas solapadas.
- La reconstrucción OCR debe conservar `rawDescription` antes de limpiar el comercio y guardar la fila completa en `sourceText`.
- `sameVisualRow` solo debe ser verdadero cuando existe una caja geométrica demostrable; una línea reconstruida sin geometría debe quedar en estado desconocido.

Entrega de esta etapa: causa reproducida o límites concretos del diagnóstico, fila/página afectada cuando se pueda demostrar, y prueba que falle antes de corregir. No afirmar que falta una fila específica solo por la diferencia de conteos.

## Etapa 2: probar un motor compartido local

La dirección propuesta es reutilizar PDF.js y el parser Rappi que ya procesaron los seis PDFs. Antes de reemplazar la ruta nativa, construir una prueba integrada y acotada en iOS. Evaluar un componente WKWebView con recursos JavaScript empaquetados localmente; confirmar compatibilidad de PDF.js, workers, fuentes y dependencias con el runtime elegido. No asumir que JavaScriptCore soporta las APIs de navegador de PDF.js.

La prueba debe ejecutar el mismo código compartido, no otra traducción manual del parser. Procesar los documentos localmente, sin CDN ni envío a un servicio. Definir un puente tipado con identificador de solicitud, versión de esquema, respuesta validada, errores, cancelación y límites de memoria/tamaño. Trabajar página por página cuando sea necesario, liberar recursos y medir duración y memoria en dispositivo.

No sustituir el lector hasta que esta prueba pase los seis archivos en iOS. Si no resulta viable, documentar el fallo medido y mantener un adaptador nativo hacia el contrato común con las mismas pruebas. No añadir una cadena de lectores alternativos sin controles de selección.

### Implementación actual del contrato compartido

En esta rama ya existe una primera integración acotada y local:

- `src/rappiEngineBridge.ts` expone el parser determinista web como `MarcelitoRappiEngine`.
- `scripts/build-ios-rappi-engine.mjs` genera `apps/ios/Cauce/Resources/rappi-engine.js`; el artefacto se comprueba en CI para impedir divergencia entre fuente y bundle.
- `apps/ios/Cauce/RappiSharedEngine.swift` ejecuta únicamente ese parser puro mediante JavaScriptCore. No intenta ejecutar PDF.js: PDFKit y Vision siguen siendo responsables de extraer texto, columnas, confianza y coordenadas.
- `Models.swift` usa el motor compartido para `pdf-text` y `vision-ocr`, pero conserva en Swift la selección del conjunto completo, la conciliación y la compuerta de importación. Un fallo del recurso devuelve la ruta nativa de recuperación; no se mezclan filas de ambos conjuntos.
- La versión del lector nativo es `ios-reader-deterministic-2026.09.17.1` y la del motor es `rappi-shared-engine-2026.09.16.2`. Cualquier cambio de contrato exige actualizar ambas pruebas de bundle y la versión del lector.

Antes de ejecutar XcodeGen, correr `npm ci`, `npm run rappi:engine:build`, `npm test` y `node node_modules/typescript/bin/tsc -b`. En macOS, Xcode debe ejecutar además `RappiSharedEngineTests` y el corpus privado. La existencia del bundle o el paso de la prueba sintética no certifican por sí solos los seis PDFs reales ni Vision en un iPhone.

## Etapa 3: contrato de filas y cobertura

Extender los contratos existentes de forma compatible. Cada fila debe poder conservar:

- Identidad del documento, página y región física; sección/tarjeta cuando se conozca.
- Fecha de operación y de cargo, texto original del importe, importe en centavos y signo impreso. Aplicar una sola vez la convención de signos del libro existente.
- `rawDescription`, `normalizedMerchant`, `displayMerchant` separados.
- Método de extracción por campo, confianza y motivos de revisión.
- Evidencia de si fecha, descripción e importe pertenecen a la misma fila; usar desconocido cuando no se pueda demostrar.
- Caja de origen normalizada y convención de coordenadas documentada, incluyendo rotación y conversión al visor PDF.

Construir un inventario de filas candidatas independiente de las filas que el parser logró aceptar. Usar límites de tabla, columnas, anclas de fechas/importes y geometría. No contar únicamente las filas aceptadas para declarar cobertura completa. Las líneas tenues, encabezados repetidos, continuaciones y cambios de sección deben estar cubiertos.

Todas las regiones candidatas deben quedar explicadas como movimiento aceptado, continuación vinculada, elemento informativo reconocido o fila pendiente. Si la cobertura no puede establecerse, informarla como desconocida; nunca inventar un porcentaje.

La identidad física distingue repeticiones: mismo comercio/fecha/importe en posiciones distintas son filas distintas. Lecturas alternativas de la misma región se comparan, no se suman. Evitar IDs basados solo en coordenadas flotantes exactas, que pueden variar entre renderizados.

## Etapa 4: recuperación OCR acotada

Activar OCR para las regiones con evidencia ausente o inconsistente. Delimitar fecha, descripción e importe por columnas calibradas. Las anotaciones de divisa y tipo de cambio son metadatos de la compra; el importe financiero viene de la columna MXN.

Conservar candidatos originales y recuperados. Asociarlos por página y región física antes de seleccionar una lectura. Si una fila mezcla campos de texto nativo y OCR, registrar esa procedencia por campo y comprobar alineación y consistencia. No concatenar conjuntos completos ni elegir importes por ser los que hacen cuadrar el saldo.

Un conflicto en fecha, signo o importe requiere revisión. La conciliación verifica el resultado completo, no decide qué número inventar. Acotar reintentos, tiempos y resolución; soportar cancelación sin importación parcial.

## Etapa 5: aceptación, persistencia y experiencia

Exigir controles financieros válidos y cobertura/evidencia suficiente para la importación automática. Mantener la política actual de cuarentena del documento cuando hay filas financieras bloqueadas. Un comercio incierto puede persistir con revisión si la fila es financieramente válida y el conjunto pasa los controles.

Separar documentos conciliados, movimientos bloqueados y movimientos por enriquecer. Mostrar página o fila faltante solo cuando exista evidencia para identificarla. De otro modo usar un motivo preciso, por ejemplo «No se pudo comprobar la lectura completa de la página».

Reutilizar y comprobar el visor existente: ajustar a ancho en móvil, controles de zoom, navegación, zoom persistente y apertura en la región del movimiento. Auditar qué mejoras ya existen antes de reimplementarlas.

Versionar el lector y planificar la relectura de estados antiguos desde el PDF guardado. Reemplazar resultados de forma atómica e idempotente; preservar correcciones del usuario, asociaciones y originales. Una relectura fallida no debe destruir datos previamente válidos ni duplicar movimientos.

## Pruebas y criterios de entrega

Pruebas de comportamiento, no solo búsquedas de cadenas en Swift:

- Seis PDFs Rappi con los conteos exactos de la tabla; signos, fechas e importes contrastados con referencia privada y totales impresos.
- Repeticiones legítimas conservadas; múltiples lecturas de una región sin duplicados.
- Cobertura parcial aunque existan algunas líneas horizontales; recuperación activada realmente, sin retorno prematuro.
- Compra extranjera con números auxiliares, continuación multilínea, encabezado repetido y cambio de tarjeta.
- OCR con signo o fecha dudosos, y errores compensatorios que preserven el total: no deben aceptarse solo por conciliar.
- Descripción degradada con números válidos: original conservado y comercio por confirmar.
- Documento ilegible, columnas desordenadas, lectura cancelada y formato desconocido: no contaminan el libro.
- Migración y relectura repetida sin pérdida de correcciones ni duplicados.
- American Express y BBVA siguen pasando texto nativo; Santander sigue pasando OCR con columnas calibradas, signos y conciliación correctos.

Ejecutar las pruebas pertinentes del proyecto, `npm test`, `npm run build` y `npm run audit:public` con el runtime disponible. Añadir nuevas pruebas al runner cuando corresponda. No asumir que `npm` está en PATH en Windows; resolver el runtime instalado.

En Windows, si `npm` no está expuesto en `PATH`, las equivalencias verificadas en esta rama son:

```powershell
node node_modules/typescript/bin/tsc -b
node --experimental-strip-types --test tests/issuer-parsers-golden.test.ts tests/reconciliation.test.ts tests/ios-concurrency-contract.test.ts tests/native-corpus-report.test.ts tests/pdf-evaluator-contract.test.mjs
node node_modules/vite/bin/vite.js build
node scripts/audit-public-repo.mjs
```

La lista corta anterior no sustituye al runner completo del proyecto; sirve para diagnosticar el entorno Windows. La certificación nativa sigue requiriendo macOS/Xcode.

Para el corpus nativo, usar el runner existente en macOS desde la raíz, después de verificar el esquema del manifiesto:

```sh
MARCELITO_PDF_CORPUS_DIR=/ruta/privada/rappi-pdfs \
MARCELITO_PDF_CORPUS_MANIFEST=/ruta/privada/manifest.json \
MARCELITO_PDF_CORPUS_VERIFY=1 \
bash apps/ios/scripts/run-native-corpus.sh
```

Para la compuerta final de publicación, repetirlo con `MARCELITO_PDF_CORPUS_REQUIRE_CERTIFIED=1`. El informe debe contener los seis nombres esperados, la versión exacta `ios-reader-deterministic-2026.09.17.1`, el método exacto que indique el manifiesto privado —para estos seis PDFs, `pdf-text`; un caso futuro puede requerir `vision-ocr`—, cero filas rechazadas y conciliación válida; además debe validarse en un iPhone físico. La certificación del runner se basa en el conjunto exacto del manifiesto, no en un mínimo fijo de archivos: así el corpus Rappi de seis PDFs puede certificarse y el mismo gate sigue aceptando un corpus más amplio. Si falta una sola evidencia, detenerse en revisión y no subir a TestFlight.

Importante para esta entrega: la pantalla `Certificar estados con Vision` ahora tiene un perfil `rappi-focused` de seis o más estados exclusivamente Rappi procesados por el lector local (`pdf-text` u `vision-ocr`), además del perfil general de 10 o más archivos. Puede exportar un JSON sanitizado de seis Rappi para que el workflow valide la lectura del dispositivo. El manifiesto privado fija el método exacto esperado por cada PDF; por eso el informe del dispositivo no sustituye los goldens privados de filas y controles. Para la certificación más fuerte, usar también el runner anterior con `MARCELITO_PDF_CORPUS_MANIFEST` y conservar el informe/log fuera del repositorio. Solo después de que el perfil de dispositivo y el manifiesto exacto estén en `certified=true`, registrar en GitHub `MARCELITO_NATIVE_CORPUS_CERTIFIED=true` y `MARCELITO_NATIVE_CORPUS_READER_VERSION=ios-reader-deterministic-2026.09.17.1`.

Exigir evidencia de que se ejecutaron todos los documentos esperados: un test omitido por falta de archivos no es un aprobado. El runner usa simulador; completar además una prueba en iPhone físico con el flujo de importación y el visor. Medir duración, memoria y capacidad de cancelar. Windows puede validar TypeScript y contratos, pero no certificar PDFKit/Vision ni una compilación iOS.

Antes de publicar, ligar commit, versión del lector y número de build a los informes. Comprobar que el archivo distribuido corresponde al commit probado. Distinguir «compilado», «subido», «procesado por Apple» y «disponible en TestFlight». No dar por resuelto el problema con una prueba web o un upload exitoso.

## Forma de trabajar y entregar a Marcelo

Implementar commits pequeños por etapa: diagnóstico/pruebas, prueba de motor compartido, contrato/cobertura, recuperación y finalmente integración/migración. Si cambia el plan por evidencia, registrar el motivo. Mantener una lista de resultados reales, pendientes y bloqueos de plataforma.

La entrega final debe indicar qué causa se confirmó, qué cambió, cuáles de los seis archivos pasaron en iOS, qué regresiones se ejecutaron y el build exacto disponible si se publicó. Cualquier validación no ejecutada debe quedar explícita. No declarar terminada la corrección mientras falte validación nativa y en dispositivo.

## Mensaje de handoff para Luna

Puedes iniciar la tarea con este texto:

> Trabaja sobre el checkout actual y conserva todos los cambios existentes. El artefacto actualmente visible es TestFlight versión `1.0.112`, build `210`, tag `ios-v1.0.112-bootstrap`, basado en `dfb79c4`; es un bootstrap para instalar/probar el certificador, no una certificación nativa final del corpus. El grupo interno tiene distribución automática, por lo que el workflow confirma disponibilidad sin hacer una asociación manual que Apple rechaza. La rama ya incluye la implementación nativa y web actuales. La entrega web que debes validar declara `web-reader-deterministic-2026.09.16.2`; la entrega nativa declara `ios-reader-deterministic-2026.09.17.1` y el motor compartido `rappi-shared-engine-2026.09.16.2`. Implementa y valida únicamente Rappi + normalización de comercios + evidencia/confianza OCR + visor PDF móvil + métricas de calidad. No reescribas Amex, BBVA ni Santander; úsalos como regresión. Lee `docs/rappi-luna-implementation.md`, `docs/rappicard-reader.md`, `apps/ios/README.md` y `apps/ios/TESTFLIGHT.md`. Ejecuta primero `git status` y el corpus privado sin mover PDFs al repositorio. En Rappi, separa `rawDescription`, `normalizedMerchant` y `displayMerchant`; quita prefijos de procesador solo de `normalizedMerchant`/`displayMerchant`, conserva el texto original y marca únicamente identificadores opacos para confirmar; nunca elijas el último importe global ni hagas conciliar por ajuste. Conserva signos explícitos; si OCR entrega un importe sin signo, no lo conviertas en cargo automáticamente: solo puede inferirse un abono cuando el texto de la fila lo prueba de forma explícita. Compara evidencia de créditos por magnitud absoluta, sin perder el signo financiero. Ejecuta las pruebas web y de TypeScript, después el runner nativo con `MARCELITO_PDF_CORPUS_VERIFY=1` y finalmente el mismo runner con `MARCELITO_PDF_CORPUS_REQUIRE_CERTIFIED=1`. En el iPhone, selecciona exclusivamente los seis Rappi para obtener `certificationScope: rappi-focused`; acepta `pdf-text` u `vision-ocr` según la evidencia real y usa además el manifiesto privado exacto para comprobar el método esperado, goldens y controles. Verifica también en el iPhone los botones de zoom, `Ajustar a ancho`, página anterior/siguiente, zoom persistente y apertura en la zona de origen. No declares éxito ni publiques TestFlight final hasta que los seis PDFs pasen el método esperado, el iPhone físico verifique el visor y ambas evidencias estén certificadas.
