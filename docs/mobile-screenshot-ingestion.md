# Ingesta de movimientos por screenshots

## Objetivo

Permitir que Marcelito registre movimientos casi en tiempo real a partir de
capturas de la app bancaria, sin confundir una observación OCR con un estado
oficial ni inflar los indicadores. Las capturas se procesan localmente y los
originales se conservan en IndexedDB.

## Perfiles cubiertos

| Origen | Evidencia esperada | Reglas específicas |
| --- | --- | --- |
| BBVA | Encabezado `Movimientos` y texto `Movimiento BBVA` | Acepta fechas completas, conceptos truncados y signos como `$ -9.63`. La leyenda `Transferencia interbancaria ...` es subtítulo, no una segunda fila. |
| Santander | Producto `SUPER NOMINA`, saldo actual y cuenta enmascarada | El saldo (`44,460.55 MXN`) se guarda como `BalanceSnapshot`, nunca como movimiento. La flecha o signo determina entrada/salida; si OCR no puede probarla, la fila queda en revisión. |
| American Express | `The Platinum Credit Card American Express` y terminación enmascarada | Una compra visible como `$405.00` se normaliza internamente a `-405`; un pago (`GRACIAS POR SU PAGO EN LINEA`) conserva `kind=cardPayment`; `Pendiente` mantiene el ciclo provisional. |
| RappiCard | Marca `RappiCard` y la cuenta seleccionada | Lee el importe principal en MXN, excluye la recompensa `+$`, pagos SPEI son pagos de tarjeta, operaciones `Rechazada` quedan fuera y filas tapadas/incompletas requieren revisión. |

Los perfiles comparten una capa de fechas, importe, evidencia OCR, cuenta,
clasificación determinista y advertencias. No se usa una regla genérica que
trate el saldo, promociones o navegación como movimientos.

## Flujo de una captura

1. El usuario elige una o varias imágenes del mismo banco/tarjeta. Puede
   seleccionar el emisor si el OCR no reconoce el encabezado y proporcionar un
   identificador enmascarado.
2. Tesseract en español lee cada imagen en el dispositivo. La pantalla de
   revisión muestra el texto visible, importes, fechas, `Pendiente`, confianza,
   filas rechazadas y conceptos truncados.
3. Al guardar, cada fila recibe `sourceType=screenshot`, `sourceCaptureId`,
   `observedAt`, `captureStatus` y evidencia `screenshot-ocr`. La captura queda
   en `marcelito-screenshot-captures.v1`; conserva también confianza OCR,
   filas rechazadas, saldos visibles y la huella de cada imagen. No entra a
   `transactions` ni a los KPI.
4. Se deduplican observaciones por cuenta, fecha, importe, tipo y concepto
   normalizado; si el concepto llega recortado, se permite una coincidencia
   por prefijo compatible. Una fila repetida en otra imagen se marca con
   `duplicateOf`, pero nunca se borra del rastro de auditoría. Dos filas
   idénticas dentro de la misma imagen se conservan porque pueden ser compras
   legítimas distintas.
5. Cuando llega un PDF oficial (y posteriormente una API), se busca una
   coincidencia uno-a-uno por emisor, cuenta, importe, fecha cercana y
   similitud del concepto. El estado oficial permanece como fuente de verdad;
   la captura solo recibe `matchedTransactionId`, confianza y explicación.

## Solapamientos y estados repetidos

- Un screenshot exactamente repetido no aumenta el total: sus filas se
  marcan como duplicadas contra la primera observación.
- Una terminación enmascarada solo concilia con la misma institución y tipo de
  cuenta; una cuenta bancaria y una tarjeta con los mismos últimos cuatro no
  se cruzan.
- Una captura de medio mes y otra del resto del mes forman una unión. Las filas
  nuevas quedan provisionales y las que se repiten por el solapamiento quedan
  marcadas, no sumadas dos veces.
- `provisional` significa que aún no existe confirmación oficial;
  `partially-reconciled` que algunas filas ya coincidieron;
  `reconciled` que todas las filas canónicas coincidieron; `review` exige
  resolver una ambigüedad.
- Una transferencia entre cuentas se conserva como dos movimientos —egreso e
  ingreso— y se enlaza solo en la conciliación contable. Nunca se deduplica por
  tener el mismo importe.
- En Amex, una fila `Pendiente` puede coincidir después con la fila posteada.
  El ciclo cambia a confirmado sin crear una segunda compra.

## Objetivos de funcionamiento

- Cero impacto de capturas en Resumen, Gastos, Patrimonio y saldos hasta
  confirmación oficial.
- Filas canónicas idempotentes por fingerprint SHA-256; el historial conserva
  cada captura importada y sus filas originales para auditoría.
- No cruzar cuentas con el mismo banco cuando existen terminaciones
  enmascaradas distintas; pedir revisión en vez de adivinar.
- Conservar el original y la evidencia suficiente para explicar cada lectura.
- Rechazar o marcar para revisión importes sin fecha, dirección, concepto o
  confianza suficiente; nunca corregir silenciosamente un importe.
- Poder reprocesar las capturas cuando cambie el lector sin perder el historial.

## Límites conocidos y siguiente fase

OCR solo puede leer lo que está visible. En Santander la dirección puede estar
representada únicamente por una flecha gráfica; cuando no hay signo o texto
semántico, la fila queda en revisión. La siguiente mejora es conservar las
coordenadas TSV y analizar esa flecha para reducir revisiones, además de
conectar el mismo contrato de conciliación a una fuente API oficial.

## Validación de estas plantillas

La lectura local se probó con las siete imágenes de referencia entregadas:
BBVA produjo 6 filas por imagen, Santander 6 por imagen y American Express
produjo 7, 6 y 7 filas. Se recuperó `Santander:bank:7079`,
`Amex:card:1003`, el saldo visible de Santander (`44,460.55 MXN`) y las tres
filas `Pendiente` de Amex. Los elementos de navegación y el banner de
referidos de Amex se rechazan como no transaccionales; los conceptos dudosos
permanecen visibles como evidencia para revisión o conciliación oficial.
