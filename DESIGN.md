# Marcelito Design System

## Intent

Una sala de control personal al final del día: crema, silenciosa y legible. La interfaz usa una base crema cálida y un azul marino firme para decisiones; el resto son variaciones de azul para explicar el tipo de flujo.

## Visual Direction

- Design variance: 6. Asimetría moderada y jerarquía clara.
- Motion intensity: 4. Transiciones breves de estado, sin coreografía de entrada.
- Visual density: 6. Información suficiente para decidir, con aire alrededor de cifras importantes.
- Theme: crema y azul marino como apariencia principal; tokens preparados para contraste y adaptación.
- Shape: tarjetas de 14px; controles de 10px; botones principales con radio de 10px.

## Color

Todos los colores se expresan en OKLCH.

```css
--bg: oklch(0.965 0.025 92);
--surface: oklch(0.985 0.012 92);
--surface-raised: oklch(0.925 0.025 92);
--ink: oklch(0.22 0.055 255);
--muted: oklch(0.43 0.045 255);
--line: oklch(0.82 0.03 92);
--primary: oklch(0.32 0.09 255);
--income: oklch(0.39 0.075 255);
--transfer: oklch(0.48 0.095 255);
--expense: oklch(0.55 0.11 255);
--debt: oklch(0.29 0.07 255);
--danger: oklch(0.43 0.11 25);
```

Ámbar identifica decisiones, selección y acciones. Verde significa dinero nuevo, azul movimiento interno, ámbar gasto y violeta deuda. Cada estado añade icono o texto para no depender solo del color.

## Typography

- Web: Geist Sans para interfaz y Geist Mono para importes, fechas y referencias.
- iOS: estilos tipográficos de San Francisco mediante Dynamic Type; `monospacedDigit()` para importes.
- Importes protagonistas usan cifras tabulares.
- Etiquetas permanecen en sentence case; no se usan cejas en mayúsculas decorativas.

## Layout

- Web: barra lateral de 248px en escritorio, navegación inferior en móvil y contenido máximo de 1440px.
- iOS: `TabView` con cinco secciones y `NavigationStack` por sección.
- Inicio: patrimonio y explicación ocupan el primer bloque; indicadores secundarios forman una franja desigual; el mapa de dinero es el centro narrativo.
- Las tablas de revisión aparecen solo durante la importación, donde la edición fila por fila es la tarea real.

## Interaction

- Transiciones de 180-240ms con curva de salida exponencial.
- Los cambios de categoría actualizan inmediatamente resumen y recomendación.
- La carga de PDF avanza por extracción, conciliación y revisión.
- Filas de baja confianza requieren confirmación explícita.
- Todos los controles tienen estados hover, focus, active, disabled, loading, error y success.

## Privacy

- Los PDF no se incorporan al repositorio ni a datos de demostración.
- La UI enmascara identificadores y evita mostrar nombre o domicilio.
- La primera implementación procesa archivos localmente en el navegador; la sincronización remota queda detrás de una capa de persistencia reemplazable.
