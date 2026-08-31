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
- Un estado que concilia pero permanece en revisión manual tampoco se considera
  verificado: sus filas quedan fuera de los KPI y el último `AuditRunRecord`
  permanece bloqueado hasta que el usuario lo confirme.
- iOS conserva esas filas para inspección, ofrece **Confirmar estado revisado**
  desde las cifras del corte y vuelve a ejecutar la autoauditoría al liberar el
  estado; una conciliación inválida nunca puede saltarse con esa acción.

El bloque de auditoría del Inicio expone los conteos y montos de cada periodo. También muestra las identidades contables y marca los KPI como provisionales cuando hay filas rechazadas, movimientos relevantes por revisar o una conciliación fuera de tolerancia.

## Reconstrucción canónica en iOS

La siguiente actualización de la app ejecuta una migración única (canonicalRebuild.v1):

1. Captura los PDFs locales y elimina todos los movimientos ligados a estados anteriores; conserva únicamente movimientos manuales.
2. Deduplica archivos por huella SHA-256 y reimporta cada estado con extracción, OCR y controles de totales.
3. Guarda el estado y su evidencia de conciliación. Las filas de estados inválidos o pendientes quedan fuera del libro canónico, aunque el documento permanece visible en Diagnóstico.
4. Solo estados con status valid alimentan saldos, gasto, flujo, patrimonio y gráficas. Si falta alguno de los diez estados validados o aparece una inconsistencia, los KPI e históricos se muestran como bloqueados.

En iOS, Resumen, Gastos, Cuentas, Patrimonio y sus tendencias leen el mismo arreglo persistido de movimientos canónicos. El menú Diagnóstico muestra el porcentaje conciliado, cada estado, los motivos de bloqueo y las identidades contables.

## Autoauditoría y recuperación

- El libro activo se guarda en un sobre versionado (`schemaVersion`, `ledgerVersion` y fecha) que contiene estados y movimientos juntos. Las claves antiguas se conservan únicamente como compatibilidad de una versión.
- Una reconstrucción marca primero `inProgress` y guarda el último sobre completo. Si iOS termina el proceso inesperadamente, al siguiente arranque se restaura ese sobre y la reconstrucción se reintenta; nunca se publica un libro parcial.
- La auditoría automática corre al finalizar una reconstrucción y al volver la app a primer plano. Persiste el identificador de auditoría, disparador, versión del libro, porcentaje conciliado, conteo de problemas y estado `Verificado`, `Advertencias` o `Bloqueado`.
- Un estado de auditoría crítico bloquea KPI e históricos. Las correcciones automáticas se limitan a normalización, deduplicación y matching inequívoco; importes o fechas ambiguos quedan en cuarentena.

Las pruebas reproducibles se ejecutan con `node --experimental-strip-types --test tests/reconciliation.test.ts` y cubren encabezados numéricos, compras idénticas, traslados propios, pagos de Amex y estados traslapados.
