# Marcelito Finanzas

Marcelito es una app local para entender gastos, cuentas, deuda y patrimonio.
Los estados de cuenta se procesan en el dispositivo; el repositorio no contiene
PDFs, exportaciones bancarias, credenciales ni un corpus financiero real.

## Desarrollo

```bash
npm ci
npm test
npm run lint
npm run build
```

La carpeta `tests/fixtures` contiene únicamente controles sintéticos. Los
documentos reales deben mantenerse fuera del repositorio y pasar por la
compuerta de conciliación antes de alimentar cualquier KPI.

La lectura de PDFs es siempre local: PDF.js/Tesseract en web y PDFKit/Vision en
iOS. El endpoint opcional configurado con `VITE_TRANSACTION_CLASSIFIER_URL`
(`VITE_STATEMENT_READER_URL` se conserva solo como alias de builds anteriores)
se usa únicamente como clasificador posterior de gastos ya conciliados
(comercio, categoría, recurrencia y viajes); nunca recibe PDFs, cuentas, saldos
ni decide ingresos o transferencias. Su contrato y configuración segura están
documentados en [docs/transaction-classifier.md](docs/transaction-classifier.md).

## iOS

El proyecto nativo se genera con XcodeGen (`apps/ios/project.yml`). El workflow
`iOS Validate` compila y ejecuta los contratos del lector en macOS. El workflow
`iOS TestFlight` está separado y protegido por el entorno `testflight`; nunca
se deben copiar certificados, perfiles, claves `.p8` o contraseñas al código.

Consulta [SECURITY.md](SECURITY.md) para reportar una exposición o rotar una
credencial.
