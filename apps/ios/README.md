# Marcelito para iOS

Cliente nativo en SwiftUI para iOS 17 o posterior.

## Abrir en Xcode

1. Instala XcodeGen: `brew install xcodegen`.
2. Desde esta carpeta ejecuta `xcodegen generate`.
3. Abre `Marcelito.xcodeproj` y selecciona tu equipo de firma.
4. Ejecuta en un iPhone o en el simulador.

Para ejecutar el contrato del lector en un simulador disponible:

```bash
xcodegen generate --spec project.yml
xcodebuild -project Marcelito.xcodeproj -scheme Marcelito \
  -destination "platform=iOS Simulator,name=iPhone 16" test
```

Para medir los PDFs reales con el mismo lector Vision, conserva los archivos
fuera del repositorio y pasa la carpeta al test nativo. El test exige todos los
archivos del manifiesto, verifica los estados de texto disponibles y emite una línea
`NATIVE_CORPUS_REPORT` con el resultado de cada escaneo:

```bash
MARCELITO_PDF_CORPUS_DIR="/ruta/a/estados-validados" \
xcodebuild -project Marcelito.xcodeproj -scheme Marcelito \
  -destination "platform=iOS Simulator,name=iPhone 16" test
```

La misma corrida ejecuta además una prueba de seguridad sin manifiesto: cada PDF
real debe identificar un emisor, conservar páginas y diagnóstico por fila, no
seleccionar importes mayores de $10 millones y no alimentar el libro si la
conciliación es inválida. El diagnóstico privado puede compartirse desde la
pantalla de certificación; contiene el fragmento OCR, la columna, el importe y
la razón de cada fila. No se incluye en `NATIVE_CORPUS_REPORT` ni en el JSON que
se guarda en GitHub.

También puedes usar el runner reproducible desde esta carpeta o desde la raíz
del repositorio; conserva el
`.xcresult` y el log en un directorio temporal para adjuntarlos a la auditoría:

```bash
MARCELITO_PDF_CORPUS_DIR="/ruta/a/estados-validados" \
  ./scripts/run-native-corpus.sh
```

Para validar automáticamente el log contra el manifiesto al terminar la
corrida, añade `MARCELITO_PDF_CORPUS_VERIFY=1`. Si además defines
`MARCELITO_PDF_CORPUS_REQUIRE_CERTIFIED=1`, el runner devuelve error mientras
el corpus no cumpla el 97%:

```bash
MARCELITO_PDF_CORPUS_VERIFY=1 \
MARCELITO_PDF_CORPUS_REQUIRE_CERTIFIED=1 \
MARCELITO_PDF_CORPUS_DIR="/ruta/a/estados-validados" \
  ./scripts/run-native-corpus.sh
```

Después de una corrida certificable, valida el resumen de XCTest antes de
registrar la versión en GitHub Actions. El verificador lee únicamente la línea
`NATIVE_CORPUS_SUMMARY` del log y falla si falta un golden, queda OCR pendiente,
hay falsos positivos o la precisión cae por debajo de 97%:

```bash
cd ../..
npm run pdf:native:verify -- \
  --log /ruta/al/xcodebuild.log \
  --manifest tests/fixtures/pdf-corpus-attachments.json \
  --reader-version ios-reader-2026.09.03.29 \
  --require-certified
```

El reporte incluye controles esperados y extraídos de saldo inicial, saldo
final, depósitos, retiros, cargos y pagos, además de confianza del emisor,
confianza OCR media y página OCR más débil. Todos los archivos deben identificar el emisor con estado
`verified`; los cuatro estados de texto validan también filas y totales como
aserciones duras. Los escaneos Santander se reportan para calibración mientras
permanezcan en `pending`.

El verificador también exige el `NATIVE_CORPUS_REPORT` por archivo: comprueba
que no falte ningún PDF, que no haya archivos repetidos, que el conjunto de
nombres coincida con el manifiesto y que cada `accountKey` sea únicamente
`emisor:últimos4` y coincida con su expectativa dorada. También exige la
huella SHA-256, emisor, tipo, estado de conciliación y conteo de filas de cada
registro, además de `sourceStatus=verified`, confianza del emisor y
`requiresReview`; contrasta esos campos contra el manifiesto. Un resumen
certificado sin trazabilidad por archivo no pasa la compuerta.

El contrato nativo también verifica el SHA-256 de cada PDF contra el manifiesto
privado del corpus. Si se sustituye, altera o renombra un archivo sin actualizar
su expectativa, la corrida falla antes de considerar sus filas como evidencia.

Al final se emite también `NATIVE_CORPUS_SUMMARY` con aceptados, bloqueados,
aceptaciones falsas, precisión automática, OCR pendiente y `certified`. La
bandera solo puede ser verdadera cuando todos los goldens están promovidos,
no hay falsos positivos, la precisión es ≥97% y no queda lectura visual sin resolver.
Para convertir esa condición en una compuerta de publicación, añade
`MARCELITO_PDF_CORPUS_REQUIRE_CERTIFIED=1` al comando; con esa variable el
test falla si `certified` es `false`. Sin ella, los goldens `pending` permiten
seguir calibrando Vision sin bloquear la iteración.

