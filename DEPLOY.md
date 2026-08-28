# Publicar Marcelito en Render y preparar TestFlight

Estado actual de la beta:

- Web publicada: https://marcelito-finanzas.onrender.com
- Repositorio privado: https://github.com/ClubAmigosTT/marcelito-finanzas
- Servicio Render: `marcelito-finanzas` (sitio estatico, despliegue automatico desde `main`)

La web se publica como sitio estático. No requiere servidor backend, base de datos ni disco persistente: los estados de cuenta se procesan localmente y se guardan en el navegador.

## Publicar la web en Render

1. Sube este repositorio a GitHub, GitLab o Bitbucket.
2. En Render selecciona New -> Blueprint y conecta el repositorio.
3. Render leerá render.yaml y ejecutará npm ci && npm run build.
4. El directorio publicado será dist.

La política pública quedará en https://<tu-dominio>/privacy.html. Antes de publicarla, cambia privacidad@marcelito.app por un correo real de contacto en public/privacy.html.

## Configuración de App Store Connect

- Registra el Bundle ID mx.marcelito.personal y crea el app record con el nombre Marcelito.
- Genera el proyecto iOS desde apps/ios con xcodegen generate, abre Marcelito.xcodeproj en Xcode y selecciona un equipo de firma.
- Sube el build desde Xcode (Archive > Distribute App > App Store Connect). Incrementa CURRENT_PROJECT_VERSION en cada subida; MARKETING_VERSION es la versión visible.
- El catálogo apps/ios/Cauce/Assets.xcassets/AppIcon.appiconset ya contiene los tamaños de iPhone, iPad y marketing. TARGETED_DEVICE_FAMILY: "1,2" mantiene ambos dispositivos.
- En App Privacy declara que Marcelito no recopila ni comparte información con el desarrollador: los estados de cuenta, movimientos y credenciales permanecen en el dispositivo. Explica en las notas que sí se procesa información financiera introducida por el usuario, pero no se transmite.
- Para export compliance, la configuración actual usa ITSAppUsesNonExemptEncryption: NO: no hay cifrado propietario ni conexiones bancarias; solo se usan Keychain, Face ID y un hash local para proteger el acceso. Revisa esta respuesta si más adelante agregas sincronización o una API.
- Proporciona a App Review las credenciales de demostración Marcelodiazs y la contraseña que definiste. El primer build ya incluye carga mensual de PDF, revisión de movimientos y eliminación de cuenta.

## Qué funciona en la beta

- La web corre en su propio servicio estático (por ejemplo, Render) y no utiliza recursos del servidor 4173.
- La web permite crear/entrar con un usuario local, importar y revisar estados de cuenta, categorizar movimientos y eliminar la cuenta.
- iOS persiste movimientos en el dispositivo, importa PDF desde Archivos, evita duplicados y permite borrar cuenta y datos desde el menú de Inicio.
- No hay sincronización entre navegadores, dispositivos o iOS todavía. Para eso habría que añadir una API y una base de datos externa.
