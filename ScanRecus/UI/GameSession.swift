import Foundation
import CoreGraphics
import CoreImage
import Observation

// MARK: - Session de jeu « Entraînement IA » (2026-10-21)

/// La table de jeu de la MÉTHODE DE GRÉGOIRE : un deck
/// d'instances (les copies tournées de la banque, brassées),
/// et pour chacune, l'IA « joue » puis Grégoire corrige.
///
/// Étape branchée : la ROTATION. Le joueur du jour 1 est
/// l'heuristique du scanner (bords + mots) ; un modèle
/// entraîné prendra le relais quand le banc le dira.
///
/// PAS de notation : la correction de Grégoire fait office
/// de note — l'écart entre la proposition et sa finale est
/// LE score (journalisé par tentative dans jeu.jsonl, via
/// TrainingBank.appendAttempt). « Acceptée sans correction »
/// compte les réussites.
@Observable
final class GameSession {

    private(set) var deck: [BankDerived] = []
    private(set) var index = 0
    private(set) var displayImage: CGImage?
    private(set) var statusText = ""
    private(set) var proposalDeg: Double?
    private(set) var proposalDetail = ""
    private(set) var confidence: Float = 0
    /// La correction de Grégoire, en degrés ajoutés à la
    /// proposition. Chaque changement réaffiche l'image.
    var delta: Double = 0 {
        didSet { renderDisplay() }
    }
    private(set) var attempts = 0
    private(set) var acceptedCount = 0
    private(set) var totalError: Double = 0

    private var baseImage: CIImage?
    private let context = CIContext()
    private weak var bank: TrainingBank?
    private weak var scanner: CompositeScanner?

    var current: BankDerived? {
        index < deck.count ? deck[index] : nil
    }

    var finished: Bool { current == nil }

    var finalDeg: Double { (proposalDeg ?? 0) + delta }

    var instanceLabel: String {
        current.map { "\($0.file) · reçu nº \($0.group)" } ?? "—"
    }

    var positionText: String {
        deck.isEmpty ? "0/0"
            : "\(min(index + 1, deck.count))/\(deck.count)"
    }

    var statsText: String {
        guard attempts > 0 else {
            return "Aucune tentative validée pour l'instant — "
                + "le score du jeu s'affichera ici (acceptées "
                + "sans correction, écart moyen)."
        }
        let pct = Int((100.0 * Double(acceptedCount)
            / Double(attempts)).rounded())
        let mean = totalError / Double(attempts)
        return "\(attempts) tentative(s) · \(acceptedCount) "
            + "acceptée(s) sans correction (\(pct) %) · "
            + "écart moyen \(String(format: "%.1f", mean))°"
    }

    static func fmt(_ deg: Double) -> String {
        String(format: "%+.1f°", deg)
    }

    // MARK: Deck

    func prepare(bank: TrainingBank,
                 scanner: CompositeScanner) {
        self.bank = bank
        self.scanner = scanner
        deck = bank.derived.shuffled()
        index = 0
        attempts = 0
        acceptedCount = 0
        totalError = 0
        loadCurrent()
    }

    func reshuffle() {
        guard let bank, let scanner else { return }
        prepare(bank: bank, scanner: scanner)
    }

    private func loadCurrent() {
        proposalDeg = nil
        proposalDetail = ""
        confidence = 0
        delta = 0
        baseImage = nil
        displayImage = nil
        guard let entry = current, let bank else {
            statusText = "Deck terminé. « Nouveau deck » pour "
                + "rejouer — entre les passes, les modèles "
                + "s'entraîneront sur tes corrections."
            return
        }
        guard let cg = bank.image(forDerived: entry) else {
            statusText = "Instance illisible (\(entry.file)) "
                + "— je passe à la suivante."
            index += 1
            loadCurrent()
            return
        }
        baseImage = CIImage(cgImage: cg)
        renderDisplay()
        statusText = "L'IA joue…"
        let image = baseImage
        let entryId = entry.id
        DispatchQueue.global(qos: .userInitiated)
            .async { [weak self] in
                guard let self, let scanner = self.scanner,
                      let image
                else { return }
                let proposal = scanner
                    .rotationProposal(for: image)
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.current?.id == entryId
                    else { return }
                    self.proposalDeg = proposal.degrees
                    self.confidence = proposal.confidence
                    self.proposalDetail = proposal.detail
                    let pct = Int((proposal.confidence * 100)
                        .rounded())
                    self.statusText = "Proposition : "
                        + "\(Self.fmt(proposal.degrees)) "
                        + "(confiance \(pct) %) — "
                        + "\(proposal.detail). Corrige l'angle "
                        + "si besoin, puis valide."
                    self.renderDisplay()
                }
            }
    }

    // MARK: Jeu

    /// Valide la tentative : la proposition, la correction
    /// de Grégoire (delta) et l'écart sont journalisés —
    /// c'est la matière des cycles d'entraînement.
    func validate() {
        guard let entry = current, let bank,
              let proposal = proposalDeg
        else { return }
        let error = abs(delta)
        let accepted = error < 0.05
        let attempt = GameAttempt(
            ts: ISO8601DateFormatter().string(from: Date()),
            stage: "rotation", file: entry.file,
            sourceNumber: bank.photos
                .first { $0.id == entry.sourceId }?.number ?? 0,
            group: entry.group,
            generationAngle: entry.angle,
            proposalDeg: proposal, confidence: confidence,
            correctionDeg: delta, finalDeg: finalDeg,
            errorDeg: error, accepted: accepted)
        bank.appendAttempt(attempt)
        attempts += 1
        if accepted { acceptedCount += 1 }
        totalError += error
        index += 1
        loadCurrent()
    }

    func skip() {
        index += 1
        loadCurrent()
    }

    // MARK: Affichage

    /// L'instance tournée de (proposition + correction) —
    /// rotation à toile élargie, comme à la génération.
    private func renderDisplay() {
        guard let baseImage else {
            displayImage = nil
            return
        }
        let radians = CGFloat(((proposalDeg ?? 0) + delta)
            * .pi / 180)
        var image = baseImage
        let centre = CGAffineTransform(
            translationX: image.extent.midX,
            y: image.extent.midY)
        let back = CGAffineTransform(
            translationX: -image.extent.midX,
            y: -image.extent.midY)
        image = image
            .transformed(by: back)
            .transformed(by: CGAffineTransform(
                rotationAngle: radians))
            .transformed(by: centre)
        image = image.transformed(by: CGAffineTransform(
            translationX: -image.extent.minX,
            y: -image.extent.minY))
        displayImage = context.createCGImage(
            image, from: image.extent)
    }
}
