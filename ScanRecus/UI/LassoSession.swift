import SwiftUI
import CoreImage
import Combine

/// LE JEU DU LASSO (2026-10-23) — le nouveau canal de
/// supervision, dicté par Grégoire : il ne corrige plus
/// rien à la main ; il JUGE. Une image à la fois, cycles
/// libres jusqu'à « Next ». La machine propose un lasso
/// fermé (polygone libre) ; il note chaque tentative
/// VIS-À-VIS de la précédente, affichée en fantôme pâle :
/// −1 moins bon, 0 équivalent, +1 mieux, +2 parfait.
///
/// La recherche (v1, purement géométrique — aucun
/// critère de perception) perturbe le meilleur lasso
/// connu à plusieurs échelles et repropose. Les notes
/// ne servent qu'ici ; le futur réseau n'apprendra que
/// la géométrie des élites par image.
///
/// Discipline issue de la revue critique du 2026-10-23 :
/// - journalisation complète des trajectoires (chaque
///   lasso, le fantôme auquel il a été comparé, la note,
///   la source, la version du moteur) ;
/// - DOUBLONS AVEUGLES (~9 % des cycles, invisibles
///   pour lui) : paire identique ou répétition différée,
///   pour mesurer la cohérence de son jugement ;
/// - garde-fous durs (dictés par Grégoire) : le lasso
///   reste dans l'image et son aire vaut au moins un
///   carré de 100 px de côté (pixels de l'image) ;
/// - le banc figé (1 reçu sur 7, par groupe) est
///   drapeau-isé dans chaque enregistrement.
@MainActor
final class LassoSession: ObservableObject {

    @Published private(set) var displayImage: CGImage?
    @Published private(set) var imageSize: CGSize = .zero
    /// Le lasso courant, foncé (coordonnées normalisées).
    @Published private(set) var current: [CGPoint] = []
    /// Le lasso précédent, en fantôme pâle.
    @Published private(set) var ghost: [CGPoint]?
    @Published private(set) var statusText = ""
    @Published private(set) var cycle = 0
    @Published private(set) var imagesDone = 0
    @Published private(set) var totalRatings = 0

    private var bank: TrainingBank?
    private var scanner: CompositeScanner?
    private var deck: [BankDerived] = []
    private var index = 0

    // État de recherche sur l'image courante.
    private var searchBase: [CGPoint] = []
    private var plusTwoLasso: [CGPoint]?
    private var history: [[CGPoint]] = []
    private var sigma = 0.05
    private var currentProbe: String?
    private var currentSource = "recherche"
    private var cyclesAtImageStart = 0

    private var entry: BankDerived? {
        deck.indices.contains(index) ? deck[index] : nil
    }

    var positionText: String {
        deck.isEmpty ? "0 / 0" : "\(index + 1) / \(deck.count)"
    }

    var instanceLabel: String { entry?.file ?? "—" }

    var statsText: String {
        "\(imagesDone) image(s) terminée(s) · "
            + "\(totalRatings) note(s) au total · "
            + "cycle \(cycle) sur cette image"
    }

