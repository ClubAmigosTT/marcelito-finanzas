# Auditoría independiente del lector iOS

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

- Lectura geométrica y caché: implementadas, sujetas a pruebas nativas.
- Auditoría por filas y runner: implementados.
- Referencia visual privada: iniciada; no representa todavía todo el corpus.
- Certificación de los once documentos y publicación: pendientes de la corrida
  nativa completa con referencias revisadas. No usar el modo bootstrap como
  evidencia de que el lector está corregido.
