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
/// - le paquet sert les photos ORIGINALES (jamais
///   les copies tournées — du stock mécanique, pas
///   du temps de jeu) dans l'ordre des GÉNÉRATIONS :
///   registre des terminaisons relu du journal,
///   photos non jouées d'abord ; une photo bankée
///   entre-temps (0 terminaison) passe devant les
///   générations suivantes (Grégoire, 2026-10-25).
/// - SÉLECTION AIDÉE (build 131, Grégoire) : la
///   recherche génère un paquet de candidats et le
///   juge GÉOMÉTRIE (k-NN du journal — le seul juge
///   au-dessus du hasard : kappa 0,64 à l'examen
///   multi-scènes) choisit celui qu'il prédit le
///   mieux noté. Jamais sur les photos d'examen ;
///   choix étiquetés « juge » au journal ; 1 tirage
///   sur 5 reste libre. Le juge neuronal, lui,
///   n'agit pas : promu seulement s'il bat la
///   géométrie à l'examen, par un geste délibéré.
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
    /// La FOULÉE de la machine : l'ampleur de ses
    /// pas, qu'ELLE choisit et calibre d'après les
    /// commentaires du juge (définitions de
    /// Grégoire, 2026-10-24 : « d'autant de pas que
    /// tu penses »). Départ 0,10 — échelle de voyage,
    /// pas de polissage.
    private var sigma = 0.10
    private var currentProbe: String?
    private var currentSource = "recherche"
    /// Le candidat affiché a-t-il été choisi par le
    /// juge géométrie (build 131) ? Il sera étiqueté
    /// « juge » au journal quand il sera noté.
    /// Drapeau SÉPARÉ de currentProbe : une sonde
    /// saute la calibration des pas (wasProbe), un
    /// choix du juge ne doit pas la sauter.
    private var aideJuge = false
    /// La mémoire du juge géométrie, relue du
    /// journal via la banque aux mêmes moments que
    /// les jauges — chaque note l'enrichit aussitôt.
    private var knnMemoire: [(features: [Double],
                              rating: Int)] = []
    /// La manœuvre choisie pour le prochain
    /// candidat, d'après le COMMENTAIRE reçu :
    /// refermer (+1), ouvrir (−1), autre chose (0),
    /// libre (défaut, sondes). La machine décide
    /// l'ampleur et les côtés — jamais le juge.
    private enum Maneuver {
        case close, open, other, none
    }
    private var maneuver: Maneuver = .none
    private var lastManeuver: Maneuver = .none
    private var pendingBase: [CGPoint] = []
    /// Dernière famille essayée après un 0, pour
    /// ne pas la resservir (« essaie AUTRE chose »).
    private var lastFamily = ""
    /// Après la note d'une suggestion, pas de doublon
    /// au cycle suivant, et les doublons « répétition »
    /// ne ressuscitent jamais un tracé d'AVANT la
    /// dernière suggestion (sinon l'IA a l'air de
    /// reproposer ses vieux tracés — vu en jouant,
    /// 2026-10-23).
    private var skipProbeOnce = false
    private var suggestionFloor = 0

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
        progress = bank.lassoProgress()
        knnMemoire = bank.geometryMemory()
        deck = Self.generationDeck(bank: bank,
                                   progress: progress)
        index = 0
        imagesDone = 0
        totalRatings = 0
        lastRating = nil
        loadCurrent()
    }

    private func refreshProgress() {
        if let bank {
            progress = bank.lassoProgress()
            knnMemoire = bank.geometryMemory()
        }
    }

    func nouveauDeck() {
        guard let bank else { return }
        prepare(bank: bank)
    }

    /// L'ordre des générations (fonction pure) :
    /// d'abord les photos les moins terminées ; à
    /// égalité, celle terminée il y a le plus
    /// longtemps (jamais = -1, donc en tête de son
    /// niveau) ; puis le numéro de photo.
    static func generationOrder(
        _ items: [(number: Int, done: Int, last: Int)]
    ) -> [Int] {
        items.sorted { a, b in
            if a.done != b.done { return a.done < b.done }
            if a.last != b.last { return a.last < b.last }
            return a.number < b.number
        }.map { $0.number }
    }

    /// Le paquet : UNE entrée par photo — la photo
    /// ORIGINALE, synthétisée en entrée de paquet —
    /// dans l'ordre des générations.
    static func generationDeck(
        bank: TrainingBank, progress: LassoProgress
    ) -> [BankDerived] {
        var lastMap: [Int: Int] = [:]
        for (i, sn) in progress.dernieresTerminaisons
            .enumerated() {
            lastMap[sn] = i
        }
        let items: [(number: Int, done: Int,
                      last: Int)] = bank.photos.map {
            photo in
            (number: photo.number,
             done: progress.completionsParPhoto[
                photo.number] ?? 0,
             last: lastMap[photo.number] ?? -1)
        }
        let byNumber = Dictionary(
            uniqueKeysWithValues: bank.photos.map {
                ($0.number, $0) })
        return generationOrder(items).compactMap { num in
            guard let photo = byNumber[num] else {
                return nil
            }
            return BankDerived(
                id: photo.id + "#orig",
                sourceId: photo.id,
                group: photo.group,
                angle: 0,
                sha256: photo.sha256,
                file: photo.file,
                width: photo.width,
                height: photo.height,
                ts: photo.ts)
        }
    }

    /// L'étiquette « Génération » du panneau de jeu :
    /// la génération de la photo affichée (sa 1re,
    /// 2e… partie), les photos encore à jouer dans
    /// cette génération, et l'état de la banque —
    /// pour savoir quand une génération complète
    /// est bouclée.
    var generationText: String {
        guard let bank else { return "" }
        let total = bank.photos.count
        let done = progress.completionsParPhoto
        let playedOnce = done.filter {
            $0.value >= 1
        }.count
        guard let entry,
              let photo = bank.photos.first(where: {
                  $0.id == entry.sourceId })
        else {
            let m = done.values.min() ?? 0
            return "Chaque photo jouée au moins "
                + "\(m) fois · \(total) photos en "
                + "banque — « Nouveau deck » pour la "
                + "génération \(m + 1)"
        }
        let g = (done[photo.number] ?? 0) + 1
        let restantes = bank.photos.filter {
            (done[$0.number] ?? 0) < g
        }.count
        return "Génération \(g) · \(restantes) "
            + "photo(s) à jouer dans cette "
            + "génération · \(playedOnce)/\(total) "
            + "photos jouées au moins une fois"
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
        sigma = 0.10
        maneuver = .none
        lastManeuver = .none
        pendingBase = []
        lastFamily = ""
        suggestionFloor = 0
        skipProbeOnce = false
        currentProbe = nil
        aideJuge = false
        guard let entry, let bank else {
            statusText = "Génération terminée. "
                + "« Nouveau deck » pour la suivante "
                + "— les photos nouvelles passeront "
                + "en premier."
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
            rating: rating,
            probe: currentProbe
                ?? (aideJuge ? "juge" : nil),
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
        // Défauts (sonde notée, etc.) : génération
        // libre depuis la meilleure base connue.
        maneuver = .none
        pendingBase = searchBase.isEmpty ? rated
            : searchBase
        // La calibration des pas par les COMMENTAIRES
        // : des +1 répétés sans arriver = pas trop
        // timides, on allonge la foulée ; un −1 après
        // une refermeture = dépassé, on la raccourcit ;
        // des −1 répétés après une ouverture =
        // ouverture insuffisante, on ouvre plus fort.
        // C'est la machine qui apprend SON ampleur.
        if !wasProbe, !wasSuggestion {
            switch (lastManeuver, rating) {
            case (.close, 1):
                sigma = min(0.30, sigma * 1.35)
            case (.close, -1):
                sigma = max(0.03, sigma * 0.55)
            case (.open, -1):
                sigma = min(0.35, sigma * 1.5)
            case (.open, 1):
                sigma = max(0.04, sigma * 0.7)
            default:
                break
            }
        }
        if !wasProbe {
            // Une suggestion est adoptée à TOUTE note
            // (correction du 2026-10-24) : ce qu'il a
            // dessiné devient la référence, et la note
            // — un commentaire — pilote la manœuvre
            // depuis elle. L'ancienne règle « jetée si
            // −1 » contredisait son « −1 = ouvre » et
            // donnait l'impression que sa note et son
            // dessin étaient ignorés.
            if wasSuggestion
                || rating >= 1
                || (rating == 0
                    && rated.count < searchBase.count) {
                // À qualité jugée égale (0), le polygone
                // le plus SIMPLE gagne : c'est la
                // pression douce vers 4 sommets — elle
                // ne contredit jamais une note.
                searchBase = rated
            }
            // La manœuvre, dans SES mots (2026-10-24) :
            // la note est un commentaire, la machine
            // choisit ses pas.
            switch rating {
            case 1:
                // « C'est bien, continue de refermer »
                // — depuis le tracé noté.
                maneuver = .close
                pendingBase = rated
            case 0:
                // « Incertitude, essaie autre chose »
                // — depuis la meilleure base connue.
                maneuver = .other
                pendingBase = searchBase.isEmpty ? rated
                    : searchBase
            default:
                // « C'est mal, ouvre ton cadre » —
                // depuis le cadre noté, à ouvrir.
                maneuver = .open
                pendingBase = rated
            }
        }
        // Sa mécanique d'affichage : le lasso noté
        // devient le fantôme, quoi qu'il arrive. Le
        // prochain candidat est généré TOUT DE SUITE,
        // en synchrone (retour à la boucle d'avant le
        // build 106 : la génération asynchrone — jetons,
        // délai minimum, roue — a rendu le jeu mou et
        // fragile pour un calcul de quelques
        // millisecondes ; supprimée au build 107).
        ghost = rated
        current = makeNextCandidate(afterRating: rating,
                                    wasProbe: wasProbe)
        cycle += 1
        if wasSuggestion {
            switch rating {
            case 1:
                statusText = "Ta suggestion, gardée — "
                    + "je continue de refermer depuis "
                    + "elle."
            case 0:
                statusText = "Ta suggestion, gardée — "
                    + "j'essaie autre chose depuis elle."
            default:
                statusText = "Ta suggestion, gardée — "
                    + "j'ouvre le cadre depuis elle."
            }
        } else {
            switch rating {
            case 1:
                statusText = "« Bien » — je continue de "
                    + "refermer."
            case 0:
                statusText = "Incertitude notée — "
                    + "j'essaie autre chose."
            default:
                statusText = "« Mal » — j'ouvre le "
                    + "cadre."
            }
        }
        if aideJuge {
            statusText += " Candidat choisi par le "
                + "juge géométrie."
        }
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
    /// tard = un paquet reconstruit par prepare selon
    /// le registre des générations, qui ressert
    /// d'abord les photos non jouées.
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
            aideJuge = false
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
            statusText = "Tracé refusé : il se croise "
                + "ou devient trop petit — revenu au "
                + "tracé de départ."
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
        aideJuge = false
    }

    // MARK: Génération des candidats

    private func makeNextCandidate(afterRating rating: Int,
                                   wasProbe: Bool) -> [CGPoint] {
        aideJuge = false
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
                history[min(suggestionFloor,
                            history.count)...]
                    .dropLast())
            if let pick = pool.randomElement() {
                currentProbe = "repetition"
                currentSource = "sonde"
                return pick
            }
        }
        currentProbe = nil
        currentSource = "recherche"
        let base = pendingBase.isEmpty
            ? (searchBase.isEmpty ? current : searchBase)
            : pendingBase
        let noise = min(0.05, max(0.015, sigma * 0.35))
        // Un PAQUET de candidats sains (build 131) :
        // avant, le premier sain était servi tel quel
        // — d'où les propositions « stupides » qui
        // rendaient le jeu pénible. Le juge géométrie
        // choisit maintenant dans le paquet, quand il
        // a le droit de le faire (voir plus bas).
        var pool: [[CGPoint]] = []
        for _ in 0..<24 {
            if pool.count >= 6 { break }
            let candidate: [CGPoint]
            switch maneuver {
            case .close:
                candidate = Self.closedIn(
                    base, stride: sigma, noise: noise)
            case .open:
                candidate = Self.opened(
                    base, stride: sigma, noise: noise)
            case .other:
                candidate = otherCandidate(
                    base: base, noise: noise)
            case .none:
                candidate = Self.perturb(base, sigma: 0.05)
            }
            let checked = guardrailed(candidate,
                                       fallback: nil)
            if checked != candidate
                || Self.isSane(candidate) {
                if !pool.contains(checked) {
                    pool.append(checked)
                }
            }
        }
        if pool.isEmpty {
            let fallback = guardrailed(base,
                                        fallback: nil)
            history.append(fallback)
            lastManeuver = maneuver
            return fallback
        }
        var chosen = pool[0]
        // Sélection aidée par le juge géométrie :
        // interdite sur les photos d'examen (il ne
        // doit pas être examiné sur ses propres
        // choix), et 1 fois sur 5 le tirage reste
        // libre — l'exploration entretient la
        // diversité des données.
        if pool.count > 1, let reference = ghost,
           knnMemoire.count >= 20, let bank, let entry,
           !bank.isExamPhoto(
               sourceNumber: bank.photos.first {
                   $0.id == entry.sourceId
               }?.number ?? 0) {
            if Double.random(in: 0..<1) < 0.8,
               let pick = knnBest(pool: pool,
                                  reference: reference) {
                chosen = pick
                aideJuge = true
            } else {
                chosen = pool.randomElement() ?? pool[0]
            }
        }
        history.append(chosen)
        lastManeuver = maneuver
        return chosen
    }

    /// Le choix du juge GÉOMÉTRIE dans le paquet :
    /// k-NN (k = 7) sur les descripteurs du journal,
    /// standardisés comme dans juge.py. Retenu : le
    /// candidat dont la classe prédite est la
    /// meilleure (+1 > 0 > −1), départagé par la
    /// part des votes de sa classe.
    private func knnBest(pool: [[CGPoint]],
                         reference: [CGPoint])
        -> [CGPoint]? {
        let memoire = knnMemoire
        let n = memoire.count
        guard n >= 20 else { return nil }
        var mu = [Double](repeating: 0, count: 4)
        var sd = [Double](repeating: 0, count: 4)
        for m in memoire {
            for j in 0..<4 { mu[j] += m.features[j] }
        }
        for j in 0..<4 { mu[j] /= Double(n) }
        for m in memoire {
            for j in 0..<4 {
                let d = m.features[j] - mu[j]
                sd[j] += d * d
            }
        }
        for j in 0..<4 {
            sd[j] = sqrt(sd[j] / Double(n))
            if sd[j] == 0 { sd[j] = 1 }
        }
        let zMemoire: [[Double]] = memoire.map { m in
            (0..<4).map {
                (m.features[$0] - mu[$0]) / sd[$0]
            }
        }
        let refPts = Self.pts(reference)
        let k = min(7, n)
        func prediction(_ cand: [CGPoint])
            -> (classe: Int, part: Double) {
            let f = TrainingBank.geomFeatures(
                cand: Self.pts(cand), ghost: refPts,
                cycle: cycle + 1)
            let z = (0..<4).map {
                (f[$0] - mu[$0]) / sd[$0]
            }
            var dists: [(Double, Int)] = []
            for i in 0..<n {
                var dd = 0.0
                for j in 0..<4 {
                    let dz = zMemoire[i][j] - z[j]
                    dd += dz * dz
                }
                dists.append((sqrt(dd),
                              memoire[i].rating))
            }
            dists.sort { $0.0 < $1.0 }
            var votes: [Int: Int] = [:]
            for i in 0..<k {
                votes[dists[i].1, default: 0] += 1
            }
            var bestClasse = -1
            var bestVotes = -1
            for (classe, v) in votes {
                if v > bestVotes
                    || (v == bestVotes
                        && classe > bestClasse) {
                    bestVotes = v
                    bestClasse = classe
                }
            }
            return (bestClasse,
                    Double(bestVotes) / Double(k))
        }
        var bestPoly: [CGPoint]? = nil
        var bestScore = -Double.infinity
        for cand in pool {
            let pr = prediction(cand)
            let score = Double(pr.classe) + pr.part
            if score > bestScore {
                bestScore = score
                bestPoly = cand
            }
        }
        return bestPoly
    }

    /// « ESSAIE AUTRE CHOSE » (note 0) : changer de
    /// famille de mouvement par rapport à la
    /// précédente — voyage, forme, ou croisement
    /// avec le fantôme.
    private func otherCandidate(base: [CGPoint],
                                noise: Double) -> [CGPoint] {
        var families = ["voyage", "forme", "croisement"]
        if !lastFamily.isEmpty {
            families.removeAll { $0 == lastFamily }
        }
        let pick = families.randomElement() ?? "forme"
        lastFamily = pick
        switch pick {
        case "voyage":
            return Self.perturb(base,
                                sigma: max(sigma, 0.10),
                                globalOnly: true)
        case "croisement":
            if let ghost, ghost.count == base.count {
                return Self.crossover(
                    base, ghost, sigma: max(noise, 0.03))
            }
            return Self.perturb(base,
                                sigma: max(0.05, noise * 2))
        default:
            return Self.perturb(base,
                                sigma: max(0.05, noise * 2))
        }
    }

    /// REFERMER : contracter le polygone vers son
    /// centre, de la foulée choisie par la machine,
    /// plus un bruit fin pour varier les appuis.
    static func closedIn(_ poly: [CGPoint],
                         stride: Double,
                         noise: Double) -> [CGPoint] {
        let c = centroid(poly)
        let f = 1 - stride * Double.random(in: 0.7...1.3)
        let shrunk = poly.map {
            CGPoint(x: c.x + ($0.x - c.x) * f,
                    y: c.y + ($0.y - c.y) * f)
        }
        return perturb(shrunk, sigma: noise, fineOnly: true)
    }

    /// OUVRIR LE CADRE : élargir depuis le centre, de
    /// la foulée choisie — tous les côtés, un axe, ou
    /// UN seul côté : la machine choisit où ça
    /// coince (sa définition du −1, 2026-10-24).
    static func opened(_ poly: [CGPoint],
                       stride: Double,
                       noise: Double) -> [CGPoint] {
        let c = centroid(poly)
        let roll = Double.random(in: 0..<1)
        var out = poly
        if roll < 0.35 {
            out = poly.map {
                CGPoint(
                    x: c.x + ($0.x - c.x) * (1 + stride),
                    y: c.y + ($0.y - c.y) * (1 + stride))
            }
        } else if roll < 0.60 {
            out = poly.map {
                CGPoint(
                    x: c.x + ($0.x - c.x) * (1 + stride),
                    y: $0.y)
            }
        } else if roll < 0.75 {
            out = poly.map {
                CGPoint(
                    x: $0.x,
                    y: c.y + ($0.y - c.y) * (1 + stride))
            }
        } else {
            let side = Int.random(in: 0..<4)
            out = poly.map { pt in
                var q = pt
                switch side {
                case 0:
                    if pt.x < c.x {
                        q.x = c.x + (pt.x - c.x)
                            * (1 + stride)
                    }
                case 1:
                    if pt.x > c.x {
                        q.x = c.x + (pt.x - c.x)
                            * (1 + stride)
                    }
                case 2:
                    if pt.y < c.y {
                        q.y = c.y + (pt.y - c.y)
                            * (1 + stride)
                    }
                default:
                    if pt.y > c.y {
                        q.y = c.y + (pt.y - c.y)
                            * (1 + stride)
                    }
                }
                return q
            }
        }
        return perturb(out, sigma: noise, fineOnly: true)
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
