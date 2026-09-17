# Plan para Luna: importación de estados con recuperación local en iPhone

> Estado: implementación base aplicada en el lector nativo. Queda pendiente
> ejecutar XCTest y el corpus privado en macOS/iPhone para certificar precisión,
> rendimiento y cobertura real por banco.

## Objetivo y alcance

Implementar una importación que pruebe sucesivamente texto PDF, reconstrucción geométrica, OCR de página y OCR dirigido, valide cada resultado y permita revisar los problemas restantes en el iPhone. Todo el procesamiento de documentos y las correcciones de esta función deben funcionar sin conexión. Prioridad inicial: BBVA, Santander, American Express y RappiCard.

Este documento conserva el plan de implementación y sus pendientes de certificación. La implementación base ya está integrada: conserva la ruta rápida de texto, usa reconstrucción geométrica cuando aplica, habilita Vision cuando el texto no concilia y ejecuta una relectura regional acotada cuando el primer OCR falla. No incluye publicar TestFlight ni enviar estados a servidores. No incorporar Python, Bank Statement Parser ni modelos remotos: la solución propuesta reutiliza PDFKit, Vision y los lectores existentes. Un modelo generativo en el dispositivo queda fuera de esta versión; primero medir cuánto recupera la extracción existente bien coordinada.

## Hallazgos del código revisado

- `apps/ios/Cauce/Models.swift`: `extractPDF` ya prueba texto y `SelectablePDFLayout` antes de recurrir a Vision cuando no concilia. No crear un segundo pipeline paralelo que duplique esta lógica.
- Esa función contiene `selectableAmex`: identificar Amex en el texto desactiva OCR, incluso si los controles fallan. Generalizar la recuperación requiere cambiar deliberadamente este contrato y las pruebas que lo exigen.
- Rappi ya cuenta con selección entre conjuntos candidatos, lectura por páginas, recuperación de controles de portada y reintentos visuales. Inventariarlos y reutilizarlos antes de agregar variantes.
- `importPDFAsync`, la reconstrucción asíncrona y la caché ya existen. Preservar la actualización atómica del libro y el trabajo fuera del hilo principal.
- `SelectablePDFLayout.swift`, `PDFReadingCache.swift`, `RappiSharedEngine.swift`, `PDFExtractionDiagnostic.swift` y `NativeCorpusCertification.swift` son puntos de integración.
- El motor compartido Rappi se genera desde TypeScript y corre localmente con JavaScriptCore. Conservar esa arquitectura; nunca editar manualmente `Resources/rappi-engine.js`.
- Ya existen pruebas nativas, auditorías de filas, manifiestos privados y certificación en dispositivo. Ampliarlos; una prueba web no acredita PDFKit/Vision.

## Reglas de implementación

1. Una lectura aceptada debe tener emisor/cuenta/periodo coherentes, evidencia de filas, importes y signos verificables, cobertura suficiente y controles financieros válidos según el producto.
2. Usar centavos enteros o Decimal con conversión comprobada. Nunca corregir un importe solo porque la diferencia de saldos o totales sugiere otro número.
3. Conservar el original, candidatos y procedencia. Una corrección humana es un evento separado; no sobrescribe silenciosamente la evidencia automática.
4. Repetir OCR con distintas imágenes no constituye evidencia independiente. La confianza de Vision tampoco equivale a precisión financiera.
5. No tratar fecha + importe + descripción como identificador único: dos operaciones legítimas pueden ser iguales. Para unir observaciones del mismo documento usar página, región, sección y correspondencia inequívoca.
6. Un estado pendiente puede persistirse como borrador, pero sus filas no deben entrar parcialmente al libro ni a los indicadores oficiales.
7. Las categorías/comercios no deciden si una lectura financiera es válida. La clasificación remota existente no se invoca desde esta importación ni es necesaria para terminarla.

## Fase 0 — Línea base y reproducción

Antes de editar, ejecutar `git status --short`, revisar instrucciones aplicables y conservar cambios ajenos. Leer `apps/ios/README.md`, `apps/ios/TESTFLIGHT.md`, `docs/FINANCE_PIPELINE.md`, `docs/native-row-audit.md`, `docs/native-device-certification.md` y los documentos por banco relevantes.

Inventariar el flujo real de cada emisor: extracción, reconstrucción, OCR, reparación, selección, conciliación, persistencia y presentación. Revisar especialmente reparaciones numéricas basadas en diferencias de saldo y su evidencia. Registrar qué piezas se mantienen, encapsulan o sustituyen.

