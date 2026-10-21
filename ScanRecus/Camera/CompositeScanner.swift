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
    private func bestTextBoxes(in image: CIImage) -> [CGRect] {
        var order: [CGImagePropertyOrientation] = [scanTextOrientation]
        for o in [CGImagePropertyOrientation.up, .right, .left]
        where o != scanTextOrientation {
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
            if let frozen { self.livePreview = frozen }
        }

        // Le reçu est localisé dans l'image retenue — une
        // image fixe, où la détection est bien plus fiable que
        // sur le flux vivant — puis redressé et lu. Pendant le
        // scan, aucune boîte n'a rien décidé.
        let t0 = CFAbsoluteTimeGetCurrent()
        // Source de l'extraction, dite honnêtement dans le
        // récap : le composite par homographies s'il a réellement
        // fusionné des vues ; sinon la moyenne recalée du chemin
        // stable, moins bruitée qu'une image seule ; sinon le
        // composite, qui ne contient que la référence.
        // NOUVELLE MÉTHODE (build 48, demande de Grégoire) :
        // la source est L'IMAGE UNIQUE LA PLUS NETTE des
        // échantillons — plus de fusion, plus de moyenne, plus
        // de composite. L'extraction travaille sur elle comme
        // avant sur le composite : localisation par les bords
        // blancs du papier, aplatissement par ses coins.
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
        var (extracted, how) = extractReceipt(from: sample)
        let tLoc = CFAbsoluteTimeGetCurrent()
        var image = extracted
        // Ramener l'origine à (0, 0) pour la suite.
        image = image.transformed(by: CGAffineTransform(
            translationX: -image.extent.minX, y: -image.extent.minY))
        // Orientation : tourner pour que les caractères soient à l'endroit.
        image = upright(image)
        let tUpright = CFAbsoluteTimeGetCurrent()
        // Redressement fin (nouvelle méthode) : la rotation
        // exacte qui rend les lignes horizontales — le reçu de
        // côté et un peu croche demande par exemple 75°, pas
        // un multiple de 90°.
        let (deskewedImage, skewAngle) = deskew(
            image, maxDegrees: how.contains("rectangle") ? 3 : 8)
        image = deskewedImage
        if abs(skewAngle) >= 0.3 * .pi / 180 {
            how += String(format: " · redressement fin : %+.1f°",
                          Double(skewAngle) * 180 / .pi)
        }
        let tOrient = CFAbsoluteTimeGetCurrent()
        // Arbitre d'orientation (demande de Grégoire, 2026-10-20 :
        // le scan final DOIT s'afficher dans un sens qui fait du
        // sens à l'œil humain) : la lecture précise dans les deux
        // sens — celle qui sert à l'extraction — décide aussi de
        // l'affichage. Si le texte se lit mieux à l'envers, on
        // retourne l'image pour de vrai avant tout le reste.
        let outcome = recognizeBestText(
            image: sharpenForReading(image))
        let tRead = CFAbsoluteTimeGetCurrent()
        if outcome.correction != .up {
            image = image.oriented(outcome.correction)
        }
        // Amélioration automatique LÉGÈRE : le test « image
        // brute » (2026-10-19, 23 h 41) a donné de bonnes
        // lectures, et Grégoire a ensuite demandé « un brin de
        // contraste, juste un peu » (23 h 58) — enhanceDocument
        // est réglée douce (voir plus bas) et c'est elle qui est
        // affichée et lue ; la brute reste publiée pour comparer.
        let rawCG = ciContext.createCGImage(image, from: image.extent)
        let enhanced = enhanceDocument(image)
        let finalCG = ciContext.createCGImage(enhanced.image,
                                              from: enhanced.image.extent)
        let tEnh = CFAbsoluteTimeGetCurrent()
        let timing = "localisation \(String(format: "%.2f", tLoc - t0)) s"
            + " · orientation \(String(format: "%.2f", tUpright - tLoc)) s"
            + " · redressement fin \(String(format: "%.2f", tOrient - tUpright)) s"
            + " · lecture \(String(format: "%.2f", tRead - tOrient)) s"
            + " · amélioration \(String(format: "%.2f", tEnh - tRead)) s"
        finishInfo = "Image finale : \(sourceHow)\nReçu localisé : \(how)"
            + "\nScan final : \(Int(image.extent.width)) × \(Int(image.extent.height)) px"
            + "\nAmélioration auto : \(enhanced.summary)"
            + "\nAnalyse : \(timing)"
            + "\nOrientation : \(lastArbiterSummary)"

        // Lecture du scan figé (première brique de l'étape 2,
        // demandée par Grégoire le 2026-10-19 : « voir les
        // informations que le programme peut extraire ») : OCR
        // précis dans les deux sens + champs extraits par
        // ReceiptParser. Affichage seulement — rien en base.
        var extraction = extractFields(from: outcome)
        // Extraits des régions encadrées en jaune, découpés dans
        // le scan final : la vue les ressort en encadrés zoomés
        // à côté de l'image (demande de Grégoire, 2026-10-20).
        // (finalCG est optionnel : le déballer avant de mesurer —
        // erreur CI du 2026-10-20.)
        if let finalCG {
            let fw = CGFloat(finalCG.width)
            let fh = CGFloat(finalCG.height)
            extraction.answerCrops = extraction.answerBoxes.map { box in
                let rect = CGRect(
                    x: box.minX * fw,
                    y: (1 - box.maxY) * fh,
                    width: box.width * fw,
                    height: box.height * fh).integral
                    .intersection(CGRect(x: 0, y: 0,
                                         width: fw, height: fh))
                return finalCG.cropping(to: rect) ?? finalCG
            }
        }
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
    private func extractReceipt(from composite: CIImage)
    -> (image: CIImage, how: String) {
        let extent = composite.extent
        let textBoxes = bestTextBoxes(in: composite)
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
            proven: Bool) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["fr-FR", "en-US"]
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(
                ciImage: candidateImage, options: [:])
            guard (try? handler.perform([request])) != nil
            else { return ([], -1, 0, false) }
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
            let proven = ReceiptParser.parseTotalVerified(text) != nil
            return (lines, Float(amounts) * 1000 + score, amounts,
                    proven)
        }
        /// Les critères de l'arbitre, dans l'ordre : preuve
        /// d'addition, nombre de montants, score.
        func isBetter(_ a: (lines: [RecognizedLine], score: Float,
                            amounts: Int, proven: Bool),
                      than b: (lines: [RecognizedLine], score: Float,
                               amounts: Int, proven: Bool)) -> Bool {
            if a.proven != b.proven { return a.proven }
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
        if down.proven != up.proven {
            flipped = down.proven
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
        if !winner.proven, winner.amounts < 2 {
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
                    + (winner.proven ? " + preuve" : "")
            } else {
                rescueNote = " · perpendiculaires écartés"
            }
        }
        let verdict = correction == .down ? "renversé"
            : correction == .up ? "droit" : "pivoté"
        lastArbiterSummary = "droit : \(up.amounts) montants"
            + (up.proven ? " + preuve" : "")
            + ", score \(Int(up.score)) · renversé : "
            + "\(down.amounts) montants"
            + (down.proven ? " + preuve" : "")
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
        let plainHit = verifiedHit == nil
            ? ReceiptParser.parseTotal(text) : nil
        let total = verifiedHit?.value ?? plainHit?.value
        let totalLine = verifiedHit?.lineIndex ?? plainHit?.lineIndex

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

        return ScanExtraction(
            text: text,
            merchant: merchant,
            date: foundDate ?? QuarterHelper.previousQuarterStart(),
            dateIsDefault: foundDate == nil,
            total: total,
            totalVerified: verifiedHit != nil,
            totalParts: verifiedHit?.parts.map(\.value) ?? [],
            answerBoxes: boxes,
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

    /// Redressement fin : cherche (pas de 1°, puis 0,2°) la
    /// rotation qui maximise la structure du profil de
    /// projection horizontal — quand les lignes de texte sont
    /// horizontales, l'obscurité moyenne par rangée alterne
    /// crêtes (texte) et vallées (blanc) franches. Rend
    /// l'image tournée, recadrée sur son étendue d'origine,
    /// et l'angle appliqué (radians ; 0 si rien de concluant).
    private func deskew(_ image: CIImage, maxDegrees: CGFloat)
    -> (CIImage, CGFloat) {
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
        // Balayage grossier à 2°, raffinement à 0,4° sur
        // ± 2° : ~20 évaluations au lieu de 44 (build 53 — le
        // redressement fin était le poste le plus lent de
        // l'analyse, jusqu'à ~1 s sur les grands reçus).
        let limit = maxDegrees * deg
        var a: CGFloat = -limit
        while a <= limit + 0.001 {
            if abs(a) > 0.001 {
                let sc = profileScore(rotated(image, a))
                if sc > bestScore { bestScore = sc; bestAngle = a }
            }
            a += 2 * deg
        }
        var b = bestAngle - 2 * deg
        while b <= bestAngle + 2 * deg + 0.001 {
            if abs(b - bestAngle) > 0.001 {
                let sc = profileScore(rotated(image, b))
                if sc > bestScore { bestScore = sc; bestAngle = b }
            }
            b += 0.4 * deg
        }
        if abs(bestAngle) < 0.3 * deg { return (image, 0) }
        return (rotated(image, bestAngle), bestAngle)
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
