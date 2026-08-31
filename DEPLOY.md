# Marcelito: publicación y beta

## Estado actual

- Web: https://marcelito-finanzas.onrender.com
- Repositorio privado: https://github.com/ClubAmigosTT/marcelito-finanzas
- Render publica el sitio estático desde `main`.
- Los estados de cuenta se procesan localmente; no se suben al servidor.

## Datos reales

La aplicación inicia vacía. El usuario importa cada PDF desde **Importar estado** y revisa banco, periodo, archivo, método y movimientos antes de guardarlo. Los estados quedan en el navegador o dispositivo que los importó.

Los movimientos se pueden buscar, categorizar y corregir. Un PDF escaneado puede quedar como pendiente de revisión sin crear movimientos ficticios.

## iOS

El proyecto nativo está en `apps/ios`. En un Mac:

```bash
cd apps/ios
xcodegen generate
open Marcelito.xcodeproj
```

Después selecciona tu equipo en Xcode, ejecuta en el iPhone y usa `Archive > Distribute App > App Store Connect` para TestFlight. Las credenciales de Apple deben introducirse directamente en Xcode/App Store Connect; no se guardan en el repositorio.

### TestFlight sin Mac

El workflow [`ios-testflight.yml`](.github/workflows/ios-testflight.yml) compila en macOS y sube el build automáticamente. Para activarlo una vez:

1. Crea en App Store Connect la app **Marcelito** con Bundle ID `mx.marcelito.personal`.
2. Crea una clave API con rol **App Manager** y agrega a los secretos de GitHub `APPLE_TEAM_ID`, `APPSTORE_ISSUER_ID`, `APPSTORE_API_KEY_ID` y `APPSTORE_API_PRIVATE_KEY` (el contenido del `.p8`). El repositorio también conserva, como secretos protegidos, la firma de distribución (`APPLE_DISTRIBUTION_P12`, `APPLE_DISTRIBUTION_P12_PASSWORD` y `APPLE_PROVISIONING_PROFILE`); nunca los guardes en el código.
3. Ejecuta **Actions > iOS TestFlight > Run workflow** con la versión deseada, o publica una etiqueta `ios-v1.0.1`.

La acción no corre en cada push. Consulta [Apple sobre claves de App Store Connect](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/) y [GitHub sobre facturación de Actions](https://docs.github.com/en/billing/concepts/product-billing/github-actions) antes de automatizar ejecuciones frecuentes. Nunca guardes contraseñas, códigos 2FA, certificados P12, perfiles de aprovisionamiento o claves `.p8` en el código.

## Privacidad

Antes de una distribución pública, sustituye el correo de contacto de `public/privacy.html` por uno real. No incluyas estados de cuenta en el repositorio ni en variables de entorno.
