# Migración a repositorio público

Esta lista es un runbook. La publicación solo se ejecuta cuando cada puerta de
seguridad está marcada; cambiar la visibilidad antes de completar las puertas
expone código, historial, ejecuciones, logs, artefactos, issues y forks.

## Fase 0 — Congelar y respaldar

- [x] Congelar cambios funcionales durante la limpieza.
- [x] Crear un backup espejo fuera del repositorio.
- [ ] Registrar quién aprueba el cambio de visibilidad.

## Fase 1 — Inventario

- [x] Buscar PDFs, CSV/XLSX, bases locales, certificados, perfiles y claves en
  el árbol actual.
- [x] Buscar secretos, credenciales de revisión, nombres, cuentas, referencias
  y saldos en el árbol actual.
- [ ] Revisar los logs y artefactos de Actions; eliminar todas las ejecuciones
  antiguas antes de publicar.

## Fase 2 — Rotación

- [ ] Revocar la clave de Zen compartida fuera de GitHub y crear una nueva.
- [ ] Rotar las claves de App Store Connect, certificados y perfiles que hayan
  sido usados mientras el repositorio era privado.
- [ ] Guardar los valores únicamente como secretos del entorno `testflight`.
- [ ] Confirmar que no queda ningún secreto de repositorio que el workflow de
  publicación pueda leer sin pasar la aprobación del entorno.

## Fase 3 — Saneamiento del código

- [x] Sustituir fixtures y ejemplos por valores sintéticos.
- [x] Eliminar cuentas de revisión sembradas y credenciales del binario.
- [x] Ignorar documentos financieros y material de firma en `.gitignore`.
- [x] Añadir `SECURITY.md`, `CONTRIBUTING.md`, `CODEOWNERS` y README público.
- [x] Crear una historia limpia de un solo commit (`public-clean-history`).
- [ ] Confirmar que la rama pública no contiene marcadores sensibles con una
  búsqueda automatizada antes de forzar `main`.

## Fase 4 — CI seguro

- [x] Mantener validación web/iOS sin secretos en cada push y pull request.
- [x] Separar TestFlight en el entorno protegido `testflight`.
- [x] Permitir que TestFlight despliegue únicamente desde tags `ios-v*`.
- [x] Reducir la retención de artefactos de diagnóstico.
- [x] Activar dependency graph, alertas y actualizaciones de seguridad de
  Dependabot en la configuración del repositorio.
- [x] Actualizar `pdfjs-dist` a una versión con el parche de seguridad y
  liberar el `PDFDocumentLoadingTask` en todas las rutas; el importador no
  ejecuta scripting/XFA interactivo.
- [ ] Activar secret scanning y push protection al quedar el repositorio
  público, y revisar sus primeros resultados.
- [ ] Configurar protección de `main` (pull request, checks obligatorios y sin
  force-push después de la migración).

## Fase 5 — Reemplazar referencias remotas

Con la aprobación final y después de rotar secretos:

```bash
git push origin public-clean-history:main --force-with-lease
git push origin --delete ios-v1.0.0 ios-v1.0.1  # repetir para todos los tags viejos
```

Crear un tag nuevo desde la historia limpia solo después de que CI pase y los
secretos del entorno estén verificados. El backup espejo conserva la historia
privada para auditoría y recuperación.

## Fase 6 — Publicar y verificar

- [ ] Cambiar la visibilidad a pública desde Settings → General.
- [ ] Verificar un clon anónimo: solo debe existir la historia limpia.
- [ ] Revisar que no haya PDFs, artefactos, logs o secretos visibles.
- [ ] Ejecutar validación web/iOS y confirmar que usa runners estándar sin
  bloqueo de facturación.
- [ ] Ejecutar TestFlight únicamente desde el tag aprobado y comprobar la
  subida en App Store Connect.

Si alguna puerta falla, detener la publicación y devolver el estado a privado;
los forks o clones ya creados no se vuelven privados automáticamente.