    private static var tsFormatter: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime,
                           .withFractionalSeconds]
        return f
    }

    func prepare(bank: TrainingBank,
                 scanner: CompositeScanner) {
        self.bank = bank
        self.scanner = scanner
        deck = bank.derived.shuffled()
        index = 0
        imagesDone = 0
        totalRatings = 0
        loadCurrent()
    }

    func reshuffle() {
        guard let bank, let scanner else { return }
        prepare(bank: bank, scanner: scanner)
    }

    // MARK: Chargement d'une image

    private func loadCurrent() {
        displayImage = nil
        imageSize = .zero
        current = []
        ghost = nil
        cycle = 0
        history = []
        searchBase = []
        plusTwoLasso = nil
        sigma = 0.05
        currentProbe = nil
        guard let entry, let bank else {
            statusText = "Deck terminé. « Nouveau deck » "
                + "pour rejouer."
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
        statusText = "Le réseau propose un premier lasso…"
        let image = CIImage(cgImage: cg)
        let entryId = entry.id
        DispatchQueue.global(qos: .userInitiated)
            .async { [weak self] in
                guard let self, let scanner = self.scanner
                else { return }
                let proposal = scanner.contourProposal(
                    for: image)
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.entry?.id == entryId
                    else { return }
                    var polygon: [CGPoint]
                    var source: String
                    if let proposal {
                        var quad = proposal.quad
                        // Calibration existante (données
                        // de la banque) appliquée à
                        // l'amorce seulement.
                        if let cal = bank.contourCalibration() {
                            let cx = quad.reduce(CGFloat(0)) {
                                $0 + $1.x
                            } / 4
                            let cy = quad.reduce(CGFloat(0)) {
                                $0 + $1.y
                            } / 4
                            quad = quad.map { pt in
                                CGPoint(
                                    x: cx + (pt.x - cx)
                                        * CGFloat(cal.scale),
                                    y: cy + (pt.y - cy)
                                        * CGFloat(cal.scale))
                            }
                        }
                        polygon = Self.withMidpoints(quad)
                        source = "init-" + proposal.source
                    } else {
                        polygon = Self.defaultPolygon()
                        source = "init-defaut"
                    }
                    polygon = self.guardrailed(polygon,
                                               fallback: nil)
                    self.current = polygon
                    self.searchBase = polygon
                    self.history = [polygon]
                    self.cycle = 1
                    self.currentSource = source
                    self.currentProbe = nil
                    self.statusText = "Premier lasso — "
                        + "note-le (−1 / 0 / +1 / +2), ou "
                        + "Next si l'image est finie."
                }
            }
    }

    // MARK: Le jeu

    /// Note la tentative courante, vis-à-vis du fantôme.
    func rate(_ rating: Int) {
        guard let entry, let bank, !current.isEmpty
        else { return }
        let srcNum = bank.photos
            .first { $0.id == entry.sourceId }?.number ?? 0
        bank.appendLassoAttempt(LassoAttempt(
            ts: Self.tsFormatter.string(from: Date()),
            file: entry.file, sourceNumber: srcNum,
            group: entry.group, generationAngle: entry.angle,
            cycle: cycle, lasso: Self.pts(current),
            ghost: ghost.map { Self.pts($0) },
            rating: rating, probe: currentProbe,
            source: currentSource,
            bench: bank.isBench(sourceNumber: srcNum)))
        totalRatings += 1

        let rated = current
        let wasProbe = currentProbe != nil
        if !wasProbe {
            if rating == 2 {
                plusTwoLasso = rated
                searchBase = rated
            } else if rating >= 1 {
                searchBase = rated
            }
            // Adaptation du pas de recherche.
            switch rating {
            case 2, 1: sigma = max(0.008, sigma * 0.75)
            case 0: sigma = min(0.15, sigma * 1.3)
            default: sigma = min(0.15, sigma * 1.15)
            }
        }
        // Sa mécanique d'affichage : le lasso noté devient
        // le fantôme, quoi qu'il arrive.
        ghost = rated
        current = makeNextCandidate(afterRating: rating,
                                    wasProbe: wasProbe)
        cycle += 1
        statusText = rating == 2
            ? "Parfait, noté. Encore un cycle, ou Next."
            : "Noté. Compare le nouveau lasso au fantôme."
    }

    /// Termine l'image : l'élite part au journal, on
    /// passe à la suivante (le réseau y fera sa première
    /// proposition).
    func next() {
        guard let entry, let bank else { return }
        let srcNum = bank.photos
            .first { $0.id == entry.sourceId }?.number ?? 0
        let elite = plusTwoLasso ?? searchBase
        if !elite.isEmpty {
            bank.appendLassoElite(LassoElite(
                ts: Self.tsFormatter.string(from: Date()),
                file: entry.file, sourceNumber: srcNum,
                group: entry.group,
                generationAngle: entry.angle,
                lasso: Self.pts(elite), cycles: cycle,
                hadPlusTwo: plusTwoLasso != nil,
                bench: bank.isBench(sourceNumber: srcNum)))
        }
        imagesDone += 1
        index += 1
        loadCurrent()
    }

    // MARK: Génération des candidats

    private func makeNextCandidate(afterRating rating: Int,
                                   wasProbe: Bool) -> [CGPoint] {
        // Doublon aveugle (~9 %) : mesure de cohérence,
        // invisible pour le joueur.
        if cycle >= 2, history.count >= 2,
           Double.random(in: 0..<1) < 0.09 {
            if Bool.random(), let ghost {
                currentProbe = "identique"
                currentSource = "sonde"
                return ghost
            }
            let pool = Array(history.dropLast())
            if let pick = pool.randomElement() {
                currentProbe = "repetition"
                currentSource = "sonde"
                return pick
            }
        }
        currentProbe = nil
        currentSource = "recherche"
        let base = searchBase.isEmpty ? current : searchBase
        for _ in 0..<8 {
            let candidate = Self.perturb(base, sigma: sigma)
            let checked = guardrailed(candidate, fallback: nil)
            if checked != candidate || Self.isSane(candidate) {
                history.append(checked)
                return checked
            }
        }
        let fallback = guardrailed(base, fallback: nil)
        history.append(fallback)
        return fallback
    }

    /// Applique les garde-fous durs : coins dans
    /// l'image, aire minimale (carré de 100 px), polygone
    /// simple. Retourne le polygone corrigé, ou le repli.
    private func guardrailed(_ polygon: [CGPoint],
                             fallback: [CGPoint]?)
    -> [CGPoint] {
        var pts = polygon.map {
            CGPoint(x: min(0.996, max(0.004, $0.x)),
                    y: min(0.996, max(0.004, $0.y)))
        }
        // Aire minimale : si trop petit, on regonfle
        // autour du centroïde.
        let minFrac = minAreaFraction()
        var tries = 0
        while abs(Self.signedArea(pts)) < minFrac,
              tries < 6 {
            let c = Self.centroid(pts)
            pts = pts.map {
                CGPoint(x: c.x + ($0.x - c.x) * 1.4,
                        y: c.y + ($0.y - c.y) * 1.4)
            }.map {
                CGPoint(x: min(0.996, max(0.004, $0.x)),
                        y: min(0.996, max(0.004, $0.y)))
            }
            tries += 1
        }
        if Self.isSane(pts), abs(Self.signedArea(pts))
            >= minFrac {
            return pts
        }
        if let fallback { return fallback }
        return Self.isSane(pts) ? pts : Self.defaultPolygon()
    }

    private func minAreaFraction() -> Double {
        guard let entry, entry.width > 0, entry.height > 0
        else { return 0.004 }
        let frac = 10_000.0
            / (Double(entry.width) * Double(entry.height))
        return max(0.002, frac)
    }

    // MARK: Géométrie des polygones (pure, sans critères)

    static func pts(_ polygon: [CGPoint]) -> [[Double]] {
        polygon.map { [Double($0.x), Double($0.y)] }
    }

    static func centroid(_ p: [CGPoint]) -> CGPoint {
        guard !p.isEmpty else { return .zero }
        return CGPoint(
            x: p.reduce(CGFloat(0)) { $0 + $1.x }
                / CGFloat(p.count),
            y: p.reduce(CGFloat(0)) { $0 + $1.y }
                / CGFloat(p.count))
    }

    static func signedArea(_ p: [CGPoint]) -> Double {
        guard p.count >= 3 else { return 0 }
        var a = 0.0
        for i in 0..<p.count {
            let u = p[i], v = p[(i + 1) % p.count]
            a += Double(u.x * v.y - v.x * u.y)
        }
        return a / 2
    }

    /// Polygone simple ? (aucune arête n'en croise une
    /// autre non adjacente.)
    static func isSane(_ p: [CGPoint]) -> Bool {
        guard p.count >= 3 else { return false }
        func seg(_ a: CGPoint, _ b: CGPoint,
                 _ c: CGPoint, _ d: CGPoint) -> Bool {
            func cross(_ o: CGPoint, _ u: CGPoint,
                       _ v: CGPoint) -> CGFloat {
                (u.x - o.x) * (v.y - o.y)
                    - (u.y - o.y) * (v.x - o.x)
            }
            let d1 = cross(c, d, a), d2 = cross(c, d, b)
            let d3 = cross(a, b, c), d4 = cross(a, b, d)
            return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0))
                && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
        }
        let n = p.count
        for i in 0..<n {
            for j in (i + 1)..<n {
                if j == i + 1 || (i == 0 && j == n - 1) {
                    continue
                }
                if seg(p[i], p[(i + 1) % n],
                       p[j], p[(j + 1) % n]) {
                    return false
                }
            }
        }
        return true
    }

    static func withMidpoints(_ quad: [CGPoint]) -> [CGPoint] {
        guard quad.count == 4 else { return quad }
        var out: [CGPoint] = []
        for i in 0..<4 {
            let a = quad[i], b = quad[(i + 1) % 4]
            out.append(a)
            out.append(CGPoint(x: (a.x + b.x) / 2,
                               y: (a.y + b.y) / 2))
        }
        return out
    }

    static func defaultPolygon() -> [CGPoint] {
        withMidpoints([
            CGPoint(x: 0.15, y: 0.15),
            CGPoint(x: 0.85, y: 0.15),
            CGPoint(x: 0.85, y: 0.85),
            CGPoint(x: 0.15, y: 0.85),
        ])
    }

    /// Perturbation géométrique multi-échelles : globale
    /// (échelle/translation/rotation), segmentaire (un
    /// bout de bord glisse le long de sa normale), par
    /// sommet, ou insertion d'un sommet. Aucun critère
    /// sur les reçus — de la géométrie seulement.
    static func perturb(_ base: [CGPoint], sigma: Double)
    -> [CGPoint] {
        guard base.count >= 3 else { return base }
        var p = base
        let roll = Double.random(in: 0..<1)
        let c = centroid(p)
        if roll < 0.30 {
            // Globale : homothétie + translation + rotation.
            let s = 1 + Double.random(in: -sigma...sigma)
            let tx = Double.random(in: -sigma...sigma) * 0.6
            let ty = Double.random(in: -sigma...sigma) * 0.6
            let ang = Double.random(in: -sigma...sigma) * 0.8
            let ca = cos(ang), sa = sin(ang)
            p = p.map { pt in
                let dx = Double(pt.x - c.x) * s
                let dy = Double(pt.y - c.y) * s
                return CGPoint(
                    x: c.x + CGFloat(dx * ca - dy * sa)
                        + CGFloat(tx),
                    y: c.y + CGFloat(dx * sa + dy * ca)
                        + CGFloat(ty))
            }
        } else if roll < 0.65 {
            // Segmentaire : 2 à 4 sommets consécutifs
            // glissent le long de leur normale moyenne.
            let n = p.count
            let start = Int.random(in: 0..<n)
            let len = Int.random(in: 2...4)
            var nx = 0.0, ny = 0.0, cnt = 0.0
            for k in 0..<len {
                let i = (start + k) % n
                let prev = p[(i + n - 1) % n]
                let next = p[(i + 1) % n]
                nx += Double(next.y - prev.y)
                ny += Double(prev.x - next.x)
                cnt += 1
            }
            let norm = max(1e-9, (nx * nx + ny * ny)
                .squareRoot())
            let d = Double.random(in: -sigma...sigma)
            let ox = CGFloat(d * nx / norm)
            let oy = CGFloat(d * ny / norm)
            for k in 0..<len {
                let i = (start + k) % n
                p[i] = CGPoint(x: p[i].x + ox,
                               y: p[i].y + oy)
            }
        } else if roll < 0.90 {
            // Par sommet : 1 ou 2 sommets bougent.
            let n = p.count
            let count = Int.random(in: 1...2)
            for _ in 0..<count {
                let i = Int.random(in: 0..<n)
                p[i] = CGPoint(
                    x: p[i].x + CGFloat(
                        Double.random(in: -sigma...sigma)),
                    y: p[i].y + CGFloat(
                        Double.random(in: -sigma...sigma)))
            }
        } else if p.count < 40 {
            // Insertion : le milieu de la plus longue
            // arête devient un sommet, légèrement décalé.
            var best = 0, bestLen = -1.0
            for i in 0..<p.count {
                let a = p[i], b = p[(i + 1) % p.count]
                let l = hypot(Double(b.x - a.x),
                              Double(b.y - a.y))
                if l > bestLen { bestLen = l; best = i }
            }
            let a = p[best], b = p[(best + 1) % p.count]
            let mid = CGPoint(
                x: (a.x + b.x) / 2 + CGFloat(
                    Double.random(in: -sigma...sigma) * 0.5),
                y: (a.y + b.y) / 2 + CGFloat(
                    Double.random(in: -sigma...sigma) * 0.5))
            p.insert(mid, at: best + 1)
        }
        return p
    }
}
