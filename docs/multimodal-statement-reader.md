# Lector multimodal de estados

Esta etapa añade un lector multimodal como respaldo para PDFs difíciles sin
convertirlo en una fuente de verdad. El recorrido obligatorio es:

`PDF → proveedor multimodal → contrato JSON estricto → validación local → conciliación con totales → pipeline canónico → KPIs`

El lector local continúa siendo el camino por defecto. El envío al proxy debe
ser una acción explícita del usuario para cada PDF; así no se suben estados
financieros de forma silenciosa.

## Contrato

El contrato versionado está en
`schemas/statement-extraction.schema.json`. Los importes se expresan como
centavos enteros absolutos y `direction` (`in`/`out`) determina el signo. Cada
fila exige fecha ISO, descripción, tipo, página, fragmento de evidencia y
confianza. El validador del cliente rechaza filas administrativas, fechas
imposibles, importes fuera de rango, páginas inexistentes y propiedades
desconocidas.

La conversión a `ImportResult` marca la evidencia como `multimodal`, conserva
la versión del contrato/modelo y ejecuta `reconcileStatementImport`. Un
resultado del proveedor que no concilia queda bloqueado y no puede alimentar
el libro canónico.

## Proxy seguro

El servidor está en `server/statement-reader.mjs` y se inicia con:

```text
OPENAI_API_KEY=... 
OPENAI_STATEMENT_MODEL=<modelo-vision-compatible>
STATEMENT_READER_TOKEN=<token-largo-aleatorio>
STATEMENT_READER_ALLOWED_ORIGIN=https://<origen-de-la-app>
pnpm reader:server
```

La clave del proveedor solo existe en el servidor. El proxy:

- exige `Authorization: Bearer …` (o `x-reader-token`) y origen exacto;
- limita el PDF a 20 MB y no lo persiste;
- envía el PDF como `input_file` a la Responses API, con `store:false` y
  salida `json_schema` estricta;
- no devuelve el PDF ni texto bruto, solo la extracción y su huella SHA-256;
- no registra nombres, filas, importes ni respuestas del proveedor.

Antes de exponerlo públicamente hay que colocarlo detrás de autenticación de
usuario, rate limiting y TLS. No se debe poner `OPENAI_API_KEY` ni un token
permanente en `VITE_*`, en una app móvil o en el repositorio.

## Activación progresiva

1. Ejecutar el lector local y guardar su diagnóstico.
2. Si el PDF queda bloqueado por texto desordenado/OCR, mostrar “Reintentar
   con lector avanzado” y solicitar consentimiento.
3. Comparar proveedor multimodal y lector local en modo sombra; aceptar solo
   cuando las filas y totales concilien.
4. Guardar en el estado del documento `extractionProvider`, `readerVersion`,
   `extractionModel` y `extractionPromptVersion` para reproducibilidad.
5. Habilitar los KPIs únicamente desde el ledger canónico ya conciliado.

La precisión se mide sobre un corpus privado de estados reales con totales
conocidos. Nunca se publica el PDF; en el repositorio solo deben quedar hashes,
metadatos saneados y casos sintéticos.
