import AppKit
import AVFoundation
import CoreImage
import SwiftUI
import Vision

/// NOUVEAU SCANNER (build 158, 2026-10-30) — le premier onglet
/// devient une capture SIMPLE, selon le design de Grégoire :
/// une bonne photo → redressement au bouton rotatif → crop
/// rectangulaire aux ciseaux → « Next » téléverse le JPEG
/// (croppé, compressé, numéroté AAAAMMJJ.NNNN) dans la boîte
/// de l'app Gestion. Le traceur et le jeu du lasso sont mis
/// de côté ; le scanner composite continue de servir les
/// autres sections, inchangées.
///
/// BUILD 160 (2026-10-30) : le cadrage (les « ciseaux ») n'est
/// plus un MODE à activer — Grégoire ne trouvait pas la paire
/// de ciseaux. Dès que la photo est prise, le cadre jaune et
/// ses 8 poignées sont là, actifs, avec l'indication à
/// l'écran ; le bouton bascule devient « ✂ Cadre plein »
/// (remettre le cadre à toute la photo).
///
/// BUILD 159 (2026-10-30) : la DÉTECTION AUTOMATIQUE revient.
/// Grégoire tient le reçu à deux mains — impossible de peser
/// sur le déclencheur. Le capteur d'image fixe juge donc
/// chaque image au critère éprouvé du scanner composite
/// (papier + texte + disposition stable, logique pure :
/// ReceiptAutoTrigger) et photographie tout seul dès que la
/// scène est stable. Le bouton déclencheur reste, pour les
/// fois où une main est libre ; la détection se désactive
/// par un interrupteur du panneau (persisté).

// MARK: - Routeur de frames

/// Aiguille les images de la caméra : vers le scanner
/// composite dans les sections héritées (comportement
/// d'origine, inchangé), vers le capteur d'image fixe dans la
/// section Scanner. CameraManager ne retient pas son délégué :
/// c'est la vue qui retient le routeur, qui ne tient les deux
/// consommateurs que faiblement.
final class FrameRouter: NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate {

    weak var legacy: CompositeScanner?
    weak var grabber: StillFrameGrabber?
    /// Vrai dans la section Scanner (nouveau flux).
    var receiptMode = true

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if receiptMode {
            grabber?.captureOutput(output,
                                   didOutput: sampleBuffer,
                                   from: connection)
        } else {
            legacy?.captureOutput(output,
                                  didOutput: sampleBuffer,
                                  from: connection)
        }
    }
}

// MARK: - Capteur d'image fixe

/// Reçoit le flux vidéo et garde la dernière image convertie
/// en CGImage : le « déclencheur » la photographie telle
/// quelle. UNE image fixe, nette autant que la caméra sait
/// l'être à son meilleur format — pas de composite.
/// Conversion étranglée (~8/s) : photographier ne doit pas
/// coûter un flux plein cadre en continu.
///
/// DÉTECTION AUTOMATIQUE (build 159) : quand elle est armée
/// (phase capture, interrupteur ouvert), chaque image
/// convertie est aussi jugée — zones de texte Vision (le
/// reçu peut être présenté de côté : les orientations
/// pivotées sont essayées, comme au scanner composite) et
/// clarté du papier — puis soumise au déclencheur pur
/// (ReceiptAutoTrigger). Au tir, `onAutoTrigger` part sur le
/// thread principal ; les changements de verdict partent par
/// `onAutoStatus`, seulement quand le texte change.
final class StillFrameGrabber: NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable {

    private let lock = NSLock()
    private var latest: CGImage?
    /// Lu/écrit seulement sur la file des frames (série).
    private var lastConvert = Date.distantPast
    private let ciContext = CIContext(
        options: [.useSoftwareRenderer: false])
    private let graySpace = CGColorSpaceCreateDeviceGray()

    // Détection auto : état lu/écrit sous le verrou, sauf le
    // déclencheur et l'orientation préférée, qui ne vivent
    // que sur la file des frames.
    private var armedFlag = false
    private var resetPending = false
    private var trigger = ReceiptAutoTrigger()
    private var preferredOrientation:
        CGImagePropertyOrientation = .up
    private var lastStatusSent: String?

    /// Posés une fois par la session (thread principal).
    var onAutoTrigger: (() -> Void)?
    var onAutoStatus: ((String) -> Void)?

