# Validación privada de cuatro Santander y tres Amex

## Ejecutar desde Windows o macOS

```text
npm run pdf:validate-private-formats
```

El comando revisa las copias privadas y los controles de
`private-corpus/amex-santander/{santander,amex}/controls.expected.json`.
Lee la versión vigente de `Models.swift`, no una versión escrita manualmente.
No importa estados al libro, modifica parsers, publica ni envía documentos.

Produce `private-corpus/amex-santander/latest-validation.json`, con resultado
por documento y comparación de controles en centavos enteros. Los importes
solo aparecen en ese archivo privado; la consola muestra conteos y códigos.
El comando sobrescribe únicamente su propio informe de última ejecución.

Salida 0: los siete documentos cumplen las comprobaciones suministradas.
Salida 1: datos o evidencia pendientes/inconsistentes. Salida 2: entradas
ilegibles o inválidas. Ni siquiera una salida 0 certifica BBVA o toda la app.
Los archivos JSON/log recibidos no son una atestación criptográfica del dispositivo.

## Evidencia necesaria por banco

Además de `pdfs/` y `controls.expected.json`, colocar en la carpeta de cada banco:

- `native.log`: log original del runner de macOS, con exactamente un
  `NATIVE_CORPUS_REPORT` y un `NATIVE_CORPUS_SUMMARY` de esa ejecución.
- `row-diagnostics.json`: exportación privada del certificador iOS de los mismos
  archivos, con `candidateRows` y diagnósticos por fila, en la misma versión.

No concatenar ejecuciones ni editar una exportación para hacerla aprobar. Las
huellas deben vincular cada resultado con su PDF. Cada log/exportación debe
contener exactamente los documentos de ese banco. Los archivos personales
deben permanecer en el entorno privado, nunca en CI pública ni en TestFlight.

Para producir el log en un Mac privado, desde la raíz del repositorio:

```bash
set -o pipefail
MARCELITO_PDF_CORPUS_DIR="$PWD/private-corpus/amex-santander/santander/pdfs" \
MARCELITO_PDF_CORPUS_MANIFEST="$PWD/private-corpus/amex-santander/santander/controls.expected.json" \
./apps/ios/scripts/run-native-corpus.sh 2>&1 | tee private-corpus/amex-santander/santander/native.log
```

Repetir con `amex` en ambas rutas y el destino del log. No usar un log de
pruebas sintéticas de CI como sustituto. El exportador del iPhone se abre desde
"Certificar lector" → elegir solo los PDFs de ese banco → ejecutar →
"Compartir diagnóstico por fila". Debe usar la versión que exige el validador.

La referencia independiente por defecto es `private-corpus/independent-rows.json`.
Se puede indicar otra colección y referencia:

```text
node scripts/validate-private-formats.mjs <carpeta-privada> <referencia-independiente.json>
```

La referencia se revisa directamente contra las páginas originales, no se
genera copiando la salida del parser. Si falta un documento, queda pendiente.
Sus conteos de filas deben contrastarse también con los controles heredados.

## Condiciones de aprobación

- Integridad SHA-256, encabezado PDF y conjunto cerrado de siete originales.
- Identidad de emisor/cuenta/tipo y versión del lector coherentes.
- Amex mediante texto nativo; Santander mediante Vision y columnas reconocidas.
- Todos los estados válidos, sin revisión, rechazos ni documentos duplicados.
- Controles oficiales y resultados nativos iguales en centavos, sin tolerancia.
- Santander: depósitos/retiros calculados también desde las filas exportadas.
- Fecha, página, descripción e importe con signo iguales a la referencia por
  ocurrencia; un error compensado por otro no pasa.

La ejecución inicial tiene siete copias íntegras, pero carece de logs/exportaciones
nativas y solo cuenta con referencia independiente para uno de los siete
documentos. Por ello no acredita todavía conciliación correcta.

## Pruebas del validador

`npm run test:private-formats` ejecuta casos sintéticos sin datos personales.
También forman parte de `npm test`. No sustituyen la ejecución sobre originales.
