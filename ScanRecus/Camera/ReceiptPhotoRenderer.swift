import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Rendu final d'un reçu du nouveau Scanner : rotation de la
/// photo selon l'angle du bouton, crop rectangulaire dans le
/// repère redressé, réduction au plus long côté de 1600 px,
/// compression JPEG ~0,8. C'est CE fichier qui part vers
/// l'app Gestion quand Grégoire appuie sur « Next ».
///
/// Toutes les correspondances d'espaces vivent dans
/// ReceiptGeometry (pure, testée) ; ici on ne fait que les
/// appliquer à CoreImage — dont le repère est Y vers le haut,
/// d'où l'angle inversé et le Y du crop retourné.
enum ReceiptPhotoRenderer {

    static let maxLongSide: CGFloat = 1600
    static let jpegQuality: CGFloat = 0.8

    private static let context = CIContext(
        options: [.useSoftwareRenderer: false])

    static func renderJPEG(photo: CGImage,
                           uiDegrees: Double,
                           cropNormalized: CGRect) -> Data? {
        let source = CIImage(cgImage: photo)
        let sourceSize = source.extent.size
        guard sourceSize.width > 0, sourceSize.height > 0
        else { return nil }

        // Rotation autour du centre de l'image : translater
        // au centre, tourner (angle CI = − angle interface),
        // revenir.
        let toCenter = CGAffineTransform(
            translationX: -sourceSize.width / 2,
            y: -sourceSize.height / 2)
        let rotate = CGAffineTransform(
            rotationAngle: CGFloat(
                ReceiptGeometry.ciRotationRadians(
                    uiDegrees: uiDegrees)))
        let back = CGAffineTransform(
            translationX: sourceSize.width / 2,
            y: sourceSize.height / 2)
        var image = source.transformed(
            by: toCenter.concatenating(rotate).concatenating(back))

        // Ramener le cadre englobant redressé à l'origine,
        // pour que le crop normalisé s'applique tel quel.
        let bounds = ReceiptGeometry.rotatedBoundingSize(
            sourceSize, degrees: uiDegrees)
        image = image.transformed(by: CGAffineTransform(
            translationX: -image.extent.minX,
            y: -image.extent.minY))

        // Crop rectangulaire (coordonnées CI, Y vers le haut).
        let cropRect = ReceiptGeometry.ciCropRect(
            normalized: ReceiptGeometry.clampCrop(cropNormalized),
            bounds: bounds)
        image = image.cropped(to: cropRect)

        // Réduction au plus long côté de 1600 px.
        let factor = ReceiptGeometry.downscaleFactor(
            size: image.extent.size, maxLongSide: maxLongSide)
        if factor < 1 {
            image = image.transformed(
                by: CGAffineTransform(scaleX: factor, y: factor))
        }

        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0,
              let cg = context.createCGImage(image, from: extent)
        else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, cg,
            [kCGImageDestinationLossyCompressionQuality:
                jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination)
        else { return nil }
        return data as Data
    }
}