    /// La détection juge les images quand vrai. Faux pendant
    /// l'ajustement : aucun calcul Vision ne brûle pour rien.
    var armed: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return armedFlag
        }
        set {
            lock.lock()
            armedFlag = newValue
            lock.unlock()
        }
    }

    /// Réarme le déclencheur (oublie disposition, compte et
    /// verrou de tir) à la prochaine image — le reset lui-même
    /// se fait sur la file des frames, là où vit le déclencheur.
    func rearmAuto() {
        lock.lock()
        resetPending = true
        lock.unlock()
    }

    var hasFrame: Bool {
        lock.lock()
        defer { lock.unlock() }
        return latest != nil
    }

    /// La dernière image reçue — celle que le déclencheur prend.
    func snapshot() -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastConvert) > 0.12,
              let buffer = CMSampleBufferGetImageBuffer(
                sampleBuffer)
        else { return }
        lastConvert = now
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cg = ciContext.createCGImage(
            image, from: image.extent) else { return }
        lock.lock()
        latest = cg
        let isArmed = armedFlag
        let doReset = resetPending
        resetPending = false
        lock.unlock()
        guard isArmed else { return }
        if doReset {
            trigger.reset()
            lastStatusSent = nil
        }
        runAutoDetection(buffer: buffer, frame: image)
    }

    // MARK: - Détection automatique (file des frames)

    /// Juge l'image courante : texte + clarté → déclencheur.
    /// Au tir, la session est prévenue sur le thread principal
    /// (elle photographiera l'image gardée, qui est celle-ci
    /// ou la suivante — la scène est stable par construction).
    private func runAutoDetection(buffer: CVPixelBuffer,
                                  frame: CIImage) {
        let boxes = detectEvidenceBoxes(buffer: buffer,
                                        frame: frame)
        let bright = grayPercentile65(frame)
        if trigger.evaluate(boxes: boxes, brightness: bright) {
            DispatchQueue.main.async { [weak self] in
                self?.onAutoTrigger?()
            }
            return
        }
        let message: String
        switch trigger.reading {
        case .noEvidence(let n):
            message = n == 0
                ? "Présentez un reçu à la caméra…"
                : "Du texte est visible, mais pas assez de "
                    + "papier blanc — approchez le reçu…"
        case .unstable:
            message = "Papier et texte détectés — tenez le "
                + "reçu tranquille…"
        case .stabilizing(let count, let needed):
            message = "Papier et texte détectés — "
                + "stabilisez… (\(count)/\(needed))"
        }
        guard message != lastStatusSent else { return }
        lastStatusSent = message
        DispatchQueue.main.async { [weak self] in
            self?.onAutoStatus?(message)
        }
    }

    /// Zones de texte pour la preuve : l'orientation préférée
    /// d'abord, puis les autres ; la première à ≥ 5 boîtes
    /// gagne et devient la préférée (un reçu présenté DE CÔTÉ
    /// rend le détecteur presque aveugle sur l'image telle
    /// quelle — repris du scanner composite).
    private func detectEvidenceBoxes(buffer: CVPixelBuffer,
                                     frame: CIImage) -> [CGRect] {
        var order: [CGImagePropertyOrientation] =
            [preferredOrientation]
        for o in [CGImagePropertyOrientation.up, .right, .left]
        where o != preferredOrientation {
            order.append(o)
        }
        var best: [CGRect] = []
        for o in order {
            let boxes = o == .up
                ? detectTextBoxes(buffer: buffer)
                : detectTextBoxes(frame: frame, orientation: o)
            if boxes.count > best.count { best = boxes }
            if boxes.count >= 5 {
                preferredOrientation = o
                return boxes
            }
        }
        return best
    }

    /// Zones de texte détectées par Vision (boîtes
    /// normalisées) — détection seule, aucune lecture.
    private func detectTextBoxes(buffer: CVPixelBuffer)
    -> [CGRect] {
        let request = VNDetectTextRectanglesRequest()
        request.reportCharacterBoxes = false
        let handler = VNImageRequestHandler(
            cvPixelBuffer: buffer, options: [:])
        guard (try? handler.perform([request])) != nil
        else { return [] }
        return (request.results ?? []).map { $0.boundingBox }
    }

    /// Boîtes de texte d'une image pivotée de 90°, ramenées
    /// dans l'espace normalisé de l'image d'origine (les axes
    /// s'échangent — formules de transposition EXIF, reprises
    /// du scanner composite).
    private func detectTextBoxes(
        frame: CIImage,
        orientation: CGImagePropertyOrientation) -> [CGRect] {
        let request = VNDetectTextRectanglesRequest()
        request.reportCharacterBoxes = false
        let handler = VNImageRequestHandler(
            ciImage: frame.oriented(orientation), options: [:])
        guard (try? handler.perform([request])) != nil
        else { return [] }
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

    /// Percentile 65 de gris de l'image, sur un rendu réduit
    /// (≤ 240 px de grand côté) — la « grande surface claire »
    /// du critère papier (repris du scanner composite).
    private func grayPercentile65(_ image: CIImage) -> CGFloat {
        let longest = max(image.extent.width, image.extent.height)
        guard longest > 0 else { return 0 }
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
        let target = 0.65 * Double(buf.count)
        var acc = 0.0
        for i in 0..<256 {
            acc += Double(hist[i])
            if acc >= target { return CGFloat(i) / 255 }
        }
        return 1
    }
}

