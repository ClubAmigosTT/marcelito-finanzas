# Ruta legacy retirada

La ruta de lectura multimodal de PDFs fue reemplazada. Marcelito procesa los
estados localmente con PDF.js/Tesseract en web y PDFKit/Vision en iOS; no envía
PDFs a OpenCode Zen.

La integración vigente está documentada en
[transaction-classifier.md](transaction-classifier.md). Zen recibe únicamente
filas de gasto ya validadas para sugerir comercio, categoría, recurrencia y
viajes. Los importes, fechas, dirección, tipo contable, conciliación y matching
de transferencias siguen siendo deterministas y locales.

El endpoint `/api/statement-reader` y los contratos antiguos se conservan solo
para que builds anteriores puedan migrar sin romper el almacenamiento. La app
actual no los invoca; antes de una exposición nueva deben retirarse o aislarse
en el gateway.
