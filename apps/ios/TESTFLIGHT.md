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
- Acceso inicial: crea un usuario local desde la pestaña **Crear usuario**. No hay credenciales compartidas ni cuentas sembradas en el binario.

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
4. El entorno protegido `testflight` solo permite `main` y tags `ios-v*`. La ruta comprobada para esta corrección es el tag `ios-v1.0.110-bootstrap`, que produjo TestFlight `1.0.110 (209)` en estado `VALID`. El grupo interno `Marcelito - Pruebas internas` tiene distribución automática; el workflow lo verifica sin intentar una asociación manual incompatible con Apple. El tag `ios-v1.0.6-bootstrap` y el build `1.0.6 (204)` quedan como histórico. Para una rama de trabajo o una siguiente versión, crea un tag nuevo sobre el commit exacto siguiendo el patrón `ios-vX.Y.Z` (o `ios-vX.Y.Z-bootstrap` si solo vas a instalar el certificador); nunca reutilices ni muevas un tag existente. Usa ese tag como **Run workflow > Use workflow from**. Para el bootstrap inicial marca `corpus_certifier=true`; para una publicación final usa `false` y solo después de certificar el corpus.

   También puedes ejecutar **Actions > iOS TestFlight > Run workflow** seleccionando ese tag, escribiendo la versión correspondiente y eligiendo el valor de bootstrap adecuado.

5. Antes de publicar, certifica todos los estados con Vision. Para esta corrección Rappi, la ruta obligatoria es el runner nativo con el manifiesto privado exacto de los seis PDFs, siguiendo `docs/rappi-luna-implementation.md` y `apps/ios/README.md`. Ese runner valida los nombres anonimizados, huellas, filas, controles y versión del lector sin copiar documentos al repositorio. Solo después de que `MARCELITO_PDF_CORPUS_REQUIRE_CERTIFIED=1` termine con `certified=true`, y después de comprobar el flujo en un iPhone físico, registra en **Settings > Secrets and variables > Actions > Variables**:
   - `MARCELITO_NATIVE_CORPUS_CERTIFIED=true`.
   - `MARCELITO_NATIVE_CORPUS_READER_VERSION=ios-reader-deterministic-2026.09.16.3`.

   La pantalla **Resumen > Opciones > Diagnóstico > Certificar estados con Vision** tiene dos perfiles: selecciona seis o más estados exclusivamente Rappi para producir `certificationScope: rappi-focused`, o diez o más estados para el perfil general. El informe Rappi enfocado exige que todos sean tarjetas Rappi, procesadas con texto nativo o `vision-ocr`, conciliadas y sin revisión pendiente. El manifiesto privado sigue fijando el método exacto esperado por cada PDF. Puede guardarse como `docs/native-corpus-certification.json` y el workflow ajustará la compuerta al perfil declarado. Este informe de dispositivo demuestra la lectura y calidad del conjunto; el runner privado con manifiesto sigue siendo la prueba más fuerte de filas, controles y goldens exactos. Nunca mezcles estados de otros emisores en el perfil Rappi.
6. Cuando finalice el workflow, espera a que App Store Connect procese el build. El workflow confirma la disponibilidad para los grupos internos con distribución automática; solo agrega manualmente el build a grupos externos o a grupos internos que no tengan distribución automática.

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
4. En **Cuentas**, toca **Subir capturas**, selecciona varias pantallas del banco, confirma que un lote repetido no duplique filas y que una pantalla solapada agregue solo movimientos nuevos. Después importa el PDF mensual y verifica que las capturas coincidentes cambien a confirmadas sin alterar dos veces los KPI.
5. Captura screenshots reales del build. Como el target incluye iPhone y iPad, prepara al menos un juego para cada familia; si decides distribuir solo iPhone, cambia TARGETED_DEVICE_FAMILY a 1 antes de archivar.
6. Archive > Distribute App > App Store Connect y sube el build. Aumenta CURRENT_PROJECT_VERSION para cada nueva subida.

## Metadatos y respuestas

- Política de privacidad: publica public/privacy.html en el dominio definitivo, por ejemplo https://tu-dominio/privacy.html, y reemplaza el correo privacidad@marcelito.app por un contacto real.
- Información financiera: Marcelito procesa estados de cuenta y movimientos que el usuario introduce, solo para mostrar resúmenes, categorías y decisiones. No se conecta a bancos, no recibe credenciales bancarias y no transmite los PDFs.
- App Privacy: al no enviar datos al desarrollador, declara que la app no recopila datos. Describe en las notas de revisión que sí procesa información financiera local introducida por el usuario.
- Export compliance: responde que no usa cifrado no exento. La beta solo usa Keychain, Face ID y un hash local de acceso; revisa la respuesta si agregas sincronización o una API.
- Nota para App Review: “Marcelito es una herramienta local de finanzas personales. En el primer acceso crea un usuario local desde **Crear usuario**. Importa PDFs desde Archivos; los movimientos permanecen en el dispositivo. La eliminación de cuenta está en Inicio > opciones > Eliminar cuenta.”

## Alcance de la primera beta

Esta beta incluye persistencia local, carga mensual de estados de cuenta y una bitácora provisional de capturas bancarias procesadas con Vision en el iPhone. No sincroniza entre iOS y web todavía. Las capturas nunca alimentan KPI por sí solas: el estado oficial conserva prioridad y confirma o corrige sus filas. Los documentos e imágenes no se envían a servicios externos.
