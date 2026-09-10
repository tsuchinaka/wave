# UIKit Reference — iPhoneOS 7.1 (deployment 6.1)

> Headers reales en `/home/main/theos/sdks/iPhoneOS7.1.sdk/System/Library/Frameworks/UIKit.framework/Headers/` (`UIKit.h` importa todo lo listado). Fallback 6.1: `/home/main/theos/sdks/iPhoneOS6.1.sdk/...` (sin APIs 7+).
> Total: **~90+ headers UIKit** + `NS*` compatibles. Validador: `ls UIKit.framework/Headers` contra SDK 7.1. Deployment sigue 6.1: todo iOS 7+ debe ir tras `+[waTheme isModernSystem]`.

## 1. UIKit.h — índice completo

```objc
// /System/Library/Frameworks/UIKit.framework/Headers/UIKit.h (6.1)
#import <UIKit/UIKitDefines.h>
#import <UIKit/UIAccelerometer.h>          // Deprecated pero existe
#import <UIKit/UIAccessibility.h> ...       // UIAccessibility*
#import <UIKit/UIActivityIndicatorView.h>
#import <UIKit/UIActivity.h>
#import <UIKit/UIActivityItemProvider.h>
#import <UIKit/UIActivityViewController.h> // ¡NUEVO iOS 6! Share Sheet grid
#import <UIKit/UIAlert.h>                  // UIAlert (privado, usar UIAlertView)
#import <UIKit/UIApplication.h>
#import <UIKit/UIBarButtonItem.h>
#import <UIKit/UIBarItem.h>
#import <UIKit/UIBezierPath.h>
#import <UIKit/UIButton.h>
#import <UIKit/UICollectionView.h>         // ¡NUEVO iOS 6!
#import <UIKit/UICollectionViewCell.h>
#import <UIKit/UICollectionViewController.h>
#import <UIKit/UICollectionViewFlowLayout.h>
#import <UIKit/UICollectionViewLayout.h>
#import <UIKit/UIColor.h>
#import <UIKit/UIControl.h>
#import <UIKit/UIDataDetectors.h>
#import <UIKit/UIDatePicker.h>
#import <UIKit/UIDevice.h>
#import <UIKit/UIDocument.h>
#import <UIKit/UIDocumentInteractionController.h>
#import <UIKit/UIEvent.h>
#import <UIKit/UIFont.h>
#import <UIKit/UIGeometry.h>
#import <UIKit/UIGestureRecognizer.h>
#import <UIKit/UIGraphics.h>
#import <UIKit/UIImage.h>
#import <UIKit/UIImagePickerController.h>
#import <UIKit/UIImageView.h>
#import <UIKit/UIInterface.h>
#import <UIKit/UILabel.h>
#import <UIKit/UILocalNotification.h>
#import <UIKit/UIManagedDocument.h>
#import <UIKit/UIMenuController.h>
#import <UIKit/UINavigationBar.h>
#import <UIKit/UINavigationController.h>
#import <UIKit/UINib.h> / UINibLoading.h
#import <UIKit/UIPageControl.h>
#import <UIKit/UIPageViewController.h>
#import <UIKit/UIPasteboard.h>
#import <UIKit/UIPickerView.h>
#import <UIKit/UIPopoverController.h>      // iPad
#import <UIKit/UIPopoverBackgroundView.h>
#import <UIKit/UIPrint*>
#import <UIKit/UIProgressView.h>
#import <UIKit/UIRefreshControl.h>         // ¡NUEVO iOS 6! pull-to-refresh
#import <UIKit/UIResponder.h>
#import <UIKit/UIScreen.h> / UIScreenMode.h
#import <UIKit/UIScrollView.h>
#import <UIKit/UISearchBar.h>
#import <UIKit/UISearchDisplayController.h>
#import <UIKit/UISegmentedControl.h>
#import <UIKit/UISlider.h>
#import <UIKit/UISplitViewController.h>
#import <UIKit/UIStepper.h>                // ¡NUEVO iOS 6!
#import <UIKit/UIStoryboard.h> / UIStoryboardSegue.h
#import <UIKit/UISwitch.h>
#import <UIKit/UITabBar.h> / UITabBarController.h / UITabBarItem.h
#import <UIKit/UITableView.h> / UITableViewCell.h / UITableViewController.h / UITableViewHeaderFooterView.h
#import <UIKit/UITextChecker.h> / UITextField.h / UITextView.h / UITextInput.h
#import <UIKit/UIToolbar.h>
#import <UIKit/UIView.h> / UIViewController.h
#import <UIKit/UIWebView.h>                // En iOS 6 NO existe WKWebView
#import <UIKit/UIWindow.h>
#import <UIKit/NSAttributedString.h> / NSText.h / NSParagraphStyle.h / NSShadow.h / NSStringDrawing.h
#import <UIKit/NSLayoutConstraint.h>       // Auto Layout 1.0 (limitado)
#import <UIKit/UIStateRestoration.h>       // State Restoration ¡NUEVO iOS 6!
```

## 2. Qué usar en wave (actual)

Wave usa actualmente `UITabBarController`, `UINavigationController`, `UITableView`, `UIScrollView`, `UISearchBar`, `UIButton`, `UIActivityIndicatorView`, `UIAlertView` y `UIActionSheet`, todos disponibles en el SDK 6.1. Las celdas custom se encuentran en `Views/` y los layouts usan frames/autoresizing.

## 3. Novedades iOS 6 que SÍ puedes usar

