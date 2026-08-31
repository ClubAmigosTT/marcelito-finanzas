# Migración a repositorio público

Esta lista es un runbook. La publicación solo se ejecuta cuando cada puerta de
seguridad está marcada; cambiar la visibilidad antes de completar las puertas
expone código, historial, ejecuciones, logs, artefactos, issues y forks.

## Fase 0 — Congelar y respaldar

- [x] Congelar cambios funcionales durante la limpieza.
- [x] Crear un backup espejo fuera del repositorio.
- [x] Registrar la autorización del propietario para sanear y continuar.

## Fase 1 — Inventario

- [x] Buscar PDFs, CSV/XLSX, bases locales, certificados, perfiles y claves en
  el árbol actual.
- [x] Buscar secretos, credenciales de revisión, nombres, cuentas, referencias
  y saldos en el árbol actual.
- [x] Revisar los logs y artefactos de Actions; eliminar todas las ejecuciones
  antiguas antes de publicar.

La limpieza remota se ejecutó el 2026-08-31: la PR automática fue cerrada, la
rama de Dependabot y los 23 tags `ios-v*` históricos fueron eliminados, y
Actions quedó sin ejecuciones antiguas.

El dry-run local de esa limpieza dejó `main` únicamente con la historia limpia,
pero todavía mostró objetos Git inalcanzables. Esto confirma que retirar ramas y
tags no sustituye la eliminación de runs, artefactos y referencias de PR.

## Fase 2 — Rotación

- [ ] Revocar la clave de Zen compartida fuera de GitHub y crear una nueva.
- [ ] Rotar las claves de App Store Connect, certificados y perfiles que hayan
  sido usados mientras el repositorio era privado.
- [ ] Guardar los valores únicamente como secretos del entorno `testflight`.
- [ ] Confirmar que no queda ningún secreto de repositorio que el workflow de
  publicación pueda leer sin pasar la aprobación del entorno.

La clave de Zen compartida no aparece en el código ni en la historia limpia,
pero su revocación solo puede hacerla el propietario desde la cuenta de Zen;
esta sesión no tiene acceso a ese panel. Debe completarse como operación
externa, aunque no bloquea el saneamiento del repositorio.

## Fase 3 — Saneamiento del código

- [x] Sustituir fixtures y ejemplos por valores sintéticos.
- [x] Eliminar cuentas de revisión sembradas y credenciales del binario.
- [x] Ignorar documentos financieros y material de firma en `.gitignore`.
- [x] Añadir `SECURITY.md`, `CONTRIBUTING.md`, `CODEOWNERS` y README público.
- [x] Crear una historia limpia en `public-clean-history`.
- [x] Confirmar que los commits de `public-clean-history` no contienen
  marcadores sensibles ni extensiones financieras o de firma (auditoría local).
- [x] Repetir la auditoría después de eliminar las referencias remotas antiguas
  y antes de forzar `main`.

## Fase 4 — CI seguro

- [x] Mantener validación web/iOS sin secretos en cada push y pull request.
- [x] Separar TestFlight en el entorno protegido `testflight`.
- [x] Permitir que TestFlight despliegue únicamente desde tags `ios-v*`.
- [x] Tras borrar los tags históricos, comprobar que la regla del entorno ya no
  incluye ningún tag antiguo (0 tags coincidentes).
- [x] Reducir la retención de artefactos de diagnóstico.
- [x] Activar dependency graph, alertas y actualizaciones de seguridad de
  Dependabot en la configuración del repositorio.
- [x] Actualizar `pdfjs-dist` a una versión con el parche de seguridad y
  liberar el `PDFDocumentLoadingTask` en todas las rutas; el importador no
  ejecuta scripting/XFA interactivo.
- [x] Activar secret scanning y push protection al quedar el repositorio
  público, y revisar sus primeros resultados.
- [x] Configurar protección de `main` (pull request, checks web/iOS obligatorios
  y sin force-push después de la migración).

## Fase 5 — Reemplazar referencias remotas

- [x] Cerrar la PR automática y retirar su rama de Dependabot.
- [x] Eliminar los tags históricos `ios-v*`.
- [x] Reemplazar `main` por `public-clean-history` con `--force-with-lease`.

Con la aprobación final y después de rotar secretos:

```bash
# No ejecutar hasta que las puertas de Fase 0–4 estén marcadas.
git fetch origin --prune
git show-ref --verify refs/remotes/origin/public-clean-history
git ls-remote --heads origin

# Primero cerrar la PR abierta y borrar su rama desde GitHub.
# Después borrar todos los tags ios-v* históricos.
git push origin --delete ios-v1.0.0 ios-v1.0.1  # repetir para todos los tags viejos

# Solo al final reemplazar main por la historia limpia.
git push origin public-clean-history:main --force-with-lease
```

La orden de reemplazo se ejecuta antes de borrar `public-clean-history` y solo
después de comprobar que el backup espejo existe y que la huella de
`public-clean-history` coincide local y remotamente. La eliminación de runs y
artefactos se hace desde Actions antes de este bloque; así los logs y
artefactos no sobreviven al cambio de visibilidad.

Crear un tag nuevo desde la historia limpia solo después de que CI pase y los
secretos del entorno estén verificados. El backup espejo conserva la historia
privada para auditoría y recuperación.

## Fase 6 — Publicar y verificar

- [x] Cambiar la visibilidad a pública desde Settings → General (2026-08-31).
- [x] Verificar un clon anónimo: solo debe existir la historia limpia; `main`
  apunta a `3fdf021`.
- [x] Revisar que no haya PDFs, CSV/DB, artefactos, logs o marcadores de
  secretos visibles en el clon público.
- [x] Ejecutar validación web/iOS y confirmar que usa runners estándar sin
  bloqueo de facturación. Web e iOS pasaron en `main` después del merge.
- [ ] Ejecutar TestFlight únicamente desde el tag aprobado y comprobar la
  subida en App Store Connect.

El repositorio quedó público en GitHub. El ruleset activo `Protect main` exige
PR, los checks `Web Reader Validate` e `iOS Validate`, y bloquea force-push. La
protección de secretos (secret scanning y push protection) también está activa.
Los warnings actuales de Actions corresponden a que `actions/checkout@v4` y
`actions/upload-artifact@v4` aún apuntan a Node.js 20; no impiden la validación.

TestFlight permanece deliberadamente fuera de esta migración: antes de crear un
tag de publicación el propietario debe revocar/rotar la clave de Zen y las
credenciales de Apple/App Store Connect, y guardarlas como secretos del entorno
`testflight` con aprobación requerida. Los secretos cifrados de repositorio no
se pueden leer ni rotar desde esta sesión.

Si alguna puerta falla, detener la publicación y devolver el estado a privado;
los forks o clones ya creados no se vuelven privados automáticamente.
