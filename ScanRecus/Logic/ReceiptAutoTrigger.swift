#if canImport(CoreGraphics)
import CoreGraphics // membres CGRect (midX, midY…) sur macOS
#endif
import Foundation

/// Déclencheur automatique du nouveau Scanner (build 159,
/// 2026-10-30) : RAMÈNE la détection automatique de l'ancien
/// scanner composite dans la capture simple. Grégoire tient
/// le reçu à DEUX mains : il ne peut pas peser sur le bouton
/// déclencheur. La photo doit donc se prendre toute seule
/// quand le reçu est là et que la scène ne bouge plus.
///
/// Le critère est celui, éprouvé, du scanner composite
/// (2026-10-19, « déclencheur scène entière » — on ne suit
/// aucun objet) : le scan part quand, dans l'image ENTIÈRE :
/// (a) le détecteur de texte voit assez de zones de texte
///     (≥ 5) — un visage ou un plafond n'en ont pas ;
/// (b) une grande surface claire est présente (le papier :
///     percentile 65 de gris ≥ 0,52) ;
/// (c) la DISPOSITION des zones de texte est stable d'une
///     image à l'autre (≥ 70 % appariées à moins de 0,03,
///     déplacement moyen < 0,02) pendant `framesNeeded`
///     images de suite.
///
/// Logique PURE (Foundation seulement) : la détection Vision
/// et la mesure de clarté vivent dans StillFrameGrabber
/// (ReceiptScannerView.swift) ; ici on ne juge que des boîtes
/// et un nombre. Testée sous Swift Linux.
struct ReceiptAutoTrigger {

    /// Ce que la dernière évaluation a vu — pour le message
    /// d'état (« présentez un reçu… », « stabilisez… (2/3) »).
    enum Reading: Equatable {
        /// Pas de preuve « papier + texte ».
        case noEvidence(textBoxes: Int)
        /// Preuve présente, disposition pas encore stable.
        case unstable
        /// Preuve présente et stable, compte en cours.
        case stabilizing(count: Int, needed: Int)
    }

    private(set) var reading: Reading = .noEvidence(textBoxes: 0)
    private(set) var stableCount = 0
    /// Verrou anti-re-déclenchement : une fois parti, le
    /// déclencheur ne repart pas tant qu'on ne le réarme pas
    /// (reset) — le même reçu immobile ne doit pas photographier
    /// en boucle pendant que l'utilisateur ajuste la photo.
    private(set) var fired = false

    private var prevBoxes: [CGRect] = []

    let framesNeeded: Int
    let minTextBoxes: Int
    let minBrightness: CGFloat

    init(framesNeeded: Int = 3,
         minTextBoxes: Int = 5,
         minBrightness: CGFloat = 0.52) {
        self.framesNeeded = framesNeeded
        self.minTextBoxes = minTextBoxes
        self.minBrightness = minBrightness
    }

    /// Réarme : oublie la disposition précédente, le compte
    /// de stabilité et le verrou de tir.
    mutating func reset() {
        prevBoxes = []
        stableCount = 0
        fired = false
        reading = .noEvidence(textBoxes: 0)
    }

    /// Juge une image (ses zones de texte normalisées et sa
    /// clarté p65). Retourne vrai UNE fois, au moment où la
    /// stabilité requise est atteinte.
    mutating func evaluate(boxes: [CGRect],
                           brightness: CGFloat) -> Bool {
        let evidence = boxes.count >= minTextBoxes
            && brightness >= minBrightness

        var layoutStable = false
        if evidence, !prevBoxes.isEmpty {
            var matched = 0
            var dispSum: CGFloat = 0
            for box in boxes {
                var best = CGFloat.greatestFiniteMagnitude
                for prev in prevBoxes {
                    let dx = prev.midX - box.midX
                    let dy = prev.midY - box.midY
                    let d = (dx * dx + dy * dy).squareRoot()
                    if d < best { best = d }
                }
                if best < 0.03 {
                    matched += 1
                    dispSum += best
                }
            }
            let frac = Double(matched) / Double(max(boxes.count, 1))
            layoutStable = frac >= 0.7 && matched > 0
                && dispSum / CGFloat(matched) < 0.02
        }
        prevBoxes = boxes

        if evidence && layoutStable {
            stableCount += 1
        } else if evidence {
            stableCount = max(0, stableCount - 1)
        } else {
            stableCount = 0
        }

        if !evidence {
            reading = .noEvidence(textBoxes: boxes.count)
        } else if stableCount > 0 {
            reading = .stabilizing(count: stableCount,
                                   needed: framesNeeded)
        } else {
            reading = .unstable
        }

        guard !fired, stableCount >= framesNeeded else {
            return false
        }
        fired = true
        return true
    }
}
