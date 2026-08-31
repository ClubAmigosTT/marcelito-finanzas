# Lector de estados: criterio de confianza del 99%

El 99% se mide como **precisión de aceptación automática**: de cada 100 filas o estados que el sistema acepta sin intervención, al menos 99 deben coincidir con el estado original. No es una promesa de 99% de caracteres OCR. Una lectura ambigua se rechaza o queda provisional; nunca se convierte en un KPI.

## Flujo obligatorio

1. Extraer: texto del PDF; si no existe, OCR visual por página.
2. Validar: fecha real, descripción con letras, importe monetario y dirección inequívoca.
3. Normalizar: comercio, fechas, separadores decimales y conceptos.
4. Deduplicar: cuenta + fecha + importe + concepto normalizado + tipo; conservar ocurrencias legítimas dentro del mismo estado.
5. Hacer matching: transferencias propias y pagos de tarjeta en una ventana de ±2 días y mismo importe.
6. Clasificar: compra, ingreso, reembolso, transferencia, pago de tarjeta, interés, comisión o MSI.
7. Conciliar: comparar filas contra totales y conteos declarados por el emisor.
8. Calcular: alimentar todos los módulos exclusivamente desde el libro canónico conciliado.

## Reglas de aceptación

- Emisor verificado por evidencia institucional del encabezado; nombres dentro de movimientos son contrapartes.
- Estado bancario válido solo si depósitos, retiros y conteos concilian dentro de ±$0.05.
- Estado de tarjeta válido solo si cargos y pagos reconocidos concilian con el resumen disponible.
- Cualquier encabezado, referencia, cuenta, RFC, certificado, saldo o total se descarta como movimiento.
- OCR web sin coordenadas queda provisional. Vision con coordenadas conserva página y método en cada fila.
- Un estado inválido, pendiente o provisional no alimenta Resumen, Gastos, Patrimonio ni gráficas.

## Corpus dorado

Los valores de control sin datos personales están en `tests/fixtures/pdf-goldens.json`. El corpus completo debe conservarse fuera del repositorio y evaluarse por emisor, plantilla y tipo de extracción (texto/OCR). Cada nueva variante de PDF se añade como fixture antes de activar su parser.

Métricas mínimas por versión:

- precisión automática de filas >= 99%;
- 0 encabezados administrativos aceptados como movimientos;
- 100% de estados aceptados conciliados contra importes y conteos;
- 100% de duplicados de solapamiento eliminados sin borrar compras idénticas legítimas;
- 100% de pagos de tarjeta y transferencias propias emparejados cuando existe la contraparte.

Si una métrica falla, el parser queda en revisión y el dashboard se bloquea hasta corregir la causa.

## Última corrida del corpus visual

En la corrida de OCR visual sobre los tres estados más recientes (30-ago-2026):

- BBVA: se reconstruyeron 11 filas; depósitos $19,500.00 y cargos $22,058.69 concilian, por lo que el estado puede aceptarse.
- Amex: el emisor y el resumen se identificaron correctamente (pago para no generar intereses $39,966.15 y crédito disponible $99,632.79), pero la suma de filas aún no concilia; el estado queda bloqueado.
- Santander: el emisor y los totales del resumen se identificaron correctamente, pero el OCR de filas no concilia; el estado queda bloqueado.

Por tanto, esta corrida demuestra el bloqueo seguro de lecturas ambiguas, pero **no certifica todavía una tasa de aceptación automática del 99% para OCR**. La certificación requiere ejecutar el corpus completo de estados en macOS/Xcode con Vision y registrar cada estado aceptado, rechazado y corregido.
