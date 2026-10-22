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
/// 1. RECHERCHE — aucun objet n'est suivi : la boîte de sélection
///    a été abandonnée le 2026-10-19 après une série d'échecs
///    (montre, rideau, visage, quadrilatère partiel). Le scan
///    démarre quand l'image ENTIÈRE montre du texte (≥ 5 zones)
///    sur une grande surface claire (le papier) ET que la
///    disposition du texte est stable ~0,4 s.
/// 2. CAPTURE — fenêtre fixe de 0,5 seconde. La première image devient
///    la référence ; chaque image suivante est enregistrée sur elle
///    par HOMOGRAPHIE (le reçu est un plan : la transformation entre
///    deux vues est exacte), déformée dans le plan du reçu et fusionnée
///    par tuiles — pour chaque tuile on garde la version la plus nette.
///    Le reçu n'a PAS besoin d'être montré au complet : le composite
///    grandit au-delà de la première vue quand on le déplace (pan).
///    Ce qui n'est jamais montré n'existe pas dans le scan.
/// 3. FIGEAGE — à 2 s, le flux caméra coupe à l'écran (la vue
///    bascule sur le composite ; la session reste en marche)
///    et le reçu est RECONSTRUIT : localisé dans le composite
///    figé (image fixe et propre — la détection y est bien plus
///    fiable que sur le flux vivant), redressé, puis tourné pour
///    que les caractères soient à l'endroit (mini-OCR
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
        case capturing   // échantillonnage en cours
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
    /// Aperçu vivant du composite pendant la capture.
    private(set) var livePreview: CGImage?
    /// Mode « Générer matériel » (2026-10-21) : finish()
    /// s'arrête à la frame figée — pas de rituel, pas
    /// d'analyse — et la vue coffre la frame dans la banque
    /// d'entraînement (TrainingBank).
    private(set) var bankingMode = false
    /// La frame brute figée du dernier scan (avant tout
    /// redressement), pour la banque de matériel.
    private(set) var frozenRawFrame: CGImage?
    /// Compteur incrémenté à chaque frame figée (la vue s'y
    /// abonne pour coffrer au bon moment).
    private(set) var frozenFrameStamp = 0

    func setBankingMode(_ on: Bool) { bankingMode = on }

    /// Statut posé par la vue (ex. confirmation du coffrage
    /// d'une photo de matériel).
    func showStatus(_ text: String) { statusText = text }
    /// Le scan final : redressé, caractères à l'endroit, AMÉLIORÉ
    /// automatiquement (voir enhanceDocument).
    private(set) var finalImage: CGImage?
    /// Le même scan AVANT amélioration, pour comparaison (bascule
    /// dans la vue) — sert à juger si l'amélioration aide ou nuit.
    private(set) var rawFinalImage: CGImage?
    /// Statistiques de diagnostic (temps par étape, compteurs).
    private(set) var statsText = ""
    /// Lecture du dernier scan figé (OCR + champs extraits) —
    /// affichage seulement, rien n'est sauvegardé.
    private(set) var extraction: ScanExtraction?

    // MARK: Réglages

    private let processInterval: CFTimeInterval = 0.12  // ~8 images/s max
    // Fenêtre d'échantillonnage de la nouvelle méthode : on
    // y note les images et on garde la plus nette (sortie
    // anticipée dès qu'une image se détache nettement).
    private let captureDuration: CFTimeInterval = 1.2
    private let smallWidth: CGFloat = 640               // enregistrement
    private let stableFramesNeeded = 3                  // ~0,4 s à 8 img/s

    // MARK: État interne (file série du délégué caméra uniquement)

    private var isProcessing = false
    private var lastProcessStart: CFTimeInterval = 0

    private var phase: State = .searching
    /// Jeton du scan en cours : posé à chaque capture, changé
    /// à chaque reset — un résultat d'analyse publié après un
    /// « Next scan » est périmé et se reconnaît à son jeton.
    private var scanToken = UUID()
    // Déclencheur « scène entière » : zones de texte de l'image
    // précédente et compteur de stabilité (voir
    // updateSceneStability) — plus aucun suivi d'objet.
    private var prevTextBoxes: [CGRect] = []
    private var sceneStableCount = 0
    private var lastTextCount = 0
    private var lastBrightness: CGFloat = 0

    private var captureStart: CFTimeInterval = 0
    private var fullSize = CGSize.zero
    private var smallSize = CGSize.zero




    /// Informations du figeage (taille du scan final + résumé de
    /// l'amélioration), ajoutées aux statistiques par buildStats().
    private var finishInfo: String?
    private var lastArbiterSummary = ""
    private var lastQuadSummary = ""

    // Statistiques
    private var framesSeen = 0
    private var lastDetectedCount = 0
    /// NOUVELLE MÉTHODE (2026-10-20, demande de Grégoire) :
    /// pendant la fenêtre, chaque frame est notée pour la
    /// netteté de ses caractères ; on ne garde que la
    /// meilleure (sa CIImage retient le buffer caméra).
    /// Ni fusion, ni moyenne, ni composite.
    private var bestSample: CIImage?
    private var bestSharpness: Double = -1
    private var sampledFrames = 0
    private var sampleScores: [Double] = []
    private var earlySharpExit = false
    /// Orientation de détection du texte (reçu présenté DE
    /// CÔTÉ) : la préférée est la dernière à avoir produit
    /// ≥ 5 boîtes ; celle du scan en cours est verrouillée au
    /// déclenchement.
    private var preferredTextOrientation: CGImagePropertyOrientation = .up
    private var scanTextOrientation: CGImagePropertyOrientation = .up
    private var lastPreviewTime: CFTimeInterval = 0

    private let ciContext = CIContext()
    private let graySpace = CGColorSpaceCreateDeviceGray()
    private let rgbSpace = CGColorSpaceCreateDeviceRGB()

    // MARK: - Réinitialisation

    /// Repart à zéro (bouton « Nouveau scan »).
    func reset() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.phase = .searching
            self.prevTextBoxes = []
            self.sceneStableCount = 0
            self.lastTextCount = 0
            self.lastBrightness = 0
            self.captureStart = 0
            self.scanTextOrientation = .up
            self.bestSample = nil
            self.bestSharpness = -1
            self.sampledFrames = 0
            self.sampleScores = []
            self.earlySharpExit = false
            self.framesSeen = 0
            self.scanToken = UUID()
            self.state = .searching
            self.statusText = "Présentez un reçu à la caméra…"
            self.quad = nil
            self.progress = 0
            self.livePreview = nil
            self.finalImage = nil
            self.rawFinalImage = nil
            self.finishInfo = nil
            self.extraction = nil
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

        let frameSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                               height: CVPixelBufferGetHeight(pixelBuffer))
        if fullSize == .zero {
            adoptFrameSize(frameSize)
        } else if frameSize != fullSize {
            // La taille des images a changé en cours de route : le
            // format haute résolution de la caméra est appliqué juste
            // après le démarrage de la session. En recherche, on
            // réadopte la nouvelle géométrie ; en capture, on ignore
            // l'image (le canvas ne correspondrait plus).
            guard phase == .searching else { return }
            adoptFrameSize(frameSize)
            prevTextBoxes = []
            sceneStableCount = 0
        }
        framesSeen += 1

        let frameFull = CIImage(cvPixelBuffer: pixelBuffer)

        switch phase {
        case .searching:
            updateSceneStability(pixelBuffer: pixelBuffer,
                                 frame: frameFull)
        case .capturing:
            // NOUVELLE MÉTHODE : échantillonner et noter. La
            // meilleure frame est copiée tout de suite (le
            // buffer caméra ne survit pas au retour du
            // délégué) ; dès qu'une frame est nettement plus
            // nette que les autres, on la prend et on arrête.
            let elapsed = now - captureStart
            let boxes = scanTextOrientation == .up
                ? detectTextBoxes(in: pixelBuffer)
                : detectTextBoxes(in: frameFull,
                                  orientation: scanTextOrientation)
            let score = sharpnessScore(frame: frameFull, boxes: boxes)
            sampledFrames += 1
            sampleScores.append(score)
            if score > bestSharpness {
                bestSharpness = score
                // La CIImage retient son buffer caméra : aucun
                // rendu pleine résolution à chaque nouvel
                // échantillon gagnant (coûteux — build 53).
                // L'ancienne image de référence vivait déjà
                // exactement ainsi.
                bestSample = frameFull
            }
            publish(progress: elapsed / captureDuration)
            if now - lastPreviewTime >= 0.35 {
                lastPreviewTime = now
                publishLivePreview()
            }
            if elapsed >= captureDuration || isClearlySharp(score) {
                earlySharpExit = elapsed < captureDuration
                finish()
            }
        case .done:
            break
        }

        // Plus aucune boîte de sélection à l'écran (choix de
        // Grégoire, 2026-10-19) : le reçu sera localisé APRÈS la
        // capture, dans le composite figé.
        publish(quad: nil)
    }

    // MARK: - Géométrie des images livrées

    /// (Ré)adopte la géométrie des images de la caméra.
    private func adoptFrameSize(_ size: CGSize) {
        fullSize = size
        let k = smallWidth / fullSize.width
        smallSize = CGSize(width: smallWidth,
                           height: (fullSize.height * k).rounded())
    }

    // MARK: - Phase recherche : papier, texte, stabilité de la scène

    /// Déclencheur « scène entière » (2026-10-19, proposé par
    /// Grégoire après la série d'échecs de la boîte de sélection :
    /// montre, rideau, visage, quadrilatère partiel) : on ne suit
    /// plus AUCUN objet. Le scan démarre quand, dans l'image
    /// ENTIÈRE :
    /// (a) le détecteur de texte voit assez de zones de texte
    ///     (≥ 5) — un visage ou un plafond n'en ont pas ;
    /// (b) une grande surface claire est présente (le papier :
    ///     percentile 65 de gris ≥ 0,52) ;
    /// (c) la DISPOSITION des zones de texte est stable d'une
    ///     image à l'autre (≥ 70 % appariées à moins de 0,03,
    ///     déplacement moyen < 0,02) pendant 3 images de suite —
    ///     la scène est fixe, on capte.
    private func updateSceneStability(pixelBuffer: CVPixelBuffer,
                                      frame: CIImage) {
        let boxes = detectEvidenceBoxes(pixelBuffer: pixelBuffer,
                                        frame: frame)
        lastTextCount = boxes.count
        lastBrightness = grayPercentiles(frame, [0.65]).first ?? 0
        let evidence = boxes.count >= 5 && lastBrightness >= 0.52

        var layoutStable = false
        if evidence, !prevTextBoxes.isEmpty {
            var matched = 0
            var dispSum: CGFloat = 0
            for box in boxes {
                var best = CGFloat.greatestFiniteMagnitude
                for prev in prevTextBoxes {
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
        prevTextBoxes = boxes

        if evidence && layoutStable {
            sceneStableCount += 1
        } else if evidence {
            sceneStableCount = max(0, sceneStableCount - 1)
        } else {
            sceneStableCount = 0
        }

        if sceneStableCount >= stableFramesNeeded {
            startCapture()
        } else if !evidence {
            publish(status: boxes.isEmpty
                    ? "Présentez un reçu à la caméra…"
                    : "Du texte est visible, mais pas assez de papier blanc — approchez le reçu…")
        } else if sceneStableCount > 0 {
            publish(status: "Papier et texte détectés — stabilisez… (\(sceneStableCount)/\(stableFramesNeeded))")
        } else {
            publish(status: "Papier et texte détectés — stabilisez l'appareil pour lancer le scan…")
        }
    }

    // MARK: - Démarrage de la capture

    private func startCapture() {
        phase = .capturing
        scanToken = UUID()
        captureStart = CFAbsoluteTimeGetCurrent()
        scanTextOrientation = preferredTextOrientation
        bestSample = nil
        bestSharpness = -1
        sampledFrames = 0
        sampleScores = []
        earlySharpExit = false
        publish(status: "Scan en cours — je cherche l'image la plus nette, tenez le reçu tranquille…")
    }

    // MARK: - Détections

    /// Tous les rectangles détectés par Vision dans l'image
    /// fournie au handler (coordonnées normalisées, [TL, TR, BR, BL]).
    private func detectRectangles(handler: VNImageRequestHandler)
    -> [[CGPoint]] {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.15
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.10
        request.maximumObservations = 6
        request.minimumConfidence = 0.3
        request.quadratureTolerance = 40
        guard (try? handler.perform([request])) != nil else { return [] }
        let results = request.results ?? []
        lastDetectedCount = results.count
        return results.map {
            [$0.topLeft, $0.topRight, $0.bottomRight, $0.bottomLeft]
        }
    }

    /// Zones de texte détectées par Vision (boîtes normalisées) —
    /// détection seule, aucune lecture.
    private func detectTextBoxes(in pixelBuffer: CVPixelBuffer)
    -> [CGRect] {
        let request = VNDetectTextRectanglesRequest()
        request.reportCharacterBoxes = false
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? []).map { $0.boundingBox }
    }

    /// Boîtes de texte d'une image pivotée de 90°, ramenées
    /// dans l'espace normalisé de l'image d'origine (les axes
    /// s'échangent — formules de transposition EXIF).
    private func detectTextBoxes(
        in image: CIImage,
        orientation: CGImagePropertyOrientation) -> [CGRect] {
        let request = VNDetectTextRectanglesRequest()
        request.reportCharacterBoxes = false
        let handler = VNImageRequestHandler(
            ciImage: image.oriented(orientation), options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? []).map {
            rawSpaceBox($0.boundingBox, orientation: orientation)
        }
    }

    /// Boîte normalisée lue dans une image pivotée → boîte
    /// normalisée de l'image d'origine (.left/.right).
    private func rawSpaceBox(
        _ box: CGRect,
        orientation: CGImagePropertyOrientation) -> CGRect {
        switch orientation {
        case .right:
            return CGRect(x: 1 - box.maxY, y: box.minX,
                          width: box.height, height: box.width)
        case .left:
            return CGRect(x: box.minY, y: 1 - box.maxX,
                          width: box.height, height: box.width)
        default:
            return box
        }
    }

    /// Détection pour la preuve et la stabilité : l'orientation
    /// préférée d'abord, puis les autres ; la première à
    /// ≥ 5 boîtes gagne et devient la préférée. Un reçu
    /// présenté DE CÔTÉ (demande de Grégoire, 2026-10-20 : il
    /// occupe alors bien plus du cadre — de meilleurs scans)
    /// rend le détecteur presque aveugle sur l'image telle
    /// quelle : il lui faut l'image pivotée.
    private func detectEvidenceBoxes(pixelBuffer: CVPixelBuffer,
                                     frame: CIImage) -> [CGRect] {
        var order: [CGImagePropertyOrientation] =
            [preferredTextOrientation]
        for o in [CGImagePropertyOrientation.up, .right, .left]
        where o != preferredTextOrientation {
            order.append(o)
        }
        var best: [CGRect] = []
        for o in order {
            let boxes = o == .up
                ? detectTextBoxes(in: pixelBuffer)
                : detectTextBoxes(in: frame, orientation: o)
            if boxes.count > best.count { best = boxes }
            if boxes.count >= 5 {
                preferredTextOrientation = o
                return boxes
            }
        }
        return best
    }

    /// Même chose, sur une image CoreImage (le composite figé).
    private func detectTextBoxes(in image: CIImage) -> [CGRect] {
        let request = VNDetectTextRectanglesRequest()
        request.reportCharacterBoxes = false
        let handler = VNImageRequestHandler(ciImage: image,
                                            options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? []).map { $0.boundingBox }
    }

    /// Meilleure détection de texte d'une image, quel que soit
    /// le sens de présentation : le sens verrouillé du scan
    /// d'abord, puis les autres ; les boîtes sont toujours
    /// ramenées dans l'espace de l'image d'origine. Depuis que
    /// les reçus se présentent DE CÔTÉ, la détection telle
    /// quelle est presque aveugle sur l'image brute — et la
    /// localisation du reçu repose entièrement sur ces boîtes
    /// (journal du 2026-10-20 : 1-2 zones détectées, le critère
    /// du papier éliminé d'office, découpes de 15 × 101 px).
    private func bestTextBoxes(in image: CIImage,
                               straightened: Bool = false)
    -> [CGRect] {
        // Image déjà redressée à la verticale : le sens
        // naturel (.up) d'abord — le sens pivoté verrouillé
        // ne doit pas rafler la mise avec des boîtes lues
        // dans le mauvais espace.
        var order: [CGImagePropertyOrientation] = straightened
            ? [.up, scanTextOrientation] : [scanTextOrientation]
        for o in [CGImagePropertyOrientation.up, .right, .left]
        where o != scanTextOrientation && !order.contains(o) {
            order.append(o)
        }
        var best: [CGRect] = []
        for o in order {
            let boxes = o == .up
                ? detectTextBoxes(in: image)
                : detectTextBoxes(in: image, orientation: o)
            if boxes.count > best.count { best = boxes }
            if boxes.count >= 5 { break }
        }
        return best
    }

    /// Les preuves « papier + texte » pour un quadrilatère d'une
    /// image : intérieur clair ET uniforme (le papier — voir le
    /// percentile 10 plus bas) et zones de texte dedans (≥ 3, ou
    /// une grande couvrant ≥ 25 % de l'objet). Sert à la
    /// RECONSTRUCTION (choisir le rectangle du reçu dans le
    /// composite figé).
    private func paperEvidence(frame: CIImage, quad: [CGPoint],
                               textBoxes: [CGRect])
    -> (ok: Bool, textCount: Int) {
        let inner = innerQuad(quad)
        let bright = meanBrightness(frame, quad: inner)
        // Uniformité : même le percentile 10 de l'intérieur doit
        // être clair. Le papier est uniformément blanc (le texte
        // couvre peu de surface) ; cheveux, tissus et peaux ont
        // des zones sombres partout — un rectangle de cheveux
        // gris, « clair » en moyenne sous le panneau, a déjà été
        // choisi comme « reçu » (retest du 2026-10-19).
        let ixs = inner.map(\.x), iys = inner.map(\.y)
        let extent = frame.extent
        let innerRect = CGRect(
            x: extent.minX + (ixs.min() ?? 0) * extent.width,
            y: extent.minY + (iys.min() ?? 0) * extent.height,
            width: ((ixs.max() ?? 0) - (ixs.min() ?? 0)) * extent.width,
            height: ((iys.max() ?? 0) - (iys.min() ?? 0)) * extent.height)
        let p10 = grayPercentiles(frame.cropped(to: innerRect),
                                  [0.10]).first ?? 0
        let paperWhite = bright >= 0.5 && p10 >= 0.48
        let xs = quad.map(\.x), ys = quad.map(\.y)
        let minX = xs.min() ?? 0, minY = ys.min() ?? 0
        let bbox = CGRect(x: minX, y: minY,
                          width: (xs.max() ?? 0) - minX,
                          height: (ys.max() ?? 0) - minY)
        let inside = textBoxes.filter {
            bbox.contains(CGPoint(x: $0.midX, y: $0.midY))
        }
        let quadArea = max(bbox.width * bbox.height, 0.0001)
        let bigText = inside.contains {
            $0.width * $0.height >= 0.25 * quadArea
        }
        return (ok: paperWhite && (inside.count >= 3 || bigText),
                textCount: inside.count)
    }

    /// Le quadrilatère resserré vers son centre (l'intérieur du
    /// papier, sans les bords ni l'arrière-plan).
    private func innerQuad(_ quad: [CGPoint]) -> [CGPoint] {
        let c = centroid(quad)
        return quad.map {
            CGPoint(x: c.x + ($0.x - c.x) * 0.7,
                    y: c.y + ($0.y - c.y) * 0.7)
        }
    }

    /// Luminosité moyenne (0…1) dans la boîte englobante du
    /// quadrilatère (CIAreaAverage).
    private func meanBrightness(_ image: CIImage,
                                quad: [CGPoint]) -> CGFloat {
        let xs = quad.map(\.x), ys = quad.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max(),
              maxX > minX, maxY > minY
        else { return 0 }
        let extent = image.extent
        let rect = CGRect(x: extent.minX + minX * extent.width,
                          y: extent.minY + minY * extent.height,
                          width: (maxX - minX) * extent.width,
                          height: (maxY - minY) * extent.height)
        guard let filter = CIFilter(name: "CIAreaAverage")
        else { return 0 }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: rect), forKey: "inputExtent")
        guard let out = filter.outputImage else { return 0 }
        var rgba = [UInt8](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { raw in
            ciContext.render(out, toBitmap: raw.baseAddress!,
                             rowBytes: 4,
                             bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                             format: .RGBA8, colorSpace: rgbSpace)
        }
        return (CGFloat(rgba[0]) + CGFloat(rgba[1]) + CGFloat(rgba[2]))
            / (3 * 255)
    }

    // MARK: - Capture : enregistrement + fusion

    private func finish() {
        phase = .done
        // L'analyse qui suit prend une à deux secondes (lecture
        // précise, amélioration) : le dire, sinon l'attente a
        // l'air d'un temps de capture qui s'éternise (remarque de
        // Grégoire le 2026-10-20).
        // L'état FIGÉ est publié DÈS MAINTENANT, avec la meilleure
        // image retenue en attendant le résultat : la vue réagit
        // en COUPANT la caméra (demande de Grégoire, 2026-10-20 —
        // plus besoin de tenir le reçu pendant le traitement).
        let token = scanToken
        let frozen = bestSample.flatMap {
            ciContext.createCGImage($0, from: $0.extent)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.scanToken == token else { return }
            self.state = .done
            self.statusText = "Analyse du scan…"
            if let frozen {
                self.livePreview = frozen
                self.frozenRawFrame = frozen
                self.frozenFrameStamp += 1
            }
        }

        // MODE « GÉNÉRER MATÉRIEL » : on s'arrête ici — la
        // frame figée est publiée, la vue la coffre dans la
        // banque. Ni rituel, ni analyse.
        if bankingMode {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scanToken == token
                else { return }
                self.statusText = "Frame figée — « Générer "
                    + "matériel » : la photo part au coffre."
            }
            return
        }

        // REDRESSEMENT PAR ÉTAPES (algorithme de Grégoire,
        // 2026-10-21) : on manipule l'image successivement
        // jusqu'à trouver le bon sens, CHAQUE étape affichée
        // 2 secondes pour être VUE travailler, puis le reçu
        // est découpé et ENFIN analysé. Étapes : 1. l'image
        // de départ ; 2. la ZONE LA PLUS BLANCHE (le papier —
        // seuil relatif, gribouillis noirs dedans absorbés),
        // tout l'extérieur devient NOIR ; 3. la DÉVIATION
        // mesurée par les BORDS de la zone (deux lignes à
        // 90°) et corrigée ; 4. le sens jugé sur les MOTS
        // (direction des lettres, déroulement des lignes) ;
        // 5. le découpage sur la zone blanche ; 6. l'analyse
        // (compagnie, date, total).
        guard let sample = bestSample else {
            DispatchQueue.main.async { [weak self] in
                self?.statusText = "Aucun échantillon — réessayez."
            }
            phase = .searching
            return
        }
        let sourceHow = "image unique la plus nette (netteté "
            + String(format: "%.1f", bestSharpness)
            + ", \(sampledFrames) échantillon(s)"
            + (earlySharpExit ? ", prise dès qu'elle était nette" : "")
            + ")"
        var trace: [String] = []
        // Affiche une étape (image + statut) et la laisse à
        // l'écran 2 secondes. Rend false si le scan a été
        // remplacé entre-temps.
        func showStep(_ image: CIImage, _ status: String) -> Bool {
            let cg = self.ciContext.createCGImage(
                image, from: image.extent)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scanToken == token
                else { return }
                self.livePreview = cg
                self.statusText = status
            }
            Thread.sleep(forTimeInterval: 2)
            return self.scanToken == token
        }
        func atOrigin(_ image: CIImage) -> CIImage {
            image.transformed(by: CGAffineTransform(
                translationX: -image.extent.minX,
                y: -image.extent.minY))
        }

        // Étape 1 — l'image de départ, TELLE QUELLE.
        // (Le flip-miroir essayé au build 65 est retiré :
        // Grégoire a vu DEUX flips à l'écran — celui de
        // l'aperçu et celui-ci — et l'image brute n'a en
        // fait jamais eu besoin d'être flippée pour être
        // lue. Build 67.)
        var work = atOrigin(sample)
        trace.append("Étape 1 — image de départ (sans flip)")
        guard showStep(work, "Étape 1 — image de départ")
        else { return }

        // Étape 2 — la ZONE LA PLUS BLANCHE (méthode de
        // Grégoire, 2026-10-21) : le papier est la zone la
        // plus blanche DISPONIBLE dans l'image (seuil
        // relatif) ; les gribouillis noirs dedans (le texte
        // imprimé) sont absorbés — dilatation, plus grande
        // composante, trous remplis. Tout ce qui est À
        // L'EXTÉRIEUR devient NOIR : il ne reste que le
        // papier et ses bords, nets, pour la mesure.
        let zone = findWhiteZone(in: work)
        if let zone {
            work = maskedToZone(work, zone: zone)
            trace.append("Étape 2 — zone la plus blanche : "
                + "\(Int(zone.coverage * 100)) % du cadre "
                + "(seuil \(zone.threshold)), extérieur en noir")
            guard showStep(work, "Étape 2 — la zone la plus "
                + "blanche, tout le reste en noir")
            else { return }
        } else {
            trace.append("Étape 2 — aucune zone blanche "
                + "dominante (\(lastZoneSummary))")
            guard showStep(work, "Étape 2 — aucune zone "
                + "blanche dominante, on continue sans masque")
            else { return }
        }

        // Étape 3 — la DÉVIATION par les BORDS : deux lignes
        // qui se croisent à 90° ajustées sur les bords de la
        // zone (axe principal, raffiné par les côtés) ; la
        // déviation vs la verticale/l'horizontale est
        // corrigée d'un coup.
        if let zone {
            if let dev = measureDeviation(zone: zone) {
                if abs(dev) > 0.2 * .pi / 180 {
                    work = rotateKeepingExtent(work, by: -dev)
                    trace.append(String(
                        format: "Étape 3 — bords : déviation "
                            + "de %+.1f°, rotation de %+.1f°",
                        Double(dev) * 180 / .pi,
                        Double(-dev) * 180 / .pi))
                    guard showStep(work, String(
                        format: "Étape 3 — déviation de %+.1f° "
                            + "corrigée",
                        Double(dev) * 180 / .pi))
                    else { return }
                } else {
                    trace.append("Étape 3 — bords déjà alignés "
                        + "(déviation < 0,2°)")
                    guard showStep(work, "Étape 3 — les bords "
                        + "sont déjà alignés")
                    else { return }
                }
            } else {
                trace.append("Étape 3 — déviation non mesurable")
                guard showStep(work, "Étape 3 — déviation non "
                    + "mesurable, on continue")
                else { return }
            }
        }

        // Étape 4 — le SENS, jugé sur les MOTS (demande de
        // Grégoire, 2026-10-21) : une fois l'image
        // parfaitement horizontale ou verticale, la lecture
        // est excellente — même à l'envers, et les chiffres
        // ne distinguent pas le sens. On lit donc les
        // LETTRES : le mot du commerce va-t-il de sa première
        // à sa dernière lettre de gauche à droite (P → A
        // pour « Postes Canada ») quand on lit depuis la
        // gauche absolue ? Le texte se déroule-t-il de haut
        // en bas ou de bas en haut ? Verdicts : bon sens /
        // à l'envers (rotation de 180°) / de côté (rotation
        // de 90°), retestés à chaque position.
        var placed = false
        var attempts = 0
        var bestSense: (image: CIImage, score: Float)
            = (work, -1)
        while attempts < 4 {
            attempts += 1
            let sense = wordSense(of: work)
            trace.append("Étape 4.\(attempts) — mots : "
                + sense.summary)
            if sense.score > bestSense.score {
                bestSense = (work, sense.score)
            }
            guard showStep(work, "Étape 4.\(attempts) — "
                + sense.status)
            else { return }
            if sense.verdict == .upright {
                placed = true
                break
            }
            let turn: CGFloat = sense.verdict == .upsideDown
                ? .pi : .pi / 2
            work = rotateKeepingExtent(work, by: turn)
            trace.append("Étape 4.\(attempts) — rotation de "
                + "\(turn == .pi ? "180" : "90")°")
        }
        if !placed {
            work = bestSense.image
            trace.append("Étape 4 — aucun sens concluant : "
                + "meilleur score de mots gardé")
        }

        // Étape 5 — on élimine le noir qui reste À
        // L'EXTÉRIEUR de la zone blanche : la zone est
        // recherchée à nouveau sur l'image orientée, et le
        // reçu est découpé sur elle — il occupe alors le
        // maximum de l'écran disponible.
        if let zone2 = findWhiteZone(in: work) {
            let ext = work.extent
            var rect = CGRect(
                x: ext.minX + zone2.bboxNorm.minX * ext.width,
                y: ext.minY + zone2.bboxNorm.minY * ext.height,
                width: zone2.bboxNorm.width * ext.width,
                height: zone2.bboxNorm.height * ext.height)
            rect = rect.insetBy(dx: -0.01 * rect.width,
                                dy: -0.01 * rect.height)
                .intersection(ext)
            if rect.width > 40, rect.height > 40 {
                work = atOrigin(work.cropped(to: rect))
                trace.append("Étape 5 — reçu découpé sur sa "
                    + "zone blanche (qui couvrait "
                    + "\(Int(zone2.coverage * 100)) % du cadre)")
                guard showStep(work, "Étape 5 — reçu découpé, "
                    + "le noir extérieur est éliminé")
                else { return }
            } else {
                trace.append("Étape 5 — zone trop petite, "
                    + "pas de découpage")
                guard showStep(work,
                    "Étape 5 — pas de découpage (zone minuscule)")
                else { return }
            }
        } else {
            trace.append("Étape 5 — zone blanche non "
                + "retrouvée (\(lastZoneSummary))")
            guard showStep(work, "Étape 5 — pas de découpage "
                + "(zone non retrouvée)")
            else { return }
        }

        // Étape 6 — ENFIN (pas avant) l'analyse : nom de la
        // compagnie, date et montant total, par les
        // algorithmes existants, sur le reçu redressé et
        // découpé. C'est le retour du finale suspendu au
        // build 65, branché au bout du rituel.
        let outcome = recognizeBestText(
            image: sharpenForReading(work))
        var image = work
        if outcome.correction != .up {
            image = image.oriented(outcome.correction)
            trace.append("Analyse — l'arbitre de lecture a "
                + "retourné l'image de 180°")
        }
        let rawCG = ciContext.createCGImage(image,
                                            from: image.extent)
        let enhanced = enhanceDocument(image)
        let finalCG = ciContext.createCGImage(enhanced.image,
            from: enhanced.image.extent)
        var extraction = extractFields(from: outcome)
        if let finalCG {
            let fw = CGFloat(finalCG.width)
            let fh = CGFloat(finalCG.height)
            func crop(_ box: CGRect) -> CGImage {
                let rect = CGRect(
                    x: box.minX * fw,
                    y: (1 - box.maxY) * fh,
                    width: box.width * fw,
                    height: box.height * fh).integral
                    .intersection(CGRect(x: 0, y: 0,
                                         width: fw, height: fh))
                return finalCG.cropping(to: rect) ?? finalCG
            }
            extraction.answerCrops = extraction.answerBoxes
                .map(crop)
        }
        finishInfo = "Image finale : \(sourceHow)"
            + "\nRedressement par étapes :\n"
            + trace.joined(separator: "\n")
            + "\nScan final : \(Int(image.extent.width)) × "
            + "\(Int(image.extent.height)) px"
            + "\nAmélioration auto : \(enhanced.summary)"
            + "\nOrientation : \(lastArbiterSummary)"
        let stats = buildStats()
        appendToJournal(stats: stats, extraction: extraction)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.scanToken == token else { return }
            self.state = .done
            self.statusText = "Scan terminé — voici le scan."
            self.progress = 1
            self.finalImage = finalCG
            self.rawFinalImage = rawCG
            self.livePreview = finalCG
            self.extraction = extraction
            self.statsText = stats
        }
    }

    /// Cherche le reçu dans le composite figé :
    /// 1. le meilleur rectangle qui prouve « papier + texte » (le
    ///    plus grand parmi ceux qui passent les preuves) →
    ///    redressement par perspective, élargi de 5 % ;
    /// 2. à défaut, la zone de texte elle-même (boîte englobante
    ///    des zones de texte, élargie de 12 %) — pas de
    ///    redressement, mais le contenu est là ;
    /// 3. à défaut, le composite entier.
    private func extractReceipt(from composite: CIImage,
                                straightened: Bool = false)
    -> (image: CIImage, how: String) {
        let extent = composite.extent
        let textBoxes = bestTextBoxes(in: composite,
                                      straightened: straightened)
        let candidates = detectRectangles(
            handler: VNImageRequestHandler(ciImage: composite,
                                           options: [:]))

        // Critère (corrigé le 2026-10-19, après qu'un grand
        // rectangle de scène eut gagné contre le reçu — scan final
        // 1044 × 1026, toute la scène redressée) : le reçu est le
        // papier qui PORTE le texte — presque toutes les zones de
        // texte, pour la plus PETITE surface. Un rectangle de
        // scène contient aussi le texte, mais avec 3-4× la surface.
        let totalTexts = textBoxes.count
        let minTexts = max(3, (totalTexts + 1) / 2)
        var passing: [(quad: [CGPoint], texts: Int, area: CGFloat)] = []
        for quad in candidates {
            let ev = paperEvidence(frame: composite, quad: quad,
                                   textBoxes: textBoxes)
            guard ev.ok, ev.textCount >= 3 else { continue }
            passing.append((quad, ev.textCount, abs(shoelace(quad))))
        }
        let maxTexts = passing.map(\.texts).max() ?? 0
        let best = passing
            .filter { $0.texts >= max(minTexts, maxTexts - 1) }
            .min { $0.area < $1.area }
        // Garde « scan partiel » : si le rectangle choisi laisse
        // une part notable des zones de texte DEHORS, il ne couvre
        // qu'un morceau du reçu (le contour complet n'a pas été
        // détecté — papier gondolé, fusion ondulée) ; on préfère
        // alors le repli « zone de texte », qui couvre tout.
        func coversText(_ quad: [CGPoint]) -> Bool {
            let xs = quad.map(\.x), ys = quad.map(\.y)
            let bbox = CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                              width: (xs.max() ?? 0) - (xs.min() ?? 0),
                              height: (ys.max() ?? 0) - (ys.min() ?? 0))
            let outside = textBoxes.filter {
                !bbox.contains(CGPoint(x: $0.midX, y: $0.midY))
            }.count
            return outside < 2
                || Double(outside) / Double(max(textBoxes.count, 1))
                    <= 0.15
        }
        if let best, coversText(best.quad) {
            // Normalisé → pixels du canvas, puis élargi de 5 %
            // (la détection rentre souvent le bord du papier).
            let raw = best.quad.map {
                CGPoint(x: extent.minX + $0.x * extent.width,
                        y: extent.minY + $0.y * extent.height)
            }
            let c = centroid(raw)
            let corners = raw.map {
                CGPoint(x: c.x + ($0.x - c.x) * 1.05,
                        y: c.y + ($0.y - c.y) * 1.05)
            }
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
                if let corrected = filter.outputImage {
                    // Garde-fou (journal du 2026-10-20 : un scan
                    // « réussi » de 689 × 3334 px dont le total
                    // était le sous-total) : un rectangle mal
                    // apparié peut produire une bande absurde ;
                    // un vrai reçu cadré ne dépasse guère 4:1.
                    // Au-delà, on n'y croit pas et on retombe
                    // sur l'union des zones de texte.
                    let e = corrected.extent
                    let longSide = max(e.width, e.height)
                    let shortSide = max(1, min(e.width, e.height))
                    if longSide / shortSide <= 4 {
                        return (corrected,
                                "rectangle du reçu (\(best.texts) zones de texte)")
                    }
                }
            }
        }
        if !textBoxes.isEmpty {
            var union = textBoxes[0]
            for box in textBoxes.dropFirst() {
                union = union.union(box)
            }
            let pw = union.width * extent.width
            let ph = union.height * extent.height
            let rect = CGRect(x: extent.minX + union.minX * extent.width,
                              y: extent.minY + union.minY * extent.height,
                              width: pw, height: ph)
                .insetBy(dx: -0.12 * pw, dy: -0.12 * ph)
            // Garde-fou (journal du 2026-10-20) : une union
            // minuscule — quelques boîtes égarées — produisait
            // des découpes de quelques dizaines de pixels,
            // pires que pas de localisation du tout. En dessous
            // de 10 % de l'image, on laisse tomber au cas
            // « aucune localisation » (image entière).
            if rect.width * rect.height
                >= 0.10 * extent.width * extent.height {
                return (composite.cropped(to: rect),
                        "zone de texte seule (\(textBoxes.count) zones)")
            }
        }
        return (composite, "image entière (aucune localisation)")
    }

    /// Le rectangle du reçu : forme rectangulaire aux bords
    /// BLANCS (intérieur clair et uniforme — la preuve
    /// « papier » existante) portant le texte. Rend les
    /// coins normalisés dans l'espace de l'image, ou nil.
    private func findPaperQuad(in image: CIImage) -> [CGPoint]? {
        // Détection DÉDIÉE au rituel, tolérante sur la forme
        // (Grégoire, 2026-10-21 : « la forme n'a pas besoin
        // d'être parfaitement rectangulaire, il doit y avoir
        // un seuil de tolérance ») : écart d'angle permis au
        // maximum (45°) — un papier un peu gondolé ou vu en
        // légère perspective reste candidat ; c'est la
        // preuve « papier blanc » qui tranche ensuite.
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.1
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.08
        request.maximumObservations = 10
        request.minimumConfidence = 0.2
        request.quadratureTolerance = 45
        let handler = VNImageRequestHandler(ciImage: image,
                                            options: [:])
        guard (try? handler.perform([request])) != nil
        else { return nil }
        let candidates = (request.results ?? []).map {
            [$0.topLeft, $0.topRight, $0.bottomRight, $0.bottomLeft]
        }
        guard !candidates.isEmpty else { return nil }
        let textBoxes = bestTextBoxes(in: image)
        var passing: [(quad: [CGPoint], texts: Int,
                       area: CGFloat)] = []
        for quad in candidates {
            let ev = paperEvidence(frame: image, quad: quad,
                                   textBoxes: textBoxes)
            if ev.ok, ev.textCount >= 3 {
                passing.append((quad, ev.textCount,
                                abs(shoelace(quad))))
            }
        }
        guard !passing.isEmpty else {
            lastQuadSummary = "\(candidates.count) rectangle(s) "
                + "détecté(s), aucun ne passe la preuve papier"
            return nil
        }
        // LE critère des bons builds (extractReceipt, corrigé
        // le 2026-10-19 après qu'un rectangle de scène eut
        // « redressé toute la scène ») : le reçu est le papier
        // qui porte PRESQUE TOUT le texte de l'image, pour la
        // plus petite surface. Le pré-filtre « presque tout le
        // texte » est l'essentiel — le rituel l'avait perdu,
        // et un fragment dense (boîte imprimée dans le reçu,
        // étiquette) gagnait par la petite surface (build 71
        // au journal : découpages de 219 × 125 px). Garde
        // « scan partiel » reprise elle aussi : le gagnant ne
        // doit pas laisser le texte dehors.
        let totalTexts = textBoxes.count
        let minTexts = max(3, (totalTexts + 1) / 2)
        let maxTexts = passing.map(\.texts).max() ?? 0
        let pool = passing.filter {
            $0.texts >= max(minTexts, maxTexts - 1)
        }
        func coversText(_ quad: [CGPoint]) -> Bool {
            let xs = quad.map(\.x), ys = quad.map(\.y)
            let bbox = CGRect(
                x: xs.min() ?? 0, y: ys.min() ?? 0,
                width: (xs.max() ?? 0) - (xs.min() ?? 0),
                height: (ys.max() ?? 0) - (ys.min() ?? 0))
            let outside = textBoxes.filter {
                !bbox.contains(CGPoint(x: $0.midX, y: $0.midY))
            }.count
            return outside < 2
                || Double(outside) / Double(max(totalTexts, 1))
                    <= 0.15
        }
        let covering = pool.filter { coversText($0.quad) }
        guard let winner = (covering.isEmpty ? pool : covering)
            .min(by: { $0.area < $1.area }) else { return nil }
        lastQuadSummary = "candidats papier : "
            + passing.map {
                "\(Int($0.area * 100)) %/\($0.texts) textes"
            }.joined(separator: ", ")
            + " → gardé \(Int(winner.area * 100)) % "
            + "(\(winner.texts) textes)"
        return winner.quad
    }

    /// Referme une forme détectée en un rectangle PARFAIT
    /// qui l'affleure (demande de Grégoire, 2026-10-21 :
    /// la boîte « doit demeurer parfaitement rectangulaire
    /// et se refermer sur l'objet détecté en l'affleurant
    /// au mieux de ses capacités de détection » — la
    /// détection brute rend des trapèzes dès que le papier
    /// est vu en perspective). Méthode : tourner les coins
    /// de l'angle du bord supérieur autour du centroïde,
    /// prendre la boîte englobante dans ce repère, ramener
    /// ses coins dans l'image. Rend les coins normalisés
    /// [haut-gauche, haut-droit, bas-droit, bas-gauche].
    private func rectifyQuad(_ quad: [CGPoint],
                             imageSize: CGSize) -> [CGPoint] {
        let pts = quad.map {
            CGPoint(x: $0.x * imageSize.width,
                    y: $0.y * imageSize.height)
        }
        let angle = quadEdges(quad, imageSize: imageSize)
            .topAngle
        let c = centroid(pts)
        func rot(_ p: CGPoint, _ a: CGFloat) -> CGPoint {
            let dx = p.x - c.x, dy = p.y - c.y
            return CGPoint(
                x: c.x + dx * cos(a) - dy * sin(a),
                y: c.y + dx * sin(a) + dy * cos(a))
        }
        let flat = pts.map { rot($0, -angle) }
        let minX = flat.map(\.x).min() ?? 0
        let maxX = flat.map(\.x).max() ?? 0
        let minY = flat.map(\.y).min() ?? 0
        let maxY = flat.map(\.y).max() ?? 0
        let corners = [CGPoint(x: minX, y: maxY),
                       CGPoint(x: maxX, y: maxY),
                       CGPoint(x: maxX, y: minY),
                       CGPoint(x: minX, y: minY)]
        return corners.map { p in
            let q = rot(p, angle)
            return CGPoint(x: q.x / imageSize.width,
                           y: q.y / imageSize.height)
        }
    }

    /// Les bords « du haut » et « de droite » d'un
    /// quadrilatère (coins normalisés, espace image à y
    /// montant), mesurés en PIXELS de l'image : le bord du
    /// haut relie les deux coins les plus hauts, de gauche à
    /// droite — son angle est l'inclinaison du rectangle.
    private func quadEdges(_ quad: [CGPoint], imageSize: CGSize)
    -> (topLength: CGFloat, rightLength: CGFloat,
        topAngle: CGFloat) {
        let pts = quad.map {
            CGPoint(x: $0.x * imageSize.width,
                    y: $0.y * imageSize.height)
        }
        let byY = pts.sorted { $0.y > $1.y }
        let top = Array(byY.prefix(2)).sorted { $0.x < $1.x }
        let byX = pts.sorted { $0.x > $1.x }
        let right = Array(byX.prefix(2))
        func len(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            hypot(b.x - a.x, b.y - a.y)
        }
        return (len(top[0], top[1]), len(right[0], right[1]),
                atan2(top[1].y - top[0].y, top[1].x - top[0].x))
    }

    /// Copie d'affichage avec le quadrilatère tracé en jaune
    /// épais — le rectangle « surligné » de l'étape 2.
    private func drawQuad(_ quad: [CGPoint], on image: CIImage)
    -> CGImage? {
        guard let cg = ciContext.createCGImage(
            image, from: image.extent) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        guard let ctx = CGContext(
            data: nil, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: rgbSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast
                .rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Le contexte Quartz est en y MONTANT, comme
        // l'espace normalisé des coins : aucun retournement
        // ici — le (1 - y) du build 65 dessinait la boîte
        // MIROITÉE à la verticale (Grégoire, build 67 : la
        // boîte « au-dessus de l'objet », angle à l'envers).
        let pts = quad.map {
            CGPoint(x: $0.x * w, y: $0.y * h)
        }
        ctx.setStrokeColor(red: 1, green: 0.85, blue: 0,
                           alpha: 1)
        ctx.setLineWidth(max(4, w * 0.006))
        ctx.beginPath()
        ctx.move(to: pts[0])
        for pt in pts.dropFirst() { ctx.addLine(to: pt) }
        ctx.closePath()
        ctx.strokePath()
        return ctx.makeImage()
    }

    /// Test « le texte est-il lisible par un humain ? » —
    /// le choix du test a été laissé à Muse par Grégoire
    /// (2026-10-21). CORRIGÉ au build 68 : les montants ne
    /// suffisent pas — Vision lit les chiffres à l'envers
    /// étonnamment bien (build 67 : 9 montants et « LISIBLE »
    /// sur un reçu presque complètement à l'envers, vu par
    /// Grégoire). Le test est donc STRUCTUREL : lisible si
    /// la lecture produit la PREUVE fiscale du total
    /// (impossible à l'envers : les parties de la preuve se
    /// retrouvent sous le total), ou le commerce du
    /// répertoire ET la date ensemble. Le score (qui sert à
    /// garder le meilleur sens si aucun ne passe) reflète
    /// la même hiérarchie.
    private func readability(of image: CIImage)
    -> (readable: Bool, score: Float, amounts: Int,
        proof: Bool, merchant: Bool, date: Bool) {
        let targetWidth: CGFloat = 720
        let k = targetWidth / max(image.extent.width, 1)
        let small = k < 1
            ? image.transformed(
                by: CGAffineTransform(scaleX: k, y: k))
            : image
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["fr-FR", "en-US"]
        let handler = VNImageRequestHandler(ciImage: small,
                                            options: [:])
        guard (try? handler.perform([request])) != nil
        else { return (false, 0, 0, false, false, false) }
        var weighted: Float = 0
        var text = ""
        for obs in request.results ?? [] {
            if let c = obs.topCandidates(1).first {
                weighted += c.confidence * Float(c.string.count)
                text += c.string + "\n"
            }
        }
        let amounts = ReceiptParser.allAmounts(text).count
        let proof = ReceiptParser.parseTotalVerified(text) != nil
        let merchantHit = ReceiptParser
            .parseMerchantMatch(text) != nil
        let dateHit = ReceiptParser.parseDate(text) != nil
        var score = weighted + Float(amounts) * 1000
        if proof { score += 100_000 }
        if merchantHit { score += 5_000 }
        if dateHit { score += 2_000 }
        let readable = proof
            || (merchantHit && dateHit && amounts >= 2)
            || (merchantHit && amounts >= 4 && weighted >= 300)
        return (readable, score, amounts, proof, merchantHit,
                dateHit)
    }

    /// Fait suivre un quadrilatère normalisé à travers la
    /// même rotation que rotateKeepingExtent applique à
    /// l'image (rotation autour du centre, puis étendue
    /// recadrée à l'origine) : les coins du rectangle du
    /// reçu restent donc sur le papier à chaque étape.
    private func mapQuad(_ quad: [CGPoint], oldSize: CGSize,
                         angle: CGFloat) -> [CGPoint] {
        let cx = oldSize.width / 2, cy = oldSize.height / 2
        func rot(_ p: CGPoint) -> CGPoint {
            let dx = p.x - cx, dy = p.y - cy
            return CGPoint(
                x: cx + dx * cos(angle) - dy * sin(angle),
                y: cy + dx * sin(angle) + dy * cos(angle))
        }
        let img = [CGPoint(x: 0, y: 0),
                   CGPoint(x: oldSize.width, y: 0),
                   CGPoint(x: oldSize.width, y: oldSize.height),
                   CGPoint(x: 0, y: oldSize.height)].map(rot)
        let minX = img.map(\.x).min() ?? 0
        let minY = img.map(\.y).min() ?? 0
        let newW = (img.map(\.x).max() ?? 0) - minX
        let newH = (img.map(\.y).max() ?? 0) - minY
        guard newW > 0, newH > 0 else { return quad }
        return quad.map { p in
            let r = rot(CGPoint(x: p.x * oldSize.width,
                                y: p.y * oldSize.height))
            return CGPoint(x: (r.x - minX) / newW,
                           y: (r.y - minY) / newH)
        }
    }

    /// Verdict de sens d'après les MOTS (voir l'étape 4 de
    /// finish) : à l'endroit / à l'envers / de côté, avec le
    /// résumé des signaux pour le journal.
    private enum SenseVerdict {
        case upright, upsideDown, sideways
    }

    /// JOUEUR CONTOURS (jour 1) de la table de jeu —
    /// étape 1 du pipeline (ordre de Grégoire, 2026-10-22 :
    /// tracer les contours AVANT tout le reste).
    /// Version JEU (build 83) : le joueur du build 82 était
    /// findPaperQuad — un détecteur de RITUEL construit
    /// pour S'ABSTENIR (preuve papier + ≥ 3 zones de texte +
    /// couverture du texte) ; sur les copies tournées à des
    /// angles quelconques, les zones de texte qui nourrissent
    /// sa preuve disparaissent, et il s'abstenait PARTOUT
    /// (journal du 2026-10-22 : 3/3 boîtes par défaut —
    /// « l'IA n'essaie même pas »). Un joueur de jeu doit
    /// TOUJOURS jouer son meilleur essai : détection de
    /// rectangles Vision tolérante, SANS les preuves, le
    /// meilleur candidat (surface × confiance) gagne. La
    /// correction de Grégoire tranchera. Coordonnées
    /// d'AFFICHAGE (origine haut-gauche), [TL, TR, BR, BL].
    func contourProposal(for image: CIImage)
    -> (quad: [CGPoint], detail: String)? {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.1
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.05
        request.maximumObservations = 8
        request.minimumConfidence = 0.1
        request.quadratureTolerance = 45
        let handler = VNImageRequestHandler(ciImage: image,
                                            options: [:])
        guard (try? handler.perform([request])) != nil,
              let results = request.results, !results.isEmpty
        else { return nil }
        func quadOf(_ o: VNRectangleObservation) -> [CGPoint] {
            [o.topLeft, o.topRight, o.bottomRight, o.bottomLeft]
        }
        guard let best = results.max(by: { a, b in
            abs(shoelace(quadOf(a))) * CGFloat(a.confidence)
                < abs(shoelace(quadOf(b)))
                * CGFloat(b.confidence)
        }) else { return nil }
        let vision = quadOf(best)
        let display = vision.map {
            CGPoint(x: $0.x, y: 1 - $0.y)
        }
        let pct = Int(abs(shoelace(vision)) * 100)
        return (display,
                "\(results.count) rectangle(s) Vision — "
                + "meilleur : confiance "
                + String(format: "%.2f", best.confidence)
                + ", \(pct) % de l'image")
    }

    /// JOUEUR ROTATION (jour 1, heuristique) de la table de
    /// jeu « Entraînement IA » : propose la rotation (en
    /// degrés appliqués à l'image) qui rend le texte lisible.
    /// Recherche bornée : alignement par les bords de la zone
    /// blanche, sens par les mots (quarts de tour, ≤ 4
    /// essais), finition par les bords. Méthode autonome —
    /// le rituel du scanner ne s'en sert pas.
    func rotationProposal(for image: CIImage)
    -> (degrees: Double, confidence: Float, detail: String) {
        var work = image
        var total: CGFloat = 0
        var notes: [String] = []
        func fmt(_ rad: CGFloat) -> String {
            String(format: "%+.1f°", rad * 180 / .pi)
        }
        // 1) Alignement grossier par les bords (la déviation
        //    se mesure sans lire le texte).
        if let zone = findWhiteZone(in: work),
           let dev = measureDeviation(zone: zone) {
            work = rotateKeepingExtent(work, by: -dev)
            total += -dev
            notes.append("bords \(fmt(dev))")
        }
        // 2) Le sens par les mots (quarts de tour). DE CÔTÉ,
        //    on essaie les DEUX sens et on garde celui que
        //    les mots lisent le mieux — tourner toujours du
        //    même bord faisait faire un tour complet
        //    (propositions à +362° vues au journal de jeu du
        //    2026-10-22).
        var confidence: Float = 0.1
        for _ in 0..<4 {
            let sense = wordSense(of: work)
            if sense.verdict == .upright {
                confidence = min(1, max(0.05,
                                        sense.score / 150_000))
                notes.append("mots : endroit")
                break
            }
            if sense.verdict == .upsideDown {
                work = rotateKeepingExtent(work, by: .pi)
                total += .pi
                notes.append("mots : envers → 180°")
                continue
            }
            let cw = rotateKeepingExtent(work, by: .pi / 2)
            let ccw = rotateKeepingExtent(work, by: -.pi / 2)
            let sCW = wordSense(of: cw)
            let sCCW = wordSense(of: ccw)
            if sCW.score >= sCCW.score {
                work = cw
                total += .pi / 2
                notes.append("mots : côté → +90°")
            } else {
                work = ccw
                total += -.pi / 2
                notes.append("mots : côté → −90°")
            }
        }
        // 3) Finition par les bords.
        if let zone = findWhiteZone(in: work),
           let dev = measureDeviation(zone: zone),
           abs(dev) > 0.003 {
            work = rotateKeepingExtent(work, by: -dev)
            total += -dev
            notes.append("finition \(fmt(dev))")
        }
        return (Double(total * 180 / .pi), confidence,
                notes.joined(separator: " · "))
    }

    /// Lit le texte d'une image parfaitement horizontale ou
    /// verticale et juge son sens sur les LETTRES :
    /// (1) la direction des lettres du mot d'ancrage (la
    /// ligne du commerce, sinon la plus longue) — ses
    /// première et dernière lettres, lues depuis la gauche
    /// absolue : de gauche à droite (P → A) = à l'endroit,
    /// de droite à gauche = à l'envers, à la verticale =
    /// de côté ; (2) le déroulement des lignes — l'ordre
    /// retourné suit-il le haut→bas spatial, ou le
    /// bas→haut ? ; (3) en appoint, les mots du lexique des
    /// reçus, le commerce du répertoire et la preuve.
    private func wordSense(of image: CIImage)
    -> (verdict: SenseVerdict, score: Float,
        summary: String, status: String) {
        let targetWidth: CGFloat = 720
        let k = targetWidth / max(image.extent.width, 1)
        let small = k < 1
            ? image.transformed(
                by: CGAffineTransform(scaleX: k, y: k))
            : image
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["fr-FR", "en-US"]
        let handler = VNImageRequestHandler(ciImage: small,
                                            options: [:])
        guard (try? handler.perform([request])) != nil,
              let results = request.results, !results.isEmpty
        else {
            return (.sideways, 0,
                    "aucune ligne reconnue",
                    "aucun texte lu → de côté ?")
        }
        let lines: [(text: String, box: CGRect,
                     obs: VNRecognizedText)] = results
            .compactMap { o in
                guard let c = o.topCandidates(1).first
                else { return nil }
                return (c.string, o.boundingBox, c)
            }
        guard !lines.isEmpty else {
            return (.sideways, 0, "aucune ligne retenue",
                    "aucun texte lu → de côté ?")
        }
        let fullText = lines.map(\.text)
            .joined(separator: "\n")
        let folded = fullText.lowercased()
        let lexicon = ["total", "sous-total", "tps", "tvq",
                       "gst", "qst", "merci", "reçu", "recu",
                       "débit", "debit", "crédit", "credit",
                       "postes", "canada", "facture", "client",
                       "article", "quantité", "quantite",
                       "paiement", "téléphone", "telephone",
                       "bonjour", "commande", "livraison"]
        let wordHits = lexicon
            .filter { folded.contains($0) }.count
        let merchant = ReceiptParser
            .parseMerchantMatch(fullText)
        let proof = ReceiptParser
            .parseTotalVerified(fullText) != nil
        let dateHit = ReceiptParser.parseDate(fullText) != nil
        // Déroulement des lignes (ordre retourné contre
        // positions, y montant : le haut a le plus grand y).
        var down = 0, up = 0
        if lines.count >= 2 {
            for i in 1..<lines.count {
                if lines[i].box.midY < lines[i - 1].box.midY {
                    down += 1
                } else if lines[i].box.midY
                            > lines[i - 1].box.midY {
                    up += 1
                }
            }
        }
        let unrollsDown: Bool? = lines.count >= 3
            ? (down > up ? true : (up > down ? false : nil))
            : nil
        // Direction des lettres sur la ligne d'ancrage.
        var anchor = lines.max {
            $0.text.count < $1.text.count
        }
        if let m = merchant,
           lines.indices.contains(m.lineIndex) {
            anchor = lines[m.lineIndex]
        }
        func charBox(_ t: VNRecognizedText, first: Bool)
        -> CGRect? {
            let str = t.string
            guard !str.isEmpty else { return nil }
            let idx = first ? str.startIndex
                : str.index(before: str.endIndex)
            let range = idx..<str.index(after: idx)
            return (try? t.boundingBox(for: range))?.boundingBox
        }
        var letters = "?"
        var ltr: Bool? = nil
        if let a = anchor,
           let f = charBox(a.obs, first: true),
           let l = charBox(a.obs, first: false) {
            let dx = l.midX - f.midX, dy = l.midY - f.midY
            if abs(dy) > 2 * abs(dx) {
                letters = "verticales"
            } else {
                ltr = dx > 0
                letters = ltr == true ? "gauche→droite"
                                      : "droite→gauche"
            }
        }
        let wordsStrong = merchant != nil || wordHits >= 3
            || proof
        let verdict: SenseVerdict
        if letters == "verticales" {
            verdict = .sideways
        } else if let l = ltr, let d = unrollsDown {
            if l && d {
                verdict = .upright
            } else {
                // !l && !d : le portrait franc de l'envers.
                // Signaux mixtes : l'envers brouille l'un
                // des deux — demi-tour, la boucle reteste.
                verdict = .upsideDown
            }
        } else if wordsStrong {
            verdict = .upright
        } else {
            verdict = .sideways
        }
        var score: Float = Float(wordHits) * 500
        if merchant != nil { score += 5_000 }
        if dateHit { score += 2_000 }
        if proof { score += 100_000 }
        if verdict == .upright { score += 50_000 }
        let summary = "lexique \(wordHits), commerce "
            + (merchant?.name ?? "—")
            + ", lettres \(letters), déroulement "
            + (unrollsDown == nil ? "?"
               : (unrollsDown! ? "haut→bas" : "bas→haut"))
            + ", preuve \(proof ? "OUI" : "non") → "
            + (verdict == .upright ? "À L'ENDROIT"
               : verdict == .upsideDown ? "À L'ENVERS"
               : "DE CÔTÉ")
        let status = verdict == .upright
            ? "texte à l'endroit ✓ (mots lus : \(wordHits))"
            : verdict == .upsideDown
                ? "texte à l'envers → rotation de 180°"
                : "texte de côté → rotation de 90°"
        return (verdict, score, summary, status)
    }

    // MARK: - Zone blanche (méthode de Grégoire, 2026-10-21)

    /// La zone la plus blanche d'une image : masque binaire
    /// (tampon réduit, rangée 0 = haut de l'image), sa boîte
    /// en coordonnées normalisées (y montant), son seuil et
    /// sa part du cadre.
    private struct WhiteZone {
        var mask: [UInt8]
        var w: Int
        var h: Int
        var threshold: Int
        var coverage: Double
        var bboxNorm: CGRect
    }

    private var lastZoneSummary = ""

    /// Cherche la zone la plus blanche DISPONIBLE : seuil
    /// d'Otsu sur l'histogramme (relatif à l'image, jamais un
    /// blanc absolu), dilatation pour absorber les
    /// gribouillis noirs DANS la zone (le texte imprimé),
    /// plus grande composante connexe, trous remplis.
    private func findWhiteZone(in image: CIImage) -> WhiteZone? {
        guard let (px, w, h) = grayBuffer(image,
                                          maxWidth: 512)
        else {
            lastZoneSummary = "tampon gris indisponible"
            return nil
        }
        let total = w * h
        var hist = [Int](repeating: 0, count: 256)
        for v in px { hist[Int(v)] += 1 }
        var sumAll = 0.0
        for i in 0..<256 { sumAll += Double(i * hist[i]) }
        var sumB = 0.0, countB = 0, best = -1.0, level = 128
        for i in 0..<256 {
            countB += hist[i]
            if countB == 0 { continue }
            let countF = total - countB
            if countF == 0 { break }
            sumB += Double(i * hist[i])
            let mB = sumB / Double(countB)
            let mF = (sumAll - sumB) / Double(countF)
            let between = Double(countB) * Double(countF)
                * (mB - mF) * (mB - mF)
            if between > best { best = between; level = i }
        }
        var mask = [UInt8](repeating: 0, count: total)
        for i in 0..<total where px[i] >= UInt8(level) {
            mask[i] = 255
        }
        mask = dilateMask(mask, w: w, h: h, passes: 2)
        mask = largestComponent(mask, w: w, h: h)
        mask = fillHoles(mask, w: w, h: h)
        var count = 0
        var minC = w, maxC = -1, minR = h, maxR = -1
        for r in 0..<h {
            for c in 0..<w where mask[r * w + c] > 0 {
                count += 1
                if c < minC { minC = c }
                if c > maxC { maxC = c }
                if r < minR { minR = r }
                if r > maxR { maxR = r }
            }
        }
        let coverage = Double(count) / Double(total)
        guard maxC >= 0, coverage >= 0.04, coverage <= 0.97
        else {
            lastZoneSummary = "seuil \(level), zone de "
                + "\(Int(coverage * 100)) % — hors limites"
            return nil
        }
        let bbox = CGRect(
            x: CGFloat(minC) / CGFloat(w),
            y: 1 - CGFloat(maxR + 1) / CGFloat(h),
            width: CGFloat(maxC - minC + 1) / CGFloat(w),
            height: CGFloat(maxR - minR + 1) / CGFloat(h))
        return WhiteZone(mask: mask, w: w, h: h,
                         threshold: level, coverage: coverage,
                         bboxNorm: bbox)
    }

    /// Dilatation binaire (voisinage 4) : la zone blanche
    /// grandit dans les gribouillis noirs qu'elle contient.
    private func dilateMask(_ mask: [UInt8], w: Int, h: Int,
                            passes: Int) -> [UInt8] {
        var cur = mask
        for _ in 0..<passes {
            var out = cur
            for r in 0..<h {
                for c in 0..<w where cur[r * w + c] == 0 {
                    if (c > 0 && cur[r * w + c - 1] > 0)
                        || (c < w - 1 && cur[r * w + c + 1] > 0)
                        || (r > 0 && cur[(r - 1) * w + c] > 0)
                        || (r < h - 1
                            && cur[(r + 1) * w + c] > 0) {
                        out[r * w + c] = 255
                    }
                }
            }
            cur = out
        }
        return cur
    }

    /// Ne garde que la plus grande composante connexe
    /// (voisinage 4) du masque.
    private func largestComponent(_ mask: [UInt8], w: Int,
                                  h: Int) -> [UInt8] {
        var labels = [Int](repeating: -1, count: w * h)
        var sizes: [Int] = []
        var stack: [Int] = []
        for start in 0..<(w * h)
        where mask[start] > 0 && labels[start] < 0 {
            let id = sizes.count
            var size = 0
            labels[start] = id
            stack = [start]
            while let idx = stack.popLast() {
                size += 1
                let r = idx / w, c = idx % w
                if c > 0, mask[idx - 1] > 0,
                   labels[idx - 1] < 0 {
                    labels[idx - 1] = id
                    stack.append(idx - 1)
                }
                if c < w - 1, mask[idx + 1] > 0,
                   labels[idx + 1] < 0 {
                    labels[idx + 1] = id
                    stack.append(idx + 1)
                }
                if r > 0, mask[idx - w] > 0,
                   labels[idx - w] < 0 {
                    labels[idx - w] = id
                    stack.append(idx - w)
                }
                if r < h - 1, mask[idx + w] > 0,
                   labels[idx + w] < 0 {
                    labels[idx + w] = id
                    stack.append(idx + w)
                }
            }
            sizes.append(size)
        }
        guard let bestId = sizes.indices
            .max(by: { sizes[$0] < sizes[$1] })
        else { return mask }
        var out = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) where labels[i] == bestId {
            out[i] = 255
        }
        return out
    }

    /// Remplit les trous : tout pixel hors zone qui n'est
    /// pas relié au bord de l'image fait partie de la zone
    /// (gribouillis refermés, boucles de lettres…).
    private func fillHoles(_ mask: [UInt8], w: Int, h: Int)
    -> [UInt8] {
        var outside = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        func seed(_ idx: Int) {
            if mask[idx] == 0, !outside[idx] {
                outside[idx] = true
                stack.append(idx)
            }
        }
        for c in 0..<w { seed(c); seed((h - 1) * w + c) }
        for r in 0..<h { seed(r * w); seed(r * w + w - 1) }
        while let idx = stack.popLast() {
            let r = idx / w, c = idx % w
            if c > 0 { seed(idx - 1) }
            if c < w - 1 { seed(idx + 1) }
            if r > 0 { seed(idx - w) }
            if r < h - 1 { seed(idx + w) }
        }
        var out = mask
        for i in 0..<(w * h)
        where mask[i] == 0 && !outside[i] {
            out[i] = 255
        }
        return out
    }

    /// L'image dont tout ce qui est hors de la zone blanche
    /// devient NOIR (masque alpha étiré au cadre, fondu).
    private func maskedToZone(_ image: CIImage,
                              zone: WhiteZone) -> CIImage {
        // Masque RGBA explicite : blanc OPAQUE dans la
        // zone, transparent dehors — le fondu suit l'alpha,
        // sans dépendre d'un masque « alpha seulement ».
        var rgba = [UInt8](repeating: 0,
                           count: zone.w * zone.h * 4)
        for i in 0..<(zone.w * zone.h) where zone.mask[i] > 0 {
            rgba[i * 4] = 255
            rgba[i * 4 + 1] = 255
            rgba[i * 4 + 2] = 255
            rgba[i * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(
                data: Data(rgba) as CFData),
              let cg = CGImage(
                width: zone.w, height: zone.h,
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: zone.w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue:
                    CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent)
        else { return image }
        let ext = image.extent
        let t = CGAffineTransform(
            a: ext.width / CGFloat(zone.w), b: 0, c: 0,
            d: ext.height / CGFloat(zone.h),
            tx: ext.minX, ty: ext.minY)
        let maskImage = CIImage(cgImage: cg).transformed(by: t)
        guard let blend = CIFilter(name: "CIBlendWithMask")
        else { return image }
        blend.setValue(image, forKey: kCIInputImageKey)
        blend.setValue(CIImage(color: .black).cropped(to: ext),
                       forKey: kCIInputBackgroundImageKey)
        blend.setValue(maskImage, forKey: kCIInputMaskImageKey)
        return blend.outputImage?.cropped(to: ext) ?? image
    }

    /// La déviation de la zone vs la verticale et
    /// l'horizontale, PAR LES BORDS : axe principal de la
    /// zone (covariance des pixels), raffiné par des lignes
    /// ajustées sur les quatre côtés dans le repère de l'axe
    /// — les deux familles de côtés se croisent à 90° par
    /// construction, et chacune donne la même déviation.
    /// Rend l'angle signé (radians, repère image y montant)
    /// dont la zone penche vs l'axe cardinal le plus proche.
    private func measureDeviation(zone: WhiteZone)
    -> CGFloat? {
        let w = zone.w, h = zone.h, mask = zone.mask
        var n = 0.0, sx = 0.0, sy = 0.0
        for r in 0..<h {
            for c in 0..<w where mask[r * w + c] > 0 {
                n += 1
                sx += (Double(c) + 0.5) / Double(w)
                sy += 1 - (Double(r) + 0.5) / Double(h)
            }
        }
        guard n > 100 else { return nil }
        let mx = sx / n, my = sy / n
        var cxx = 0.0, cyy = 0.0, cxy = 0.0
        for r in 0..<h {
            for c in 0..<w where mask[r * w + c] > 0 {
                let dx = (Double(c) + 0.5) / Double(w) - mx
                let dy = 1 - (Double(r) + 0.5) / Double(h) - my
                cxx += dx * dx
                cyy += dy * dy
                cxy += dx * dy
            }
        }
        // Angle de l'axe principal (le grand côté du papier).
        let phi = 0.5 * atan2(2 * cxy, cxx - cyy)
        let e1x = cos(phi), e1y = sin(phi)
        let e2x = -sin(phi), e2y = cos(phi)
        // Points de BORD dans le repère (u = grand axe,
        // v = petit axe).
        var us: [Double] = [], vs: [Double] = []
        for r in 0..<h {
            for c in 0..<w where mask[r * w + c] > 0 {
                let isBorder = (c == 0 || mask[r * w + c - 1] == 0)
                    || (c == w - 1 || mask[r * w + c + 1] == 0)
                    || (r == 0 || mask[(r - 1) * w + c] == 0)
                    || (r == h - 1 || mask[(r + 1) * w + c] == 0)
                guard isBorder else { continue }
                let dx = (Double(c) + 0.5) / Double(w) - mx
                let dy = 1 - (Double(r) + 0.5) / Double(h) - my
                us.append(dx * e1x + dy * e1y)
                vs.append(dx * e2x + dy * e2y)
            }
        }
        var gamma = 0.0
        if us.count >= 40,
           let umin = us.min(), let umax = us.max(),
           let vmin = vs.min(), let vmax = vs.max(),
           umax - umin > 0.05, vmax - vmin > 0.05 {
            let ur = umax - umin, vr = vmax - vmin
            // Ajuste B = α + β·A par moindres carrés ; rend β.
            func slope(_ pairs: [(a: Double, b: Double)])
            -> Double? {
                guard pairs.count >= 8 else { return nil }
                let m = Double(pairs.count)
                let ma = pairs.reduce(0) { $0 + $1.a } / m
                let mb = pairs.reduce(0) { $0 + $1.b } / m
                var num = 0.0, den = 0.0
                for p in pairs {
                    num += (p.a - ma) * (p.b - mb)
                    den += (p.a - ma) * (p.a - ma)
                }
                return den > 0 ? num / den : nil
            }
            var estimates: [Double] = []
            // Longs côtés : v en fonction de u.
            let top = zip(us, vs).filter { $0.1 > vmax - 0.15 * vr }
                .map { (a: $0.0, b: $0.1) }
            let bottom = zip(us, vs)
                .filter { $0.1 < vmin + 0.15 * vr }
                .map { (a: $0.0, b: $0.1) }
            if let b = slope(top) { estimates.append(atan(b)) }
            if let b = slope(bottom) { estimates.append(atan(b)) }
            // Courts côtés : u en fonction de v — leur
            // inclinaison donne la même déviation.
            let left = zip(us, vs).filter { $0.0 < umin + 0.15 * ur }
                .map { (a: $0.1, b: $0.0) }
            let right = zip(us, vs).filter { $0.0 > umax - 0.15 * ur }
                .map { (a: $0.1, b: $0.0) }
            if let b = slope(left) { estimates.append(atan(b)) }
            if let b = slope(right) { estimates.append(atan(b)) }
            if !estimates.isEmpty {
                gamma = estimates.reduce(0, +)
                    / Double(estimates.count)
            }
        }
        let longDeg = (phi + gamma) * 180 / .pi
        let devDeg = abs(longDeg) <= 45
            ? longDeg
            : longDeg - (longDeg > 0 ? 90 : -90)
        return CGFloat(devDeg * .pi / 180)
    }

    // MARK: - Lecture du scan (OCR précis + champs, affichage seulement)

    /// Résultat de la lecture d'un scan figé.
    struct ScanExtraction {
        var text: String
        var merchant: String
        var date: Date?
        var dateIsDefault: Bool
        var total: Double?
        var totalVerified: Bool
        var totalParts: [Double]
        var answerBoxes: [CGRect]
        var answerCrops: [CGImage] = []
        /// Boîtes des montants de la preuve (sous-total, TPS,
        /// TVQ) — surlignées en jaune, quand les réponses sont
        /// en vert (demande de Grégoire, 2026-10-20).
        var proofBoxes: [CGRect] = []
        var readUpsideDown: Bool
    }

    /// Une ligne reconnue par l'OCR, avec sa boîte (coordonnées
    /// normalisées Vision, dans le référentiel de l'image finale
    /// affichée — après retournement éventuel).
    struct RecognizedLine {
        var text: String
        var box: CGRect
    }

    /// Résultat complet d'une lecture précise : les lignes (avec
    /// boîtes), le texte joint, et si l'image a dû être retournée
    /// pour être lisible.
    struct RecognitionOutcome {
        var lines: [RecognizedLine]
        var text: String
        var upsideDown: Bool
        /// Orientation à appliquer à l'image pour la mettre
        /// dans le sens gagnant (.up = aucun changement) —
        /// couvre aussi le secours perpendiculaire (build 44).
        var correction: CGImagePropertyOrientation
    }

    /// OCR précis sur l'image finale, essayé dans les DEUX sens
    /// (droit et renversé) : chaque passage OCRise une image
    /// RÉELLEMENT pivotée (aucune ambiguïté sur les coordonnées
    /// des lignes), triées du haut vers le bas, et le sens retenu
    /// est celui qui « ressemble le plus à un reçu » : nombre de
    /// montants lisibles d'abord, score OCR ensuite. La première
    /// version (orientation confiée à Vision + score de confiance)
    /// a lu un reçu À REBOURS quand le scan restait inversé :
    /// commerce = ligne du bas, total aberrant, date par défaut
    /// (retest du 2026-10-19, 23 h 37).
    private func recognizeBestText(image: CIImage)
    -> RecognitionOutcome {
        func pass(_ candidateImage: CIImage)
        -> (lines: [RecognizedLine], score: Float, amounts: Int,
            proof: Int) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["fr-FR", "en-US"]
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(
                ciImage: candidateImage, options: [:])
            guard (try? handler.perform([request])) != nil
            else { return ([], -1, 0, 0) }
            var lines: [RecognizedLine] = []
            var score: Float = 0
            for obs in request.results ?? [] {
                guard let top = obs.topCandidates(1).first
                else { continue }
                score += top.confidence * Float(top.string.count)
                lines.append(RecognizedLine(text: top.string,
                                            box: obs.boundingBox))
            }
            lines.sort {
                let a = $0.box, b = $1.box
                if abs(a.maxY - b.maxY) > 0.01 {
                    return a.maxY > b.maxY
                }
                return a.minX < b.minX
            }
            let text = lines.map(\.text).joined(separator: "\n")
            // Un reçu lu à l'endroit contient plusieurs montants
            // lisibles ; lu à l'envers, presque aucun — c'est le
            // critère qui départage les deux sens.
            let amounts = ReceiptParser.allAmounts(text).count
            // La preuve d'addition (sous-total + TPS + TVQ =
            // total) est le signal le plus fort des deux sens :
            // un texte renversé produit des « montants » par
            // hallucination de chiffres (build 42 : 10 contre 10,
            // score même supérieur), pas une addition de taxes
            // cohérente.
            // Niveaux de preuve : 2 = structurée (forme
            // fiscale), 1 = somme nue (les articles peuvent la
            // fabriquer — journal du 2026-10-20), 0 = aucune.
            // L'arbitre compare les niveaux, pas un booléen :
            // une preuve faible ne doit pas faire retourner un
            // reçu dont l'autre sens a la vraie structure.
            let verified = ReceiptParser.parseTotalVerified(text)
            let proof = verified == nil ? 0
                : (verified!.structured ? 2 : 1)
            return (lines, Float(amounts) * 1000 + score, amounts,
                    proof)
        }
        /// Les critères de l'arbitre, dans l'ordre : preuve
        /// d'addition, nombre de montants, score.
        func isBetter(_ a: (lines: [RecognizedLine], score: Float,
                            amounts: Int, proof: Int),
                      than b: (lines: [RecognizedLine], score: Float,
                               amounts: Int, proof: Int)) -> Bool {
            if a.proof != b.proof { return a.proof > b.proof }
            if a.amounts != b.amounts { return a.amounts > b.amounts }
            return a.score > b.score
        }
        let up = pass(image)
        let down = pass(image.oriented(.down))
        // Ordre des critères (build 43) : 1) la PREUVE
        // d'addition — un seul sens peut l'avoir ; 2) le nombre
        // de montants ; 3) le score, avec la marge exigée par
        // l'audit du 2026-10-20 (retourner à tort un scan droit
        // coûte plus cher que l'inverse — plus jamais de
        // décision au point près).
        let flipped: Bool
        if down.proof != up.proof {
            flipped = down.proof > up.proof
        } else if down.amounts != up.amounts {
            flipped = down.amounts > up.amounts
        } else {
            flipped = down.score > up.score * 1.2
        }
        var winner = flipped ? down : up
        var correction: CGImagePropertyOrientation =
            flipped ? .down : .up
        var rescueNote = ""
        // Secours perpendiculaire (build 44) : si le meilleur
        // des deux sens n'a ni preuve ni montants, le juge
        // amont a pu choisir la mauvaise PAIRE d'orientations
        // (90°) — les deux sens comparés sont alors faux tous
        // les deux, et aucun retournement de 180° ne peut
        // rattraper ça : c'est le cas des scans « à l'envers »
        // récurrents de Grégoire, pleins d'erreurs de lecture.
        // On lit alors les deux sens perpendiculaires, et le
        // meilleur des quatre gagne, mêmes critères.
        if winner.proof == 0, winner.amounts < 2 {
            let sideA = pass(image.oriented(.left))
            let sideB = pass(image.oriented(.right))
            var bestResult = sideA
            var bestOrientation: CGImagePropertyOrientation = .left
            if isBetter(sideB, than: bestResult) {
                bestResult = sideB
                bestOrientation = .right
            }
            if isBetter(bestResult, than: winner) {
                winner = bestResult
                correction = bestOrientation
                rescueNote = " · secours perpendiculaire : "
                    + "\(winner.amounts) montants"
                    + proofTag(winner.proof)
            } else {
                rescueNote = " · perpendiculaires écartés"
            }
        }
        func proofTag(_ level: Int) -> String {
            level == 2 ? " + preuve"
                : level == 1 ? " + preuve faible" : ""
        }
        let verdict = correction == .down ? "renversé"
            : correction == .up ? "droit" : "pivoté"
        lastArbiterSummary = "droit : \(up.amounts) montants"
            + proofTag(up.proof)
            + ", score \(Int(up.score)) · renversé : "
            + "\(down.amounts) montants"
            + proofTag(down.proof)
            + ", score \(Int(down.score))"
            + rescueNote
            + " → \(verdict)"
        return RecognitionOutcome(
            lines: winner.lines,
            text: winner.lines.map(\.text).joined(separator: "\n"),
            upsideDown: correction == .down,
            correction: correction)
    }

    /// Lit le scan et en tire les champs affichables. Date non
    /// trouvée → 1er jour du trimestre précédent (la règle
    /// métier), signalée comme valeur par défaut. Le total est
    /// accompagné de sa preuve par addition quand elle existe
    /// (sous-total + taxes = total) — le vérificateur prévu pour
    /// l'étape 2, déjà à l'œuvre pour l'affichage.
    private func extractFields(from outcome: RecognitionOutcome)
    -> ScanExtraction {
        let text = outcome.text
        let lines = outcome.lines
        let foundDate = ReceiptParser.parseDate(text)
        // Le total vient d'abord de la PREUVE D'ADDITION
        // (ReceiptParser.parseTotalVerified — la doctrine de
        // Grégoire) ; sinon, la voie classique du parseur.
        let verifiedHit = ReceiptParser.parseTotalVerified(text)
        // Une preuve NON structurée peut être fabriquée par
        // les articles eux-mêmes (19,60 + 2,00 = le sous-total,
        // journal du 2026-10-20) : parseTotal la soumet au veto
        // de la ligne TOTAL, l'extraction fait de même — si le
        // veto donne un autre montant, c'est lui qui fait foi
        // et la « preuve » tombe.
        var proof = verifiedHit
        var plainHit: (value: Double, lineIndex: Int)?
        if let v = verifiedHit {
            if !v.structured,
               let checked = ReceiptParser.parseTotal(text),
               abs(checked.value - v.value) > 0.005 {
                proof = nil
                plainHit = checked
            }
        } else {
            plainHit = ReceiptParser.parseTotal(text)
        }
        let total = proof?.value ?? plainHit?.value
        let totalLine = proof?.lineIndex ?? plainHit?.lineIndex

        // Carrés jaunes (demande de Grégoire, 2026-10-20) : les
        // boîtes des lignes d'où viennent les TROIS réponses —
        // commerce, date, total. PAS les parties de la preuve :
        // il a demandé 3 boîtes, pas 6 ; les parties restent
        // nommées dans le texte « ✓ preuve : … » du panneau.
        var boxes: [CGRect] = []
        func addBox(lineIndex: Int?) {
            guard let lineIndex, lines.indices.contains(lineIndex)
            else { return }
            let box = lines[lineIndex].box
            if !boxes.contains(box) { boxes.append(box) }
        }
        let directoryHit = ReceiptParser.parseMerchantMatch(text)
        let merchant = directoryHit?.name
            ?? ReceiptParser.parseMerchant(text) ?? ""
        if let directoryHit {
            // Le nom canonique n'est pas le préfixe de la ligne
            // brute (« CANAC » vs « C A N A C ») : l'index de
            // ligne du parseur fait foi pour le carré jaune.
            addBox(lineIndex: directoryHit.lineIndex)
        } else if !merchant.isEmpty {
            addBox(lineIndex: lines.firstIndex {
                $0.text.trimmingCharacters(in: .whitespaces)
                    .hasPrefix(merchant)
            })
        }
        if let foundDate {
            addBox(lineIndex: lines.firstIndex {
                ReceiptParser.parseDate($0.text) == foundDate
            })
        }
        // Le carré du total doit contenir un MONTANT, jamais le
        // seul mot « TOTAL » (demande de Grégoire, 2026-10-20) :
        // quand la ligne rapportée ne porte pas le montant
        // (étiquette seule, montant lu à la ligne suivante — le
        // cas du repli mot-clé), on vise la ligne voisine qui
        // le contient.
        func amountLine(_ idx: Int?, value: Double?) -> Int? {
            guard let idx, let value else { return idx }
            func hasAmount(_ i: Int) -> Bool {
                lines.indices.contains(i)
                    && ReceiptParser.allAmounts(lines[i].text)
                        .contains { abs($0.value - value) < 0.005 }
            }
            if hasAmount(idx) { return idx }
            if hasAmount(idx + 1) { return idx + 1 }
            if hasAmount(idx - 1) { return idx - 1 }
            let near = lines.indices.filter { hasAmount($0) }
            return near.min(by: {
                abs($0 - idx) < abs($1 - idx)
            }) ?? idx
        }
        addBox(lineIndex: amountLine(totalLine, value: total))

        // Boîtes des montants de la PREUVE (sous-total, TPS,
        // TVQ — et l'article éventuel d'une preuve à 4) :
        // surlignées en jaune, à côté des réponses en vert
        // (demande de Grégoire, 2026-10-20). Les parties de la
        // preuve portent l'index de la ligne du montant même.
        var proofBoxes: [CGRect] = []
        if let proof {
            for part in proof.parts {
                if lines.indices.contains(part.lineIndex) {
                    let b = lines[part.lineIndex].box
                    if !proofBoxes.contains(b) {
                        proofBoxes.append(b)
                    }
                }
            }
        }

        return ScanExtraction(
            text: text,
            merchant: merchant,
            date: foundDate ?? QuarterHelper.previousQuarterStart(),
            dateIsDefault: foundDate == nil,
            total: total,
            totalVerified: proof != nil,
            totalParts: proof?.parts.map(\.value) ?? [],
            answerBoxes: boxes,
            proofBoxes: proofBoxes,
            readUpsideDown: outcome.upsideDown)
    }

    /// Choisit, parmi 4 rotations, celle où l'OCR reconnaît le vrai
    /// texte. Score = Σ confiance × longueur de la chaîne : le texte
    /// à l'endroit fait des mots (« PHARMACIE », « SOUS-TOTAL »),
    /// le texte renversé fait des fragments courts que l'ancien
    /// score (confiances brutes additionnées) laissait parfois
    /// gagner — scans inversés haut-en-bas au retest du 2026-10-19.
    /// Si la rotation opposée (180°) reste proche, un second
    /// passage au niveau accurate départage. Aucune extraction :
    /// seule l'orientation est déterminée.
    private func upright(_ image: CIImage) -> CIImage {
        let targetWidth: CGFloat = 720
        let k = targetWidth / image.extent.width
        let small = image.transformed(
            by: CGAffineTransform(scaleX: k, y: k))
        let orientations: [CGImagePropertyOrientation] =
            [.up, .right, .down, .left]
        func score(_ orientation: CGImagePropertyOrientation,
                   level: VNRequestTextRecognitionLevel) -> Float {
            let rotated = small.oriented(orientation)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = level
            request.recognitionLanguages = ["fr-FR", "en-US"]
            let handler = VNImageRequestHandler(ciImage: rotated,
                                                options: [:])
            guard (try? handler.perform([request])) != nil
            else { return -1 }
            var total: Float = 0
            var text = ""
            for obs in request.results ?? [] {
                if let candidate = obs.topCandidates(1).first {
                    total += candidate.confidence
                        * Float(candidate.string.count)
                    text += candidate.string + "\n"
                }
            }
            // Les montants lisibles sont le signal le plus fort
            // d'un reçu à l'endroit — même doctrine que
            // l'arbitre : un reçu pivoté à 90° n'en produit
            // presque aucun. Sans eux, le juge choisissait
            // parfois la mauvaise PAIRE d'orientations, que
            // rien ne réexaminait ensuite (audit 2026-10-20,
            // confirmé au terrain par Grégoire : scans « à
            // l'envers » et lectures dégradées).
            total += Float(ReceiptParser.allAmounts(text).count)
                * 1000
            return total
        }
        let scores = orientations.map { score($0, level: .fast) }
        var bestIdx = scores.indices.max { scores[$0] < scores[$1] } ?? 0
        if scores[bestIdx] >= 0 {
            // Réexamen en lecture précise : le meilleur ET tout
            // sens dont le score rapide atteint 60 % du sien —
            // avant, seul l'opposé à 180° avait ce droit, et un
            // mauvais choix de paire (90°) n'était jamais
            // rattrapé.
            var bestAccurate = score(orientations[bestIdx],
                                     level: .accurate)
            for idx in orientations.indices where idx != bestIdx {
                if scores[idx] >= 0,
                   scores[idx] > scores[bestIdx] * 0.6 {
                    let candidate = score(orientations[idx],
                                          level: .accurate)
                    if candidate > bestAccurate {
                        bestAccurate = candidate
                        bestIdx = idx
                    }
                }
            }
        }
        return image.oriented(orientations[bestIdx])
    }

    /// Petite touche de netteté pour la LECTURE seulement
    /// (demande de Grégoire, 2026-10-20 : « presque rien ») :
    /// 0,15 de CISharpenLuminance sur l'image soumise à l'OCR
    /// et à l'arbitre. L'affichage garde son amélioration
    /// propre ; la géométrie ne change pas.
    private func sharpenForReading(_ image: CIImage) -> CIImage {
        image.applyingFilter(
            "CISharpenLuminance",
            parameters: ["inputSharpness": 0.15])
            .cropped(to: image.extent)
    }

    // MARK: - Amélioration automatique (look « scanner »)

    /// Constantes de l'amélioration, affichées dans les statistiques
    /// pour pouvoir les régler d'après les retours de terrain.
    private let enhanceSaturation: CGFloat = 0.35
    private let enhanceSharpness: CGFloat = 0.35

    /// Amélioration TRÈS légère de l'image finale (affichage et
    /// extraits zoomés ; la lecture OCR, elle, se fait sur
    /// l'image brute redressée) :
    /// 1. niveaux automatiques doux par percentiles (5/92) ;
    /// 2. le résultat est FONDU à 45 % avec l'image d'origine —
    ///    l'effet de contraste est donc moins que la moitié de
    ///    l'étirement calculé ;
    /// 3. saturation réduite — presque gris, un soupçon de couleur
    ///    (tampons, logos) survit.
    /// Historique : la « division » (aplatissement par un fond
    /// flou) a été retirée le 2026-10-20 — même seule avec des
    /// niveaux doux, Grégoire a jugé le contraste « beaucoup
    /// trop augmenté ». Pas de courbe « encre », pas de netteté
    /// non plus.
    /// Aucune étape ne déplace un pixel : la géométrie du scan
    /// redressé est intacte (rien n'est « déformé »).
    private func enhanceDocument(_ image: CIImage)
    -> (image: CIImage, summary: String) {
        let extent = image.extent

        // Pas d'aplatissement par division : c'était LUI le gros
        // du contraste excessif (retiré le 2026-10-20). Les
        // niveaux s'appliquent directement à l'image redressée.
        let flat = image

        // 3. Niveaux DOUX (« un brin de contraste, juste un
        // peu » — Grégoire, 2026-10-19, 23 h 58, après le test
        // concluant de l'image brute) : point noir au percentile
        // 5, point blanc au percentile 92 — un étirement léger,
        // loin des ancrages agressifs qui écrasaient les blancs.
        let levels = grayPercentiles(flat, [0.05, 0.92])
        let bp = min(max(levels.first ?? 0, 0), 0.45)
        // Plancher 0,72 : si la région extraite contient peu de
        // papier, le percentile 85 tombe trop bas et tout s'écrase
        // vers le blanc (blancs « poussés à l'extrême » vus au
        // retest du 2026-10-19).
        let wp = min(max(levels.last ?? 1, max(bp + 0.25, 0.72)), 1)
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

        // 4. Fondu avec l'originale : l'étirement n'est appliqué
        // qu'à 45 % — « un brin », pour vrai cette fois. (Le
        // 2026-10-20, Grégoire a jugé la version précédente —
        // division + niveaux pleins — « beaucoup trop augmentée ».)
        var blended = leveled
        if let dissolve = CIFilter(name: "CIDissolveTransition") {
            dissolve.setValue(image, forKey: kCIInputImageKey)
            dissolve.setValue(leveled, forKey: kCIInputTargetImageKey)
            dissolve.setValue(0.45, forKey: kCIInputTimeKey)
            if let out = dissolve.outputImage {
                blended = out.cropped(to: extent)
            }
        }

        // 5. Saturation réduite. PAS d'accentuation (sharpening) :
        // retirée depuis la version légère — ses halos
        // fusionnaient les chiffres à l'OCR.
        let desaturated = blended.applyingFilter(
            "CIColorControls", parameters: [
                "inputSaturation": enhanceSaturation,
            ]).cropped(to: extent)

        let summary = String(
            format: "TRÈS LÉGÈRE : niveaux doux noir %.2f / blanc %.2f, fondus à 45 %% avec l'originale, saturation 0,35, ni division ni courbe ni netteté",
            bp, wp)
        return (desaturated, summary)
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

    // MARK: - Quadrilatères : utilitaires


    // MARK: - Nouvelle méthode : netteté et redressement fin

    /// Tampon gris 8 bits d'une image réduite, rangée 0 = HAUT
    /// de l'image : le CGImage est dessiné avec un
    /// retournement explicite, donc les coordonnées Vision
    /// (y vers le haut) se convertissent sans ambiguïté.
    private func grayBuffer(_ image: CIImage, maxWidth: CGFloat,
                            maxHeight: CGFloat = 100_000)
    -> (pixels: [UInt8], width: Int, height: Int)? {
        let normalized = image.transformed(by: CGAffineTransform(
            translationX: -image.extent.minX,
            y: -image.extent.minY))
        guard normalized.extent.width > 0,
              normalized.extent.height > 0 else { return nil }
        let k = min(1, maxWidth / normalized.extent.width,
                    maxHeight / normalized.extent.height)
        let scaled = normalized.transformed(
            by: CGAffineTransform(scaleX: k, y: k))
        let w = max(1, Int(scaled.extent.width.rounded()))
        let h = max(1, Int(scaled.extent.height.rounded()))
        guard let cg = ciContext.createCGImage(scaled,
                                               from: scaled.extent),
              let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w, space: graySpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = ctx.data
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let pixels = [UInt8](UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: UInt8.self),
            count: w * h))
        return (pixels, w, h)
    }

    /// Netteté d'une frame, mesurée SUR LES CARACTÈRES :
    /// gradient moyen dans les zones de texte de l'image
    /// réduite en gris. Flou ou bougé → contours des
    /// caractères écrasés → gradient faible. Sans zones
    /// exploitables, toute l'image sert de zone.
    private func sharpnessScore(frame: CIImage,
                                boxes: [CGRect]) -> Double {
        guard let (px, w, h) = grayBuffer(frame,
                                          maxWidth: smallSize.width),
              w > 2, h > 2 else { return 0 }
        var mask = [Bool](repeating: false, count: w * h)
        var anyMask = false
        for box in boxes {
            let x0 = max(0, Int(box.minX * CGFloat(w)) - 2)
            let x1 = min(w - 1, Int(box.maxX * CGFloat(w)) + 2)
            let yTop = max(0, Int((1 - box.maxY) * CGFloat(h)) - 2)
            let yBot = min(h - 1, Int((1 - box.minY) * CGFloat(h)) + 2)
            guard x1 > x0, yBot > yTop else { continue }
            for row in yTop...yBot {
                for col in x0...x1 { mask[row * w + col] = true }
            }
            anyMask = true
        }
        var sum = 0.0
        var count = 0
        for row in 1..<(h - 1) {
            for col in 1..<(w - 1) {
                if anyMask && !mask[row * w + col] { continue }
                let i = row * w + col
                let gx = Int(px[i + 1]) - Int(px[i - 1])
                let gy = Int(px[i + w]) - Int(px[i - w])
                sum += Double(abs(gx) + abs(gy))
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        return sum / Double(count)
    }

    /// Barre de sortie anticipée : une frame nettement plus
    /// nette que la médiane des échantillons (et au-delà d'un
    /// plancher absolu provisoire) est prise tout de suite —
    /// « la minute qu'on a une image sharp, c'est celle-là ».
    /// Le plancher sera calibré sur les scores réels que les
    /// statistiques affichent.
    private func isClearlySharp(_ score: Double) -> Bool {
        guard sampleScores.count >= 5 else { return false }
        let sortedScores = sampleScores.sorted()
        let median = sortedScores[sortedScores.count / 2]
        // Barre surtout RELATIVE : le journal a montré un scan
        // parfait à 8,5 (Best Buy, texte clairsemé) et d'autres
        // à 25 — un plancher absolu élevé retarderait les bons
        // scans sobres. 7 ne sert qu'à écarter le bruit noir.
        return score >= 7 && score >= 1.3 * median
    }

    /// Angles bruts des glyphes d'une image : pour chaque
    /// caractère détecté, la direction de son bord supérieur
    /// (radians, espace de l'image). Détection pure — aucune
    /// lecture. ATTENTION : sur un texte de côté, ces boîtes
    /// ne suivent pas la ligne et leurs angles mentent (au
    /// build 63, un reçu de côté « mesurait » −0,0°) ; elles
    /// ne disent vrai que sur un texte presque horizontal.
    private func characterAngles(_ image: CIImage) -> [CGFloat] {
        guard let cg = ciContext.createCGImage(
            image, from: image.extent) else { return [] }
        let request = VNDetectTextRectanglesRequest()
        request.reportCharacterBoxes = true
        let handler = VNImageRequestHandler(cgImage: cg,
                                            options: [:])
        guard (try? handler.perform([request])) != nil
        else { return [] }
        var angles: [CGFloat] = []
        for obs in request.results ?? [] {
            for box in obs.characterBoxes ?? [] {
                let dx = box.topRight.x - box.topLeft.x
                let dy = box.topRight.y - box.topLeft.y
                if abs(dx) > 0.002 {
                    angles.append(atan2(dy, dx))
                }
            }
        }
        return angles
    }

    /// Médiane CIRCULAIRE d'angles de glyphes : les angles
    /// sont déballés autour de leur direction moyenne avant
    /// la médiane, sinon une grappe à cheval sur ±180°
    /// (texte à l'envers) s'effondrerait vers 0. Nil si les
    /// glyphes sont trop rares (< 12) ou trop dispersés
    /// (concentration < 0,3) pour conclure.
    private func circularMedian(_ angles: [CGFloat])
    -> CGFloat? {
        guard angles.count >= 12 else { return nil }
        var sx = 0.0, sy = 0.0
        for a in angles {
            sx += cos(Double(a))
            sy += sin(Double(a))
        }
        let concentration = (sx * sx + sy * sy).squareRoot()
            / Double(angles.count)
        guard concentration >= 0.3 else { return nil }
        let mean = CGFloat(atan2(sy, sx))
        let unwrapped = angles.map { a -> CGFloat in
            var d = a - mean
            while d > .pi { d -= 2 * .pi }
            while d <= -.pi { d += 2 * .pi }
            return mean + d
        }.sorted()
        var median = unwrapped[unwrapped.count / 2]
        while median > .pi { median -= 2 * .pi }
        while median <= -.pi { median += 2 * .pi }
        return median
    }

    /// Angle du texte d'une image au texte presque
    /// horizontal (usage : amorce du redressement fin).
    private func textAngle(_ image: CIImage) -> CGFloat? {
        circularMedian(characterAngles(image))
    }

    /// Mesure du redressement à la verticale, pour l'image
    /// brute où le texte est DE CÔTÉ : on mesure dans des
    /// copies tournées d'un quart de tour — là où le texte
    /// redevient horizontal, les boîtes de glyphes disent
    /// vrai, et les deux copies horizontales (à l'endroit,
    /// à l'envers) désignent le MÊME angle du texte dans
    /// l'image. Le groupe de candidats le mieux peuplé
    /// gagne ; la rotation retenue est ensuite VÉRIFIÉE sur
    /// l'image tournée (à l'envers → demi-tour de plus ;
    /// encore de côté → on ne touche à rien). Rend la
    /// rotation à appliquer (radians, ]-π, π]) et, pour le
    /// journal, le nombre de glyphes vus par quart de tour.
    private func straightenMeasure(for frame: CIImage)
    -> (rotation: CGFloat?, counts: [Int]) {
        let scale = min(1, 1100 / max(frame.extent.width, 1))
        let small = scale < 1
            ? frame.transformed(
                by: CGAffineTransform(scaleX: scale, y: scale))
            : frame
        let betas: [CGFloat] = [0, .pi / 2, -.pi / 2, .pi]
        var counts: [Int] = []
        var candidates: [(theta: CGFloat, count: Int)] = []
        for beta in betas {
            let copy = beta == 0 ? small
                : rotateKeepingExtent(small, by: beta)
            let angles = characterAngles(copy)
            counts.append(angles.count)
            if angles.count >= 40,
               let phi = circularMedian(angles) {
                candidates.append((theta: phi - beta,
                                   count: angles.count))
            }
        }
        var winner: (theta: CGFloat, total: Int)?
        for c in candidates {
            var total = 0
            for other in candidates {
                var d = abs(other.theta - c.theta)
                    .truncatingRemainder(dividingBy: 2 * .pi)
                if d > .pi { d = 2 * .pi - d }
                if d <= 10 * .pi / 180 { total += other.count }
            }
            if winner == nil || total > winner!.total {
                winner = (c.theta, total)
            }
        }
        guard let winner else { return (nil, counts) }
        var rotation = -winner.theta
        let turned = rotateKeepingExtent(small, by: rotation)
        if let check = circularMedian(characterAngles(turned)) {
            let a = abs(check)
            if a >= 155 * .pi / 180 {
                rotation += .pi
            } else if a > 25 * .pi / 180 {
                return (nil, counts)
            }
        }
        while rotation > .pi { rotation -= 2 * .pi }
        while rotation <= -.pi { rotation += 2 * .pi }
        return (rotation, counts)
    }

    /// Rotation d'une image autour de son centre, en
    /// gardant TOUT son contenu : l'étendue résultante est
    /// celle de l'image tournée (les dimensions s'échangent
    /// à ~90°), ramenée à l'origine (0, 0).
    private func rotateKeepingExtent(_ image: CIImage,
                                     by angle: CGFloat)
    -> CIImage {
        let cx = image.extent.midX, cy = image.extent.midY
        var t = CGAffineTransform(translationX: cx, y: cy)
        t = t.rotated(by: angle)
        t = t.translatedBy(x: -cx, y: -cy)
        let r = image.transformed(by: t)
        return r.transformed(by: CGAffineTransform(
            translationX: -r.extent.minX, y: -r.extent.minY))
    }

    /// Redressement fin : rend les lignes de texte
    /// horizontales. La rotation est d'abord MESURÉE sur les
    /// glyphes (textSlopeAngle) quand c'est possible — le
    /// profil de projection horizontal (l'obscurité moyenne
    /// par rangée alterne crêtes et vallées franches quand
    /// les lignes sont horizontales) départage alors le
    /// signe de la correction et raffine au dixième de
    /// degré. Sans mesure utilisable, le profil balaye seul
    /// la plage permise. Rend l'image tournée, recadrée sur
    /// son étendue d'origine, l'angle appliqué (radians ; 0
    /// si rien de concluant) et si la mesure a guidé la
    /// recherche.
    private func deskew(_ image: CIImage, maxDegrees: CGFloat)
    -> (CIImage, CGFloat, Bool) {
        func rotated(_ img: CIImage, _ angle: CGFloat) -> CIImage {
            let cx = img.extent.midX, cy = img.extent.midY
            var t = CGAffineTransform(translationX: cx, y: cy)
            t = t.rotated(by: angle)
            t = t.translatedBy(x: -cx, y: -cy)
            let r = img.transformed(by: t)
            let target = CGRect(
                x: r.extent.midX - img.extent.width / 2,
                y: r.extent.midY - img.extent.height / 2,
                width: img.extent.width, height: img.extent.height)
            return r.cropped(to: target)
        }
        func profileScore(_ img: CIImage) -> Double {
            guard let (px, w, h) = grayBuffer(img, maxWidth: 400,
                                              maxHeight: 640),
                  h > 2 else { return 0 }
            let x0 = w / 8, x1 = w - w / 8
            guard x1 > x0 else { return 0 }
            var prev: Double?
            var score = 0.0
            for row in 0..<h {
                var sum = 0.0
                for col in x0..<x1 {
                    sum += Double(255 - px[row * w + col])
                }
                let mean = sum / Double(x1 - x0)
                if let prev {
                    let d = mean - prev
                    score += d * d
                }
                prev = mean
            }
            return score
        }
        let deg = CGFloat.pi / 180
        var bestAngle: CGFloat = 0
        var bestScore = profileScore(rotated(image, 0))
        // Centre de recherche : la mesure des glyphes, si
        // elle existe et reste une INCLINAISON (≤ 25°) ; le
        // signe de la correction est départagé au profil,
        // sans faire confiance au repère les yeux fermés.
        var centre: CGFloat = 0
        var seeded = false
        if let slope = textAngle(image),
           abs(slope) <= 25 * deg {
            let s1 = profileScore(rotated(image, -slope))
            let s2 = profileScore(rotated(image, slope))
            centre = s1 >= s2 ? -slope : slope
            seeded = true
        }
        // Balayage grossier puis raffinement autour du
        // meilleur angle ; fenêtre étroite quand la mesure
        // guide, plage entière sinon.
        let window = seeded ? 2.5 * deg : maxDegrees * deg
        let coarseStep = seeded ? 1 * deg : 2 * deg
        var a = centre - window
        while a <= centre + window + 0.001 {
            if abs(a) > 0.001 {
                let sc = profileScore(rotated(image, a))
                if sc > bestScore { bestScore = sc; bestAngle = a }
            }
            a += coarseStep
        }
        let fineStep = seeded ? 0.2 * deg : 0.4 * deg
        var b = bestAngle - 2 * deg
        while b <= bestAngle + 2 * deg + 0.001 {
            if abs(b - bestAngle) > 0.001 {
                let sc = profileScore(rotated(image, b))
                if sc > bestScore { bestScore = sc; bestAngle = b }
            }
            b += fineStep
        }
        if abs(bestAngle) < 0.3 * deg { return (image, 0, seeded) }
        return (rotated(image, bestAngle), bestAngle, seeded)
    }

    // MARK: - Journal des scans (données de contrôle sur Drive)

    /// Clé UserDefaults du dossier du journal choisi dans la
    /// vue (même chaîne que le @AppStorage de la vue).
    static let journalFolderKey = "journalFolderPath"

    /// Fichier journal : le dossier choisi par Grégoire, sinon
    /// le dossier Google Drive monté par Drive pour
    /// ordinateur (~/Library/CloudStorage/GoogleDrive-*),
    /// sinon l'ancien ~/Google Drive, sinon Application
    /// Support. Nom fixe : scanrecus-journal.txt.
    private func journalFileURL() -> URL {
        let fm = FileManager.default
        let name = "scanrecus-journal.txt"
        if let chosen = UserDefaults.standard.string(
            forKey: Self.journalFolderKey), !chosen.isEmpty {
            return URL(fileURLWithPath: chosen)
                .appendingPathComponent(name)
        }
        let cloud = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage")
        if let entries = try? fm.contentsOfDirectory(
            at: cloud, includingPropertiesForKeys: nil) {
            for entry in entries
            where entry.lastPathComponent.hasPrefix("GoogleDrive") {
                let drive = entry.appendingPathComponent("My Drive")
                if fm.fileExists(atPath: drive.path) {
                    return drive.appendingPathComponent(name)
                }
            }
        }
        let legacy = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Google Drive")
        if fm.fileExists(atPath: legacy.path) {
            return legacy.appendingPathComponent(name)
        }
        let support = fm.urls(for: .applicationSupportDirectory,
                              in: .userDomainMask)[0]
            .appendingPathComponent("ScanRecus", isDirectory: true)
        return support.appendingPathComponent(name)
    }

    /// Ajoute le compte rendu complet d'un scan au journal
    /// (demande de Grégoire, 2026-10-20 : les données de
    /// contrôle quittent l'écran et s'accumulent dans un
    /// fichier Drive que Muse lit au besoin pour analyser).
    /// Texte seulement, aucune image. Écriture silencieuse en
    /// cas d'échec : le journal ne bloque jamais un scan.
    private func appendToJournal(stats: String,
                                 extraction: ScanExtraction) {
        let url = journalFileURL()
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.locale = Locale(identifier: "fr_CA")
        var entry = "\n\n===== SCAN \(df.string(from: Date())) · "
            + "\(BuildInfo.stamp) =====\n"
        entry += stats
        if !stats.hasSuffix("\n") { entry += "\n" }
        entry += "--- Extraction ---\n"
        entry += "Commerce : \(extraction.merchant.isEmpty ? "—" : extraction.merchant)\n"
        let dfd = DateFormatter()
        dfd.dateFormat = "yyyy-MM-dd"
        if let d = extraction.date {
            entry += "Date : \(dfd.string(from: d))"
                + (extraction.dateIsDefault ? " (par défaut)" : "")
                + "\n"
        } else {
            entry += "Date : —\n"
        }
        if let t = extraction.total {
            entry += String(format: "Total : %.2f", t)
            if extraction.totalVerified {
                let parts = extraction.totalParts
                    .map { String(format: "%.2f", $0) }
                    .joined(separator: " + ")
                entry += " (prouvé : \(parts))"
            }
            entry += "\n"
        } else {
            entry += "Total : —\n"
        }
        entry += "--- Texte OCR ---\n"
        entry += extraction.text.isEmpty
            ? "(aucun texte reconnu)" : extraction.text
        entry += "\n"
        do {
            let fm = FileManager.default
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            if fm.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(entry.utf8))
            } else {
                let header = "# Journal ScanReçus — données de "
                    + "contrôle des scans, pour analyse par Muse.\n"
                try (header + entry).write(to: url, atomically: true,
                                           encoding: .utf8)
            }
        } catch {
            // Silencieux par design (voir ci-dessus).
        }
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
            if let newProgress {
                // Borné : publier un dépassement de fenêtre tel
                // quel fait rouspéter ProgressView (« out-of-
                // bounds progress value », vu par Grégoire le
                // 2026-10-20).
                self.progress = min(1, max(0, newProgress))
            }
            self.statsText = stats
        }
    }

    private func publishLivePreview() {
        guard let bestSample,
              let cg = ciContext.createCGImage(bestSample,
                                               from: bestSample.extent)
        else { return }
        DispatchQueue.main.async { [weak self] in
            self?.livePreview = cg
        }
    }

    /// Journal, version « redressement par étapes »
    /// (phase de test, 2026-10-21) : statistiques de capture
    /// et trace des étapes, sans extraction (suspendue).
    private func appendRitualToJournal(stats: String,
                                       trace: [String]) {
        let url = journalFileURL()
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.locale = Locale(identifier: "fr_CA")
        var entry = "\n\n===== SCAN \(df.string(from: Date())) · "
            + "\(BuildInfo.stamp) =====\n"
        entry += stats
        if !stats.hasSuffix("\n") { entry += "\n" }
        entry += "--- Redressement par étapes "
            + "(phase de test) ---\n"
        entry += trace.joined(separator: "\n") + "\n"
        entry += "Analyse suspendue après le redressement.\n"
        do {
            let fm = FileManager.default
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            if fm.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(entry.utf8))
            } else {
                let header = "# Journal ScanReçus — données de "
                    + "contrôle des scans, pour analyse par Muse.\n"
                try (header + entry).write(to: url, atomically: true,
                                           encoding: .utf8)
            }
        } catch {
            // Silencieux par design (comme appendToJournal).
        }
    }

    private func buildStats() -> String {
        var text = ""
        if fullSize != .zero {
            text += String(format: "Caméra : %.0f × %.0f\n",
                           fullSize.width, fullSize.height)
        }
        text += "Images traitées : \(framesSeen)\n"
            + "Zones de texte (dernière image) : \(lastTextCount)  •  stabilité scène : \(sceneStableCount)/\(stableFramesNeeded)\n"
        if preferredTextOrientation != .up {
            text += "Détection du texte : pivotée à 90° (reçu de côté)\n"
        }
        if let finishInfo {
            text += "\n" + finishInfo
        }
        return text
    }

    // MARK: - Maths (homographies, conventions maison)

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

}
