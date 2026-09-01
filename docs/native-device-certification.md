# Certificación del lector sin Mac

Marcelito puede certificar el lector nativo directamente en un iPhone. La
herramienta usa el mismo PDFKit + Vision de producción, pero trabaja sobre una
selección temporal de estados y no escribe movimientos en el libro canónico.

## Ejecutar en el iPhone

1. Abre **Resumen → Opciones → Diagnóstico → Certificar estados con Vision**.
2. Selecciona los 10 estados validados desde Archivos.
3. Pulsa **Ejecutar Vision** y espera a que termine cada PDF.
4. Solo se acepta un corpus con al menos 10 archivos únicos, todos conciliados,
   emisor verificado, sin revisión pendiente, OCR ≥ 88% y página más débil ≥
   78%. Para Santander también deben estar calibradas las columnas.
5. Comparte **informe JSON** y guárdalo como
   `docs/native-corpus-certification.json` en el repositorio. El archivo está
   sanitizado: no contiene PDFs, descripciones, saldos ni importes.

El informe conserva hashes SHA-256 y señales de calidad para demostrar que los
archivos fueron procesados, pero no permite reconstruir un estado de cuenta.
Un PDF duplicado o un estado pendiente bloquea la certificación completa.

## Publicación posterior

El workflow `iOS TestFlight` valida automáticamente ese JSON contra la versión
actual (`FinanceStore.readerVersion`). Si el informe no coincide, está vencido,
contiene una fila incompleta o queda por debajo de 99%, la build se detiene.

La primera build que incluye esta herramienta se ejecuta manualmente con la
opción **Bootstrap: incluir la herramienta de certificación local**. Esa opción
solo instala el certificador; no certifica el corpus por sí misma. Después de
subir el informe sanitizado al repositorio, las siguientes builds vuelven a usar
la compuerta normal y ya no requieren una Mac externa.

Los estados permanecen en el iPhone y el JSON se puede revisar antes de
publicarlo. Si un archivo falla, corrígelo o vuelve a seleccionarlo; nunca se
debe marcar `certified` manualmente.