Los estados escaneados que sigan en `pending` no alimentan el libro; cuando
Vision concilie uno, se puede promover su expectativa a `valid` y exigir
también conteo exacto de filas en la siguiente corrida.

Las pruebas verifican que el emisor se identifica por el encabezado
institucional, que las filas administrativas se descartan y que un crédito de
Amex no termina como gasto. El workflow de GitHub las ejecuta automáticamente
en macOS. El corpus real no se incluye en CI porque contiene estados privados:
la certificación completa debe ejecutarse manualmente con
`MARCELITO_PDF_CORPUS_DIR` y `MARCELITO_PDF_CORPUS_REQUIRE_CERTIFIED=1`.

Para no depender de una Mac, los builds recientes incluyen un certificador en
**Resumen > Opciones > Diagnóstico > Certificar estados con Vision**. Selecciona
los estados privados directamente en el iPhone, ejecuta el lector nativo y
comparte el informe JSON sanitizado. El informe de certificación no contiene
PDFs, descripciones, saldos ni importes; solo hashes y señales de calidad. El
botón separado **Compartir diagnóstico por fila** es privado y sí incluye el
texto OCR necesario para depurar una extracción. Guárdalo como
`docs/native-corpus-certification.json` para que el workflow lo valide antes de
publicar. La primera build que instala esta herramienta se ejecuta con la
opción de bootstrap del workflow; después la compuerta vuelve a exigir un
informe certificado de al menos 10 estados únicos.

Para una auditoría con expectativas doradas, el runner nativo admite además
`MARCELITO_PDF_CORPUS_MANIFEST` apuntando a un JSON privado fuera del checkout.
Ese manifiesto puede reutilizar el formato de
`tests/fixtures/pdf-corpus-attachments.json` (SHA-256, `emisor:últimos4`, tipo,
estado, filas y controles); la versión declarada debe ser igual a
`FinanceStore.readerVersion`. El script resuelve la ruta, exige que el conjunto
de nombres coincida con los PDFs y valida los controles con PDFKit + Vision:

```bash
MARCELITO_PDF_CORPUS_DIR=/ruta/privada/estados \
MARCELITO_PDF_CORPUS_MANIFEST=/ruta/privada/corpus-ios.json \
MARCELITO_PDF_CORPUS_VERIFY=1 \
./apps/ios/scripts/run-native-corpus.sh
```

El fixture público sigue siendo el predeterminado cuando no se define la
variable. Ninguno de estos modos copia PDFs, descripciones o importes privados
al repositorio.

La autenticación usa Keychain y Face ID. La aplicación inicia sin movimientos de muestra: importa tus PDFs desde Archivos, revisa banco, periodo y movimientos, y los guarda solo en ese dispositivo. Los estados escaneados pueden quedar pendientes de revisión sin inventar filas.

Movimientos y estados de cuenta se persisten localmente, se evita volver a contar el mismo archivo y las categorías se pueden corregir desde el detalle de cada movimiento. El menú de Inicio permite eliminar la cuenta y todos los datos locales.

En Cuentas > Movimientos puedes abrir la configuración de clasificación asistida. La clave de OpenCode Zen se guarda en el llavero del iPhone y solo se usa después de confirmar el envío de movimientos pendientes. El selector de la app contiene únicamente modelos gratuitos compatibles con el endpoint de chat (`mimo-v2.5-free`, `ling-3.0-flash-fin-free`, `nemotron-3-ultra-free`, `nemotron-3.5-lightning-free` y `big-pickle`).

Los PDFs importados se conservan en Application Support del dispositivo para que cada tarjeta de Documentos importados pueda abrir el archivo original sin mostrar nombres parseados en la pantalla principal. Vision conserva la página y la confianza real de cada observación OCR; si una fila queda por debajo del umbral, el estado requiere revisión y no entra en los KPI. Cuando el documento concilia pero la evidencia institucional del emisor es provisional, puedes confirmar manualmente el banco mostrado; esa liberación queda registrada como confirmación humana independiente de la aceptación automática.

La importación de la interfaz usa `importPDFAsync` y la reconstrucción de arranque usa `rebuildCanonicalLedgerIfNeededAsync`: la lectura PDFKit/Vision y el cálculo de huellas se ejecutan en tareas de fondo y el indicador de carga permanece visible mientras se procesa cada archivo. El libro canónico solo se actualiza después de terminar extracción, validación y conciliación; así una página pesada o un OCR lento no bloquea el hilo principal ni puede dejar un commit parcial.

Si el emisor o el tipo se detectan mal, abre **Cuentas > Editar cifras del corte**, corrige ambos campos y usa **Releer con esta configuración**. Marcelito vuelve a construir las filas desde el PDF original, registra la corrección como revisión manual y no libera el estado a los KPI hasta que la conciliación sea válida y se confirme.

El catálogo de iconos está en `Cauce/Assets.xcassets/AppIcon.appiconset`. Antes de TestFlight registra el Bundle ID `mx.marcelito.personal` y completa App Privacy, export compliance y screenshots en App Store Connect.
