# Guía de Interfaces iOS 6 — Skeuomorphism

> SDK objetivo: `iPhoneOS6.1.sdk` en `/home/main/theos/sdks/iPhoneOS6.1.sdk`
> Proyecto: `wave` (`com.bytebox.wave`) | `TARGET := iphone:clang:6.1:6.1` (`Makefile:1`)
> Última versión skeuomórfica antes del redesign flat de iOS 7 (19 Sep 2012, codename Sundance). Sucesor: iOS 7 (18 Sep 2013).

---

## 1. Filosofía: qué es Skeuomorphism

> "Make digital contexts feel familiar by replicating analog forms and recognizable physical materials." — Apple HIG 2012

- Cada elemento imita un material físico real para que el usuario entienda su función sin aprendizaje previo.
- Pico en iOS 6 y OS X Mountain Lion bajo Scott Forstall / Steve Jobs. Jony Ive lo elimina en iOS 7 argumentando que el usuario ya sabe usar cristal táctil.
- No es solo decoración: carpeta = carpeta real, estantería = estantería real, botón = botón físico presionable.

### Ejemplos canónicos iOS 6
| App | Metáfora física |
|-----|-----------------|
| **Notes** | Papel amarillo de bloc con líneas azules y margen rojo |
| **Calendar (iPad/OS X)** | Cuero marrón con costuras / textura del Gulfstream de Jobs |
| **Newsstand / iBooks** | Estantería de madera con veta y sombras |
| **Voice Memos** | Micrófono metálico cromado con malla |
| **Game Center** | Mesa de juego con fieltro verde y madera |
| **Find My Friends** | Cuero cosido |
| **Passbook (nuevo iOS 6)** | Tarjetas de embarque / tickets de papel |
| **Clock (iPad, nuevo iOS 6)** | Reloj ferroviario suizo (licenciado a SBB) |
| **Music** | Reproductor blanco con scrubber sensible al movimiento (estilo iPod nano 7G) |

---

## 2. Lenguaje visual

### Paleta y luz
- **Gradientes multi-stop** (3+ tonos), siempre **claro arriba → oscuro abajo**. Nunca color plano.
- **Fuente de luz consistente**: arriba o arriba-izquierda. Highlights arriba, sombras abajo-derecha en TODO.
- **Brillo / Gloss**: franja blanca-transparente en la mitad superior de botones e iconos (`rgba(255,255,255,0.45) → rgba(255,255,255,0.10)` vía `::before { height:50% }`). Sin esto el elemento parece plano.

### Sombras, biseles y profundidad
- **2-3 sombras por elemento**: sombra dura de contacto + sombra difusa ambiental (`0 3px 8px rgba(0,0,0,0.3), inset 0 1px 0 rgba(255,255,255,0.35)`).
- **Bevel / inner highlight** para simular borde biselado que atrapa luz.
- **Profundidad extrema**: nada es plano. Incluso separadores de tabla tienen sombra interna.

### Texturas (nunca color sólido)
| Material | Técnica CSS / UIKit |
|----------|---------------------|
| **Linen gris** (fondo de carpetas, Notification Center) | Base `#3a3a3a` + `repeating-linear-gradient` cruzado baja opacidad |
| **Linen beige / Canvas** | Beige + grid cruzado |
| **Cuero cosido** | Degradado marrón oscuro + `repeating-linear-gradient` ruido + `border: dashed` para puntadas + `inner shadow` |
| **Madera** | Marrón cálido + rayas horizontales `repeating-linear-gradient` + gradiente direccional |
| **Aluminio cepillado** | Gris claro multi-stop + rayas horizontales finas + `border-top` highlight |
| **Papel / Bloc** | Gradiente `off-white → pale-yellow` + líneas regladas `repeating-linear-gradient` + línea roja margen vía `::before` |
| **Plástico brillante** | Color vivo + gradiente 3 stops + overlay gloss superior |
| **Vidrio** | Blanco semitransparente + `backdrop-filter: blur()` (no disponible en iOS 6, se simulaba con transparencia) |

> **Regla**: fidelidad de textura crítica. Tiling visible rompe la ilusión. Mejor generar con gradientes que usar PNG de baja calidad.

### Tipografía
- **Helvetica Neue Bold** para títulos de barra.
- Sombras de texto grabadas: `text-shadow: 0 1px 0 rgba(0,0,0,0.5)` o `0 1px 0 rgba(255,255,255,0.5)` para efecto emboss.
- Tono conversacional, corto y amigable (HIG: "Each word matters").

---

## 3. Componentes UIKit en SDK 6.1

> Referencia directa al SDK instalado en `/home/main/theos/sdks/iPhoneOS6.1.sdk` (`SDKSettings.plist: CanonicalName=iphoneos6.1`, `IPHONEOS_DEPLOYMENT_TARGET=6.1`)

### UINavigationBar
- Degradado azul brillante (`#6d8cb0 → #3b5a7f`) con franja gloss superior.
- Título blanco centrado con sombra.
- `UIBarButtonItem` azul con borde, sombra y gloss. Estilo por defecto `UIBarStyleDefault`. No existe `tintColor` moderno ni `UINavigationBarAppearance`.
- Status bar: `UIStatusBarStyleBlackTranslucent` o `BlackOpaque` con gradiente.

### UITabBar
- Negro con degradado brillante + borde superior metálico claro.
- Iconos PNG glossy (no SF Symbols). Solo `filled` estilo.
- 5 tabs máximo visibles; el sexto es "More" con lista.

