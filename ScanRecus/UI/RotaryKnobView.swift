import AppKit
import SwiftUI

/// Le BOUTON ROTATIF du nouveau Scanner — le cœur du design
/// (référence de Grégoire : le bouton TUNE/SCROLL de la radio
/// de son Forester). Un disque sombre lustré, un bord moleté
/// dont les encoches TOURNENT visiblement, un point repère sur
/// la face, l'angle affiché en degrés à côté.
///
/// Gestes, tous deux continus et sans aucun palier :
/// - glisser en cercle autour du bouton (l'angle suit la
///   position angulaire du pointeur autour du centre) ;
/// - molette de la souris / défilement du trackpad par-dessus.
/// L'angle vit dans le binding, en degrés interface (positif =
/// horaire), SANS quantification : la photo suit le geste en
/// temps réel. À 0/90/180/270, l'affichage des degrés se
/// souligne — indication visuelle seulement, le geste
/// n'accroche jamais.
struct RotaryKnobView: View {
    @Binding var angle: Double
    var diameter: CGFloat = 148

    private var display: Double {
        ReceiptGeometry.displayDegrees(angle)
    }
    private var atRightAngle: Bool {
        ReceiptGeometry.isRightAngle(angle)
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                // Bague extérieure fixe.
                Circle()
                    .fill(LinearGradient(
                        colors: [Color(white: 0.16),
                                 Color(white: 0.05)],
                        startPoint: .top, endPoint: .bottom))
                    .frame(width: diameter, height: diameter)
                    .shadow(color: .black.opacity(0.6),
                            radius: 6, y: 3)
                // Le bord moleté : les encoches tournent AVEC
                // l'angle — c'est elles qui rendent la
                // rotation visible sur un disque sombre.
                KnurlRim(diameter: diameter - 12)
                    .rotationEffect(.degrees(angle))
                // La face lustrée.
                Circle()
                    .fill(RadialGradient(
                        colors: [Color(white: 0.30),
                                 Color(white: 0.10)],
                        center: UnitPoint(x: 0.35, y: 0.30),
                        startRadius: 2,
                        endRadius: diameter * 0.55))
                    .frame(width: diameter - 30,
                           height: diameter - 30)
                // Le point repère, sur la face, tourne aussi.
                Circle()
                    .fill(Color.orange)
                    .frame(width: 11, height: 11)
                    .offset(y: -(diameter - 30) / 2 + 11)
                    .rotationEffect(.degrees(angle))
                // Le reflet : fixe, lui (la lumière ne tourne
                // pas avec le bouton).
                Ellipse()
                    .fill(Color.white.opacity(0.13))
                    .frame(width: diameter * 0.52,
                           height: diameter * 0.26)
                    .offset(x: -diameter * 0.16,
                            y: -diameter * 0.24)
                    .blur(radius: 6)
                // Le calque d'interaction (AppKit) : drag
                // circulaire + molette, exactement sur le disque.
                KnobInteractionView { delta in
                    angle += delta
                }
                .frame(width: diameter, height: diameter)
            }
            .frame(width: diameter, height: diameter)

            HStack(spacing: 10) {
                Text(String(format: "%.1f°", display))
                    .font(.system(size: 16, weight: .semibold,
                                  design: .monospaced))
                    .foregroundColor(atRightAngle
                                     ? .yellow : .white)
                    .frame(minWidth: 76, alignment: .trailing)
                Button("Remettre à 0°") {
                    angle = (angle / 360).rounded() * 360
                }
                .controlSize(.small)
            }
        }
    }
}

/// Les encoches du bord moleté, disposées en couronne.
private struct KnurlRim: View {
    let diameter: CGFloat
    private let notches = 48

    var body: some View {
        ZStack {
            ForEach(0..<notches, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(white: 0.38))
                    .frame(width: 3.2, height: 10)
                    .offset(y: -diameter / 2 + 5)
                    .rotationEffect(
                        .degrees(Double(i) * 360
                                 / Double(notches)))
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - Calque d'interaction AppKit

/// Reçoit le glisser circulaire et la molette AU-DESSUS du
/// disque : AppKit donne les deltas de défilement et les
/// positions du pointeur sans les approximations des gestes
/// SwiftUI — c'est ce qui rend la rotation absolument
/// continue et smooth. Le delta rapporté est en degrés,
/// positif = horaire (convention de l'interface).
private struct KnobInteractionView: NSViewRepresentable {
    var onDelta: (Double) -> Void

    func makeNSView(context: Context) -> KnobEventView {
        let view = KnobEventView()
        view.onDelta = onDelta
        return view
    }

    func updateNSView(_ nsView: KnobEventView,
                      context: Context) {
        nsView.onDelta = onDelta
    }
}

final class KnobEventView: NSView {
    var onDelta: ((Double) -> Void)?

    /// Dernier angle du pointeur (atan2, repère AppKit Y vers
    /// le haut) ; nil hors drag ou trop près du centre, où
    /// l'angle devient instable.
    private var lastPointerAngle: Double?

    private func pointerAngle(from event: NSEvent) -> Double? {
        let point = convert(event.locationInWindow, from: nil)
        let dx = Double(point.x - bounds.midX)
        let dy = Double(point.y - bounds.midY)
        guard hypot(dx, dy) > 12 else { return nil }
        return atan2(dy, dx)
    }

    override func mouseDown(with event: NSEvent) {
        lastPointerAngle = pointerAngle(from: event)
    }

    override func mouseDragged(with event: NSEvent) {
        let current = pointerAngle(from: event)
        if let last = lastPointerAngle, let current {
            onDelta?(ReceiptGeometry.clockwiseDeltaDegrees(
                fromAtan2: last, toAtan2: current))
        }
        if current != nil { lastPointerAngle = current }
    }

    override func mouseUp(with event: NSEvent) {
        lastPointerAngle = nil
    }

    override func scrollWheel(with event: NSEvent) {
        // Molette : une encoche ≈ 1°. Trackpad (deltas
        // précis, en points, en rafale) : beaucoup plus fin,
        // pour le redressement au quart de degré.
        let factor = event.hasPreciseScrollingDeltas ? 0.06 : 1.0
        onDelta?(Double(event.scrollingDeltaY) * factor)
    }
}
