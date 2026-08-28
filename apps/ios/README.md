# Marcelito para iOS

Cliente nativo en SwiftUI para iOS 17 o posterior.

## Abrir en Xcode

1. Instala XcodeGen: brew install xcodegen.
2. Desde esta carpeta ejecuta xcodegen generate.
3. Abre Marcelito.xcodeproj y selecciona un equipo de firma.
4. Ejecuta en un dispositivo con Face ID o en el simulador.

La autenticación usa un usuario local guardado en Keychain y Face ID mediante LocalAuthentication. La cuenta inicial de la beta es Marcelodiazs con la contraseña que definiste; no se guarda la contraseña en texto plano. El usuario puede crear otra cuenta después de eliminar la actual.

FinanceStore guarda movimientos en el dispositivo, permite importar PDFs desde Archivos una vez al mes y evita duplicar filas al volver a seleccionar el mismo estado de cuenta. Las categorías se pueden corregir desde el detalle de cada movimiento. El menú de Inicio incluye eliminación de cuenta y datos locales.

El catálogo de íconos está en Cauce/Assets.xcassets/AppIcon.appiconset. Antes de subir a TestFlight sustituye el correo de contacto de public/privacy.html, registra el Bundle ID mx.marcelito.personal y completa App Privacy, export compliance y screenshots en App Store Connect.