// MARK: - Session du nouveau scanner

/// État et gestes du nouveau Scanner : capture, ajustement
/// (angle + crop), envoi numéroté via la file d'envoi.
@Observable
final class ReceiptScanSession {

    enum Phase { case capture, adjust }

    private(set) var phase: Phase = .capture
    private(set) var photo: CGImage?
    /// Angle du bouton rotatif, degrés interface, continu.
    var angleDegrees: Double = 0
    /// Crop normalisé dans le repère de la photo redressée.
    /// Le cadrage est TOUJOURS actif (build 160) : pas de mode.
    var cropNormalized = CGRect(x: 0, y: 0, width: 1, height: 1)
    var statusMessage =
        "Présentez un reçu devant la caméra, puis déclenchez."
    private(set) var outboxCount = 0
    private(set) var isFlushing = false

    /// Détection automatique (build 159) : l'interrupteur du
    /// panneau, persisté sur ce Mac. À l'ouverture, le capteur
    /// photographie tout seul dès qu'un reçu stable est là ;
    /// à la fermeture, seul le bouton déclencheur photographie.
    var autoDetectionEnabled = true {
        didSet {
            UserDefaults.standard.set(
                autoDetectionEnabled,
                forKey: "receiptAutoDetection")
            applyAutoArming()
        }
    }

    let grabber = StillFrameGrabber()
    let outbox = ReceiptOutbox()
    let brutOutbox = ReceiptBrutOutbox()

    init() {
        autoDetectionEnabled = UserDefaults.standard.object(
            forKey: "receiptAutoDetection") as? Bool ?? true
        refreshOutboxCount()
        grabber.onAutoTrigger = { [weak self] in
            self?.autoShutter()
        }
        grabber.onAutoStatus = { [weak self] message in
            guard let self, self.phase == .capture else { return }
            self.statusMessage = message
        }
        // L'affectation d'init ne passe pas par didSet :
        // armer explicitement si l'interrupteur est ouvert.
        grabber.armed = autoDetectionEnabled
        if autoDetectionEnabled {
            statusMessage = "Présentez un reçu : il se "
                + "photographiera tout seul dès qu'il sera stable."
        }
    }

    /// Ouverture/fermeture de la détection selon
    /// l'interrupteur et la phase : armée seulement en
    /// capture, toujours réarmée à zéro quand elle s'arme.
    private func applyAutoArming() {
        if autoDetectionEnabled && phase == .capture {
            grabber.rearmAuto()
            grabber.armed = true
            statusMessage = "Présentez un reçu : il se "
                + "photographiera tout seul dès qu'il sera stable."
        } else {
            grabber.armed = false
            if phase == .capture {
                statusMessage = "Présentez un reçu devant la "
                    + "caméra, puis déclenchez."
            }
        }
    }

    /// Tir automatique : même geste que le bouton, venu du
    /// capteur. Ignoré hors phase capture (un tir en vol
    /// pendant l'ajustement ne doit rien photographier).
    func autoShutter() {
        guard phase == .capture, autoDetectionEnabled else {
            return
        }
        shutter()
    }