Ejecutar el lector nativo actual contra el corpus privado con expectativas por fila. Registrar por archivo: hash, versión, método, filas correctas/omitidas/adicionales, signos, controles, estado final, duración y dispositivo/iOS. Mantener datos sensibles fuera de los artefactos públicos.

Incluir PDFs que ya funcionan y los que fallan, texto desordenado, escaneos, páginas mixtas, tablas de varias páginas, descripciones multilínea, cargos iguales legítimos, créditos, pagos, MSI y moneda extranjera. Agregar casos sintéticos cuando falten ejemplos, marcándolos como tales.

**Salida:** diagnóstico reproducible y tabla de fallos por causa. Si falta Mac o iPhone, continuar con código y pruebas disponibles, dejando explícitamente pendiente la medición nativa; nunca sustituirla por resultados web.

## Fase 1 — Contrato común y coordinador

Introducir módulos pequeños; los nombres siguientes son propuestas, adaptables a las convenciones del proyecto:

- `StatementReadPipeline.swift`: orden de etapas, progreso, cancelación y presupuesto de trabajo.
- `StatementReadCandidate.swift`: observaciones, movimientos candidatos, controles y procedencia.
- `StatementReadValidator.swift`: validación reutilizable para cualquier estrategia.
- `StatementRecoveryPlanner.swift`: decide las páginas/regiones que requieren otro intento.

Extraer responsabilidades de `Models.swift` de forma incremental. Mantener un adaptador al `PDFImportExtraction` actual hasta completar la migración.

Contrato mínimo de candidato: identificador, hash del documento, estrategia y versión, emisor/cuenta/periodo con evidencia, páginas cubiertas, movimientos, controles impresos con ubicación, regiones sin resolver, fallos tipados y duración. Cada fila debe mantener texto original, fecha, importe en centavos, dirección, moneda, sección, página y bounds cuando estén disponibles. Las coordenadas deben usar una convención documentada y transformaciones probadas para PDF, Vision y recortes.

Separar tres conceptos: resultado de extracción, resultado de validación y decisión de admisión. Estados propuestos: procesando, requiere revisión, listo, guardado, cancelado y error recuperable. Que un intento falle no debe borrar un candidato anterior.

**Salida:** el coordinador reproduce los resultados de la línea base usando los lectores existentes. Refactorizar primero sin cambiar las decisiones de aceptación.

## Fase 2 — Lectura de texto y geometría

Orden de estrategias:

1. Texto seleccionable con límites de página y lectores actuales.
2. Reconstrucción por posición mediante `SelectablePDFLayout` si la primera lectura no valida.
3. Validación de cada conjunto completo antes de elegirlo.

Preservar columnas, encabezados, secciones y continuaciones entre páginas. Detectar páginas sin texto y zonas con anclas de movimiento no explicadas por las filas extraídas. No inferir cobertura completa solo por longitud de texto o coincidencia de sumas.

Un fallo debe describir lo que falta: fecha inválida, importe ambiguo, signo ausente, columna no calibrada, control ilegible, periodo desconocido, tabla incompleta o conflicto entre candidatos. Esta información alimenta el plan de recuperación.

Si el texto ya cumple todos los criterios de admisión, terminar sin OCR. Si solo falta un control de portada, recuperar esa región antes de releer todas las tablas.

**Salida:** PDFs válidos conservan la ruta rápida; PDFs con texto abundante pero incorrecto sí avanzan a recuperación.

## Fase 3 — Recuperación con Vision

Encapsular el OCR actual en un servicio reutilizable, por ejemplo `StatementVisionReader.swift`. Consultar lenguajes disponibles y conservar las recuperaciones de configuración existentes. Procesar páginas secuencialmente inicialmente; mantener PDFDocument/PDFPage dentro del contexto de ejecución que los posee y transferir resultados de valor al hilo principal.

Elegir páginas relevantes con evidencia de cobertura. Si no se puede localizar el fallo, recorrer todas las páginas necesarias del estado; no saltarse una continuación porque no repite encabezado.

Sustituir la prohibición global de OCR de Amex por la regla común: texto válido termina; texto fallido permite candidato Vision independiente. Probar pagos, créditos, MSI, secciones extranjeras y filas multilínea antes de habilitar aceptación automática de esta ruta.

Reutilizar los lectores visuales BBVA/Santander y la recuperación Rappi. Conservar resultados independientes: ejecutar OCR no significa que su resultado deba reemplazar automáticamente al texto.

