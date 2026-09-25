# Diagnóstico del lector sin Mac

Marcelito puede medir el lector nativo directamente en un iPhone. La
herramienta usa el mismo PDFKit + Vision de producción, siempre dentro del
dispositivo. Trabaja sobre una selección temporal de estados y no escribe
movimientos en el libro canónico. La publicación requiere además el runner
privado con goldens por fila. OpenCode Zen no participa en la lectura ni en la
conciliación de PDFs; se reserva para clasificar gastos después.

## Ejecutar en el iPhone

Esta herramienta ofrece dos perfiles de diagnóstico: el general, con 10
archivos o más, y `rappi-focused`, con seis o más tarjetas Rappi procesadas por
el lector local. Un archivo puede usar texto nativo de PDFKit u OCR de Vision.
El resultado de esta pantalla demuestra que el lector procesó los documentos,
pero no certifica por sí solo cada movimiento. La publicación usa el runner
privado y el manifiesto de filas exactas descritos más abajo.

1. Abre **Resumen → Opciones → Diagnóstico → Diagnosticar estados con Vision**.
2. Selecciona los 22 PDFs del corpus aprobado para una publicación general, o
   seis estados Rappi solo para una regresión enfocada.
3. Pulsa **Ejecutar diagnóstico** y espera a que termine cada PDF.
4. El perfil Rappi solo se acepta si todos los archivos son tarjetas Rappi,
   usan `pdf-text` o `vision-ocr`, están conciliados, tienen emisor verificado
   y no tienen revisión pendiente. El perfil general conserva las mismas
   reglas y requiere al menos 10 archivos. Para OCR, el lector exige una
   confianza media ≥ 88% y una página más débil ≥ 78% cuando no existe una
   prueba independiente exacta. Una auditoría independiente que coincida por
   fila, página, importe, fecha y conciliación permite conservar estados con
   puntuación OCR bruta menor; sin esa prueba el estado queda bloqueado. Las
   tarjetas Rappi no necesitan calibración de columnas bancarias; Santander sí
   exige columnas calibradas.
5. Comparte **informe JSON** para inspección. El archivo está sanitizado: no
   contiene PDFs, descripciones, saldos ni importes. No lo uses como
   certificación final sin el informe generado por el runner privado.

El informe conserva hashes SHA-256 y señales de calidad para demostrar que los
archivos fueron procesados, pero no permite reconstruir un estado de cuenta.
Un PDF duplicado o un estado pendiente bloquea la certificación completa.

Para comparar el lector nativo con una implementación independiente, el runner
también ofrece un export privado optativo. Este archivo sí contiene las filas
candidatas, conceptos e importes, por lo que debe quedarse fuera del repositorio
y usarse solo para preparar una referencia revisada:

```bash
MARCELITO_PDF_CORPUS_DIR=/ruta/privada/estados \
MARCELITO_PDF_CORPUS_EXPORT_PRIVATE_DIAGNOSTICS=1 \
MARCELITO_PDF_CORPUS_PRIVATE_EXPORT=/ruta/privada/native-audit.json \
./apps/ios/scripts/run-native-corpus.sh
```

El export es evidencia de comparación, no un golden. La referencia final debe
provenir de una segunda lectura revisada contra el PDF y conservarse con
`referenceMethod: "visual-independent"`.

La identidad de cuenta es una compuerta independiente de las filas. El lector
busca primero el encabezado seleccionable del mismo PDF; si PDFKit conserva la
etiqueta pero pierde el número, ejecuta una pasada Vision acotada a las dos
primeras páginas solo para recuperar la máscara `emisor:últimos4`. Esa pasada
no aporta movimientos ni controles. Si no obtiene una máscara válida, el
estado queda en revisión y la comparación privada falla cerrada.

El comparador privado deja solo conteos y tipos de discrepancia en su salida:

La comparación exige la misma huella del PDF, emisor, cuenta enmascarada,
cantidad de filas, fecha, importe y página. El concepto debe coincidir después
de normalizar acentos y espacios. Las diferencias de tipo (`compra`, `pago de
tarjeta`, `devolución`, etc.) se conservan como `semanticReview` y también
dejan el archivo en `review`: pueden ser una taxonomía distinta entre lectores,
pero también cambiarían el flujo financiero. El campo `coreOutcome` sirve solo
para diagnosticar que fecha, importe, concepto y página coinciden; no autoriza
una certificación. Un archivo con diferencias de fecha, importe, concepto,
página, identidad, clasificación o estructura permanece en `review`.
El resultado de este comparador usa `schemaVersion: 2`; un reporte anterior no
debe reutilizarse como evidencia de publicación.

```bash
npm run pdf:native:compare -- \
  --native /ruta/privada/native-audit.json \
  --independent /ruta/privada/.web-independent-text.json \
  --out /ruta/privada/row-comparison.json
```

