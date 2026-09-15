# Plantillas de lectura de estados

Las plantillas viven en `schemas/statement-templates/` y son contratos versionados, no ejemplos de PDF. No se guardan estados de cuenta, imágenes personales ni texto financiero en este repositorio.

## Contrato

- Todas las cajas usan `normalized-bottom-left`: `x`, `y`, `width` y `height` están entre 0 y 1 respecto de la página.
- La plantilla identifica emisor, tipo de estado, firma institucional, título de tabla, columnas y validaciones obligatorias.
- La coincidencia exige firma institucional, título, encabezados esenciales ordenados y alineación geométrica. Las coordenadas del encabezado del documento nuevo transforman el rango de referencia; no se usan píxeles ni una cuadrícula rígida.
- Un resultado conserva `templateId`, `templateVersion`, puntuación de alineación, páginas calibradas/heredadas y evidencia por movimiento. Una coincidencia en revisión no puede alimentar el libro ni KPI.

## Santander cuenta de cheques v1

`santander-checking-v1.json` describe las zonas `FECHA`, `DESCRIPCION`, `DEPOSITO`, `RETIRO` y `SALDO`. La fecha abre una fila; líneas posteriores solo continúan la descripción. El importe se selecciona exclusivamente de DEPÓSITO o RETIRO. SALDO se conserva como control de conciliación y nunca se convierte en movimiento.

La web consume las cajas de Tesseract y iOS las de Vision. Ambas conservan el mismo contrato conceptual de observación: página, texto, caja normalizada, confianza, orden de lectura y motor OCR.

## Añadir o modificar formatos

No se edita una plantilla existente para acomodar un PDF incompatible. Se crea una versión nueva (`santander-checking-v2.json`, por ejemplo), con regresiones sintéticas y corpus privado actualizado. Un formato desconocido debe quedar en revisión. La certificación nativa requiere evidencia completa, conciliación exacta y una precisión de aceptación automática de al menos 99%; no se promueve por una coincidencia parcial de totales.
