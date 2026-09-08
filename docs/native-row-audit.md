# Auditoría independiente del lector iOS

## Corrección Santander — lector 2026.09.07.5

La extracción mantiene filas físicas ancladas a FECHA dentro de la tabla de
cheques. Los importes requieren cajas contenidas en las columnas fijas; las
continuaciones se conservan en la descripción sin crear movimientos.

La validación compara cada importe con los dos saldos **impresos** adyacentes,
no con el último movimiento aceptado. Una celda inválida no provoca una cascada
de rechazos usando un saldo antiguo. Si falta un saldo se rompe ese enlace y
se retoma la comprobación cuando vuelven a existir dos controles legibles.
Una fila sin validar sigue bloqueando el estado completo, incluso cuando los
errores se compensan en la suma. La misma compuerta protege importar y certificar.

Las celdas ambiguas o cuya ecuación falla se releen una vez mediante recortes
fijos de DEPÓSITO, RETIRO y SALDO usando PDFKit/Vision. La confianza media de
página no impide este reintento. No se inventa un importe a partir de la
diferencia de saldos. El informe privado conserva texto original, textos de
las tres celdas (en ese orden), ordinal, página, banda normalizada y resultado
del reintento. Los errores públicos excluyen saldos y descripciones.

`SantanderIndependentRowsTests` cubre geometría, errores localizados,
compuertas y una recuperación con Vision sobre un PDF generado. Estas pruebas
son sintéticas. Tampoco los controles aritméticos de dos filas por periodo
acreditan la lectura de los cuatro estados originales. Antes de distribuir
como corregido, ejecutar la auditoría privada descrita abajo, comparando todas
las filas y los totales al centavo. No subir los PDFs a la CI pública.

Una compilación correcta y un informe del lector web no certifican PDFKit/Vision.
La prueba `NativeRowAuditTests` usa los PDFs privados con el extractor de producción
y compara cada ocurrencia contra una referencia transcrita de las páginas originales.
Se comprueban cuenta, emisor, periodo, fecha, página, descripción e importe con signo.
La comparación conserva ocurrencias repetidas y detecta errores que se compensan
en una suma. El diagnóstico usa ordinales y campos, sin imprimir datos privados.

## Ejecución en macOS

```bash
MARCELITO_PDF_ROW_MANIFEST=/ruta/privada/independent-rows.json \
MARCELITO_PDF_CORPUS_DIR=/ruta/privada/pdfs \
./apps/ios/scripts/run-native-corpus.sh
```

El runner resuelve la raíz y el directorio de Xcode y transmite las variables
al `TestAction` del esquema generado, no solo al proceso `xcodebuild`.
El esquema resultante contiene rutas privadas y no debe subirse al repositorio.

Una referencia parcial sirve para diagnosticar un documento. Para certificar
se requiere además el manifiesto completo de controles existente y:

```bash
MARCELITO_PDF_CORPUS_REQUIRE_CERTIFIED=1 \
MARCELITO_PDF_CORPUS_VERIFY=1 \
MARCELITO_PDF_CORPUS_MANIFEST=/ruta/privada/controls.json \
MARCELITO_PDF_ROW_MANIFEST=/ruta/privada/independent-rows.json \
MARCELITO_PDF_CORPUS_DIR=/ruta/privada/pdfs \
./apps/ios/scripts/run-native-corpus.sh
```

En ese modo, faltar la referencia o no cubrir todos los PDFs es un error.
Una prueba omitida en CI pública no demuestra la precisión del corpus real.
Las referencias y PDFs permanecen fuera de Git. El directorio `private-corpus/`
ya está ignorado. `referenceMethod: visual-independent` describe el proceso
humano de revisión; la etiqueta por sí sola no acredita que se haya realizado.

## Comportamiento de lectura y actualización

El lector intenta primero el texto original de PDFKit. Si falla la conciliación,
reconstruye palabras según sus coordenadas visuales antes de intentar Vision.
Solo adopta ese texto cuando las reglas de conciliación existentes lo aceptan.

Las importaciones reutilizan lecturas conciliadas de una caché privada protegida.
La clave incluye huella del PDF, versión del lector, nombre, opciones y reglas
de categoría. Cambiar cualquiera invalida esa entrada. La caché no duplica los
bytes del PDF, tiene un máximo de 128 entradas y es prescindible: si falta o está
dañada, se vuelve a leer. Las lecturas inciertas no se guardan y las auditorías
siempre fuerzan extracción fresca. Al reutilizar una lectura, el commit del libro
vuelve a aplicar sus controles normales.

Esto evita repetir PDFKit/Vision sobre documentos ya comprobados en la misma
versión; no implementa aún versiones de parser independientes por banco ni
reemplaza la reconstrucción completa por una actualización del libro por periodo.

## Estado de implementación

### Auditoría desde Windows con un iPhone

El exportador privado incluye ahora `sourceFingerprint`, cuenta enmascarada,
periodo y `candidateRows` (fecha ISO local, página, importe con signo como texto
y descripción). Son candidatos, incluso cuando el estado está bloqueado;
no se incorporan por ello al libro canónico. El informe público no los incluye.

Después de ejecutar el certificador en el iPhone, usar **Compartir diagnóstico
por fila** y comparar localmente:

```powershell
node scripts/audit-native-rows.mjs private-corpus/independent-rows.json <exportacion-privada.json> ios-reader-2026.09.06.36
```

La comparación se hace por huella, no por nombre. Exige coincidencia de filas,
signos, fechas, páginas, descripción y versión; rechaza archivos sin referencia,
duplicados y exportaciones antiguas sin candidatos. Los importes se comparan en
centavos enteros sin redondear. Solo imprime ordinales y campos discrepantes.
Un resultado correcto no certifica clasificación, conciliación nativa ni toda
la colección: se necesita además el informe de certificación y referencia
completa. No subir estos dos archivos privados al repositorio ni a CI público.

Referencia privada revisada: cuatro archivos BBVA y Santander de agosto. Este
último requiere OCR en la extracción local comprobada; su referencia visual no
se debe confundir con una validación de Vision. Los seis archivos restantes
siguen pendientes de referencia independiente.

La comparación local de Santander de agosto detectó dos importes alterados por
un saldo OCR incorrecto: se compensaban en el total. Se eliminó del parser web
la reparación de importes plausibles basada solo en diferencias pequeñas del
saldo. Tras el cambio sus 43 filas coinciden con la referencia (fecha, página,
importe y fragmento de descripción). La prueba sintética reproduce el fallo
sin publicar cifras privadas. El parser nativo ya preservaba la columna
explícita en esta situación; se corrigió su diagnóstico para no afirmar que
el saldo confirma el importe cuando discrepa. Sigue pendiente probarlo sobre
el original con Vision.

- Lectura geométrica y caché: implementadas, sujetas a pruebas nativas.
- Auditoría por filas y runner: implementados.
- Referencia visual privada: iniciada; no representa todavía todo el corpus.
- Certificación de los once documentos y publicación: pendientes de la corrida
  nativa completa con referencias revisadas. No usar el modo bootstrap como
  evidencia de que el lector está corregido.
