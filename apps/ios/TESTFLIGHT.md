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

## Publicar desde GitHub Actions (sin Mac)

El workflow `.github/workflows/ios-testflight.yml` compila Marcelito en un runner macOS, genera el proyecto a partir de `project.yml`, firma con la cuenta de Apple y sube el IPA a TestFlight. Solo se ejecuta manualmente o con una etiqueta `ios-v*`, así que hacer push de código no inicia una compilación costosa.

### Configuración única

1. En [App Store Connect](https://appstoreconnect.apple.com/) crea la app **Marcelito** para iOS con el Bundle ID `mx.marcelito.personal`. La app debe existir antes de subir el primer build.
2. En **Users and Access > Integrations > App Store Connect API**, crea una clave con rol **App Manager**. Descarga el archivo `.p8` una sola vez y anota el **Key ID** y el **Issuer ID**. No subas el `.p8` al repositorio.
3. En GitHub abre **Settings > Secrets and variables > Actions > New repository secret** y confirma estos secretos. Los tres últimos ya están configurados en este repositorio y no debes regenerarlos salvo que revoques la firma:
   - `APPLE_TEAM_ID`: el Team ID de Apple Developer (10 caracteres), no tu correo.
   - `APPSTORE_ISSUER_ID`: Issuer ID de App Store Connect.
   - `APPSTORE_API_KEY_ID`: Key ID de la clave anterior.
   - `APPSTORE_API_PRIVATE_KEY`: contenido completo del archivo `.p8`, incluyendo `BEGIN PRIVATE KEY` y `END PRIVATE KEY`.
   - `APPLE_DISTRIBUTION_P12`: certificado de distribución en Base64.
   - `APPLE_DISTRIBUTION_P12_PASSWORD`: contraseña del certificado P12.
   - `APPLE_PROVISIONING_PROFILE`: perfil App Store en Base64 para `mx.marcelito.personal`.
4. En GitHub abre **Actions > iOS TestFlight > Run workflow**, escribe la versión (por ejemplo `1.0.1`) y ejecuta. Alternativamente, desde una terminal:

   ```bash
   git tag ios-v1.0.1
   git push origin ios-v1.0.1
   ```

5. Cuando finalice el workflow, espera a que App Store Connect procese el build y agrégalo a un grupo de testers en TestFlight.

La firma de distribución se importa en un llavero temporal del runner y se elimina al terminar; no hace falta una Mac local. Si Apple muestra un error de firma, revisa que el Bundle ID exista, que la clave tenga permisos de App Manager y que `APPLE_TEAM_ID` corresponda al equipo que creó la app.

### Seguridad y consumo

- Nunca pegues tu contraseña de Apple, códigos de doble factor ni el contenido de la clave `.p8` en una conversación o commit.
- La clave se escribe solo en el almacenamiento temporal del runner y se elimina al terminar el job.
- El workflow está limitado a ejecuciones manuales y tags para evitar builds accidentales. Revisa la cuota de [GitHub Actions](https://docs.github.com/en/billing/concepts/product-billing/github-actions) antes de activar ejecuciones frecuentes.

## Publicación manual (alternativa)

Si en algún momento tienes acceso a una Mac, también puedes usar Xcode directamente:

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