| Clase | Header | Uso |
|-------|--------|-----|
| `UICollectionView` + `UICollectionViewFlowLayout` | `UICollectionView.h` | Grids, no existía en iOS 5 |
| `UIActivityViewController` | `UIActivityViewController.h` | Share Sheet grid de iconos (fotos, links) |
| `UIRefreshControl` | `UIRefreshControl.h` | Pull-to-refresh nativo (antes era librería) |
| `UIStepper` | `UIStepper.h` | Control +/- |
| `UIStateRestoration` | `UIStateRestoration.h` | Restaurar estado tras kill |
| `NSLayoutConstraint` | `NSLayoutConstraint.h` | Auto Layout básico (sin anchors) |
| `PassKit` (framework separado) | `<PassKit/PassKit.h>` | Passbook |

## 4. Qué NO existe en 6.1 / qué exige guard iOS 7+

| Moderno (iOS 7+) | En 6.1 usa / guard |
|------------------|-------------------|
| `UIAlertController` (iOS 8) | `UIAlertView.h` + `UIActionSheet.h` |
| `WKWebView` (iOS 8) | `UIWebView.h` |
| `UIStackView` (iOS 9) | `UIView` con frames / `autoresizingMask` |
| `UISearchController` (iOS 8) | `UISearchDisplayController.h` + `UISearchBar.h` |
| `UIVisualEffectView` (iOS 8) | `UIImageView` con imagen translúcida o `UIToolbar` barStyle |
| `UIAlertControllerStyle` | `UIAlertViewStyle` |
| `SF Symbols` | PNGs `Resources/AppIcon*.png` |
| `UIContextMenu` | `UIMenuController.h` |
| `UIScene` | `UIApplication.h` delegate clásico (`waAppDelegate.h:3`) |
| **iOS 7 APIs usadas con guard** | `barTintColor`/`translucent`/`edgesForExtendedLayout`/`automaticallyAdjustsScrollViewInsets`/`imageWithRenderingMode:` → siempre tras `[waTheme isModernSystem]` + `respondsToSelector` (ver `waTheme.m:60`) |

## 5. CoreGraphics + QuartzCore (linkeados en Makefile:9)

- **CoreGraphics**: `CGContext.h`, `CGColor.h`, `CGPath.h`, `CGGradient.h`, `CGImage.h`, `CGGeometry.h` ... (`CoreGraphics.framework/Headers/`)
- **QuartzCore**: `CALayer.h`, `CAAnimation.h`, `CAGradientLayer.h`, `CAShapeLayer.h`, `CATransaction.h` ... (`QuartzCore.framework/Headers/`)

Útiles para replicar gloss/gradientes/sombras skeuomórficas vía `CAGradientLayer` y `CALayer.shadow*` (ver `ios6-interface-guide.md` §2).

## 6. Cómo verificar un header existe

```bash
ls /home/main/theos/sdks/iPhoneOS7.1.sdk/System/Library/Frameworks/UIKit.framework/Headers/UITableView.h
grep -r "UIRefreshControl" /home/main/theos/sdks/iPhoneOS7.1.sdk/System/Library/Frameworks/UIKit.framework/Headers/
grep -r "barTintColor" /home/main/theos/sdks/iPhoneOS7.1.sdk/System/Library/Frameworks/UIKit.framework/Headers/UINavigationBar.h | head
# Si no aparece ni en 7.1, no existe; si aparece solo en 7.1, exige guard isModernSystem para deployment 6.1
```

## 7. Import template para wave

```objc
#import <UIKit/UIKit.h>          // todo UIKit 6.1
#import <QuartzCore/QuartzCore.h> // si usas CALayer
#import <CoreGraphics/CoreGraphics.h>

// Nuevos iOS 6 opcionales:
#import <Social/Social.h>
#import <PassKit/PassKit.h>
#import <MapKit/MapKit.h>
```

## 8. Pop-ups, selectores y controladores modales

### Pop-ups y menús emergentes

| Clase | Header | Funcionalidad |
|-------|--------|---------------|
| `UIAlertView` | `UIAlertView.h` | Mensajes, advertencias, confirmaciones y campos de texto con botones. |
| `UIActionSheet` | `UIActionSheet.h` | Menú de acciones con botones cancelar, destructivo y otras acciones. |
| `UIPopoverController` | `UIPopoverController.h` | Ventana flotante para presentar otro controlador, principalmente en iPad. |

### Selectores y paneles de selección

| Clase | Header | Funcionalidad |
|-------|--------|---------------|
| `UIImagePickerController` | `UIImagePickerController.h` | Seleccionar fotos/vídeos o capturar contenido con la cámara. |
| `UIDocumentInteractionController` | `UIDocumentInteractionController.h` | Previsualizar, abrir o compartir documentos con otras aplicaciones. |
| `UIPrintInteractionController` | `UIPrintInteractionController.h` | Configurar y enviar contenido a una impresora AirPrint. |
| `UIActivityViewController` | `UIActivityViewController.h` | Seleccionar una actividad para compartir texto, imágenes, URLs u otros objetos. |

### Controladores modales

| Clase | Framework/header | Funcionalidad |
|-------|------------------|---------------|
| `MFMailComposeViewController` | MessageUI / `MFMailComposeViewController.h` | Redactar y enviar un email. |
| `MFMessageComposeViewController` | MessageUI / `MFMessageComposeViewController.h` | Redactar y enviar SMS o iMessage. |
| `EKEventViewController` | EventKitUI / `EKEventViewController.h` | Mostrar los detalles de un evento del Calendario. |
| `UIWebView` | UIKit / `UIWebView.h` | Mostrar contenido web dentro de una pantalla propia. |
