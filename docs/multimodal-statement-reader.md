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
STATEMENT_READER_API_KEY=...
STATEMENT_READER_MODEL=<modelo-vision-compatible>
STATEMENT_READER_PROVIDER_URL=https://api.openai.com/v1/responses
STATEMENT_READER_TOKEN=<token-largo-aleatorio>
STATEMENT_READER_ALLOWED_ORIGIN=https://<origen-de-la-app>
STATEMENT_READER_MAX_REQUESTS_PER_MINUTE=10
STATEMENT_READER_MAX_CONCURRENT_REQUESTS=2
STATEMENT_READER_PROVIDER_TIMEOUT_MS=120000
pnpm reader:server
```

La clave y la URL del proveedor solo existen en el servidor. El proxy acepta
un endpoint compatible con Responses API para poder probar proveedores como
Zen sin modificar el cliente; la compatibilidad multimodal y de salida
estructurada debe verificarse por modelo antes de usarlo en producción. El
proxy:

- exige `Authorization: Bearer …` (o `x-reader-token`) y origen exacto;
- limita solicitudes autenticadas por origen y lecturas simultáneas, con un
  tiempo máximo configurable para el proveedor;
- limita el PDF a 20 MB y no lo persiste;
- envía el PDF como `input_file` a la Responses API, con `store:false` y
  salida `json_schema` estricta;
- no devuelve el PDF ni texto bruto, solo la extracción y su huella SHA-256;
- no registra nombres, filas, importes ni respuestas del proveedor.

Antes de exponerlo públicamente hay que colocarlo detrás de autenticación de
usuario, rate limiting y TLS. No se debe poner `OPENAI_API_KEY` ni un token
permanente en `VITE_*`, en una app móvil o en el repositorio.

El `render.yaml` de este repositorio deja preparado el patrón de dos servicios:
la web estática expone solo `VITE_STATEMENT_READER_URL` y el servicio Node
`marcelito-statement-reader` conserva las dos credenciales como secretos. El
valor inicial de Render usa el modelo gratuito
`muse-spark-1.2-contributor-free` de Zen porque es uno de los modelos que Zen
publica en el endpoint `/v1/responses`; aun así, se debe hacer una prueba con
un PDF anonimizado y comprobar que el modelo realmente acepta archivos y
salida estructurada antes de enviar estados reales.

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