    /// Déclencheur : photographie l'image courante de la caméra.
    func shutter() {
        guard let frame = grabber.snapshot() else {
            statusMessage = "La caméra n'a pas encore d'image "
                + "— un petit instant…"
            return
        }
        grabber.armed = false
        photo = frame
        angleDegrees = 0
        cropNormalized = CGRect(x: 0, y: 0, width: 1, height: 1)
        phase = .adjust
        statusMessage = "Photo prise ✓ — redressez au bouton "
            + "rotatif, tirez les poignées jaunes ✂ pour "
            + "cadrer, puis « Next »."
    }

    /// « ✂ Cadre plein » : le cadre de cadrage revient à
    /// toute la photo (annule un cadrage raté sans reprendre
    /// la photo).
    func resetCrop() {
        cropNormalized = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    /// « Reprendre la photo » : jette l'image courante et
    /// réarme la détection (le prochain reçu repart de zéro).
    func retake() {
        photo = nil
        phase = .capture
        statusMessage = "Présentez un reçu devant la caméra, "
            + "puis déclenchez."
        applyAutoArming()
    }

    /// « Next » : rend le JPEG (rotation + crop + compression),
    /// lui assigne son numéro, le dépose dans la file d'envoi
    /// (sûreté d'abord), réarme le scanner, puis tente l'envoi.
    /// Sans jeton : message clair, rien n'est consommé ni envoyé.
    @MainActor
    func next(token: String) async {
        guard let photo else { return }
        let token = token.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            statusMessage = "⚠️ Jeton d'envoi manquant : ouvrez "
                + "« Réglages d'envoi » dans le panneau du bas "
                + "et collez le jeton — rien n'a été envoyé."
            return
        }
        guard let jpeg = ReceiptPhotoRenderer.renderJPEG(
            photo: photo, uiDegrees: angleDegrees,
            cropNormalized: cropNormalized) else {
            statusMessage = "⚠️ Le rendu de la photo a échoué "
                + "— reprenez la photo."
            return
        }
        let numero = ReceiptNumbering.next()
        do {
            try outbox.enqueue(jpeg: jpeg, numero: numero)
        } catch {
            statusMessage = "⚠️ Impossible de garder le reçu "
                + "\(numero) dans la file d'envoi : "
                + error.localizedDescription
            return
        }
        // La photo brute + le « chemin » (angle + cadre) pour
        // la banque d'entraînement : au mieux — un échec ici
        // ne doit jamais coûter le reçu, déjà en sûreté.
        if let brut = ReceiptPhotoRenderer.renderRawJPEG(
            photo: photo) {
            try? brutOutbox.enqueue(
                jpeg: brut, numero: numero,
                angleDegrees: angleDegrees, crop: cropNormalized)
        }
        refreshOutboxCount()
        self.photo = nil
        phase = .capture
        let sent = await flush(token: token)
        statusMessage = sent.contains(numero)
            ? "Reçu \(numero) envoyé ✓"
            : "Reçu \(numero) gardé dans la file d'envoi — "
                + "l'envoi reprendra tout seul dès que le "
                + "réseau ou le serveur répondra."
        // Réarmer la détection, mais pas tout de suite : le
        // message de confirmation doit rester lisible un
        // moment avant que la chasse au prochain reçu
        // reprenne ses propres messages.
        if autoDetectionEnabled {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 2.5) { [weak self] in
                guard let self, self.phase == .capture
                else { return }
                self.applyAutoArming()
            }
        }
    }

    /// Tente de vider la file d'envoi (au lancement, à chaque
    /// Next, au bouton « Réessayer »). Retourne les numéros partis.
    @MainActor
    @discardableResult
    func flush(token: String) async -> [String] {
        let token = token.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !token.isEmpty, !isFlushing else { return [] }
        isFlushing = true
        defer {
            isFlushing = false
            refreshOutboxCount()
        }
        let sent = await outbox.flush(
            send: ReceiptUploader.sender(token: token))
        // Les bruts d'entraînement suivent, au mieux : leur
        // sort ne change rien au verdict des reçus.
        _ = await brutOutbox.flush(
            send: ReceiptUploader.brutSender(token: token))
        return sent
    }

    /// Le bouton « Réessayer l'envoi » du panneau : il dit
    /// TOUJOURS son verdict — un réessai muet a déjà coûté un
    /// aller-retour de débogage (2026-10-30).
    @MainActor
    func retryFlush(token: String) async {
        let avant = outboxCount
        let sent = await flush(token: token)
        if !sent.isEmpty {
            statusMessage = outboxCount == 0
                ? "File d'envoi vidée ✓ (\(sent.count) reçu(s) parti(s))"
                : "\(sent.count) reçu(s) envoyé(s) — il en "
                    + "reste \(outboxCount) dans la file."
        } else if avant > 0 {
            statusMessage = token.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty
                ? "⚠️ Aucun envoi : le jeton est manquant "
                    + "(voir « Réglages d'envoi »)."
                : "⚠️ L'envoi a échoué — jeton refusé ou "
                    + "réseau muet. Le reçu reste dans la file."
        }
    }

    func refreshOutboxCount() {
        outboxCount = outbox.count
    }
}

