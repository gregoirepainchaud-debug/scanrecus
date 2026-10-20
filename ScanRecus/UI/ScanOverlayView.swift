import SwiftUI

/// Composant partagé extrait de l'ancien ScanDebugView lors de
/// sa suppression (lot 3, 2026-10-20) : la vue du scan
/// composite l'utilise pour dessiner le contour du reçu.
// MARK: - Surcouche graphique

/// Dessine le contour du reçu (jaune), la boîte du total (vert) et le
/// cadre de sélection souris (orange, déjà en coordonnées écran).
///
/// Conversions de coordonnées : Vision travaille en normalisé 0…1,
/// origine en bas à gauche, image NON miroitée ; Y est toujours inversé
/// (origine haut-gauche de SwiftUI), X seulement en mode miroir.
struct ScanOverlayView: View {
    let quad: [CGPoint]?
    let totalBox: CGRect?
    let hoverRect: CGRect?
    let mirrored: Bool
    let size: CGSize

    private func screenPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (mirrored ? 1 - p.x : p.x) * size.width,
                y: (1 - p.y) * size.height)
    }

    private func screenRect(_ r: CGRect) -> CGRect {
        CGRect(x: (mirrored ? 1 - r.maxX : r.minX) * size.width,
               y: (1 - r.maxY) * size.height,
               width: r.width * size.width,
               height: r.height * size.height)
    }

    var body: some View {
        ZStack {
            if let quad, quad.count == 4 {
                // Contour du reçu.
                Path { path in
                    path.move(to: screenPoint(quad[0]))
                    for p in quad.dropFirst() {
                        path.addLine(to: screenPoint(p))
                    }
                    path.closeSubpath()
                }
                .stroke(Color.yellow, lineWidth: 2)
            }
            if let hoverRect {
                // Ligne OCR survolée (phase capture).
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: hoverRect.width, height: hoverRect.height)
                    .position(x: hoverRect.midX, y: hoverRect.midY)
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.orange, lineWidth: 2.5)
                    .frame(width: hoverRect.width, height: hoverRect.height)
                    .position(x: hoverRect.midX, y: hoverRect.midY)
            }
            if let box = totalBox {
                let rect = screenRect(box)
                Rectangle()
                    .stroke(Color.green, lineWidth: 3)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
    }
}
