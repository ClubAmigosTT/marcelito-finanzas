# Seguridad y datos sensibles

No subas estados de cuenta, capturas, exportaciones CSV/XLSX, bases locales,
certificados, perfiles de aprovisionamiento, claves `.p8`/`.p12` ni tokens de
API. Los fixtures públicos deben ser sintéticos y no deben conservar nombres,
números de cuenta, referencias, saldos reales ni huellas de archivos reales.

Zen es un enriquecimiento opcional de gastos. `OPENAI_API_KEY` (o
`STATEMENT_READER_API_KEY`) y `STATEMENT_READER_TOKEN` solo viven en el proxy
de servidor; nunca deben aparecer en `VITE_*`, la app iOS, el bundle web, logs
o el historial de Git.
El proxy exige un origen exacto, token temporal, TLS, límites de tamaño,
solicitudes/concurrencia y tiempo de proveedor. Antes
de activarlo para más de un usuario hay que añadir autenticación de sesión,
rate limiting y una política de retención compatible con el proveedor. El
lector local sigue siendo el camino por defecto y el clasificador remoto solo
recibe filas de gasto ya conciliadas, con consentimiento explícito; el PDF
nunca se envía.

Si una credencial aparece en un commit, log, artefacto o comentario:

1. Revócala o rótala inmediatamente en el proveedor (Apple, Zen u otro).
2. Elimina el valor de los secretos de GitHub y crea uno nuevo en el entorno
   protegido correspondiente.
3. Conserva el hash del incidente fuera del repositorio y solicita la limpieza
   del historial antes de cambiar la visibilidad a pública.

Para reportar un problema de seguridad, abre un aviso privado a los
administradores de `ClubAmigosTT` o contacta al propietario de la organización.
No publiques el secreto ni un PDF en una issue o pull request.
