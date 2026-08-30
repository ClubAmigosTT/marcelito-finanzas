# Motor financiero reproducible

Marcelito calcula los KPI desde un libro mayor canónico. Cada importación pasa por
este orden, antes de que cualquier cifra llegue al dashboard:

`extraer → validar → normalizar → deduplicar → matching entre cuentas → clasificar → conciliar → calcular`

## Reglas de calidad

- Una fila importada necesita fecha válida, importe distinto de cero, descripción con texto de comercio y dirección (entrada o salida). Encabezados, totales, RFC, CLABE, saldos y metadatos administrativos se rechazan.
- La identidad base de una operación es `cuenta + fecha canónica + importe en centavos + concepto normalizado + tipo + flujo`. Se conserva más de una operación idéntica dentro del mismo estado (pueden ser compras reales); al comparar estados se añade el ordinal de ocurrencia para eliminar el solapamiento sin borrar una segunda compra legítima idéntica.
- Una salida bancaria y entrada bancaria propia del mismo importe en ±2 días se concilian como `internalTransfer`. Una salida bancaria y el movimiento equivalente de una tarjeta se concilian como `cardPayment`. Ambos quedan fuera de ingresos y gasto consolidado.
- El gasto se suma por la fecha del movimiento y por el periodo seleccionado; nunca se suman todos los resúmenes de todos los PDFs. Los resúmenes se usan como respaldo de saldos de tarjeta cuando no hay filas válidas.
- La deuda procede de tarjetas/créditos: saldo al corte, saldo revolvente y MSI pendientes se mantienen separados del efectivo bancario.
- En cuentas bancarias, la suma de filas positivas y negativas debe coincidir con los depósitos y retiros declarados (±$0.05); si no, la importación queda bloqueada. En tarjetas se concilian cargos y pagos contra el resumen del emisor.
- Los estados con conciliación pendiente o inválida no entran al dashboard ejecutivo y se marcan como provisionales en la auditoría.

El bloque de auditoría del Inicio expone los conteos y montos de cada periodo. También muestra las identidades contables y marca los KPI como provisionales cuando hay filas rechazadas, movimientos relevantes por revisar o una conciliación fuera de tolerancia.

Las pruebas reproducibles se ejecutan con `node --experimental-strip-types --test tests/reconciliation.test.ts` y cubren encabezados numéricos, compras idénticas, traslados propios, pagos de Amex y estados traslapados.
