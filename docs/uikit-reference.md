# UIKit — iPhoneOS 5.1

Headers en `/home/main/theos/sdks/iPhoneOS5.1.sdk/System/Library/Frameworks/UIKit.framework/Headers/`. Son 99. `UIKit.h` importa el conjunto de esta versión, no el de iOS 6 ni 7.

El libro en `/home/main/programming-ios6/` describe iOS 6. Sirve para ObjC, ciclo de vida y tablas. No sirve como permiso para copiar una API. Si el header no está en el SDK 5.1, no existe aquí.

## Sí están

Controles y contenedores que wave usa o puede usar:

- `UIAlertView`, `UIActionSheet` — modales con delegate. No hay `UIAlertController`.
- `UITabBarController`, `UINavigationController`, `UITableView` (`Plain` y `Grouped`)
- `UIToolbar`, `UISearchBar`, `UISearchDisplayController`
- `UIButton`, `UISlider`, `UISwitch`, `UIStepper`, `UISegmentedControl`, `UIProgressView`, `UIPageControl`
- `UIScrollView`, `UIWebView`, `UIImagePickerController`
- `UIGestureRecognizer` y las subclases pan, pinch, rotation, long-press, swipe, tap
- `UIAppearance` — `waSkin` instala imágenes de barra, botón y segmento por esta vía
- `UIPopoverController`, `UISplitViewController` — iPad. El target principal es el teléfono.
- `UIPageViewController`, `UIDocument`, `UIStoryboard` — existen. Wave no carga storyboards ni xibs.

Presentar un modal en 5.1 es `presentModalViewController:animated:`. `waAppDelegate.m:76` cierra con `dismissModalViewControllerAnimated:`. No usar `presentViewController:animated:completion:` ni `dismissViewControllerAnimated:completion:`: no están en este SDK.

## No están

Comprobado con `ls` de los headers:

| API | Sustituto en wave |
|-----|-------------------|
| `UICollectionView` | `UITableView` y `Skin/waCarouselView` (scroll horizontal propio) |
| `UIRefreshControl` | recarga explícita, no pull-to-refresh de sistema |
| `UIActivityViewController` | no hay share sheet de iOS 6 |
| `UIAlertController` | `UIAlertView` / `UIActionSheet` |
| `WKWebView` | `UIWebView` si hiciera falta |
| `UIStackView`, `UIVisualEffectView` | frames y `autoresizingMask` |
| `NSLayoutConstraint` / `NSLayoutAnchor` | frames. `waRootController.m:73` usa `UIViewAutoresizingFlexibleWidth` |
| `NSURLSession` | `NSURLConnection`, o `waTLS` cuando el handshake de 5.1 no llega |

Tampoco hay `UIRefreshControl`, `edgesForExtendedLayout`, `barTintColor` ni `UIImageRenderingMode`. Esas son de iOS 7. No hace falta un `isModernSystem`: el deployment es 5.1 y el binario no corre en 7.

## Texto y tablas

- Alineación: el SDK habla `UITextAlignment` y `UILineBreakMode`. `Support/waIOS5Compat.h:28-42` los alias a `NSTextAlignment*` y `NSLineBreakBy*` para poder escribir el nombre nuevo.
- `YES`/`NO` del SDK 5.1 no se pueden meter en `@YES`. El mismo header los redefine (`waIOS5Compat.h:22-26`).
- Subscripts `array[i]` y `dict[key]` no vienen en Foundation 5.1. El shim está en `Support/waIOS5Compat.m`.
- Celdas: `UITableViewCellStyleDefault`, `Subtitle`, `Value1`, `Value2`. Fuentes en `waSkin` `applyPlainCellFonts:`, `applySubtitleCellFonts:`, `applyValueCellFonts:`.

## Alertas

```objc
UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Title"
                                                 message:@"msg"
                                                delegate:self
                                       cancelButtonTitle:@"Cancel"
                                       otherButtonTitles:@"OK", nil];
[alert show];
```

La decisión va en `alertView:clickedButtonAtIndex:`. Después de `show` el código no sigue en línea.

`UIActionSheet` se crea con `initWithTitle:delegate:cancelButtonTitle:destructiveButtonTitle:otherButtonTitles:` y se muestra con `showInView:`.
