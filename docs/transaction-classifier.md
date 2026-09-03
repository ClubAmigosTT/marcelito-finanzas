# Clasificador opcional de gastos con OpenCode Zen

La lectura de estados de cuenta no depende de IA. El recorrido de cada PDF es
local y determinista:

`PDF → PDF.js/PDFKit → OCR local si hace falta → validar → normalizar → deduplicar → matching → conciliar → libro canónico`

Solo después de que un estado concilia y sus filas entran al libro canónico se
puede pedir a Zen un enriquecimiento analítico:

`filas de gasto → comercio/categoría/recurrencia/viaje → validación estricta → libro canónico`

## Alcance y límites

Zen recibe únicamente, por fila, `index`, `date`, `description`,
`amount_cents`, `category`, `flow`, `kind` y `travel`. No recibe PDF, texto OCR
completo, número de cuenta, saldo, periodo del estado ni credenciales de banco.
El cliente filtra ingresos, reembolsos, pagos de tarjeta y transferencias antes
de construir la petición.

El clasificador puede cambiar solo campos analíticos: comercio normalizado,
categoría, recurrencia, extraordinario, viaje, confianza y motivo. No puede
modificar fecha, importe, signo, flujo, tipo contable ni conciliación. Una
respuesta incompleta, duplicada, administrativa o con una categoría fuera de
la lista se rechaza completa.

Las transferencias entre cuentas propias y los pagos de tarjeta se emparejan
con reglas deterministas (importe, dirección y ventana de ±2 días). Zen no
decide si una operación es ingreso, gasto o transferencia.

## Contrato y servidor

El contrato versionado está en
`schemas/transaction-classification.schema.json`. El proxy expone:

- `POST /api/transaction-classifier/preflight`: prueba el modelo con una fila
  sintética, sin datos del usuario.
- `POST /api/transaction-classifier`: recibe el lote validado y devuelve una
  clasificación por índice.

El servidor conserva la clave del proveedor solo en variables de entorno y
acepta únicamente modelos gratuitos de Zen incluidos en su allowlist. El
cliente exige HTTPS (o localhost durante desarrollo), autorización temporal,
timeout y validación del contrato. Los modelos gratuitos son una ayuda para
agrupar conceptos, no una fuente contable.

La ruta histórica `/api/statement-reader` se conserva solo para compatibilidad
con builds antiguas; la aplicación actual no la invoca y el lector nativo
remoto de PDFs fue retirado. Antes de desplegar una instalación nueva, debe
retirarse o aislarse esa ruta legacy en el gateway.

## Flujo recomendado

1. Importar el PDF y esperar la lectura local.
2. Corregir banco, tipo o filas y exigir conciliación contra los totales
   impresos.
3. Ejecutar la autoauditoría; si hay errores críticos, el documento no entra a
   los KPI.
4. Probar el preflight del clasificador en Diagnóstico.
5. Autorizar de forma explícita la clasificación de los gastos elegibles.
6. Aplicar únicamente el enriquecimiento validado y conservar su versión,
   modelo, confianza y motivo para reproducibilidad.

Si Zen no responde, el libro canónico y todos los KPI siguen funcionando con
las reglas locales. La clasificación puede repetirse sin volver a importar el
PDF ni duplicar movimientos.