**Salida:** los cuatro emisores pueden llegar a OCR cuando corresponde, con los mismos requisitos financieros y de evidencia.

## Fase 4 — Relectura dirigida y selección

Crear `StatementRegionRecovery.swift` o equivalente. A partir de los fallos, recortar filas/columnas/controles con margen suficiente para conservar fecha, signo y contexto. Renderizar desde el PDF original; ampliar una imagen ya pequeña no añade detalle.

Presupuesto inicial configurable para la prueba: una pasada OCR de página y hasta dos variantes por región, máximo doce regiones por documento. Si el documento requiere más, devolver revisión o permitir continuar explícitamente. Ajustar esos valores con medidas en el iPhone de referencia; no presentarlos como óptimos demostrados.

Variantes: mayor resolución acotada por píxeles, escala de grises/contraste moderado y lectura numérica sin corrección lingüística. Conservar también la lectura original. Liberar imágenes entre operaciones, atender cancelación y registrar agotamiento del presupuesto como tal.

Selección:

- Preferir un candidato completo que supere todos los controles y tenga cobertura verificable.
- Si dos candidatos válidos difieren en campos financieros, abrir un conflicto; ni confianza ni velocidad desempatan automáticamente.
- Integrar una recuperación regional solo cuando la correspondencia con la fila/región original sea inequívoca. Conservar evidencia por campo y ejecutar nuevamente validación y conciliación del documento completo.
- Mantener juntas operaciones idénticas legítimas; eliminar únicamente observaciones repetidas de la misma región.
- Si las sumas cuadran pero quedan regiones de movimientos sin explicar, requerir revisión.

**Salida:** rescate localizado y acotado, sin ajustes contables para forzar aceptación.

## Fase 5 — Revisión en el iPhone

Integrar el flujo en `Sections.swift` y los componentes existentes de importación/visor. Crear `StatementReviewView.swift` si facilita aislarlo.

Mostrar progreso comprensible: “Leyendo documento”, “Revisando movimientos”, “Releyendo 2 zonas” y “Hay 3 filas por revisar”. El usuario no necesita elegir motores ni conocer Vision.

Para cada problema mostrar el fragmento original con contexto, la lectura obtenida, alternativas disponibles y causa. Permitir corregir fecha, descripción, importe y cargo/abono; agregar una fila omitida vinculada a su región o descartar una fila administrativa con motivo. La revisión de controles impresos debe estar separada de la edición de movimientos.

Registrar antes/después, origen de la corrección, documento, región y fecha. Revalidar tras cada corrección y conciliar antes de guardar. La confirmación humana no equivale a un botón para ignorar diferencias. Distinguir lecturas automáticas de estados corregidos manualmente.

Usar borradores persistentes: cerrar, cancelar o reiniciar no debe perder correcciones ni incorporar movimientos incompletos. El PDF original debe permanecer disponible para revisar. Probar zoom, giro, navegación y alineación del recorte.

**Salida:** un documento recuperable puede completarse en modo avión, incluyendo correcciones y guardado.

## Fase 6 — Persistencia, caché y rendimiento

Integrar con `PDFReadingCache.swift`, `importPDFAsync` y la reconstrucción del libro. Versionar caché con hash, lector, estrategia/configuración, overrides de cuenta/tipo y versión de correcciones aplicable. No reutilizar evidencia incompatible tras cambiar esas entradas.

Guardar el estado y sus movimientos como una única operación lógica; reimportar el mismo PDF o releer uno existente no puede duplicar el libro. Preservar categorías y correcciones cuando exista correspondencia comprobable; resolver ambigüedades de migración en revisión.

Mantener límites actuales de tamaño/páginas salvo cambio justificado. Incorporar límites de píxeles, número de intentos y concurrencia; medir tiempos por etapa y memoria máxima. Cancelar entre páginas/regiones y solicitudes Vision cuando la API lo permita. La interfaz debe seguir respondiendo durante todo el proceso.

No registrar texto bancario en logs públicos. Conservar protección de archivos y exclusión de evidencias privadas de exportaciones sanitizadas. No reanalizar documentos al abrir cada pantalla.

## Fase 7 — Pruebas y certificación

Ampliar las pruebas de `apps/ios/Tests`, especialmente `ReaderContractTests`, `SelectablePDFLayoutTests`, `PDFReadingCacheTests`, `NativeRowAuditTests`, `NativeCorpusContractTests`, `RappiReaderTests`, `RappiSharedEngineTests`, `SantanderIndependentRowsTests` y `AmexDiagnosticTests` según corresponda.