### UITableView
- **Grouped**: fondo `groupTableViewBackgroundColor` = rayas pinstripes grises verticales (`#e5e5e5`). Celdas con esquinas redondeadas `10pt`, sombra externa + gradiente blanco `#ffffff → #f5f5f5`, separadores con sombra interna.
- **Plain**: fondo pinstripes, celdas planas con línea separadora `1px #c8c7cc` + sombra sutil. Wave combina tablas plain y grouped según la pantalla, con componentes custom en `Views/`.
- `UITableViewCellStyleDefault` con `textLabel` Helvetica 17pt, `detailTextLabel` 14pt gris.

### Otros controles
- **UIToolbar**: Aluminio cepillado o negro translúcido.
- **UISegmentedControl**: Bevelado, con divisores metálicos y segmento seleccionado con gradiente azul presionado.
- **UISwitch**: Track con degradado + sombra, thumb con brillo y borde.
- **UIAlertView / UIActionSheet**: Borde negro grueso `3px`, esquinas `10pt`, fondo linen oscuro + gloss, botones con gradiente azul/rojo.
- **UISlider / UIProgressView**: Barra con track interno sombreado + thumb circular brillante.

### Iconos
- Tamaños: `57x57` (1x), `114x114` (2x) iPhone, `72x72`/`144x144` iPad — ver `Resources/AppIcon57x57.png` etc.
- Gloss automático de sistema (`UIPrerenderedIcon = true` en `Resources/Info.plist:19`), esquinas redondeadas `~10px`, borde + sombra. No aplanar.

---

## 4. Patrones de navegación y layout (HIG iOS 6)

1. **No mezclar estilos**: usar elementos de una sola versión de iOS (6.1). No combinar flat con skeuomorfico.
2. **Visible siempre la barra de navegación/tab bar** excepto en modal fullscreen.
3. **Split View en iPad** (`UISplitViewController`): master a la izquierda, detail a la derecha con toolbar.
4. **Share Sheet** (nuevo iOS 6): grid de iconos (antes lista) para compartir.
5. **Notificaciones**: pull-down con fondo linen gris oscuro superpuesto.
6. **Pantalla principal**: 4 filas en iPhone 4S- y 5 filas en iPhone 5/iPod 5 (nuevo en iOS 6) + banner "New" en apps recién descargadas.

---

## 5. Qué NO hacer (errores comunes al targetear 6.1)

- ❌ `UIVisualEffectView`, `UIBlurEffect`, `Liquid Glass`, `materials` semitransparentes de iOS 7+ (no existen).
- ❌ `SF Symbols`, `Dynamic Type`, `Dark Mode`, `TintColor` global.
- ❌ Paleta flat neón, sin gradientes ni sombras.
- ❌ `Auto Layout` avanzado (iOS 6 tiene Auto Layout inicial pero limitado; preferir `autoresizingMask` / frames).
- ❌ Tipografía `San Francisco` (es Helvetica Neue en iOS 6).

### Reglas de implementación (traducido a CSS/UIKit)

```css
/* Botón skeuomórfico típico iOS 6 */
.skeu-button {
  background: linear-gradient(180deg, #6d8cb0, #3b5a7f);
  border: 1px solid #2a3d5a;
  border-radius: 6px;
  box-shadow: 
    0 1px 0 rgba(255,255,255,0.35) inset,
    0 2px 4px rgba(0,0,0,0.3);
}
.skeu-button::before {
  content: '';
  height: 50%;
  background: linear-gradient(180deg, rgba(255,255,255,0.45), rgba(255,255,255,0.10));
}
.skeu-button:active {
  background: linear-gradient(180deg, #3b5a7f, #6d8cb0);
  box-shadow: inset 0 2px 4px rgba(0,0,0,0.4);
}
```

- **Gloss siempre en mitad superior**.
- **Sombras en capas** (2-3 valores).
- **Luz coherente** arriba-izquierda.
- **Active = gradiente invertido + `inset shadow`**.

---

## 6. Estado actual de `wave`

- `waAppDelegate.m:69-108` crea la ventana, el `UITabBarController`, cuatro navegaciones y el Player modal.
- La interfaz usa tema común (`waTheme`), gradientes, gloss, sombras y frames/autoresizing compatibles con iOS 6.
- Search, Library, playlists, Queue y las vistas de detalle usan celdas y componentes reutilizables en `Views/`.
- Audio se divide entre `waAudioPlayer`, categorías de cola/motor y `Audio/waAudioEngine`.

---

## 7. Fuentes

- Wikipedia — iOS 6 (skeuomorphic last release, Sundance, 19 Sep 2012)
- AppleInsider — What Apple learned from skeuomorphism (peak iOS 6: Notes yellow paper, Newsstand bookshelf, Voice Memos metal)
- BetaWiki — iOS 6
- Design Showcase — Skeuomorphism traits, materials table, implementation tips
- SDK local: `/home/main/theos/sdks/iPhoneOS6.1.sdk/SDKSettings.plist`

## 8. Siguientes pasos sugeridos

1. Mantener los contratos `+Private.h` alineados cuando se mueva lógica entre categorías.
2. Ejecutar `make clean && make -j4` antes de empaquetar cambios estructurales.
3. Probar reproducción, Queue, Search y rotación en el dispositivo iOS 6.1.
