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
    /// BOUCLÉE dans (−180°, +180°] : une rotation est
    /// circulaire — à 359° on retombe à 0, jamais au-delà
    /// de 360 (règle de Grégoire, 2026-10-22).
    var delta: Double = 0 {
        didSet {
            delta = Self.wrap(delta)
            renderDisplay()
        }
    }

    /// Ramène un angle dans (−180°, +180°] : 359° devient
    /// −1°, 502° devient +142°, etc.
    static func wrap(_ deg: Double) -> Double {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d <= -180 { d += 360 }
        if d > 180 { d -= 360 }
        return d
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

    var finalDeg: Double {
        Self.wrap((proposalDeg ?? 0) + delta)
    }

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
                    self.proposalDeg = Self.wrap(
                        proposal.degrees)
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

// MARK: - Session de jeu « contours » (étape 1, 2026-10-22)

/// Étape 1 du pipeline (ordre de Grégoire, 2026-10-22) :
/// TRACER LES CONTOURS du reçu. Le joueur du jour 1 est
/// findPaperQuad (Vision + preuve papier) ; Grégoire
/// déplace les 4 coins à la souris — l'extérieur du
/// quadrilatère est assombri à l'écran : c'est ce que la
/// découpe ENLÈVERA une fois les contours validés. L'écart
/// moyen des coins (% de la diagonale) fait office de
/// note ; tout est journalisé (QuadAttempt).
@Observable
final class ContourSession {

    private(set) var deck: [BankDerived] = []
    private(set) var index = 0
    private(set) var displayImage: CGImage?
    private(set) var imageSize: CGSize = .zero
    private(set) var statusText = ""
    private(set) var proposalQuad: [CGPoint]?
    private(set) var proposalDetail = ""
    private(set) var proposalSource = "vision"
    private(set) var proposalAlt: [CGPoint]?
    /// Les coins de travail, déplaçables (coordonnées
    /// normalisées d'affichage, [TL, TR, BR, BL]).
    var quad: [CGPoint] = []
    private(set) var attempts = 0
    private(set) var acceptedCount = 0
    private(set) var totalError: Double = 0

    private weak var bank: TrainingBank?
    private weak var scanner: CompositeScanner?

    var current: BankDerived? {
        index < deck.count ? deck[index] : nil
    }

    var finished: Bool { current == nil }

    var instanceLabel: String {
        current.map { "\($0.file) · reçu nº \($0.group)" } ?? "—"
    }

    var positionText: String {
        deck.isEmpty ? "0/0"
            : "\(min(index + 1, deck.count))/\(deck.count)"
    }

    /// Écart moyen courant proposition ↔ coins actuels,
    /// en % de la diagonale de l'image.
    var currentErrorPct: Double? {
        guard let proposal = proposalQuad, quad.count == 4
        else { return nil }
        var sum = 0.0
        for i in 0..<4 {
            let dx = Double(quad[i].x - proposal[i].x)
            let dy = Double(quad[i].y - proposal[i].y)
            sum += sqrt(dx * dx + dy * dy)
        }
        return sum / 4 / sqrt(2) * 100
    }

    var statsText: String {
        guard attempts > 0 else {
            return "Aucune tentative validée — le score du "
                + "jeu (coins acceptés sans retouche, écart "
                + "moyen) s'affichera ici."
        }
        let pct = Int((100.0 * Double(acceptedCount)
            / Double(attempts)).rounded())
        let mean = totalError / Double(attempts)
        return "\(attempts) tentative(s) · \(acceptedCount) "
            + "acceptée(s) sans retouche (\(pct) %) · "
            + "écart moyen \(String(format: "%.1f", mean)) % "
            + "de la diagonale"
    }

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
        proposalQuad = nil
        proposalDetail = ""
        proposalSource = "defaut"
        proposalAlt = nil
        quad = []
        displayImage = nil
        imageSize = .zero
        guard let entry = current, let bank else {
            statusText = "Deck terminé. « Nouveau deck » "
                + "pour rejouer — entre les passes, les "
                + "modèles s'entraîneront sur tes corrections."
            return
        }
        guard let cg = bank.image(forDerived: entry) else {
            statusText = "Instance illisible (\(entry.file)) "
                + "— je passe à la suivante."
            index += 1
            loadCurrent()
            return
        }
        displayImage = cg
        imageSize = CGSize(width: cg.width, height: cg.height)
        statusText = "L'IA trace les contours…"
        let image = CIImage(cgImage: cg)
        let entryId = entry.id
        DispatchQueue.global(qos: .userInitiated)
            .async { [weak self] in
                guard let self, let scanner = self.scanner
                else { return }
                let proposal = scanner
                    .contourProposal(for: image)
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.current?.id == entryId
                    else { return }
                    if let proposal {
                        // Filet : jamais un coin hors cadre
                        // à l'écran, quel que soit le joueur.
                        let clamped = proposal.quad.map {
                            self.clampPoint($0)
                        }
                        self.proposalQuad = clamped
                        self.quad = clamped
                        self.proposalDetail = proposal.detail
                        self.proposalSource = proposal.source
                        self.proposalAlt = proposal.alt
                        self.statusText = "Contours proposés "
                            + "(\(proposal.detail)) — déplace "
                            + "les coins qui dépassent ou qui "
                            + "rognent le reçu, puis valide. "
                            + "L'extérieur assombri est ce qui "
                            + "sera enlevé."
                    } else {
                        let def = [
                            CGPoint(x: 0.08, y: 0.08),
                            CGPoint(x: 0.92, y: 0.08),
                            CGPoint(x: 0.92, y: 0.92),
                            CGPoint(x: 0.08, y: 0.92),
                        ]
                        self.proposalQuad = def
                        self.quad = def
                        self.proposalDetail = "aucune détection"
                        self.statusText = "Aucune détection — "
                            + "boîte par défaut : place les 4 "
                            + "coins sur le reçu, puis valide."
                    }
                }
            }
    }

    func setCorner(_ i: Int, _ p: CGPoint) {
        guard quad.count == 4, (0..<4).contains(i) else { return }
        quad[i] = CGPoint(x: min(1, max(0, p.x)),
                          y: min(1, max(0, p.y)))
    }

    func resetToProposal() {
        if let proposalQuad { quad = proposalQuad }
    }

    func validate() {
        guard let entry = current, let bank,
              let proposal = proposalQuad, quad.count == 4,
              let error = currentErrorPct
        else { return }
        let accepted = error < 0.5
        let proposalPts: [[Double]] = proposal.map {
            [Double($0.x), Double($0.y)]
        }
        let finalPts: [[Double]] = quad.map {
            [Double($0.x), Double($0.y)]
        }
        let altPts: [[Double]]? = proposalAlt?.map {
            [Double($0.x), Double($0.y)]
        }
        let sourceNumber = bank.photos
            .first { $0.id == entry.sourceId }?.number ?? 0
        let attempt = QuadAttempt(
            ts: ISO8601DateFormatter().string(from: Date()),
            stage: "contours", file: entry.file,
            sourceNumber: sourceNumber,
            group: entry.group,
            generationAngle: entry.angle,
            proposal: proposalPts, final: finalPts,
            meanErrorPct: error,
            source: proposalSource, altProposal: altPts,
            accepted: accepted)
        bank.appendQuadAttempt(attempt)
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
}
