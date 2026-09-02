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

La confianza del proveedor también se trata como una compuerta, aunque la
respuesta conserve `mode: "text"` para compatibilidad con el importador
existente: el proxy y el cliente exigen una media mínima de 88% y una media
por página mínima de 78% sobre las filas visuales. Una respuesta por debajo de
esos umbrales se rechaza o queda provisional; nunca se presenta como un estado
`ready` ni llega a los KPI.

El prompt versionado (`statement-reader-v2`) pide una doble pasada: ubicar la
tabla por página y después reconstruir filas comprobando conteos y sumas. Las
filas se devuelven ordenadas y sin combinar operaciones de páginas continuas;
si el modelo no puede demostrar una fila, debe omitirla para que la
conciliación la bloquee, en lugar de inventar un importe.

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
STATEMENT_READER_MAX_OUTPUT_TOKENS=32768
pnpm reader:server
```

La clave y la URL del proveedor solo existen en el servidor. El proxy acepta
un endpoint compatible con Responses API o Chat Completions para poder probar
proveedores como Zen sin modificar el cliente; el formato de la petición se
elige según la ruta configurada. La compatibilidad multimodal y de salida
estructurada debe verificarse por modelo antes de usarlo en producción. El
proxy:

- exige `Authorization: Bearer …` (o `x-reader-token`) y origen exacto;
- limita solicitudes autenticadas por origen y lecturas simultáneas, con un
  tiempo máximo configurable para el proveedor;
- reserva hasta 32,768 tokens de salida por defecto para que estados con muchas
  filas no se corten a mitad del JSON; el límite puede ajustarse por entorno;
- limita el PDF a 20 MB y no lo persiste;
- envía el PDF como `input_file` a la Responses API, con `store:false` y
  salida `json_schema` estricta;
- si un gateway compatible rechaza únicamente `json_schema`, reintenta una
  sola vez solicitando JSON directo; el mismo validador estricto del servidor
  sigue siendo obligatorio antes de entregar el resultado;
- entiende tanto la envoltura Responses (`output_text`/`output`) como la
  envoltura compatible Chat Completions (`choices`), sin relajar el contrato;
- no devuelve el PDF ni texto bruto, solo la extracción y su huella SHA-256;
- no registra nombres, filas, importes ni respuestas del proveedor.

Antes de exponerlo públicamente hay que colocarlo detrás de autenticación de
usuario, rate limiting y TLS. No se debe poner `OPENAI_API_KEY` ni un token
permanente en `VITE_*`, en una app móvil o en el repositorio.

Antes de cargar estados reales, el propietario puede ejecutar un preflight
autenticado en `POST /api/statement-reader/preflight`. El proxy envía un PDF
syntético generado en memoria con una sola fila conocida y exige que el
proveedor la recupere con los valores exactos además de cumplir el contrato;
el resultado solo indica `status: "ready"`, el modelo y la versión del contrato.
Este control no sube ningún estado del usuario y permite detectar si el modelo
configurado realmente admite entrada PDF y salida JSON estructurada.
La interfaz espera hasta 120 segundos para contemplar el arranque en frío del
servicio gratuito; un timeout no desbloquea ni modifica los KPI.

El `render.yaml` de este repositorio deja preparado el patrón de dos servicios:
la web estática expone solo `VITE_STATEMENT_READER_URL` y el servicio Node
`marcelito-statement-reader` conserva las dos credenciales como secretos. El
valor inicial de Render usa el modelo gratuito
`muse-spark-1.2-contributor-free` de Zen porque es uno de los modelos que Zen
publica en el endpoint `/v1/responses`; aun así, se debe hacer una prueba con
un PDF anonimizado y comprobar que el modelo realmente acepta archivos y
salida estructurada antes de enviar estados reales. El proxy rechaza por
configuración cualquier modelo de Zen que no esté en la lista gratuita vigente
(`muse-spark-1.2-contributor-free`, `mimo-v2.5-free`,
`ling-3.0-flash-fin-free`, `nemotron-3-ultra-free`,
`nemotron-3.5-lightning-free` o `big-pickle`), de modo que una variable de
entorno mal escrita no puede activar accidentalmente un modelo de pago. Los
demás proveedores compatibles conservan su propia política de facturación.
En Zen, Muse Spark usa `/v1/responses`; los otros modelos gratuitos publicados
para este lector usan `/v1/chat/completions`. El proxy marca la configuración
como no lista si el modelo y la ruta no corresponden, antes de aceptar archivos.
Los modelos gratuitos de Zen pueden tener condiciones de uso de datos distintas
al lector local; por eso la interfaz muestra una advertencia y pide consentimiento
cada vez que se envía un PDF nuevo. El lector local sigue siendo la opción por
defecto para mantener los estados en el dispositivo.

## Activación progresiva

1. Ejecutar el lector local y guardar su diagnóstico.
2. Si el PDF queda bloqueado por texto desordenado/OCR, mostrar “Reintentar
   con lector avanzado” y solicitar consentimiento.
3. Exigir que el preflight del proveedor haya terminado correctamente antes de
   enviar un PDF real; si no, conservarlo en el lector local.
4. Comparar proveedor multimodal y lector local en modo sombra; aceptar solo
   cuando las filas y totales concilien.
5. Guardar en el estado del documento `extractionProvider`, `readerVersion`,
   `extractionModel` y `extractionPromptVersion` para reproducibilidad.
6. Habilitar los KPIs únicamente desde el ledger canónico ya conciliado.

La precisión se mide sobre un corpus privado de estados reales con totales
conocidos. Nunca se publica el PDF; en el repositorio solo deben quedar hashes,
metadatos saneados y casos sintéticos.
