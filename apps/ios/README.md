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

Las pruebas verifican que el emisor se identifica por el encabezado
institucional, que las filas administrativas se descartan y que un crédito de
Amex no termina como gasto. El workflow de GitHub las ejecuta automáticamente
en macOS.

La autenticación usa Keychain y Face ID. La aplicación inicia sin movimientos de muestra: importa tus PDFs desde Archivos, revisa banco, periodo y movimientos, y los guarda solo en ese dispositivo. Los estados escaneados pueden quedar pendientes de revisión sin inventar filas.

Movimientos y estados de cuenta se persisten localmente, se evita volver a contar el mismo archivo y las categorías se pueden corregir desde el detalle de cada movimiento. El menú de Inicio permite eliminar la cuenta y todos los datos locales.

En Cuentas > Movimientos puedes abrir la configuración de clasificación asistida. La clave de OpenCode Zen se guarda en el llavero del iPhone y solo se usa después de confirmar el envío de movimientos pendientes. El selector de la app contiene únicamente modelos gratuitos (`mimo-v2.5-free`, `deepseek-v4-flash-free`, `north-mini-code-free`, `nemotron-3-ultra-free` y `big-pickle`).

Los PDFs importados se conservan en Application Support del dispositivo para que cada tarjeta de Documentos importados pueda abrir el archivo original sin mostrar nombres parseados en la pantalla principal. Vision conserva la página y la confianza real de cada observación OCR; si una fila queda por debajo del umbral, el estado requiere revisión y no entra en los KPI.

El catálogo de iconos está en `Cauce/Assets.xcassets/AppIcon.appiconset`. Antes de TestFlight registra el Bundle ID `mx.marcelito.personal` y completa App Privacy, export compliance y screenshots en App Store Connect.
