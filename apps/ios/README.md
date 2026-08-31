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
fuera del repositorio y pasa la carpeta al test nativo. El test exige los ocho
archivos del manifiesto, verifica los cuatro estados de texto y emite una línea
`NATIVE_CORPUS_REPORT` con el resultado de cada escaneo:

```bash
MARCELITO_PDF_CORPUS_DIR="/ruta/a/estados-validados" \
xcodebuild -project Marcelito.xcodeproj -scheme Marcelito \
  -destination "platform=iOS Simulator,name=iPhone 16" test
```

También puedes usar el runner reproducible desde esta carpeta; conserva el
`.xcresult` y el log en un directorio temporal para adjuntarlos a la auditoría:

```bash
MARCELITO_PDF_CORPUS_DIR="/ruta/a/estados-validados" \
  ./scripts/run-native-corpus.sh
```

Después de una corrida certificable, valida el resumen de XCTest antes de
registrar la versión en GitHub Actions. El verificador lee únicamente la línea
`NATIVE_CORPUS_SUMMARY` del log y falla si falta un golden, queda OCR pendiente,
hay falsos positivos o la precisión cae por debajo de 99%:

```bash
cd ../..
npm run pdf:native:verify -- \
  --log /ruta/al/xcodebuild.log \
  --manifest tests/fixtures/pdf-corpus-attachments.json \
  --reader-version ios-reader-2026.08.31.14 \
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
`emisor:últimos4` y coincida con su expectativa dorada.

El contrato nativo también verifica el SHA-256 de cada PDF contra el manifiesto
privado del corpus. Si se sustituye, altera o renombra un archivo sin actualizar
su expectativa, la corrida falla antes de considerar sus filas como evidencia.

Al final se emite también `NATIVE_CORPUS_SUMMARY` con aceptados, bloqueados,
aceptaciones falsas, precisión automática, OCR pendiente y `certified`. La
bandera solo puede ser verdadera cuando todos los goldens están promovidos,
no hay falsos positivos, la precisión es ≥99% y no queda OCR sin resolver.
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

La autenticación usa Keychain y Face ID. La aplicación inicia sin movimientos de muestra: importa tus PDFs desde Archivos, revisa banco, periodo y movimientos, y los guarda solo en ese dispositivo. Los estados escaneados pueden quedar pendientes de revisión sin inventar filas.

Movimientos y estados de cuenta se persisten localmente, se evita volver a contar el mismo archivo y las categorías se pueden corregir desde el detalle de cada movimiento. El menú de Inicio permite eliminar la cuenta y todos los datos locales.

En Cuentas > Movimientos puedes abrir la configuración de clasificación asistida. La clave de OpenCode Zen se guarda en el llavero del iPhone y solo se usa después de confirmar el envío de movimientos pendientes. El selector de la app contiene únicamente modelos gratuitos (`mimo-v2.5-free`, `deepseek-v4-flash-free`, `north-mini-code-free`, `nemotron-3-ultra-free` y `big-pickle`).

Los PDFs importados se conservan en Application Support del dispositivo para que cada tarjeta de Documentos importados pueda abrir el archivo original sin mostrar nombres parseados en la pantalla principal. Vision conserva la página y la confianza real de cada observación OCR; si una fila queda por debajo del umbral, el estado requiere revisión y no entra en los KPI. Cuando el documento concilia pero la evidencia institucional del emisor es provisional, puedes confirmar manualmente el banco mostrado; esa liberación queda registrada como confirmación humana independiente de la aceptación automática.

Si el emisor o el tipo se detectan mal, abre **Cuentas > Editar cifras del corte**, corrige ambos campos y usa **Releer con esta configuración**. Marcelito vuelve a construir las filas desde el PDF original, registra la corrección como revisión manual y no libera el estado a los KPI hasta que la conciliación sea válida y se confirme.

El catálogo de iconos está en `Cauce/Assets.xcassets/AppIcon.appiconset`. Antes de TestFlight registra el Bundle ID `mx.marcelito.personal` y completa App Privacy, export compliance y screenshots en App Store Connect.
