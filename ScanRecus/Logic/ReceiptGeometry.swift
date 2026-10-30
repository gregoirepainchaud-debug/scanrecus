#if canImport(CoreGraphics)
import CoreGraphics // membres CGRect (width, minX, integral…) sur macOS
#endif
import Foundation

/// Géométrie pure du nouveau Scanner (2026-10-30) : rotation
/// continue de la photo, boîte de crop rectangulaire dans le
/// repère de l'image REDRESSÉE, et correspondances d'espaces
/// (écran ↔ normalisé ↔ pixels) utilisées à l'affichage comme
/// au rendu final.
///
/// Conventions :
/// - L'angle de l'interface est en degrés, POSITIF = horaire à
///   l'écran (le sens de SwiftUI.rotationEffect).
/// - Le crop est stocké NORMALISÉ (0…1) dans le repère de
///   l'image redressée : son cadre englobant (bounding box)
///   après rotation. À l'écran il est donc toujours
///   axis-aligné — angles de 90° stricts par construction.
/// - CoreImage travaille en Y vers le HAUT, origine en bas à
///   gauche : les fonctions « ci… » font la conversion.
///
/// Foundation seulement (les types CGPoint/CGSize/CGRect y
/// vivent, sur macOS comme sous Linux) : testée sous Linux.
enum ReceiptGeometry {

    static func radians(_ degrees: Double) -> Double {
        degrees * .pi / 180
    }

    /// Cadre englobant d'un rectangle tourné de `degrees`.
    static func rotatedBoundingSize(_ size: CGSize,
                                    degrees: Double) -> CGSize {
        let rad = abs(radians(degrees))
        let c = abs(cos(rad)), s = abs(sin(rad))
        return CGSize(width: size.width * c + size.height * s,
                      height: size.width * s + size.height * c)
    }

    /// Plus grand rectangle de même ratio que `content` tenant
    /// dans `container`, centré. (Même rôle que l'aspectFitRect
    /// privé de CompositeScanView, en version pure et testée.)
    static func aspectFitRect(content: CGSize,
                              container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0,
              container.width > 0, container.height > 0
        else { return .zero }
        let scale = min(container.width / content.width,
                        container.height / content.height)
        let w = content.width * scale
        let h = content.height * scale
        return CGRect(x: (container.width - w) / 2,
                      y: (container.height - h) / 2,
                      width: w, height: h)
    }

    /// Point écran (repère conteneur, Y vers le bas) → point
    /// normalisé (0…1) dans le cadre `fit` (le cadre englobant
    /// affiché de la photo redressée).
    static func normalizedPoint(_ point: CGPoint,
                                in fit: CGRect) -> CGPoint {
        guard fit.width > 0, fit.height > 0 else { return .zero }
        return CGPoint(
            x: (point.x - fit.minX) / fit.width,
            y: (point.y - fit.minY) / fit.height)
    }

    /// Inverse : point normalisé → point écran dans `fit`.
    static func screenPoint(_ normalized: CGPoint,
                            in fit: CGRect) -> CGPoint {
        CGPoint(x: fit.minX + normalized.x * fit.width,
                y: fit.minY + normalized.y * fit.height)
    }

    /// Borne un crop normalisé : reste dans [0, 1], taille
    /// minimale `minSize` sur chaque axe (on ne cadre pas un
    /// timbre-poste par accident).
    static func clampCrop(_ crop: CGRect,
                          minSize: CGFloat = 0.05) -> CGRect {
        var r = crop
        r.size.width = min(max(r.width, minSize), 1)
        r.size.height = min(max(r.height, minSize), 1)
        r.origin.x = min(max(r.minX, 0), 1 - r.width)
        r.origin.y = min(max(r.minY, 0), 1 - r.height)
        return r
    }

    /// Le crop normalisé → rectangle PIXELS dans l'image
    /// redressée de taille `bounds` (repère interface : origine
    /// en HAUT à gauche, Y vers le bas).
    static func pixelCropRect(normalized crop: CGRect,
                              bounds: CGSize) -> CGRect {
        CGRect(x: crop.minX * bounds.width,
               y: crop.minY * bounds.height,
               width: crop.width * bounds.width,
               height: crop.height * bounds.height)
            .integral
    }

    /// Le même crop, mais pour CoreImage : origine en BAS à
    /// gauche, Y vers le haut — le Y se retourne.
    static func ciCropRect(normalized crop: CGRect,
                           bounds: CGSize) -> CGRect {
        CGRect(x: crop.minX * bounds.width,
               y: (1 - crop.maxY) * bounds.height,
               width: crop.width * bounds.width,
               height: crop.height * bounds.height)
            .integral
    }

    /// Angle de rotation à donner à CoreImage pour reproduire
    /// l'angle de l'interface : CI tourne en Y vers le haut,
    /// positif = antihoraire à l'écran — le signe s'inverse.
    static func ciRotationRadians(uiDegrees: Double) -> Double {
        -radians(uiDegrees)
    }

    /// Facteur de réduction pour que le plus long côté ne
    /// dépasse pas `maxLongSide` (jamais d'agrandissement).
    static func downscaleFactor(size: CGSize,
                                maxLongSide: CGFloat) -> CGFloat {
        let longest = max(size.width, size.height)
        guard longest > maxLongSide, longest > 0 else { return 1 }
        return maxLongSide / longest
    }

    /// Écart angulaire signé le plus court entre deux angles
    /// (degrés), ramené dans (−180, 180]. Sert au glisser
    /// circulaire du bouton : le delta du pointeur ne doit
    /// jamais « sauter » de +179 à −179.
    static func wrappedDeltaDegrees(from: Double,
                                    to: Double) -> Double {
        var d = (to - from).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    /// Delta HORAIRE (degrés) entre deux positions du pointeur
    /// autour du centre du bouton, à partir de leurs angles
    /// atan2 dans un repère Y vers le HAUT (AppKit non retourné,
    /// où atan2 croît en antihoraire) : l'horaire est l'inverse.
    static func clockwiseDeltaDegrees(fromAtan2 a0: Double,
                                      toAtan2 a1: Double) -> Double {
        -wrappedDeltaDegrees(from: a0 * 180 / .pi,
                             to: a1 * 180 / .pi)
    }

    /// Angle normalisé pour l'affichage : [0, 360).
    static func displayDegrees(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        return a
    }

    /// Vrai si l'angle affiché est (à `tolerance` près) un
    /// multiple de 90° — l'indication VISUELLE des angles
    /// droits. Aucun accrochage : c'est un style, pas un aimant.
    static func isRightAngle(_ angle: Double,
                             tolerance: Double = 0.06) -> Bool {
        let a = displayDegrees(angle)
        let nearest = (a / 90).rounded() * 90
        return abs(a - nearest) <= tolerance
            || abs(a - (nearest + 360)) <= tolerance
    }
}
