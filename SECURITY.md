# Seguridad y datos sensibles

No subas estados de cuenta, capturas, exportaciones CSV/XLSX, bases locales,
certificados, perfiles de aprovisionamiento, claves `.p8`/`.p12` ni tokens de
API. Los fixtures públicos deben ser sintéticos y no deben conservar nombres,
números de cuenta, referencias, saldos reales ni huellas de archivos reales.

Si una credencial aparece en un commit, log, artefacto o comentario:

1. Revócala o rótala inmediatamente en el proveedor (Apple, Zen u otro).
2. Elimina el valor de los secretos de GitHub y crea uno nuevo en el entorno
   protegido correspondiente.
3. Conserva el hash del incidente fuera del repositorio y solicita la limpieza
   del historial antes de cambiar la visibilidad a pública.

Para reportar un problema de seguridad, abre un aviso privado a los
administradores de `ClubAmigosTT` o contacta al propietario de la organización.
No publiques el secreto ni un PDF en una issue o pull request.
