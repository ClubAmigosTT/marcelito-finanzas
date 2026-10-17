# Préstamo ITAM en UDIS

## Componentes y origen

- `LoanPDFReader` / `ITAMPDFText`: lectura explícita del PDF ITAM fuera de MainActor. El documento mezcla celdas en su flujo de texto; se usan posiciones, ToUnicode y anchos de sus fuentes. No se ejecuta OCR ni relectura al abrir la app.
- `ITAMLoanReader`: controles independientes de cuotas, capital, interés, abonos UDIS y abonos MXN contra el pie del PDF. Una fila incompleta rechaza toda la importación.
- `LoanBook` / `LoanLedger`: libro separado `marcelito.loans.v1`, respaldo de la versión previa, snapshots por fecha y SHA256. Reimportar es idempotente; fechas conflictivas no se reemplazan automáticamente.
- `LoanPaymentResolver`: solo aplica vínculos que el usuario confirmó, con evidencia elegible, importe, fecha y recibo sin cambios. Un recibo puede aplicarse a varias cuotas, pero se vincula a un solo débito. UUID nuevo se resuelve solo por identidad única. Transferencias propias y pagos de tarjeta no son candidatos.
- `LoanAccountsView`: Cuentas → Préstamos; revisión antes de guardar, calendario, recibos, origen PDF y reserva extra mensual.

## Contabilidad

- Deuda nativa = capital pendiente + interés ya vencido sin pagar, informado por el estado. No suma de nuevo el capital vencido. No incluye interés futuro ni moratorios no informados.
- Deuda MXN = deuda UDIS × valor fechado de UDI confirmado por el usuario desde Banxico. Sin valor no se muestra cero ni patrimonio completo. La consulta automática de UDI queda pendiente; la interfaz ofrece la fuente oficial y captura fechada.
- Los abonos no reducen nuevamente el saldo: el PDF ya los descontó. El tiempo transcurrido y los extras presupuestados tampoco reducen deuda.
- El débito bancario original, su categoría, evidencia y clasificaciones se conservan. La proyección de consumo lo sustituye por un componente derivado de interés; no persiste otro cargo bancario. El detalle de ese componente es de lectura y enlaza al abono completo.
- Presupuesto = cuota del mes menos anticipos de meses anteriores, convertida como estimación, más extra configurable. Se reserva el mayor entre esa suma y los abonos bancarios vinculados del mes. El interés derivado no se resta otra vez como variable.
- Cierre = ingreso − consumo − mensualidades MSI − capital bancario de préstamos. Los intereses ya están en consumo.
- El puente mensual de financiación se mantiene sin calcular al existir préstamos si solo hay cortes bancarios/tarjetas; falta demostrar el saldo del préstamo y la valoración UDI en ambos extremos del mes.
- Histórico de patrimonio exige snapshot y UDI disponibles a cada fecha. No aplica la tasa actual a meses pasados ni reconstruye capital anterior con evidencia insuficiente.
- Crédito/utilización sigue usando solo tarjetas. El préstamo aparece por separado y se incluye en deuda total.

## Datos faltantes

- Sin estado posterior, una cuota vencida después del corte dice **sin pago confirmado**, sin inventar morosidad. Los atrasos pagados conservan fechas y se identifican como pagados con atraso.
- No hay reglas contractuales de moratorios, condonaciones ni liquidación anticipada en el PDF aportado. No se calculan.
- La captura de un abono posterior no confirmado por ITAM se hace al importar el siguiente estado; no se inventa el desglose capital/interés a partir del débito.
- Los folios genéricos MOVIMIENTO conservan evidencia separada; no se unen automáticamente como un único recibo.

## Validación

`bash scripts/test-ios-loans.sh` ejecuta los tests del libro en macOS con Foundation/CoreGraphics/PDFKit y XCTest. Para probar además el PDF privado, definir `MARCELITO_ITAM_REGRESSION_PDF` sin copiarlo al repositorio.

`LoanIntegrationTests` verifica dentro del target iOS la preservación del movimiento manual, consumo de interés, reserva de caja, UUID reconstruidos, ambigüedad y deuda/utilización. Requiere compilación de iOS y permisos para macros/CoreSimulator.
