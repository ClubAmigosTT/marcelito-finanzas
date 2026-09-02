# Certificación del lector sin Mac

Marcelito puede certificar el lector nativo directamente en un iPhone. La
herramienta usa el mismo PDFKit + Vision de producción y, si el usuario lo
activa, el respaldo multimodal de Zen. Trabaja sobre una selección temporal de
estados y no escribe movimientos en el libro canónico.

## Ejecutar en el iPhone

1. Abre **Resumen → Opciones → Diagnóstico → Certificar estados con Vision**.
2. Selecciona los 10 estados validados desde Archivos.
3. Si quieres el respaldo externo, configura OpenCode Zen y activa **Usar IA
   si Vision no concilia**. Los PDFs que ya concilien localmente no se envían.
4. Pulsa **Ejecutar lector** y espera a que termine cada PDF.
5. Solo se acepta un corpus con al menos 10 archivos únicos, todos conciliados,
   emisor verificado, sin revisión pendiente, OCR ≥ 88% y página más débil ≥
   78%. Para Santander también deben estar calibradas las columnas.
6. Comparte **informe JSON** y guárdalo como
   `docs/native-corpus-certification.json` en el repositorio. El archivo está
   sanitizado: no contiene PDFs, descripciones, saldos ni importes.

El informe conserva hashes SHA-256 y señales de calidad para demostrar que los
archivos fueron procesados, pero no permite reconstruir un estado de cuenta.
Un PDF duplicado o un estado pendiente bloquea la certificación completa.

## Publicación posterior

El workflow `iOS TestFlight` valida automáticamente ese JSON contra la versión
actual (`FinanceStore.readerVersion`). Si el informe no coincide, está vencido,
contiene una fila incompleta o queda por debajo de 97%, la build se detiene.

La primera build que incluye esta herramienta se ejecuta manualmente con la
opción **Bootstrap: incluir la herramienta de certificación local**. Esa opción
solo instala el certificador; no certifica el corpus por sí misma. Después de
subir el informe sanitizado al repositorio, las siguientes builds vuelven a usar
la compuerta normal y ya no requieren una Mac externa.

## Auditoría nativa con un manifiesto privado (opcional)

Si además de la conciliación del banco quieres comparar cada estado contra
expectativas doradas, guarda un manifiesto fuera del repositorio y ejecútalo
con el runner de XCTest. El archivo solo contiene hashes y controles; nunca
incluye los PDFs ni las descripciones de movimientos:

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

`status: "valid"` exige `rows`; para un escaneo todavía en calibración se
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
./apps/ios/scripts/run-native-corpus.sh
```

El runner comprueba que el directorio y el manifiesto tengan exactamente el
mismo conjunto de archivos, verifica SHA-256, emisor, cuenta enmascarada,
filas, controles de saldo y conciliación, y conserva el `.xcresult` para
reproducir un fallo. El fixture sintético público se sigue usando cuando no
se define `MARCELITO_PDF_CORPUS_MANIFEST`.

Sin respaldo externo, los estados permanecen en el iPhone. Con Zen activado,
solo los documentos que no concilien localmente salen temporalmente del
dispositivo. El JSON se puede revisar antes de publicarlo. Si un archivo falla,
corrígelo o vuelve a seleccionarlo; nunca se debe marcar `certified`
manualmente.