Para preparar la revisión visual sin copiar datos financieros, genera una cola
privada con solo documentos, ordinales de fila y categorías de discrepancia:

```bash
npm run pdf:native:review-queue -- \
  --comparison /ruta/privada/row-comparison.json \
  --out /ruta/privada/visual-review-queue.json
```

La cola es una lista de trabajo, no una referencia dorada. Después de revisar
cada fila contra el PDF, los resultados deben transcribirse al manifiesto
`visual-independent`; la cola por sí sola nunca habilita una publicación.

También se puede generar un borrador privado con la salida del lector
independiente para acelerar esa transcripción. Sus campos se llaman
`titleCandidate` y `kindCandidate` deliberadamente: el verificador no los
acepta como expectativas certificadas.

```bash
npm run pdf:native:reference-draft -- \
  --independent /ruta/privada/.web-independent-ocr.json \
  --native /ruta/privada/native-audit.json \
  --out /ruta/privada/visual-reference-draft.json
```

## Publicación posterior

El workflow `iOS TestFlight` valida `docs/native-corpus-certification.json`
contra la versión actual (`FinanceStore.readerVersion`), exige exactamente 22
archivos, auditoría por fila y prueba independiente para OCR. Si el informe no
coincide, está vencido, contiene una fila incompleta o queda por debajo de 97%,
la build se detiene. El modo bootstrap falla deliberadamente si intenta
publicar; no hay una variable booleana alternativa.

## Auditoría nativa con un manifiesto privado

Si además de la conciliación del banco quieres comparar cada estado contra
expectativas doradas, guarda un manifiesto fuera del repositorio y ejecútalo
con el runner de XCTest. El archivo privado contiene hashes, controles y
referencias mínimas por fila; nunca incluye los PDFs ni descripciones completas
de movimientos:

```json
{
  "schemaVersion": 1,
  "readerVersion": "ios-reader-AAAA.MM.DD.NN",
  "files": [
    {
      "file": "estado-agosto.pdf",
      "sourceFingerprint": "<sha256 de 64 caracteres>",
      "source": "Santander",
      "accountKey": "santander:7079",
      "kind": "bank",
      "status": "valid",
      "rows": 43,
      "rowExpectations": [
        {
          "date": "2026-08-14",
          "page": 2,
          "signedAmount": "-123.45",
          "titleContains": "comercio revisado",
          "kind": "Compra"
        }
      ],
      "summary": {
        "previousBalance": 55627.93,
        "cashBalance": 27654.24,
        "depositTotal": 36187.42,
        "withdrawalTotal": 64161.11
      }
    }
  ]
}
```

`status: "valid"` exige `rows` y exactamente una `rowExpectation` por cada
movimiento, incluyendo su `kind`; para un escaneo todavía en calibración se
puede usar `status: "pending"`. Los importes también aceptan texto con coma
decimal y los nombres `extractedDepositTotal`, `extractedWithdrawalTotal`,
`extractedChargeTotal` y equivalentes del reporte web. La versión debe
coincidir exactamente con `FinanceStore.readerVersion`; si cambia una regla,
el manifiesto queda vencido y hay que volver a medirlo.

En macOS:

```bash
MARCELITO_PDF_CORPUS_DIR=/ruta/privada/estados \
MARCELITO_PDF_CORPUS_MANIFEST=/ruta/privada/corpus-ios.json \
MARCELITO_PDF_CORPUS_VERIFY=1 \
MARCELITO_PDF_CORPUS_REQUIRE_CERTIFIED=1 \
./apps/ios/scripts/run-native-corpus.sh
```

El runner comprueba que el directorio y el manifiesto tengan exactamente el
mismo conjunto de archivos, verifica SHA-256, emisor, cuenta enmascarada,
filas, controles de saldo, conciliación y cada fecha/importe/página/concepto de
`rowExpectations`. Conserva el `.xcresult` para reproducir un fallo. El fixture
sintético público se sigue usando cuando no se define
`MARCELITO_PDF_CORPUS_MANIFEST`.

Después de que el verificador del log termine sin errores, crea el JSON
sanitizado que sí entra al repositorio:

```bash
npm run pdf:native:report -- \
  --log /ruta/privada/xcodebuild.log \
  --output docs/native-corpus-certification.json \
  --reader-version ios-reader-recovery-2026.09.25.15 \
  --expected-files 22
```

El constructor elimina las expectativas de filas, títulos e importes y vuelve
a ejecutar la validación estricta sobre el artefacto antes de escribirlo.

Los estados permanecen en el iPhone durante toda la certificación. El JSON se
puede revisar antes de publicarlo. Si un archivo falla, corrígelo o vuelve a
seleccionarlo; nunca se debe marcar `certified` manualmente. Zen solo puede
recibir posteriormente descripciones, fechas e importes de gastos ya
conciliados desde la pantalla de Movimientos, nunca el PDF.
