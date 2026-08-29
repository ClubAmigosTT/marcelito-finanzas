# Marcelito para iOS

Cliente nativo en SwiftUI para iOS 17 o posterior.

## Abrir en Xcode

1. Instala XcodeGen: `brew install xcodegen`.
2. Desde esta carpeta ejecuta `xcodegen generate`.
3. Abre `Marcelito.xcodeproj` y selecciona tu equipo de firma.
4. Ejecuta en un iPhone o en el simulador.

La autenticación usa Keychain y Face ID. La aplicación inicia sin movimientos de muestra: importa tus PDFs desde Archivos, revisa banco, periodo y movimientos, y los guarda solo en ese dispositivo. Los estados escaneados pueden quedar pendientes de revisión sin inventar filas.

Movimientos y estados de cuenta se persisten localmente, se evita volver a contar el mismo archivo y las categorías se pueden corregir desde el detalle de cada movimiento. El menú de Inicio permite eliminar la cuenta y todos los datos locales.

El catálogo de iconos está en `Cauce/Assets.xcassets/AppIcon.appiconset`. Antes de TestFlight registra el Bundle ID `mx.marcelito.personal` y completa App Privacy, export compliance y screenshots en App Store Connect.
