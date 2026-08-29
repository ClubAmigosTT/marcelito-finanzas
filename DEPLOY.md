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

## Privacidad

Antes de una distribución pública, sustituye el correo de contacto de `public/privacy.html` por uno real. No incluyas estados de cuenta en el repositorio ni en variables de entorno.
