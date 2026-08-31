# Contribuir

Antes de abrir un pull request ejecuta `npm test`, `npm run lint` y `npm run
build`. No incluyas estados financieros reales: usa los fixtures sintéticos o
un corpus local fuera de Git.

Los cambios que afectan importación, conciliación o métricas deben incluir una
prueba reproducible y conservar el orden del pipeline:

`extraer → validar → normalizar → deduplicar → matching → clasificar →
conciliar → calcular`.

Las subidas a TestFlight se hacen únicamente mediante el workflow protegido y
requieren revisión de un mantenedor.
