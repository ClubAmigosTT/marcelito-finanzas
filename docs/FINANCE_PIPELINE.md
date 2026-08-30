# Motor financiero reproducible

Marcelito calcula los KPI desde un libro mayor canónico. Cada importación pasa por
este orden, antes de que cualquier cifra llegue al dashboard:

`extraer → validar → normalizar → deduplicar → matching entre cuentas → clasificar → conciliar → calcular`

## Reglas de calidad

- Una fila importada necesita fecha válida, importe distinto de cero, descripción con texto de comercio y dirección (entrada o salida). Encabezados, totales, RFC, CLABE, saldos y metadatos administrativos se rechazan.
- La identidad de una operación es `cuenta + fecha canónica + importe en centavos + concepto normalizado + tipo`. Se conserva más de una operación idéntica dentro del mismo estado (pueden ser compras reales) y solo se elimina la repetición entre estados.
- Una salida bancaria y entrada bancaria propia del mismo importe en ±2 días se concilian como `internalTransfer`. Una salida bancaria y el movimiento equivalente de una tarjeta se concilian como `cardPayment`. Ambos quedan fuera de ingresos y gasto consolidado.
- El gasto se suma por la fecha del movimiento y por el periodo seleccionado; nunca se suman todos los resúmenes de todos los PDFs. Los resúmenes se usan como respaldo de saldos de tarjeta cuando no hay filas válidas.
- La deuda procede de tarjetas/créditos: saldo al corte, saldo revolvente y MSI pendientes se mantienen separados del efectivo bancario.

El bloque de auditoría del Inicio expone los conteos y montos de cada periodo. También muestra las identidades contables y marca los KPI como provisionales cuando hay filas rechazadas, movimientos relevantes por revisar o una conciliación fuera de tolerancia.

Las pruebas reproducibles se ejecutan con `node --experimental-strip-types --test tests/reconciliation.test.ts` y cubren encabezados numéricos, compras idénticas, traslados propios, pagos de Amex y estados traslapados.