// MARK: - Scène (zone du haut)

/// La zone d'image du nouveau Scanner. En capture, elle est
/// transparente : l'aperçu caméra partagé (toujours dans la
/// hiérarchie, sous la scène) montre le flux, la scène ne pose
/// que le déclencheur. En ajustement, elle montre la photo,
/// la grille guide, le crop et le bouton rotatif.
struct ReceiptScannerStage: View {
    @Bindable var session: ReceiptScanSession
    var containerSize: CGSize
    @AppStorage("receiptUploadToken") private var uploadToken = ""

    @State private var dragStartCrop: CGRect?
    @State private var dragStartPoint: CGPoint?

    var body: some View {
        ZStack {
            if session.phase == .adjust, let photo = session.photo {
                adjustContent(photo: photo)
            } else {
                captureContent
            }
        }
        .frame(width: containerSize.width,
               height: containerSize.height)
        .coordinateSpace(name: "receiptStage")
    }

    // Capture : l'état de la détection en haut (visible
    // pendant qu'il tient le reçu à deux mains — « stabilisez…
    // (2/3) » lui dit où en est le compte), le déclencheur
    // manuel en bas, par-dessus l'aperçu partagé.
    private var captureContent: some View {
        ZStack {
            VStack {
                HStack {
                    Text(session.statusMessage)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.55))
                        .cornerRadius(8)
                    Spacer()
                }
                Spacer()
            }
            .padding(12)
            VStack {
                Spacer()
                Button {
                    session.shutter()
                } label: {
                    ZStack {
                        Circle()
                            .stroke(Color.white, lineWidth: 4)
                            .frame(width: 76, height: 76)
                        Circle()
                            .fill(Color.white)
                            .frame(width: 60, height: 60)
                    }
                    .shadow(color: .black.opacity(0.5), radius: 4)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 26)
            }
        }
        .frame(width: containerSize.width,
               height: containerSize.height)
    }

    // Ajustement : photo redressée, grille, crop, bouton, barre.
    private func adjustContent(photo: CGImage) -> some View {
        let imageSize = CGSize(width: photo.width,
                               height: photo.height)
        let bounds = ReceiptGeometry.rotatedBoundingSize(
            imageSize, degrees: session.angleDegrees)
        let fit = ReceiptGeometry.aspectFitRect(
            content: bounds, container: containerSize)
        let scale = bounds.width > 0 ? fit.width / bounds.width : 1
        return ZStack {
            Color.black
            Image(photo, scale: 1, label: Text("Photo du reçu"))
                .resizable()
                .frame(width: imageSize.width * scale,
                       height: imageSize.height * scale)
                .position(x: fit.midX, y: fit.midY)
                .rotationEffect(.degrees(session.angleDegrees))
            gridOverlay(fit: fit)
            cropOverlay(fit: fit)
            // L'indication du cadrage, en haut à gauche —
            // les ciseaux se voient et se nomment (build 160).
            VStack {
                HStack {
                    Text("✂ Cadrage : tirez les poignées "
                        + "jaunes du cadre")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.55))
                        .cornerRadius(8)
                    Spacer()
                }
                Spacer()
            }
            .padding(12)
            .allowsHitTesting(false)
            // Le bouton rotatif, en bas à droite de la photo.
            RotaryKnobView(angle: $session.angleDegrees)
                .position(x: containerSize.width - 96,
                          y: containerSize.height - 128)
            // La barre d'actions, en bas.
            VStack {
                Spacer()
                HStack(spacing: 12) {
                    Button("Reprendre la photo") {
                        session.retake()
                    }
                    .controlSize(.large)
                    Button("✂ Cadre plein") {
                        session.resetCrop()
                    }
                    .controlSize(.large)
                    Spacer()
                    Button("Next ✓") {
                        Task { await session.next(token: uploadToken) }
                    }
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [])
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
    }

    /// Grille guide mince, FIXE à l'écran (elle ne tourne pas
    /// avec la photo) : c'est contre ses lignes qu'on aligne
    /// le texte du reçu.
    private func gridOverlay(fit: CGRect) -> some View {
        Canvas { context, _ in
            let steps = 6
            var lines = Path()
            for i in 1..<steps {
                let x = fit.minX + fit.width * CGFloat(i)
                    / CGFloat(steps)
                lines.move(to: CGPoint(x: x, y: fit.minY))
                lines.addLine(to: CGPoint(x: x, y: fit.maxY))
                let y = fit.minY + fit.height * CGFloat(i)
                    / CGFloat(steps)
                lines.move(to: CGPoint(x: fit.minX, y: y))
                lines.addLine(to: CGPoint(x: fit.maxX, y: y))
            }
            context.stroke(lines,
                           with: .color(.white.opacity(0.25)),
                           lineWidth: 0.75)
            var cross = Path()
            cross.move(to: CGPoint(x: fit.midX, y: fit.minY))
            cross.addLine(to: CGPoint(x: fit.midX, y: fit.maxY))
            cross.move(to: CGPoint(x: fit.minX, y: fit.midY))
            cross.addLine(to: CGPoint(x: fit.maxX, y: fit.midY))
            context.stroke(cross,
                           with: .color(.white.opacity(0.45)),
                           lineWidth: 0.75)
            context.stroke(Path(fit),
                           with: .color(.white.opacity(0.45)),
                           lineWidth: 0.75)
        }
        .frame(width: containerSize.width,
               height: containerSize.height)
        .allowsHitTesting(false)
    }

    // Le crop : assombrissement extérieur, bordure, surface
    // de déplacement et les 8 poignées — TOUJOURS actifs
    // (build 160 : plus de mode ciseaux à ouvrir).
    private func cropOverlay(fit: CGRect) -> some View {
        let crop = ReceiptGeometry.clampCrop(session.cropNormalized)
        let rect = CGRect(
            x: fit.minX + crop.minX * fit.width,
            y: fit.minY + crop.minY * fit.height,
            width: crop.width * fit.width,
            height: crop.height * fit.height)
        return ZStack {
            Path { path in
                path.addRect(CGRect(origin: .zero,
                                    size: containerSize))
                path.addRect(rect)
            }
            .fill(Color.black.opacity(0.45),
                  style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            Rectangle()
                .path(in: rect)
                .stroke(Color.yellow, lineWidth: 2)
                .allowsHitTesting(false)
            Color.white.opacity(0.001)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .gesture(handleDrag(.interior, fit: fit))
            ForEach(CropHandle.allCases, id: \.self) { handle in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.yellow)
                    .frame(width: 20, height: 20)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.black, lineWidth: 1))
                    .position(handlePoint(handle, in: rect))
                    .gesture(handleDrag(handle, fit: fit))
            }
        }
    }

    private func handlePoint(_ handle: CropHandle,
                             in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        case .interior: return CGPoint(x: rect.midX, y: rect.midY)
        }
    }

    /// Drag d'une poignée (ou de l'intérieur) : tout part de
    /// l'instantané du crop au début du geste, converti en
    /// normalisé, puis borné — angles de 90° par construction.
    private func handleDrag(_ handle: CropHandle,
                            fit: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0,
                    coordinateSpace: .named("receiptStage"))
            .onChanged { value in
                let current = ReceiptGeometry.normalizedPoint(
                    value.location, in: fit)
                if dragStartCrop == nil {
                    dragStartCrop = ReceiptGeometry.clampCrop(
                        session.cropNormalized)
                    dragStartPoint = current
                }
                guard let start = dragStartCrop,
                      let startPoint = dragStartPoint else { return }
                session.cropNormalized = ReceiptGeometry.clampCrop(
                    applying(handle, to: start,
                             startPoint: startPoint,
                             currentPoint: current))
            }
            .onEnded { _ in
                dragStartCrop = nil
                dragStartPoint = nil
            }
    }

    private func applying(_ handle: CropHandle, to crop: CGRect,
                          startPoint: CGPoint,
                          currentPoint: CGPoint) -> CGRect {
        let dx = currentPoint.x - startPoint.x
        let dy = currentPoint.y - startPoint.y
        var minX = crop.minX, minY = crop.minY
        var maxX = crop.maxX, maxY = crop.maxY
        if handle == .interior {
            minX += dx; maxX += dx
            minY += dy; maxY += dy
        } else {
            if handle.affectsLeft { minX += dx }
            if handle.affectsRight { maxX += dx }
            if handle.affectsTop { minY += dy }
            if handle.affectsBottom { maxY += dy }
        }
        return CGRect(x: minX, y: minY,
                      width: maxX - minX, height: maxY - minY)
    }
}

