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
    /// Les jauges de progression, relues du journal
    /// aux moments utiles (jamais dans le rendu —
    /// c'était une source de lenteur).
    @Published private(set) var progress = LassoProgress()
    /// La dernière note donnée : le retour visible
    /// immédiat qu'elle est bien rentrée.
    @Published private(set) var lastRating: Int?
    @Published private(set) var imagesDone = 0
    @Published private(set) var totalRatings = 0

    private var bank: TrainingBank?

    /// Plafond DUR de sommets (Grégoire, 2026-10-23).
    /// L'objectif mou, lui, est 4 — voir perturb().
    static let maxVertices = 30
    private var deck: [BankDerived] = []
    private var index = 0

    // État de recherche sur l'image courante.
    private var searchBase: [CGPoint] = []
    private var plusTwoLasso: [CGPoint]?
    private var history: [[CGPoint]] = []
    private var sigma = 0.05
    private var currentProbe: String?
    private var currentSource = "recherche"
    /// Vrai après un −1 : le prochain candidat doit
    /// EXPLORER (saut global, pas plus large) — exigé
    /// par Grégoire le 2026-10-23.
    private var exploreNext = false
    /// Après la note d'une suggestion, pas de doublon
    /// au cycle suivant, et les doublons « répétition »
    /// ne ressuscitent jamais un tracé d'AVANT la
    /// dernière suggestion (sinon l'IA a l'air de
    /// reproposer ses vieux tracés — vu en jouant,
    /// 2026-10-23).
    private var skipProbeOnce = false
    private var suggestionFloor = 0
    /// Après un +1 : le prochain candidat POLIT
    /// (retouches fines seulement). Après un 0 —
    /// « mouvement latéral : amélioration et
    /// régression à la fois » (sa définition,
    /// 2026-10-23) — le prochain candidat est un
    /// CROISEMENT des deux tracés comparés : garder
    /// ce qui s'est amélioré, refaire le reste.
    private var polishNext = false
    private var lateralParents: (a: [CGPoint],
                                 b: [CGPoint])?

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

    func prepare(bank: TrainingBank) {
        self.bank = bank
        deck = bank.derived.shuffled()
        index = 0
        imagesDone = 0
        totalRatings = 0
        lastRating = nil
        progress = bank.lassoProgress()
        loadCurrent()
    }

    private func refreshProgress() {
        if let bank { progress = bank.lassoProgress() }
    }

    func reshuffle() {
        guard let bank else { return }
        prepare(bank: bank)
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
        exploreNext = false
        currentProbe = nil
        guard let entry, let bank else {
            statusText = "Deck terminé. « Nouveau deck » "
                + "pour rejouer."
            return
        }
        statusText = "Chargement de l'image…"
        let entryId = entry.id
        // Le décodage part en arrière-plan (basse
        // priorité) ; le fil principal ne reçoit que le
        // résultat. L'amorce est NEUTRE : ni Vision ni
        // l'outil de zone — une boîte de départ qui ne
        // doit rien à aucun système de perception
        // (décision de Grégoire, 2026-10-23 : la boîte
        // noire, c'est NOTRE réseau ; un point de départ
        // emprunté ancrerait toute la grimpe).
        DispatchQueue.global(qos: .utility)
            .async { [weak self] in
                guard let self else { return }
                guard let cg = bank.image(
                    forDerived: entry) else {
                    DispatchQueue.main.async { [weak self] in
                        guard let self,
                              self.entry?.id == entryId
                        else { return }
                        self.statusText = "Instance "
                            + "illisible (\(entry.file)) "
                            + "— je passe à la suivante."
                        self.index += 1
                        self.loadCurrent()
                    }
                    return
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.entry?.id == entryId
                    else { return }
                    self.displayImage = cg
                    self.imageSize = CGSize(
                        width: cg.width, height: cg.height)
                    let polygon = self.guardrailed(
                        Self.neutralStart(), fallback: nil)
                    self.current = polygon
                    self.searchBase = polygon
                    self.history = [polygon]
                    self.cycle = 1
                    self.currentSource = "init-neutre"
                    self.currentProbe = nil
                    self.statusText = "Premier lasso "
                        + "(départ neutre) — note-le "
                        + "(−1 / 0 / +1 / +2), ou Next si "
                        + "l'image est finie."
                }
            }
    }

    // MARK: Le jeu

    /// Note la tentative courante, vis-à-vis du fantôme.
    /// +2 = parfait : l'image est FINIE (ajustement de
    /// Grégoire, 2026-10-23 — continuer ne servirait à
    /// rien) : l'élite part au journal, on passe à la
    /// suivante.
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
        lastRating = rating
        refreshProgress()

        if rating == 2 {
            finishImage(elite: current, hadPlusTwo: true)
            return
        }
        let rated = current
        let wasProbe = currentProbe != nil
        let wasSuggestion = currentSource == "suggestion"
        if wasSuggestion {
            skipProbeOnce = true
            suggestionFloor = max(0, history.count - 1)
        }
        if !wasProbe {
            // Une suggestion notée 0 (« équivalente »)
            // est quand même adoptée : c'est la
            // direction qu'il a indiquée, et elle n'est
            // pas moins bonne que le fantôme.
            if rating >= 1
                || (rating == 0 && wasSuggestion)
                || (rating == 0
                    && rated.count < searchBase.count) {
                // À qualité jugée égale (0), le polygone
                // le plus SIMPLE gagne : c'est la
                // pression douce vers 4 sommets — elle
                // ne contredit jamais une note.
                searchBase = rated
            }
            // La politique de recherche, dans SES mots
            // (2026-10-23) : +1 = resserrer les arêtes,
            // 0 = mouvement latéral, −1 = agrandir.
            switch rating {
            case 1:
                // RESSERRER : pas réduit, et le prochain
                // candidat ne fera que des retouches
                // fines (bords et sommets).
                sigma = max(0.006, sigma * 0.6)
                polishNext = true
            case 0:
                // LATÉRAL : ni resserrer ni élargir —
                // croiser les deux tracés comparés (le
                // noté et son fantôme). Le pas ne bouge
                // pas.
                if let ghostBefore = ghost {
                    lateralParents = (a: rated,
                                      b: ghostBefore)
                }
            default:
                // −1 = AGRANDIR : le pas grandit
                // franchement (×1,6, plafond relevé) et
                // le prochain candidat sera un saut
                // global d'exploration.
                sigma = min(0.28, sigma * 1.6)
                exploreNext = true
            }
        }
        // Sa mécanique d'affichage : le lasso noté devient
        // le fantôme, quoi qu'il arrive.
        ghost = rated
        current = makeNextCandidate(afterRating: rating,
                                    wasProbe: wasProbe)
        cycle += 1
        statusText = "Noté. Compare le nouveau lasso "
            + "au fantôme."
    }

    /// Termine l'image sans +2 (bouton Next) : l'élite
    /// est le meilleur lasso connu de l'image.
    func next() {
        finishImage(elite: plusTwoLasso ?? searchBase,
                    hadPlusTwo: plusTwoLasso != nil)
    }

    /// Clôt l'image courante : l'élite part au journal,
    /// on avance à la suivante. Chaque note étant déjà
    /// journalisée à la seconde où elle est donnée,
    /// quitter l'app ne perd rien ; et reprendre plus
    /// tard = un deck neuf, mélangé (prepare), donc une
    /// image au hasard pour recommencer.
    private func finishImage(elite: [CGPoint],
                             hadPlusTwo: Bool) {
        guard let entry, let bank else { return }
        let srcNum = bank.photos
            .first { $0.id == entry.sourceId }?.number ?? 0
        if !elite.isEmpty {
            bank.appendLassoElite(LassoElite(
                ts: Self.tsFormatter.string(from: Date()),
                file: entry.file, sourceNumber: srcNum,
                group: entry.group,
                generationAngle: entry.angle,
                lasso: Self.pts(elite), cycles: cycle,
                hadPlusTwo: hadPlusTwo,
                bench: bank.isBench(sourceNumber: srcNum)))
        }
        imagesDone += 1
        index += 1
        refreshProgress()
        loadCurrent()
    }

    /// Une SUGGESTION de Grégoire (2026-10-23) : il
    /// édite le lasso courant à la souris. Ni un ordre
    /// ni une vérité — une direction offerte à la
    /// recherche (« si tu vas par là, tu auras de
    /// meilleurs résultats »). C'est sa NOTE, ensuite,
    /// qui décide : la suggestion devient un candidat
    /// comme les autres.
    /// Grammaire d'édition : tirer un sommet le
    /// déplace ; cliquer une arête y fait naître un
    /// sommet ; clic droit sur un sommet l'efface.
    /// Règles DURES : jamais moins de 4 sommets, jamais
    /// plus de 30 ; un polygone croisé ou sous l'aire
    /// minimale est refusé en douceur. Éditer un
    /// doublon aveugle l'annule (il n'est plus
    /// identique/répété) — le journal reste honnête.
    /// Le tracé gardé au début d'un glissement, pour
    /// y revenir si le résultat final est invalide.
    private var dragBackup: [CGPoint]?

    func beginVertexDrag() {
        dragBackup = current
    }

    func moveVertex(_ index: Int, to point: CGPoint) {
        guard current.indices.contains(index) else { return }
        let target = clamped(point)
        let old = current[index]
        // Filtre à tremblements : ignorer les
        // micro-déplacements — chaque publication
        // reconstruit le canevas, et à ~120 événements
        // par seconde c'est ce qui rendait le
        // glissement poussif (2026-10-23).
        if abs(target.x - old.x) < 0.0008,
           abs(target.y - old.y) < 0.0008 { return }
        var candidate = current
        candidate[index] = target
        if dragBackup != nil {
            // PENDANT le glissement : le sommet suit la
            // souris SANS rejet — un tracé
            // temporairement croisé est permis. Avant,
            // chaque position intermédiaire passait
            // par le filtre de validité et le sommet
            // avait l'air coincé, « buggé ». La
            // validation se fait au lâcher.
            current = candidate
            if !history.isEmpty {
                history[history.count - 1] = candidate
            }
            currentProbe = nil
            currentSource = "suggestion"
        } else {
            applySuggestion(candidate)
        }
    }

    /// Fin du glissement : si le tracé final est
    /// invalide (croisé, sous l'aire minimale), on
    /// revient au tracé d'avant le glissement.
    func endVertexDrag() {
        defer { dragBackup = nil }
        guard let backup = dragBackup else { return }
        if current.count < 4, !Self.isSane(current) {
            // (garde-fou — le compte ne peut pas
            // changer pendant un glissement)
        }
        if !Self.isSane(current)
            || abs(Self.signedArea(current))
                < minAreaFraction() {
            current = backup
            if !history.isEmpty {
                history[history.count - 1] = backup
            }
        }
    }

    /// Naissance d'un sommet sur l'arête `edge`
    /// (du sommet edge vers edge+1), au point donné.
    func insertVertex(onEdge edge: Int, at point: CGPoint) {
        guard current.count >= 4,
              current.count < Self.maxVertices,
              current.indices.contains(edge)
        else { return }
        var candidate = current
        candidate.insert(clamped(point), at: edge + 1)
        applySuggestion(candidate)
    }

    /// Effacement d'un sommet (clic droit). Bloqué à
    /// 4 sommets : 0 à 3 est impossible, règle dure.
    func deleteVertex(_ index: Int) {
        guard current.count > 4,
              current.indices.contains(index)
        else { return }
        var candidate = current
        candidate.remove(at: index)
        applySuggestion(candidate)
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(0.996, max(0.004, point.x)),
                y: min(0.996, max(0.004, point.y)))
    }

    private func applySuggestion(_ candidate: [CGPoint]) {
        guard candidate.count >= 4,
              Self.isSane(candidate),
              abs(Self.signedArea(candidate))
                >= minAreaFraction()
        else { return }
        current = candidate
        if !history.isEmpty {
            history[history.count - 1] = candidate
        }
        currentProbe = nil
        currentSource = "suggestion"
    }

    // MARK: Génération des candidats

    private func makeNextCandidate(afterRating rating: Int,
                                   wasProbe: Bool) -> [CGPoint] {
        // Doublon aveugle (~9 %) : mesure de cohérence,
        // invisible pour le joueur. Jamais juste après
        // la note d'une suggestion ; la répétition ne
        // puise que dans l'après-dernière-suggestion.
        let skipProbe = skipProbeOnce
        skipProbeOnce = false
        if !skipProbe, cycle >= 2, history.count >= 2,
           Double.random(in: 0..<1) < 0.09 {
            if Bool.random(), let ghost {
                currentProbe = "identique"
                currentSource = "sonde"
                return ghost
            }
            let pool = Array(
                history[suggestionFloor...].dropLast())
            if let pick = pool.randomElement() {
                currentProbe = "repetition"
                currentSource = "sonde"
                return pick
            }
        }
        currentProbe = nil
        currentSource = "recherche"
        let forceGlobal = exploreNext
        exploreNext = false
        let polish = polishNext
        polishNext = false
        let lateral = lateralParents
        lateralParents = nil
        let base = searchBase.isEmpty ? current : searchBase
        for _ in 0..<8 {
            let candidate: [CGPoint]
            if let lateral,
               lateral.a.count == lateral.b.count {
                candidate = Self.crossover(
                    lateral.a, lateral.b, sigma: sigma)
            } else if let lateral {
                candidate = Self.perturb(
                    lateral.a, sigma: sigma, fineOnly: true)
            } else {
                candidate = Self.perturb(
                    base, sigma: sigma,
                    globalOnly: forceGlobal,
                    fineOnly: polish)
            }
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
        if pts.count >= 4, Self.isSane(pts),
           abs(Self.signedArea(pts)) >= minFrac {
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

    /// Le départ NEUTRE : une boîte 18 %–82 % avec un
    /// léger tremblement (±3 %). Aucune perception —
    /// c'est le même point de départ (à un souffle
    /// près) pour toutes les images.
    static func neutralStart() -> [CGPoint] {
        func j(_ v: CGFloat) -> CGFloat {
            v + CGFloat(Double.random(in: -0.03...0.03))
        }
        return withMidpoints([
            CGPoint(x: j(0.18), y: j(0.18)),
            CGPoint(x: j(0.82), y: j(0.18)),
            CGPoint(x: j(0.82), y: j(0.82)),
            CGPoint(x: j(0.18), y: j(0.82)),
        ])
    }

    static func defaultPolygon() -> [CGPoint] {
        withMidpoints([
            CGPoint(x: 0.15, y: 0.15),
            CGPoint(x: 0.85, y: 0.15),
            CGPoint(x: 0.85, y: 0.85),
            CGPoint(x: 0.15, y: 0.85),
        ])
    }

    /// Perturbation géométrique multi-échelles :
    /// globale (échelle/translation/rotation),
    /// segmentaire (un bout de bord glisse le long de
    /// sa normale), par sommet, insertion ou
    /// SUPPRESSION d'un sommet. Aucun critère sur les
    /// reçus — de la géométrie seulement.
    ///
    /// OBJECTIF MOU (Grégoire, 2026-10-23) : pousser
    /// le lasso vers 4 sommets. Les poids des
    /// opérateurs en tiennent compte : plus le
    /// polygone a de sommets, plus la suppression
    /// devient probable et l'insertion rare. Et la
    /// suppression enlève le sommet dont le retrait
    /// déforme le moins le polygone. Plafond dur :
    /// 30 sommets ; plancher de suppression : 4.
    static func perturb(_ base: [CGPoint], sigma: Double,
                        globalOnly: Bool = false,
                        fineOnly: Bool = false)
    -> [CGPoint] {
        guard base.count >= 3 else { return base }
        var p = base
        let n = p.count
        let wGlobal = 0.30
        let wSeg = 0.32
        let wVert = 0.20
        let wInsert = n < maxVertices ? 0.08 : 0.0
        let wRemove = n > 4
            ? 0.10 + min(0.15, Double(n - 8) * 0.012)
            : 0.0
        let total = wGlobal + wSeg + wVert + wInsert
            + wRemove
        var roll = Double.random(in: 0..<total)
        if globalOnly { roll = 0 }
        if fineOnly {
            // « Resserrer » : retouches fines
            // (segmentaire + sommet) + une part
            // d'INSERTION. Même après une suggestion
            // à 4 arêtes notée +1, l'IA doit pouvoir
            // AJOUTER des sommets si la photo l'exige
            // (aberration, coin déchiré) — une
            // suggestion n'est pas une cage
            // (Grégoire, 2026-10-23).
            roll = wGlobal + Double.random(
                in: 0..<(wSeg + wVert + wInsert))
        }
        let c = centroid(p)
        if roll < wGlobal {
            // Globale : homothétie + translation +
            // rotation. Amplitude PLAFONNÉE (0,12) et
            // rotation réduite : même en exploration,
            // un saut ne doit pas défigurer une forme
            // adoptée — avant ce plafond, un −1
            // vandalisait la suggestion de Grégoire
            // (échelle ±28 %, rotation ±13°) et le jeu
            // avait l'air de régresser (2026-10-23).
            let g = min(sigma, 0.12)
            let s = 1 + Double.random(in: -g...g)
            let tx = Double.random(in: -g...g) * 0.6
            let ty = Double.random(in: -g...g) * 0.6
            let ang = Double.random(in: -g...g) * 0.4
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
        } else if roll < wGlobal + wSeg {
            // Segmentaire : 2 à 4 sommets consécutifs
            // glissent le long de leur normale moyenne.
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
        } else if roll < wGlobal + wSeg + wVert {
            // Par sommet : 1 ou 2 sommets bougent.
            let count = Int.random(in: 1...2)
            for _ in 0..<count {
                let i = Int.random(in: 0..<n)
                p[i] = CGPoint(
                    x: p[i].x + CGFloat(
                        Double.random(in: -sigma...sigma)),
                    y: p[i].y + CGFloat(
                        Double.random(in: -sigma...sigma)))
            }
        } else if roll < wGlobal + wSeg + wVert + wInsert {
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
        } else {
            // Suppression : le sommet dont le retrait
            // déforme le moins (distance au segment de
            // ses voisins) disparaît.
            var worst = 0, worstDev = Double.greatestFiniteMagnitude
            for i in 0..<n {
                let prev = p[(i + n - 1) % n]
                let next = p[(i + 1) % n]
                let pt = p[i]
                let vx = Double(next.x - prev.x)
                let vy = Double(next.y - prev.y)
                let len = max(1e-9, (vx * vx + vy * vy)
                    .squareRoot())
                let dev = abs(vx * Double(pt.y - prev.y)
                    - vy * Double(pt.x - prev.x)) / len
                if dev < worstDev {
                    worstDev = dev
                    worst = i
                }
            }
            p.remove(at: worst)
        }
        return p
    }

    /// Le CROISEMENT du mouvement latéral (note 0) :
    /// sommet par sommet, l'enfant hérite au hasard
    /// d'un des deux parents — le tracé noté ou son
    /// fantôme — plus un léger tremblement. Il teste
    /// ainsi quelles parties étaient l'amélioration
    /// et lesquelles la régression.
    static func crossover(_ a: [CGPoint], _ b: [CGPoint],
                          sigma: Double) -> [CGPoint] {
        guard a.count == b.count, a.count >= 4 else {
            return a
        }
        let jitter = sigma * 0.4
        return (0..<a.count).map { i in
            let src = Bool.random() ? a[i] : b[i]
            return CGPoint(
                x: src.x + CGFloat(
                    Double.random(in: -jitter...jitter)),
                y: src.y + CGFloat(
                    Double.random(in: -jitter...jitter)))
        }
    }
}
