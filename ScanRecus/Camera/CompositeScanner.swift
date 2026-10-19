import AVFoundation
import Vision
import CoreImage
import Foundation
import Observation
import simd

// MARK: - Moteur de scan composite (ÉTAPE 1 : le scan seul)

/// Nouvelle approche (2026-10-19, demandée par Grégoire) : on règle le
/// SCAN avant toute extraction. La logique de flux (ScanFlow) est
/// désactivée ; les modules (Models, ReceiptParser…) sont conservés.
///
/// Déroulement :
/// 1. RECHERCHE — un quadrilatère de reçu est détecté (Vision) ; quand
///    il bouge PEU (les mains tremblent toujours un peu) pendant
///    ~0,4 s, le scan démarre tout seul.
/// 2. CAPTURE — fenêtre fixe de 2 secondes. La première image devient
///    la référence ; chaque image suivante est enregistrée sur elle
///    par HOMOGRAPHIE (le reçu est un plan : la transformation entre
///    deux vues est exacte), déformée dans le plan du reçu et fusionnée
///    par tuiles — pour chaque tuile on garde la version la plus nette.
///    Le reçu n'a PAS besoin d'être montré au complet : le composite
///    grandit au-delà de la première vue quand on le déplace (pan).
///    Ce qui n'est jamais montré n'existe pas dans le scan.
/// 3. FIGEAGE — à 2 s, le flux caméra coupe à l'écran (la vue
///    bascule sur le composite ; la session reste en marche)
///    et le composite est redressé (correction de perspective) puis
///    tourné pour que les caractères soient à l'endroit (mini-OCR
///    d'orientation seulement — aucune extraction à cette étape).
///
/// Le composite vit uniquement en RAM (CIImage) : aucune image de reçu
/// n'est écrite sur le disque, comme exigé.
///
/// CONVENTIONS — le format exact de `warpTransform` de Vision
/// (direction, pixels vs normalisé, transposition, retournement Y)
/// n'est pas documenté assez clairement pour coder à l'aveugle sans
/// filet. Le moteur se CALIBRE donc tout seul au début de chaque scan :
/// quand les quadrilatères complets du reçu sont visibles dans la
/// référence ET dans une nouvelle image avec un déplacement suffisant,
/// une homographie « maison » est calculée par correspondances de coins
/// (DLT — maths déterministes, conventions connues) et sert de juge :
/// parmi 16 interprétations candidates de la matrice de Vision, celle
/// qui reproduit le juge est verrouillée — PROVISOIREMENT.
///
/// Une sonde de validation (Python, voir Tests/validate_math.py) a
/// montré qu'à petit déplacement, une convention étrangère peut
/// coïncider sur les 4 coins et passer le seuil : le verrouillage est
/// donc devenu provisoire. Aucune fusion ne peut utiliser la recette
/// tant qu'une image ultérieure, prise d'un point de vue nettement
/// différent (déplacement ≥ 0,07), ne l'a pas CONFIRMÉE contre un
/// nouveau juge ; si la confirmation échoue, la recette est jetée et
/// rien de faux n'a été fusionné. Garde de déplacement et seuils
/// resserrés en conséquence (0,07 ; RMS < 15 px ; contrôle DLT de
/// validation à 30 px) — protocole validé en Python le 2026-10-19
/// (11/11 tests, y compris la reproduction de l'attaque).
///
/// Tant que le calibrage n'est pas confirmé, seule la référence
/// compose le scan — un reçu tenu parfaitement immobile donne donc
/// un scan à une image, ce qui est le résultat correct de toute façon.
@Observable
final class CompositeScanner: NSObject,
                              AVCaptureVideoDataOutputSampleBufferDelegate,
                              @unchecked Sendable {

    enum State: Equatable {
        case searching   // en attente d'un quadrilatère stable
        case capturing   // fenêtre de 2 s en cours
        case done        // composite figé, affiché
    }

    // MARK: Publié (thread principal)

    private(set) var state: State = .searching
    private(set) var statusText = "Présentez un reçu à la caméra…"
    /// Quadrilatère courant (coordonnées normalisées Vision, origine
    /// bas-gauche, ordre TL, TR, BR, BL) pour l'overlay.
    private(set) var quad: [CGPoint]?
    /// Avancement de la fenêtre de capture (0…1).
    private(set) var progress: Double = 0
    /// Remplissage du rectangle englobant du composite (0…100).
    private(set) var fillPercent: Int = 0
    private(set) var filledTiles: Int = 0
    /// Aperçu vivant du composite pendant la capture.
    private(set) var livePreview: CGImage?
    /// Le scan final : redressé, caractères à l'endroit, AMÉLIORÉ
    /// automatiquement (voir enhanceDocument).
    private(set) var finalImage: CGImage?
    /// Le même scan AVANT amélioration, pour comparaison (bascule
    /// dans la vue) — sert à juger si l'amélioration aide ou nuit.
    private(set) var rawFinalImage: CGImage?
    /// Statistiques de diagnostic (temps par étape, compteurs).
    private(set) var statsText = ""

    // MARK: Réglages

    private let processInterval: CFTimeInterval = 0.12  // ~8 images/s max
    private let captureDuration: CFTimeInterval = 2.0
    private let smallWidth: CGFloat = 640               // enregistrement
    private let stableThreshold: CGFloat = 0.03         // mouvement max (normalisé, quadrilatère lissé)
    private let stableFramesNeeded = 3                  // ~0,4 s à 8 img/s
    private let quadSmoothing: CGFloat = 0.4            // lissage exponentiel anti-bruit du détecteur
    private let tileCols = 24
    private let tileRows = 14
    private let sharpRenderScale: CGFloat = 1.0 / 6.0
    /// Échelle des seuils exprimés en pixels : ils ont été réglés
    /// à 720p (1280 px de large) ; à plus haute résolution, la même
    /// tolérance physique couvre davantage de pixels.
    private var pxScale: CGFloat { max(1, fullSize.width / 1280) }

    // MARK: État interne (file série du délégué caméra uniquement)

    private var isProcessing = false
    private var lastProcessStart: CFTimeInterval = 0

    private var phase: State = .searching
    private var smoothedQuad: [CGPoint]?   // quadrilatère lissé (normalisé, [TL, TR, BR, BL])
    private var stableCount = 0

    private var captureStart: CFTimeInterval = 0
    private var fullSize = CGSize.zero
    private var smallSize = CGSize.zero

    private var refSmall: CIImage?         // référence réduite (enregistrement)
    private var refQuadNorm: [CGPoint]?    // quadrilatère de la référence
    private var canvasExtent = CGRect.zero
    private var composite: CIImage?        // le composite, coordonnées canvas
    private var tileSharpness: [Float] = []
    private var tileFilled: [Bool] = []

    private var lastSmall: CIImage?        // dernière image acceptée (chaînage)
    private var lastHSmall = matrix_identity_float3x3

    /// Recette de conversion de la matrice Vision, verrouillée par calibrage.
    private struct Recipe {
        var base: Int          // 0 = W, 1 = W⁻¹, 2 = Wᵀ, 3 = (W⁻¹)ᵀ
        var normalized: Bool   // la matrice travaille en coordonnées 0…1
        var flipped: Bool      // retournement Y à conjuguer
        var label: String {
            let b = ["W", "W⁻¹", "Wᵀ", "(W⁻¹)ᵀ"][base]
            return b + (normalized ? ", normalisé" : ", pixels")
                + (flipped ? ", Y inversé" : "")
        }
    }
    private var recipe: Recipe?
    /// Vrai seulement après confirmation du verrouillage provisoire
    /// sur une image ultérieure (voir confirm()).
    private var recipeConfirmed = false

    /// Informations du figeage (taille du scan final + résumé de
    /// l'amélioration), ajoutées aux statistiques par buildStats().
    private var finishInfo: String?

    // Statistiques
    private var framesSeen = 0
    private var lastDetectedCount = 0
    private var framesFused = 0
    private var framesChained = 0
    private var registrationsFailed = 0
    private var validationsFailed = 0
    private var calibrationAttempts = 0
    private var calibrationRejections = 0
    private var regTimeTotal: Double = 0
    private var regCount = 0
    private var fuseTimeTotal: Double = 0
    private var fuseCount = 0
    private var lastPreviewTime: CFTimeInterval = 0

    private let ciContext = CIContext()
    private let graySpace = CGColorSpaceCreateDeviceGray()

    // MARK: - Réinitialisation

    /// Repart à zéro (bouton « Nouveau scan »).
    func reset() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.phase = .searching
            self.smoothedQuad = nil
            self.stableCount = 0
            self.captureStart = 0
            self.refSmall = nil
            self.refQuadNorm = nil
            self.composite = nil
            self.tileSharpness = []
            self.tileFilled = []
            self.lastSmall = nil
            self.lastHSmall = matrix_identity_float3x3
            self.recipe = nil
            self.recipeConfirmed = false
            self.framesSeen = 0
            self.framesFused = 0
            self.framesChained = 0
            self.registrationsFailed = 0
            self.validationsFailed = 0
            self.calibrationAttempts = 0
            self.calibrationRejections = 0
            self.regTimeTotal = 0
            self.regCount = 0
            self.fuseTimeTotal = 0
            self.fuseCount = 0
            self.state = .searching
            self.statusText = "Présentez un reçu à la caméra…"
            self.quad = nil
            self.progress = 0
            self.fillPercent = 0
            self.filledTiles = 0
            self.livePreview = nil
            self.finalImage = nil
            self.rawFinalImage = nil
            self.finishInfo = nil
            self.statsText = ""
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = CFAbsoluteTimeGetCurrent()
        guard !isProcessing, now - lastProcessStart >= processInterval
        else { return }
        isProcessing = true
        lastProcessStart = now
        defer { isProcessing = false }

        guard phase != .done,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        if fullSize == .zero {
            fullSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                              height: CVPixelBufferGetHeight(pixelBuffer))
            let k = smallWidth / fullSize.width
            smallSize = CGSize(width: smallWidth,
                               height: (fullSize.height * k).rounded())
        }
        framesSeen += 1

        let quadNorm = detectQuad(in: pixelBuffer)
        let frameFull = CIImage(cvPixelBuffer: pixelBuffer)

        switch phase {
        case .searching:
            updateStability(quadNorm: quadNorm, frame: frameFull)
        case .capturing:
            let elapsed = now - captureStart
            if elapsed >= captureDuration {
                finish()
            } else {
                captureFrame(frameFull: frameFull, quadNorm: quadNorm)
                publish(progress: elapsed / captureDuration)
                if now - lastPreviewTime >= 0.35 {
                    lastPreviewTime = now
                    publishLivePreview()
                }
            }
        case .done:
            break
        }

        publish(quad: quadNorm)
    }

    // MARK: - Phase recherche : stabilité

    private func updateStability(quadNorm: [CGPoint]?, frame: CIImage) {
        guard let quadNorm else {
            stableCount = 0
            smoothedQuad = nil
            publish(status: "Présentez un reçu à la caméra…")
            return
        }
        // Lissage exponentiel du quadrilatère suivi : le détecteur
        // Vision fait trembler les coins d'une image à l'autre, même
        // reçu immobile, et une main tremble toujours un peu. Avec le
        // seuil d'origine (0,015, retour à zéro au moindre écart), le
        // compteur n'arrivait jamais à terme à main levée — constat
        // de Grégoire, 2026-10-19. Le mouvement est donc mesuré sur
        // le quadrilatère lissé, et un écart isolé ne coûte qu'un pas.
        let a = quadSmoothing
        if let prev = smoothedQuad {
            let smoothed = (0..<4).map { i in
                CGPoint(x: prev[i].x + a * (quadNorm[i].x - prev[i].x),
                        y: prev[i].y + a * (quadNorm[i].y - prev[i].y))
            }
            let movement = (0..<4).map { i -> CGFloat in
                let dx = smoothed[i].x - prev[i].x
                let dy = smoothed[i].y - prev[i].y
                return (dx * dx + dy * dy).squareRoot()
            }.max() ?? 1
            if movement < stableThreshold {
                stableCount += 1
            } else {
                stableCount = max(0, stableCount - 1)
            }
            smoothedQuad = smoothed
        } else {
            smoothedQuad = quadNorm
            stableCount = 0
        }

        if stableCount >= stableFramesNeeded {
            startCapture(frame: frame, quadNorm: quadNorm)
        } else if stableCount > 0 {
            publish(status: "Reçu détecté — stabilisez… (\(stableCount)/\(stableFramesNeeded))")
        } else {
            publish(status: "Reçu détecté — stabilisez le reçu pour lancer le scan…")
        }
    }

    // MARK: - Démarrage de la capture

    private func startCapture(frame: CIImage, quadNorm: [CGPoint]) {
        phase = .capturing
        captureStart = CFAbsoluteTimeGetCurrent()
        refQuadNorm = quadNorm
        refSmall = materializedSmall(frame)
        lastSmall = refSmall
        lastHSmall = matrix_identity_float3x3

        // Le canvas partage les coordonnées de l'image de référence,
        // élargi de 35 % de chaque côté pour laisser le pan déborder.
        canvasExtent = CGRect(origin: .zero, size: fullSize)
            .insetBy(dx: -0.35 * fullSize.width,
                     dy: -0.35 * fullSize.height)
        tileSharpness = [Float](repeating: 0,
                                count: tileCols * tileRows)
        tileFilled = [Bool](repeating: false,
                            count: tileCols * tileRows)
        composite = CIImage(color: .black).cropped(to: canvasExtent)

        // La référence elle-même est la première tuile du composite.
        fuse(frame: frame, hSmall: matrix_identity_float3x3)
        publish(status: "Scan en cours — bougez lentement pour montrer ce qui compte…")
        publishLivePreview()
    }

    // MARK: - Capture : enregistrement + fusion

    private func captureFrame(frameFull: CIImage, quadNorm: [CGPoint]?) {
        guard let refSmall else { return }
        let frameSmall = smallImage(frameFull)

        // Tant que la recette n'est pas CONFIRMÉE, aucune fusion ne
        // peut l'utiliser : on calibre (verrouillage provisoire),
        // puis on confirme sur une image ultérieure à déplacement franc.
        guard let locked = recipe else {
            if let w = register(scene: refSmall, template: frameSmall) {
                _ = calibrate(w: w, frameQuadNorm: quadNorm)
            } else {
                registrationsFailed += 1
            }
            return
        }
        if !recipeConfirmed {
            guard let w = register(scene: refSmall, template: frameSmall)
            else { registrationsFailed += 1; return }
            switch confirm(w: w, frameQuadNorm: quadNorm) {
            case .confirmed(let h):
                accept(frame: frameFull, hSmall: h, chained: false,
                       quadNorm: quadNorm)
            case .rejected:
                recipe = nil
                calibrationRejections += 1
            case .notApplicable:
                break  // attendre une image plus tranchée
            }
            return
        }

        // Recette confirmée : enregistrement direct sur la référence.
        var hSmall: matrix_float3x3?
        var chained = false
        if let w = register(scene: refSmall, template: frameSmall) {
            hSmall = convert(w, recipe: locked)
        } else {
            registrationsFailed += 1
        }

        // Repli : chaînage sur la dernière image acceptée
        // (utile quand le recouvrement avec la référence faiblit).
        if hSmall == nil, let lastSmall,
           let wStep = register(scene: lastSmall, template: frameSmall) {
            hSmall = lastHSmall * convert(wStep, recipe: locked)
            chained = hSmall != nil
        }

        guard let h = hSmall else { return }
        accept(frame: frameFull, hSmall: h, chained: chained,
               quadNorm: quadNorm)
    }

    /// Validation géométrique (+ juge DLT quand c'est possible), puis
    /// fusion et comptabilité d'une image acceptée.
    private func accept(frame: CIImage, hSmall: matrix_float3x3,
                        chained: Bool, quadNorm: [CGPoint]?) {
        guard validate(hSmall: hSmall, frameQuadNorm: quadNorm) else {
            validationsFailed += 1
            return
        }
        fuse(frame: frame, hSmall: hSmall)
        framesFused += 1
        if chained { framesChained += 1 }
        lastSmall = materializedSmall(frame)
        lastHSmall = hSmall
    }

    /// Enregistrement homographique Vision : matrice brute, ou nil.
    private func register(scene: CIImage, template: CIImage)
    -> matrix_float3x3? {
        let t0 = CFAbsoluteTimeGetCurrent()
        defer {
            regTimeTotal += CFAbsoluteTimeGetCurrent() - t0
            regCount += 1
        }
        let request = VNHomographicImageRegistrationRequest(
            targetedCIImage: template, options: [:])
        let handler = VNImageRequestHandler(ciImage: scene, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first
        else { return nil }
        return observation.warpTransform
    }

    // MARK: - Calibrage de la convention Vision

    /// Cherche, parmi 16 interprétations de la matrice brute, celle qui
    /// reproduit l'homographie « juge » calculée par correspondances de
    /// coins (DLT). Exige : quadrilatères complets des deux côtés et un
    /// déplacement franc (0,07–0,45) pour lever les ambiguïtés (une
    /// matrice identité est compatible avec presque toutes les
    /// conventions, et à petit déplacement une convention étrangère
    /// peut coïncider sur les coins — voir la sonde Python).
    /// Succès = verrouillage PROVISOIRE (retourne vrai) : la recette
    /// ne servira aux fusions qu'après confirmation (voir confirm()).
    private func calibrate(w: matrix_float3x3,
                           frameQuadNorm: [CGPoint]?) -> Bool {
        guard let refQuad = refQuadNorm, let frameQuad = frameQuadNorm,
              isFullQuad(refQuad), isFullQuad(frameQuad)
        else { return false }
        // Déplacement du centre du quadrilatère (coordonnées normalisées,
        // comparables d'une image à l'autre : même caméra).
        let cRef = centroid(refQuad), cNew = centroid(frameQuad)
        let shift = ((cNew.x - cRef.x) * (cNew.x - cRef.x)
            + (cNew.y - cRef.y) * (cNew.y - cRef.y)).squareRoot()
        guard shift > 0.07, shift < 0.45 else { return false }

        let src = frameQuad.map { px($0, fullSize) }
        let dst = refQuad.map { px($0, fullSize) }
        guard let judge = solveHomography(from: src, to: dst)
        else { return false }

        calibrationAttempts += 1
        let testPoints = src + [centroid(src)]
        let judgePoints = testPoints.compactMap { applyH(judge, $0) }
        guard judgePoints.count == testPoints.count else { return false }

        var best: (recipe: Recipe, h: matrix_float3x3, rms: CGFloat)?
        for base in 0..<4 {
            for normalized in [false, true] {
                for flipped in [false, true] {
                    let candidate = Recipe(base: base,
                                           normalized: normalized,
                                           flipped: flipped)
                    let hSmall = convert(w, recipe: candidate)
                    let hFull = toFullRes(hSmall)
                    var sumSq: CGFloat = 0
                    var ok = true
                    for i in testPoints.indices {
                        guard let p = applyH(hFull, testPoints[i])
                        else { ok = false; break }
                        let dx = p.x - judgePoints[i].x
                        let dy = p.y - judgePoints[i].y
                        sumSq += dx * dx + dy * dy
                    }
                    guard ok else { continue }
                    let rms = (sumSq / CGFloat(testPoints.count)).squareRoot()
                    if best == nil || rms < best!.rms {
                        best = (candidate, hSmall, rms)
                    }
                }
            }
        }
        guard let found = best, found.rms < 15 * pxScale else { return false }
        recipe = found.recipe
        recipeConfirmed = false  // provisoire : à confirmer plus tard
        return true
    }

    private enum ConfirmResult {
        /// Recette confirmée ; l'homographie de cette image suit.
        case confirmed(matrix_float3x3)
        /// La recette était fausse : elle a été déverrouillée.
        case rejected
        /// Pas assez d'évidence sur cette image : attendre la suivante.
        case notApplicable
    }

    /// Confirmation du verrouillage provisoire : sur une image prise
    /// d'un point de vue nettement différent de la référence
    /// (déplacement du centre ≥ 0,07, quadrilatères complets), la
    /// conversion de la matrice Vision par la recette provisoire doit
    /// reproduire le juge DLT de CETTE image (RMS < 15 px). Une fausse
    /// recette peut coïncider sur les coins d'UNE position ; en
    /// reproduire une deuxième, indépendante, est d'un autre ordre de
    /// difficulté (validé en Python, Tests/validate_math.py).
    private func confirm(w: matrix_float3x3,
                         frameQuadNorm: [CGPoint]?) -> ConfirmResult {
        guard let recipe, let refQuad = refQuadNorm,
              let frameQuad = frameQuadNorm,
              isFullQuad(refQuad), isFullQuad(frameQuad)
        else { return .notApplicable }
        let cRef = centroid(refQuad), cNew = centroid(frameQuad)
        let shift = ((cNew.x - cRef.x) * (cNew.x - cRef.x)
            + (cNew.y - cRef.y) * (cNew.y - cRef.y)).squareRoot()
        guard shift >= 0.07, shift < 0.45 else { return .notApplicable }
        let src = frameQuad.map { px($0, fullSize) }
        let dst = refQuad.map { px($0, fullSize) }
        guard let judge = solveHomography(from: src, to: dst)
        else { return .notApplicable }
        let hSmall = convert(w, recipe: recipe)
        let hFull = toFullRes(hSmall)
        let testPoints = src + [centroid(src)]
        var sumSq: CGFloat = 0
        for p in testPoints {
            guard let a = applyH(hFull, p), let b = applyH(judge, p)
            else { return .notApplicable }
            sumSq += (a.x - b.x) * (a.x - b.x)
                + (a.y - b.y) * (a.y - b.y)
        }
        let rms = (sumSq / CGFloat(testPoints.count)).squareRoot()
        guard rms < 15 * pxScale else { return .rejected }
        recipeConfirmed = true
        return .confirmed(hSmall)
    }

    /// Convertit une matrice brute de Vision selon la recette :
    /// base (W, W⁻¹, Wᵀ, (W⁻¹)ᵀ) → échelle (pixels ou normalisé)
    /// → conjugaison par retournement Y si requis.
    /// Résultat : homographie image→référence, en pixels « réduits ».
    private func convert(_ w: matrix_float3x3, recipe: Recipe)
    -> matrix_float3x3 {
        let bases: [matrix_float3x3] = [
            w, w.inverse, w.transpose, w.transpose.inverse,
        ]
        var h = bases[recipe.base]
        if recipe.normalized {
            let sw = Float(smallSize.width), sh = Float(smallSize.height)
            let s = matrix_float3x3(
                SIMD3<Float>(1 / sw, 0, 0),
                SIMD3<Float>(0, 1 / sh, 0),
                SIMD3<Float>(0, 0, 1))
            let sInv = matrix_float3x3(
                SIMD3<Float>(sw, 0, 0),
                SIMD3<Float>(0, sh, 0),
                SIMD3<Float>(0, 0, 1))
            h = sInv * h * s
        }
        if recipe.flipped {
            let fh = Float(smallSize.height)
            let f = matrix_float3x3(
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(0, -1, fh),
                SIMD3<Float>(0, 0, 1))
            h = f * h * f  // F est sa propre inverse
        }
        return h
    }

    /// Homographie réduite → pleine résolution (même origine, échelle k).
    private func toFullRes(_ hSmall: matrix_float3x3) -> matrix_float3x3 {
        let k = Float(fullSize.width / smallSize.width)
        let d = matrix_float3x3(
            SIMD3<Float>(k, 0, 0),
            SIMD3<Float>(0, k, 0),
            SIMD3<Float>(0, 0, 1))
        return d * hSmall * d.inverse
    }

    /// Validation d'une homographie candidate (pleine résolution) :
    /// coins finis, quadrilatère convexe non retourné, échelle et
    /// position plausibles ; si les deux quadrilatères complets sont
    /// connus, accord avec le juge DLT.
    private func validate(hSmall: matrix_float3x3,
                          frameQuadNorm: [CGPoint]?) -> Bool {
        let h = toFullRes(hSmall)
        let w = fullSize.width, ht = fullSize.height
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0),
                       CGPoint(x: w, y: ht), CGPoint(x: 0, y: ht)]
        var mapped: [CGPoint] = []
        for c in corners {
            guard let p = applyH(h, c), p.x.isFinite, p.y.isFinite
            else { return false }
            mapped.append(p)
        }
        // Convexité + orientation conservée (produits vectoriels de
        // même signe, positifs pour un ordre BL→BR→TR→TL en Y montant).
        var crosses: [CGFloat] = []
        for i in 0..<4 {
            let a = mapped[i], b = mapped[(i + 1) % 4], c = mapped[(i + 2) % 4]
            crosses.append((b.x - a.x) * (c.y - b.y)
                - (b.y - a.y) * (c.x - b.x))
        }
        guard crosses.allSatisfy({ $0 > 0 }) else { return false }
        // Aire plausible par rapport à l'image source.
        let area = abs(shoelace(mapped))
        let srcArea = w * ht
        guard area > 0.08 * srcArea, area < 10 * srcArea else { return false }
        // Centre dans le canvas (avec marge).
        let c = centroid(mapped)
        let bounds = canvasExtent.insetBy(dx: -0.4 * canvasExtent.width,
                                          dy: -0.4 * canvasExtent.height)
        guard bounds.contains(c) else { return false }
        // Juge DLT, quand les quadrilatères complets sont disponibles.
        if let refQuad = refQuadNorm, let frameQuad = frameQuadNorm,
           isFullQuad(refQuad), isFullQuad(frameQuad) {
            let src = frameQuad.map { px($0, fullSize) }
            let dst = refQuad.map { px($0, fullSize) }
            if let judge = solveHomography(from: src, to: dst) {
                var sumSq: CGFloat = 0
                for p in src {
                    guard let a = applyH(h, p), let b = applyH(judge, p)
                    else { return false }
                    sumSq += (a.x - b.x) * (a.x - b.x)
                        + (a.y - b.y) * (a.y - b.y)
                }
                let rms = (sumSq / CGFloat(src.count)).squareRoot()
                guard rms < 30 * pxScale else { return false }
            }
        }
        return true
    }

    // MARK: - Fusion par tuiles

    /// Déforme l'image dans le plan du reçu (homographie pleine
    /// résolution) et fusionne : chaque tuile du canvas est remplacée
    /// si la nouvelle vue la couvre et est plus nette que le contenu
    /// actuel (ou si la tuile est encore vide).
    private func fuse(frame: CIImage, hSmall: matrix_float3x3) {
        guard let composite else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        defer {
            fuseTimeTotal += CFAbsoluteTimeGetCurrent() - t0
            fuseCount += 1
        }
        let hFull = toFullRes(hSmall)
        let w = fullSize.width, ht = fullSize.height
        guard let mBL = applyH(hFull, CGPoint(x: 0, y: 0)),
              let mBR = applyH(hFull, CGPoint(x: w, y: 0)),
              let mTR = applyH(hFull, CGPoint(x: w, y: ht)),
              let mTL = applyH(hFull, CGPoint(x: 0, y: ht)),
              let warp = CIFilter(name: "CIPerspectiveTransform")
        else { return }
        warp.setValue(frame, forKey: kCIInputImageKey)
        warp.setValue(CIVector(cgPoint: mTL), forKey: "inputTopLeft")
        warp.setValue(CIVector(cgPoint: mTR), forKey: "inputTopRight")
        warp.setValue(CIVector(cgPoint: mBR), forKey: "inputBottomRight")
        warp.setValue(CIVector(cgPoint: mBL), forKey: "inputBottomLeft")
        guard let warpedRaw = warp.outputImage else { return }
        let warped = warpedRaw.cropped(to: canvasExtent)

        // Netteté par tuile, mesurée sur un rendu gris réduit du
        // résultat déformé (variance du Laplacien).
        let bw = max(8, Int(canvasExtent.width * sharpRenderScale))
        let bh = max(8, Int(canvasExtent.height * sharpRenderScale))
        var pixels = [UInt8](repeating: 0, count: bw * bh)
        pixels.withUnsafeMutableBytes { raw in
            ciContext.render(warped, toBitmap: raw.baseAddress!,
                             rowBytes: bw, bounds: canvasExtent,
                             format: .L8, colorSpace: graySpace)
        }

        let hInv = hFull.inverse
        let tw = canvasExtent.width / CGFloat(tileCols)
        let th = canvasExtent.height / CGFloat(tileRows)
        var mask = [UInt8](repeating: 0, count: tileCols * tileRows)
        var changed = false

        for row in 0..<tileRows {
            for col in 0..<tileCols {
                let idx = row * tileCols + col
                let center = CGPoint(
                    x: canvasExtent.minX + (CGFloat(col) + 0.5) * tw,
                    y: canvasExtent.minY + (CGFloat(row) + 0.5) * th)
                // La tuile est-elle couverte par cette vue ?
                // (centre ramené dans l'image source, avec marge)
                guard let src = applyH(hInv, center),
                      src.x > 0.03 * w, src.x < 0.97 * w,
                      src.y > 0.03 * ht, src.y < 0.97 * ht
                else { continue }
                let sharp = tileSharpness(pixels, bw: bw, bh: bh,
                                          col: col, row: row)
                let stored = tileSharpness[idx]
                let shouldUpdate = !tileFilled[idx]
                    || (sharp > stored * 1.10 && sharp > stored + 2)
                if shouldUpdate {
                    // Le tampon du masque est rangé ligne du haut
                    // d'abord (convention CGImage).
                    mask[(tileRows - 1 - row) * tileCols + col] = 255
                    tileSharpness[idx] = max(stored, sharp)
                    tileFilled[idx] = true
                    changed = true
                }
            }
        }
        guard changed else { return }

        // Masque : tuiles → image floue (plumes douces entre tuiles),
        // multiplié par l'alpha de l'image déformée pour ne jamais
        // peindre en noir les bords extérieurs au quadrilatère.
        guard let maskCG = makeGrayImage(mask, width: tileCols,
                                         height: tileRows)
        else { return }
        var maskCI = CIImage(cgImage: maskCG).transformed(by:
            CGAffineTransform(a: tw, b: 0, c: 0, d: th,
                              tx: canvasExtent.minX,
                              ty: canvasExtent.minY))
        maskCI = maskCI.clampedToExtent()
            .applyingFilter("CIGaussianBlur",
                            parameters: ["inputRadius": 30])
            .cropped(to: canvasExtent)
        let alpha = warped.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ]).cropped(to: canvasExtent)
        guard let multiply = CIFilter(name: "CIMultiplyBlendMode"),
              let blend = CIFilter(name: "CIBlendWithMask")
        else { return }
        multiply.setValue(maskCI, forKey: kCIInputImageKey)
        multiply.setValue(alpha, forKey: kCIInputBackgroundImageKey)
        guard let combinedMask = multiply.outputImage else { return }
        blend.setValue(warped, forKey: kCIInputImageKey)
        blend.setValue(composite, forKey: kCIInputBackgroundImageKey)
        blend.setValue(combinedMask, forKey: kCIInputMaskImageKey)
        guard let out = blend.outputImage?.cropped(to: canvasExtent),
              let cg = ciContext.createCGImage(out, from: canvasExtent)
        else { return }
        // Matérialiser : sinon le graphe CI grandit à chaque image et
        // chaque rendu réévalue toute la chaîne.
        self.composite = CIImage(cgImage: cg).transformed(by:
            CGAffineTransform(translationX: canvasExtent.minX,
                              y: canvasExtent.minY))
        updateFillStats()
    }

    /// Variance du Laplacien dans la portion du tampon gris
    /// correspondant à une tuile (rangée 0 = bas du canvas,
    /// coordonnées CoreImage).
    private func tileSharpness(_ buf: [UInt8], bw: Int, bh: Int,
                               col: Int, row: Int) -> Float {
        let tw = CGFloat(bw) / CGFloat(tileCols)
        let th = CGFloat(bh) / CGFloat(tileRows)
        let x0 = max(Int(CGFloat(col) * tw) + 1, 1)
        let x1 = min(Int(CGFloat(col + 1) * tw) - 1, bw - 2)
        let y0 = max(Int(CGFloat(row) * th) + 1, 1)
        let y1 = min(Int(CGFloat(row + 1) * th) - 1, bh - 2)
        guard x1 > x0, y1 > y0 else { return 0 }
        var sum = 0.0, sumSq = 0.0, n = 0.0
        for y in y0...y1 {
            let r = y * bw
            for x in x0...x1 {
                let c = Int(buf[r + x])
                let lap = 4 * c - Int(buf[r + x - 1]) - Int(buf[r + x + 1])
                    - Int(buf[r - bw + x]) - Int(buf[r + bw + x])
                let d = Double(lap)
                sum += d
                sumSq += d * d
                n += 1
            }
        }
        guard n > 0 else { return 0 }
        let mean = sum / n
        return Float(max(0, sumSq / n - mean * mean))
    }

    private func makeGrayImage(_ bytes: [UInt8], width: Int,
                               height: Int) -> CGImage? {
        guard let provider = CGDataProvider(
            data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: width,
                       space: graySpace,
                       bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil,
                       shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    private func updateFillStats() {
        var minC = tileCols, maxC = -1, minR = tileRows, maxR = -1
        var filled = 0
        for row in 0..<tileRows {
            for col in 0..<tileCols where tileFilled[row * tileCols + col] {
                filled += 1
                minC = min(minC, col); maxC = max(maxC, col)
                minR = min(minR, row); maxR = max(maxR, row)
            }
        }
        let boxTiles = maxC >= 0
            ? (maxC - minC + 1) * (maxR - minR + 1) : 0
        let percent = boxTiles > 0 ? filled * 100 / boxTiles : 0
        DispatchQueue.main.async { [weak self] in
            self?.filledTiles = filled
            self?.fillPercent = percent
        }
    }

    // MARK: - Figeage : redressement + orientation

    private func finish() {
        guard let composite, let refQuad = refQuadNorm else { return }
        phase = .done

        // Redressement : le quadrilatère de la référence (coordonnées
        // canvas = coordonnées de l'image de référence) devient un
        // rectangle propre.
        let corners = refQuad.map { px($0, fullSize) }  // TL, TR, BR, BL
        var corrected: CIImage?
        if let filter = CIFilter(name: "CIPerspectiveCorrection") {
            filter.setValue(composite, forKey: kCIInputImageKey)
            filter.setValue(CIVector(cgPoint: corners[0]),
                            forKey: "inputTopLeft")
            filter.setValue(CIVector(cgPoint: corners[1]),
                            forKey: "inputTopRight")
            filter.setValue(CIVector(cgPoint: corners[2]),
                            forKey: "inputBottomRight")
            filter.setValue(CIVector(cgPoint: corners[3]),
                            forKey: "inputBottomLeft")
            corrected = filter.outputImage
        }
        var image = corrected ?? composite
        // Ramener l'origine à (0, 0) pour la suite.
        image = image.transformed(by: CGAffineTransform(
            translationX: -image.extent.minX, y: -image.extent.minY))
        // Orientation : tourner pour que les caractères soient à l'endroit.
        image = upright(image)
        // Amélioration automatique « look scanner » : c'est elle qui
        // est affichée (et qui, à l'étape 2, sera lue par l'OCR) ;
        // la version brute reste publiée à part pour comparaison.
        let rawCG = ciContext.createCGImage(image, from: image.extent)
        let enhanced = enhanceDocument(image)
        let finalCG = ciContext.createCGImage(enhanced.image,
                                              from: enhanced.image.extent)
        finishInfo = "Scan final : \(Int(image.extent.width)) × \(Int(image.extent.height)) px"
            + "\nAmélioration auto : \(enhanced.summary)"

        let stats = buildStats()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.state = .done
            self.statusText = "Scan terminé — voici le composite."
            self.progress = 1
            self.finalImage = finalCG
            self.rawFinalImage = rawCG
            self.livePreview = finalCG
            self.statsText = stats
        }
    }

    /// Choisit, parmi 4 rotations, celle où un OCR rapide reconnaît le
    /// plus de texte avec la meilleure confiance — puis l'applique.
    /// Aucune extraction : seule l'orientation est déterminée.
    private func upright(_ image: CIImage) -> CIImage {
        let targetWidth: CGFloat = 720
        let k = targetWidth / image.extent.width
        let small = image.transformed(
            by: CGAffineTransform(scaleX: k, y: k))
        let orientations: [CGImagePropertyOrientation] =
            [.up, .right, .down, .left]
        var best: CGImagePropertyOrientation = .up
        var bestScore: Float = -1
        for orientation in orientations {
            let rotated = small.oriented(orientation)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.recognitionLanguages = ["fr-FR", "en-US"]
            let handler = VNImageRequestHandler(ciImage: rotated,
                                                options: [:])
            guard (try? handler.perform([request])) != nil
            else { continue }
            var score: Float = 0
            for obs in request.results ?? [] {
                if let candidate = obs.topCandidates(1).first {
                    score += candidate.confidence
                }
            }
            if score > bestScore {
                bestScore = score
                best = orientation
            }
        }
        return image.oriented(best)
    }

    // MARK: - Amélioration automatique (look « scanner »)

    /// Constantes de l'amélioration, affichées dans les statistiques
    /// pour pouvoir les régler d'après les retours de terrain.
    private let enhanceSaturation: CGFloat = 0.35
    private let enhanceSharpness: CGFloat = 0.7

    /// Rend le scan redressé « propre » comme un scanner de
    /// documents, pour l'œil ET pour l'OCR de l'étape 2 :
    /// 1. aplatissement de l'éclairage — division par un fond estimé
    ///    (version très floue de l'image) : le papier devient blanc
    ///    même sous une lumière inégale, ombres et vignettage
    ///    disparaissent ;
    /// 2. niveaux automatiques par percentiles — le blanc devient
    ///    vraiment blanc, l'encre vraiment noire ;
    /// 3. saturation réduite — presque gris, un soupçon de couleur
    ///    (tampons, logos) survit ;
    /// 4. accentuation de la LUMINANCE seulement — caractères plus
    ///    nets, aucun halo coloré.
    /// Aucune étape ne déplace un pixel : la géométrie du scan
    /// redressé est intacte (rien n'est « déformé »).
    private func enhanceDocument(_ image: CIImage)
    -> (image: CIImage, summary: String) {
        let extent = image.extent

        // 1. Fond estimé : l'image elle-même, très floue.
        let background = image.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [
                "inputRadius": max(24, extent.width / 14),
            ])
            .cropped(to: extent)

        // 2. Aplatissement par division. La sémantique exacte de
        // CIDivideBlendMode (qui divise qui) est vérifiée PAR LES
        // DONNÉES : le bon candidat garde le texte sombre (son
        // percentile 2 reste bas) ; le candidat inversé blanchit le
        // texte jusqu'au clip (p2 proche de 1). On garde le plus bas.
        func divided(_ backgroundImage: CIImage,
                     _ foreground: CIImage) -> CIImage? {
            guard let filter = CIFilter(name: "CIDivideBlendMode")
            else { return nil }
            filter.setValue(foreground, forKey: kCIInputImageKey)
            filter.setValue(backgroundImage,
                            forKey: kCIInputBackgroundImageKey)
            return filter.outputImage?.cropped(to: extent)
        }
        var flat = image
        if let a = divided(image, background),
           let b = divided(background, image) {
            let p2a = grayPercentiles(a, [0.02]).first ?? 1
            let p2b = grayPercentiles(b, [0.02]).first ?? 1
            flat = p2a <= p2b ? a : b
        } else if let a = divided(image, background) {
            flat = a
        }

        // 3. Niveaux automatiques : point noir au percentile 2,
        // point blanc au percentile 98 (bornés pour rester sains),
        // appliqués par une matrice de couleur + clamp.
        let levels = grayPercentiles(flat, [0.02, 0.98])
        let bp = min(max(levels.first ?? 0, 0), 0.45)
        let wp = min(max(levels.last ?? 1, bp + 0.25), 1)
        let s = 1 / (wp - bp)
        var leveled = flat.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: s, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: s, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: s, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: -bp * s, y: -bp * s,
                                        z: -bp * s, w: 0),
        ])
        leveled = leveled.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ]).cropped(to: extent)

        // 4. Saturation réduite, puis accentuation de la luminance.
        let desaturated = leveled.applyingFilter(
            "CIColorControls", parameters: [
                "inputSaturation": enhanceSaturation,
            ])
        let sharpened = desaturated.applyingFilter(
            "CISharpenLuminance", parameters: [
                "inputSharpness": enhanceSharpness,
            ]).cropped(to: extent)

        let summary = String(
            format: "fond aplati (division), niveaux noir %.2f / blanc %.2f, saturation 0,35, netteté %.1f",
            bp, wp, enhanceSharpness)
        return (sharpened, summary)
    }

    /// Percentiles de gris d'une image, calculés sur un rendu réduit
    /// (≤ 240 px de grand côté) — un sac de pixels : l'orientation
    /// des rangées n'a aucune importance ici.
    private func grayPercentiles(_ image: CIImage,
                                 _ ps: [Double]) -> [CGFloat] {
        let longest = max(image.extent.width, image.extent.height)
        guard longest > 0 else { return ps.map { _ in 0 } }
        let k = min(1, 240 / longest)
        let small = image.transformed(
            by: CGAffineTransform(scaleX: k, y: k))
        let w = max(1, Int(small.extent.width.rounded()))
        let h = max(1, Int(small.extent.height.rounded()))
        var buf = [UInt8](repeating: 0, count: w * h)
        buf.withUnsafeMutableBytes { raw in
            ciContext.render(small, toBitmap: raw.baseAddress!,
                             rowBytes: w, bounds: small.extent,
                             format: .L8, colorSpace: graySpace)
        }
        var hist = [Int](repeating: 0, count: 256)
        for v in buf { hist[Int(v)] += 1 }
        let total = Double(buf.count)
        return ps.map { p in
            let target = p * total
            var acc = 0.0
            for i in 0..<256 {
                acc += Double(hist[i])
                if acc >= target { return CGFloat(i) / 255 }
            }
            return 1
        }
    }

    // MARK: - Détection du quadrilatère

    /// Le plus grand rectangle plausible = le reçu (même approche que
    /// ScanEngine, seuils élargis : vues partielles et reçu plus petit
    /// dans le champ sont acceptés — la stabilité filtre le bruit).
    private func detectQuad(in pixelBuffer: CVPixelBuffer) -> [CGPoint]? {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.15
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.10
        request.maximumObservations = 6
        request.minimumConfidence = 0.3
        request.quadratureTolerance = 40
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        let results = request.results ?? []
        lastDetectedCount = results.count
        // Choix par AIRE RÉELLE du quadrilatère plutôt que par sa
        // boîte englobante, parmi davantage de candidats : un petit
        // objet rectangulaire proche de la caméra — une montre, vécu
        // le 2026-10-19 — ne doit pas gagner contre le reçu.
        let best = results.max {
            abs(shoelace([$0.topLeft, $0.topRight,
                          $0.bottomRight, $0.bottomLeft]))
                < abs(shoelace([$1.topLeft, $1.topRight,
                                $1.bottomRight, $1.bottomLeft]))
        }
        guard let rect = best else { return nil }
        return [rect.topLeft, rect.topRight, rect.bottomRight, rect.bottomLeft]
    }

    /// Un quadrilatère « complet » : assez grand et ne touchant pas les
    /// bords de l'image (sinon le reçu est probablement tronqué et ses
    /// coins ne sont pas les vrais coins du reçu).
    private func isFullQuad(_ quad: [CGPoint]) -> Bool {
        let xs = quad.map(\.x), ys = quad.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max()
        else { return false }
        let area = (maxX - minX) * (maxY - minY)
        return area > 0.05
            && minX > 0.02 && maxX < 0.98
            && minY > 0.02 && maxY < 0.98
    }

    // MARK: - Petites images

    private func smallImage(_ image: CIImage) -> CIImage {
        let k = smallSize.width / fullSize.width
        return image.transformed(by: CGAffineTransform(scaleX: k, y: k))
    }

    /// Version matérialisée (bitmap) de l'image réduite : un CIImage
    /// adossé au pixel buffer de la caméra ne survit pas au retour du
    /// délégué (le buffer est recyclé).
    private func materializedSmall(_ image: CIImage) -> CIImage? {
        let small = smallImage(image)
        guard let cg = ciContext.createCGImage(small, from: small.extent)
        else { return nil }
        return CIImage(cgImage: cg)
    }

    // MARK: - Publication

    private func publish(status: String? = nil, quad newQuad: [CGPoint]?? = nil,
                         progress newProgress: Double? = nil) {
        let stats = buildStats()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.state = self.phase
            if let status { self.statusText = status }
            if let newQuad { self.quad = newQuad }
            if let newProgress { self.progress = newProgress }
            self.statsText = stats
        }
    }

    private func publishLivePreview() {
        guard let composite,
              let cg = ciContext.createCGImage(composite,
                                               from: canvasExtent)
        else { return }
        DispatchQueue.main.async { [weak self] in
            self?.livePreview = cg
        }
    }

    private func buildStats() -> String {
        let regMs = regCount > 0 ? regTimeTotal * 1000 / Double(regCount) : 0
        let fuseMs = fuseCount > 0
            ? fuseTimeTotal * 1000 / Double(fuseCount) : 0
        let calib: String
        if let r = recipe {
            calib = recipeConfirmed
                ? "verrouillé et confirmé (\(r.label))"
                : "provisoire (\(r.label)) — en attente de confirmation"
        } else {
            calib = "non verrouillé (\(calibrationAttempts) tentative(s), "
                + "\(calibrationRejections) rejet(s) en confirmation)"
        }
        var text = ""
        if fullSize != .zero {
            text += String(format: "Caméra : %.0f × %.0f\n",
                           fullSize.width, fullSize.height)
        }
        text += "Images traitées : \(framesSeen)  •  fusionnées : \(framesFused)"
            + " (dont chaînées : \(framesChained))\n"
            + "Rectangles détectés (dernière image) : \(lastDetectedCount)\n"
            + "Échecs enregistrement : \(registrationsFailed)"
            + "  •  validations rejetées : \(validationsFailed)\n"
            + "Calibrage Vision : \(calib)\n"
            + String(format: "Enregistrement : %.0f ms/img  •  fusion : %.0f ms/img",
                     regMs, fuseMs)
        if let finishInfo {
            text += "\n" + finishInfo
        }
        return text
    }

    // MARK: - Maths (homographies, conventions maison)

    /// Coordonnées normalisées Vision → pixels (origine bas-gauche
    /// des deux côtés : aucun retournement).
    private func px(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: p.x * size.width, y: p.y * size.height)
    }

    private func centroid(_ pts: [CGPoint]) -> CGPoint {
        let n = CGFloat(pts.count)
        return CGPoint(x: pts.map(\.x).reduce(0, +) / n,
                       y: pts.map(\.y).reduce(0, +) / n)
    }

    private func shoelace(_ pts: [CGPoint]) -> CGFloat {
        var sum: CGFloat = 0
        for i in pts.indices {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    /// Applique une homographie (convention : vecteur colonne,
    /// M · (x, y, 1), division perspective). Nil si le point part à
    /// l'infini.
    private func applyH(_ m: matrix_float3x3, _ p: CGPoint) -> CGPoint? {
        let v = m * SIMD3<Float>(Float(p.x), Float(p.y), 1)
        guard v.z != 0, v.x.isFinite, v.y.isFinite, v.z.isFinite
        else { return nil }
        return CGPoint(x: CGFloat(v.x / v.z), y: CGFloat(v.y / v.z))
    }

    /// Homographie par correspondances de 4 points (DLT, h33 = 1,
    /// élimination gaussienne à pivots partiels). Points en pixels,
    /// même ordre des deux côtés ([TL, TR, BR, BL] par ex.).
    private func solveHomography(from src: [CGPoint],
                                 to dst: [CGPoint]) -> matrix_float3x3? {
        guard src.count == 4, dst.count == 4 else { return nil }
        // Inconnues : h11 h12 h13 h21 h22 h23 h31 h32 (h33 = 1).
        var a: [[Double]] = []
        for i in 0..<4 {
            let x = Double(src[i].x), y = Double(src[i].y)
            let u = Double(dst[i].x), v = Double(dst[i].y)
            a.append([-x, -y, -1, 0, 0, 0, u * x, u * y, -u])
            a.append([0, 0, 0, -x, -y, -1, v * x, v * y, -v])
        }
        let n = 8
        for col in 0..<n {
            var pivot = col
            for r in col..<n where abs(a[r][col]) > abs(a[pivot][col]) {
                pivot = r
            }
            guard abs(a[pivot][col]) > 1e-9 else { return nil }
            if pivot != col { a.swapAt(pivot, col) }
            let d = a[col][col]
            for j in col...n { a[col][j] /= d }
            for r in 0..<n where r != col {
                let f = a[r][col]
                if f != 0 {
                    for j in col...n { a[r][j] -= f * a[col][j] }
                }
            }
        }
        let h = (0..<n).map { a[$0][n] }
        return matrix_float3x3(
            SIMD3<Float>(Float(h[0]), Float(h[3]), Float(h[6])),
            SIMD3<Float>(Float(h[1]), Float(h[4]), Float(h[7])),
            SIMD3<Float>(Float(h[2]), Float(h[5]), Float(1)))
    }
}