/// Les poignées du crop : 4 coins + 4 arêtes (+ l'intérieur,
/// qui déplace la boîte entière).
private enum CropHandle: CaseIterable {
    case topLeft, top, topRight, right,
         bottomRight, bottom, bottomLeft, left, interior

    static var allCases: [CropHandle] {
        [.topLeft, .top, .topRight, .right,
         .bottomRight, .bottom, .bottomLeft, .left]
    }

    var affectsLeft: Bool {
        self == .left || self == .topLeft || self == .bottomLeft
    }
    var affectsRight: Bool {
        self == .right || self == .topRight || self == .bottomRight
    }
    var affectsTop: Bool {
        self == .top || self == .topLeft || self == .topRight
    }
    var affectsBottom: Bool {
        self == .bottom || self == .bottomLeft || self == .bottomRight
    }
}

// MARK: - Panneau (bas de l'écran)

/// Le panneau du nouveau Scanner : le message d'état, la file
/// d'envoi (compteur + réessai) et les réglages d'envoi (le
/// jeton, gardé sur ce Mac seulement — jamais dans le code,
/// le dépôt est public).
struct ReceiptScannerPanel: View {
    @Bindable var session: ReceiptScanSession
    @AppStorage("receiptUploadToken") private var uploadToken = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.statusMessage)
                .font(.system(size: 15, weight: .medium))
            Toggle(isOn: $session.autoDetectionEnabled) {
                Text("Détection automatique — le reçu se "
                    + "photographie tout seul dès qu'il est "
                    + "stable (les deux mains restent sur le reçu)")
                    .font(.system(size: 13.5))
            }
            .toggleStyle(.switch)
            .frame(maxWidth: 560, alignment: .leading)
            if session.outboxCount > 0 {
                HStack(spacing: 10) {
                    Text("📤 \(session.outboxCount) reçu(s) "
                        + "en attente d'envoi")
                        .font(.system(size: 14))
                    Button("Réessayer l'envoi") {
                        Task {
                            await session.retryFlush(
                                token: uploadToken)
                        }
                    }
                    .disabled(session.isFlushing
                              || uploadToken.isEmpty)
                    if uploadToken.isEmpty {
                        Text("(jeton manquant — voir les réglages)")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }
            }
            DisclosureGroup("Réglages d'envoi") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Jeton d'envoi — il reste sur ce Mac, "
                        + "il ne part que dans l'en-tête des envois :")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    TextField("Collez le jeton ici",
                              text: $uploadToken)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 520)
                    HStack(spacing: 10) {
                        Button("Coller le jeton") {
                            if let texte = NSPasteboard.general
                                .string(forType: .string) {
                                uploadToken = texte
                                    .trimmingCharacters(
                                        in: .whitespacesAndNewlines)
                            }
                        }
                        Text(uploadToken.isEmpty
                            ? "Aucun jeton présent."
                            : "Jeton présent : "
                                + "\(uploadToken.count) caractères.")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    Text("Destination : la boîte « Reçus » de "
                        + "l'app Gestion (app.gregoirepainchaud.ca). "
                        + "Chaque « Next » y envoie un reçu, "
                        + "un à la fois, au fur et à mesure.")
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: 560)
        }
        .onAppear {
            session.refreshOutboxCount()
            if session.outboxCount > 0 {
                Task { await session.flush(token: uploadToken) }
            }
        }
    }
}
