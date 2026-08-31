# Roadmap del lector de estados al 99%

## Definición de éxito

La meta es **99% de precisión de aceptación automática**: de todos los
documentos que el sistema marca como `valid` y alimentan el libro canónico,
al menos 99 de cada 100 deben coincidir con el estado original en emisor,
periodo, filas, importes, dirección y clasificación. No se promete que OCR
reconozca el 99% de los caracteres; una lectura incierta se bloquea o queda
provisional.

La unidad de control es el estado de cuenta y la unidad de auditoría es cada
movimiento. Toda aceptación debe conservar evidencia suficiente para llegar
desde el KPI hasta la página, coordenadas y texto que originaron la fila.

## Arquitectura objetivo

1. **Ingesta inmutable**: conservar archivo, hash SHA-256, tamaño, número de
   páginas, fecha de importación y versión del lector. Nunca sobrescribir una
   importación anterior.
2. **Detección de emisor**: puntuar únicamente evidencia institucional del
   encabezado (razón social, dominio, producto y formato); las contrapartes en
   movimientos no pueden cambiar el banco detectado.
3. **Extracción por capas**: usar primero la capa de texto del PDF; si es
   insuficiente, ejecutar OCR visual por página con coordenadas y confianza.
   Mantener cada observación con página, bounding box, método y confianza, y
   persistir un fragmento de origen acotado en cada movimiento aceptado.
4. **Reconstrucción de filas**: anclar por fecha válida, agrupar descripción y
   tomar el importe desde la columna correcta (CARGOS/ABONOS o IMPORTE), nunca
   desde referencias, saldos corridos ni números administrativos.
5. **Validación y normalización**: validar fecha real, importe monetario,
   descripción y dirección; normalizar comercio, moneda, separadores, meses
   OCR y conceptos.
6. **Deduplicación y matching**: generar llave estable por cuenta + fecha +
   importe + concepto normalizado + tipo; después emparejar transferencias
   propias y pagos de tarjeta en ±2 días.
7. **Clasificación**: separar compra, ingreso, reembolso, transferencia,
   pago de tarjeta, interés, comisión, crédito y MSI.
8. **Conciliación**: comparar filas, conteos y totales con el resumen del
   emisor. Una discrepancia bloquea la importación.
9. **Libro canónico**: Resumen, Gastos, Patrimonio y gráficas solo leen esta
   tabla de movimientos conciliados; nunca el texto crudo ni estados parciales.
10. **Puerta de calidad**: estados `pending`, `invalid` o con OCR débil no
    alimentan KPI; se muestran en diagnóstico con el motivo exacto.

## Fases y criterios de salida

### Fase 0 — Contrato y corpus dorado

- Registrar una muestra por emisor, plantilla, periodo, texto/OCR y casos
  difíciles (solapamiento, pagos Amex, transferencias, encabezados numéricos).
- Guardar expectativas de emisor, tipo, estado, conteos y totales sin incluir
  datos personales en el repositorio.
- Salida: manifiesto versionado y comando reproducible
  `npm run pdf:corpus -- --dir ... --manifest ...`.

### Fase 1 — Texto estructurado

- Implementar detectores de encabezado y regiones de tabla para Santander,
  BBVA y Amex.
- Aplicar reglas de rechazo para RFC, CLABE, certificados, saldos, totales,
  periodos y texto administrativo.
- Salida: 100% de estados con texto que concilian importes y conteos; cero
  encabezados aceptados como movimiento.

### Fase 2 — Normalización contable

- Unificar comercios y conceptos con diccionario determinista y alias
  versionados; conservar descripción original.
- Aplicar deduplicación idempotente y matching entre cuentas propias y tarjetas.
- Salida: reimportar el mismo archivo no cambia el libro; dos compras idénticas
  legítimas permanecen como dos filas.

### Fase 3 — OCR visual controlado

- Ejecutar Vision en iOS por página, con escala adaptativa, coordenadas y
  confianza real por observación/página.
- Usar correcciones OCR estrictamente acotadas a tokens de fecha (por ejemplo
  `AG0`→`AGO`, `O5/AGO`, `OBIAGO`); nunca sustituir texto globalmente.
- Salida: promedio de página ≥88%, ninguna página <78%, cobertura de filas
  completa y conciliación dentro de ±$0.05; de lo contrario, revisión humana.

### Fase 4 — Conciliación y libro canónico

- Ejecutar siempre: extraer → validar → normalizar → deduplicar → matching →
  clasificar → conciliar → calcular.
- Validar identidades: saldo inicial + ingresos − egresos = saldo final; límite −
  disponible = deuda utilizada; ingresos − gasto real = flujo neto; patrimonio =
  efectivo − deuda.
- Salida: cualquier identidad fuera de tolerancia marca periodo inconsistente y
  bloquea el dashboard ejecutivo.

### Fase 5 — Auditoría y observabilidad

- Mostrar por periodo archivos, páginas, filas extraídas/válidas, duplicados,
  transferencias, pagos de tarjeta, ingresos, gastos, reembolsos, pendientes,
  confianza OCR y diferencias de conciliación.
- Registrar versión del parser, hash del archivo y razones de bloqueo.
- Salida: cada cifra del dashboard se puede explicar hasta filas y evidencia.

### Fase 6 — Certificación y despliegue

- Ejecutar el corpus completo en macOS/Xcode, incluyendo Vision y simulador.
- Publicar solo si precisión de aceptación ≥99%, cobertura de plantillas 100%,
  cero falsos positivos administrativos y todas las identidades contables
  pasan.
- Mantener canary: nuevas plantillas empiezan en `pending`, se miden durante
  una versión y solo después se habilita su aceptación automática.
- El workflow de iOS se ejecuta en `push`, `pull_request` y manualmente para
  evitar que cambios del lector lleguen a distribución sin compilar y correr
  las pruebas de contrato en macOS.

## Umbrales y respuesta

| Señal | Umbral | Acción |
| --- | ---: | --- |
| Diferencia de total/conteo | > $0.05 o cualquier conteo distinto | Bloquear estado |
| Importe absurdo | ≥ $100,000,000 o identificador no monetario | Rechazar fila |
| Confianza OCR media | < 88% | Provisional |
| Confianza mínima de página | < 78% | Provisional |
| Cobertura de filas | < 100% cuando el estado declara conteo | Bloquear estado |
| Identidad contable | Fuera de tolerancia | Marcar periodo inconsistente |
| Precisión automática del corpus | < 99% | Detener publicación |

## Estado actual

El repositorio ya implementa las fases 1–5 para la capa web y el contrato de
lectura iOS, incluyendo pruebas de encabezados, duplicados legítimos,
transferencias, pagos Amex, MSI, conteos BBVA, confianza por página y fechas
OCR. En los ocho adjuntos disponibles, cuatro estados de texto concilian y
cuatro estados escaneados quedan correctamente bloqueados hasta Vision.

La certificación final del 99% queda pendiente de ejecutar el corpus completo
en macOS/Xcode con Vision; el entorno Windows no dispone de `xcodebuild` ni del
framework Vision. Hasta completar esa corrida, los estados OCR no deben
alimentar KPI productivos.
