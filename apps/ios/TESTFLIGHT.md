# Checklist de TestFlight para Marcelito

## Ya preparado en el proyecto

- Bundle ID: mx.marcelito.personal.
- Nombre visible: Marcelito.
- Versión inicial: 1.0.0 (build 1).
- Face ID: uso declarado en la configuración de Info.plist.
- AppIcon: catálogo completo para iPhone, iPad y marketing en Cauce/Assets.xcassets/AppIcon.appiconset.
- Export compliance inicial: ITSAppUsesNonExemptEncryption = NO.
- Eliminación de cuenta: Inicio > opciones > Eliminar cuenta.
- Importación mensual: Inicio > importar estado de cuenta. El mismo PDF no vuelve a duplicar movimientos.
- Revisión manual: Movimientos > + permite agregar una fila y cada movimiento permite corregir su categoría.
- Credenciales de revisión: usuario Marcelodiazs y la contraseña que definiste.

## Pasos que requieren una Mac

1. En apps/ios instala XcodeGen y ejecuta xcodegen generate.
2. Abre Marcelito.xcodeproj en Xcode 26 o posterior, elige tu Team y confirma la firma automática.
3. Prueba en un iPhone con Face ID: entrar, importar un Amex, corregir una categoría, agregar un movimiento y eliminar la cuenta.
4. Captura screenshots reales del build. Como el target incluye iPhone y iPad, prepara al menos un juego para cada familia; si decides distribuir solo iPhone, cambia TARGETED_DEVICE_FAMILY a 1 antes de archivar.
5. Archive > Distribute App > App Store Connect y sube el build. Aumenta CURRENT_PROJECT_VERSION para cada nueva subida.

## Metadatos y respuestas

- Política de privacidad: publica public/privacy.html en el dominio definitivo, por ejemplo https://tu-dominio/privacy.html, y reemplaza el correo privacidad@marcelito.app por un contacto real.
- Información financiera: Marcelito procesa estados de cuenta y movimientos que el usuario introduce, solo para mostrar resúmenes, categorías y decisiones. No se conecta a bancos, no recibe credenciales bancarias y no transmite los PDFs.
- App Privacy: al no enviar datos al desarrollador, declara que la app no recopila datos. Describe en las notas de revisión que sí procesa información financiera local introducida por el usuario.
- Export compliance: responde que no usa cifrado no exento. La beta solo usa Keychain, Face ID y un hash local de acceso; revisa la respuesta si agregas sincronización o una API.
- Nota para App Review: “Marcelito es una herramienta local de finanzas personales. Usa las credenciales de prueba incluidas en App Store Connect. Importa PDFs desde Archivos; los movimientos permanecen en el dispositivo. La eliminación de cuenta está en Inicio > opciones > Eliminar cuenta.”

## Alcance de la primera beta

Esta beta sí incluye persistencia local y carga mensual de estados de cuenta. No sincroniza entre iOS y web todavía. Los PDFs con texto extraíble (como Amex) se leen localmente; los estados escaneados (como algunos Santander) requieren alta manual. El PDF no se almacena ni se envía a servicios externos.
