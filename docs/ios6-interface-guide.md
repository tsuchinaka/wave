# Interfaz — iOS 5.1

El nombre del archivo es el de la guía vieja. El target ya no es iOS 6.1 ni un binario 6.1/7.x. La piel vive en `Skin/waSkin` y el comentario de `Skin/waSkin.h:7-9` es el contrato: controles UIKit de stock, imágenes de gloss y gradiente, Helvetica Neue. Sin look de terceros y sin diseño plano.

SDK: `iPhoneOS5.1.sdk`. `Makefile:1` es `iphone:clang:5.1:5.1`.

## Qué se imita

iOS 5 todavía es skeuomórfico. La barra es un objeto con luz arriba y sombra abajo. La tabla agrupada es papel con pinstripe. El botón parece presionable. Eso se consigue con imágenes de `waSkin`, no con blur ni con tint de iOS 7.

Paleta que expone `waSkin`:

- `tintColor` — azul de controles agrupados
- `navigationTint` / `barTint` — relleno de barras
- `tableBackground` — papel de tabla agrupada
- `tablePlainBackground` — blanco
- `primaryText`, `secondaryText`, `accentText`, `destructive`
- `separator`, `cellBackground`, `cellSelectedBackground`

Fuentes: `bodyFont`, `boldBodyFont`, `smallFont`, `titleFont`, `cellTitleFont`, `cellSubtitleFont`, `sectionFont`. Son las Helvetica Neue que trae el sistema. No cargar una familia que el teléfono no tiene.

Métricas: `margin`, `rowHeight`, `artworkSize`.

## Cómo se aplica

`waSkin install` corre en `UI/waAppDelegate.m:21`, antes de crear la ventana. Después:

- `styleNavigationBar:`, `styleTabBar:`, `styleToolbar:`
- `styleSearchBar:`, `styleSegmentedControl:`, `styleSwitch:`, `styleSlider:`, `styleProgressView:`
- `styleTableView:grouped:`
- `styleBarButtonItem:`
- `groupedCellBackgroundForPosition:` — 0 top, 1 middle, 2 bottom, 3 single
- `applyPlainCellFonts:`, `applyValueCellFonts:`, `applySubtitleCellFonts:`

Las cuatro pestañas están en `UI/waRootController.m:47-69`: Home, Search, Library, Settings. Cada una va dentro de un `UINavigationController`. El player grande no es una pestaña: `showPlayer` lo presenta. Debajo hay `waMiniPlayerBar`, un `UIToolbar`.

Layout con frames y `autoresizingMask`. No hay Auto Layout en este SDK.

## Qué no hacer

- No `UICollectionView`. Los estantes horizontales son `Skin/waCarouselView`.
- No `UIRefreshControl`. No existe.
- No barras translúcidas, `barTintColor`, `edgesForExtendedLayout` ni rendering mode de iOS 7. El binario no corre ahí.
- No SF Symbols, ni `UIVisualEffectView`, ni stacks.
- No storyboard. `UIStoryboard` existe en el SDK; el proyecto no lo usa.
- No inventar un tema claro/oscuro intercambiable. `waSkin` es una piel fija de iOS 5.1. El selector de temas de la rama 0.1.x no está en este árbol.
- No sustituir `UIAlertView` / `UIActionSheet` por un controlador que el SDK no tiene.

## Alertas y hojas

El patrón está en `docs/uikit-reference.md`. Delegate, no lógica después de `show`.