Casos obligatorios:

- Texto válido evita OCR; texto inválido activa recuperación; Amex fallido llega a Vision.
- OCR vacío o error conserva diagnóstico anterior; cancelación no deja commit parcial.
- PDF mixto y tabla continuada conservan todas las páginas relevantes.
- Dos lecturas que cuadran pero difieren en filas requieren revisión.
- Dos errores compensados no pasan por coincidencia de total.
- Operaciones idénticas legítimas permanecen; recortes solapados no duplican filas.
- Signo ilegible no se convierte por defecto en cargo; saldos no se confunden con importes.
- Recortes conservan coordenadas correctas con páginas rotadas.
- Corrección manual revalida, persiste y se distingue de aceptación automática.
- Cache hit, invalidación, corrupción y reimportación no alteran el libro.
- El flujo completo funciona en modo avión con el archivo disponible en el dispositivo.

Ejecutar `npm test`, `npm run lint` y `npm run build` para regresión del repositorio. Si cambia el motor compartido, ejecutar `npm run rappi:engine:build` y validar el recurso generado. En macOS generar el proyecto con XcodeGen y ejecutar XCTest con un simulador realmente disponible.

Ejecutar el runner privado con las variables documentadas:

```sh
MARCELITO_PDF_CORPUS_DIR=/ruta/privada/estados \
MARCELITO_PDF_CORPUS_MANIFEST=/ruta/privada/corpus-ios.json \
MARCELITO_PDF_CORPUS_VERIFY=1 \
MARCELITO_PDF_CORPUS_REQUIRE_CERTIFIED=1 \
./apps/ios/scripts/run-native-corpus.sh
```

Actualizar versión, esquema y verificadores si el nuevo pipeline agrega métodos/estados. No renombrar evidencia de recortes o revisión manual como texto automático para satisfacer un manifiesto antiguo. No actualizar expectativas automáticamente a lo que produzca el lector.

El umbral agregado existente del 97% no sustituye estas condiciones: cero aceptaciones automáticas incorrectas en el corpus; coincidencia exacta de fecha/importe/signo y multiplicidad para todas las filas aceptadas contra goldens; controles exactos; ningún documento antes correcto empeora sin causa analizada. Medir recuperación automática y recuperación asistida por separado. Reportar resultados como n/N y por banco/plantilla; no prometer precisión universal fuera del corpus.

Comparar latencia mediana y peor caso, memoria, reintentos y cancelación en un iPhone físico identificado. Establecer presupuestos finales a partir de la línea base y documentarlos. Una prueba en simulador no certifica rendimiento ni interacción real.

## Entregas y orden recomendado

1. Diagnóstico y línea base; pruebas que reproduzcan los fallos seleccionados.
2. Contratos y coordinador con comportamiento equivalente.
3. Validación compartida y recuperación texto → geometría → Vision en los cuatro emisores.
4. Recuperación regional, cobertura y resolución de conflictos.
5. Revisión asistida, borradores, correcciones y guardado atómico.
6. Caché/migración, medición, corpus completo y prueba en iPhone.

Cada entrega debe dejar compilación y pruebas relevantes operativas. Implementar todas las etapas para completar el encargo; no detenerse después del refactor o de una demostración sintética. Si el corpus o el dispositivo no están disponibles, terminar el trabajo independiente y señalar exactamente qué validación queda pendiente.

## Instrucción lista para delegar a Luna

Implementa `docs/ios-local-reader-luna-plan.md` en el checkout actual. El objetivo es importar estados de BBVA, Santander, Amex y RappiCard completamente en el iPhone: texto, geometría, Vision y relectura regional con validación común, revisión asistida y persistencia atómica. Inspecciona primero el estado de Git y el flujo nativo existente; reutiliza sus recuperaciones. Cambia explícitamente la excepción que impide OCR de Amex y sus pruebas, sin debilitar validación. Conserva originales, trazabilidad por fila/campo y distinción entre corrección humana y lectura automática. No envíes documentos fuera del dispositivo ni agregues Python o modelos remotos. Ejecuta las pruebas disponibles y la certificación nativa cuando el entorno lo permita. Entrega cambios, comparación antes/después y pendientes de verificación reales. Este encargo autoriza implementación y validación; no publicar TestFlight ni modificar estados externos de certificación como parte de este plan.
