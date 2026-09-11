# RappiCard: alcance de la integración iOS

El lector específico reconoce el encabezado RappiCard aunque el documento también muestre Banorte. Identifica la cuenta con una terminación enmascarada y el periodo impreso, sin usar el nombre del archivo.

## Reglas

- Lee solamente la tabla de cargos, abonos y compras regulares. No importa páginas fiscales, recompensas ni tablas de reclamaciones como nuevas compras.
- Conserva operaciones idénticas dentro del mismo estado. Los duplicados de capturas pasan por la revisión existente.
- Invierte el signo impreso de la tarjeta: compra positiva a gasto negativo; abono negativo a crédito positivo. Pago por SPEI es pago de tarjeta, no ingreso.
- Usa el monto MXN firmado, no el importe USD ni la tasa de conversión de una compra extranjera.
- Comprueba cargos y pagos/abonos contra cifras independientes del resumen y verifica saldo anterior + cargos − abonos = saldo final.
- El formato con saldo o capital a meses distinto de cero queda pendiente: requiere un ejemplo con MSI antes de habilitarlo.
- Las capturas se leen por bloques de comercio, fecha, monto y Titular. No se importa cashback informativo +$, operaciones rechazadas ni filas finales incompletas. Las filas tapadas deben volver a capturarse; el OCR no puede garantizar que detecte toda oclusión.
- Las capturas sin marca se importan desde la cuenta Rappi seleccionada. Sin identidad de cuenta explícita no se fuerza conciliación automática con un PDF.
- La palabra Rappi sola ya no implica restaurante. Se usa el comercio cuando es identificable; en otro caso queda por revisar.

## Verificación

`scripts/audit-rappi-pdfs.py` es una comprobación local independiente de sumas sobre PDFs privados con pypdf. No copia archivos ni imprime datos de cuenta o comercios. Esta comprobación pasó con los tres documentos proporcionados, pero no sustituye ejecutar Swift/PDFKit.

Se agregaron pruebas nativas sintéticas en `RappiReaderTests.swift` para identidad, periodo, sumas, abonos faltantes, límites MSI, moneda extranjera y capturas. Deben ejecutarse en Xcode junto con el resto de la suite. No se han ejecutado en Windows.

Antes de TestFlight: compilar en Xcode, ejecutar las pruebas y probar PDFKit/Vision con el corpus privado y con capturas superpuestas en un iPhone. Los estados anteriormente rechazados necesitan relectura del original. No se publicó ni se modificó el número de versión en esta integración.
