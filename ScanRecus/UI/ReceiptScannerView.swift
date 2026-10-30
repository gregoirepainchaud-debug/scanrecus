import AVFoundation
import CoreImage
import SwiftUI

/// NOUVEAU SCANNER (build 158, 2026-10-30) — le premier onglet
/// devient une capture SIMPLE, selon le design de Grégoire :
/// une bonne photo → redressement au bouton rotatif → crop
/// rectangulaire aux ciseaux → « Next » téléverse le JPEG
/// (croppé, compressé, numéroté AAAAMMJJ.NNNN) dans la boîte
/// de l'app Gestion. Le traceur et le jeu du lasso sont mis
/// de côté ; le scanner composite continue de servir les
/// autres sections, inchangées.

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
/// l'être à son meilleur format — pas de composite, pas de
/// détection. Conversion étranglée (~8/s) : photographier ne
/// doit pas coûter un flux plein cadre en continu.
final class StillFrameGrabber: NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable {

    private let lock = NSLock()
    private var latest: CGImage?
    /// Lu/écrit seulement sur la file des frames (série).
    private var lastConvert = Date.distantPast
    private let ciContext = CIContext(
        options: [.useSoftwareRenderer: false])

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
        lock.unlock()
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
    var cropNormalized = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Mode ciseaux : les poignées du crop sont actives.
    var cropMode = false
    var statusMessage =
        "Présentez un reçu devant la caméra, puis déclenchez."
    private(set) var outboxCount = 0
    private(set) var isFlushing = false

    let grabber = StillFrameGrabber()
    let outbox = ReceiptOutbox()

    init() { refreshOutboxCount() }

    /// Déclencheur : photographie l'image courante de la caméra.
    func shutter() {
        guard let frame = grabber.snapshot() else {
            statusMessage = "La caméra n'a pas encore d'image "
                + "— un petit instant…"
            return
        }
        photo = frame
        angleDegrees = 0
        cropNormalized = CGRect(x: 0, y: 0, width: 1, height: 1)
        cropMode = false
        phase = .adjust
        statusMessage = "Redressez au bouton rotatif, cadrez "
            + "aux ciseaux si besoin, puis « Next »."
    }

    /// « Reprendre la photo » : jette l'image courante.
    func retake() {
        photo = nil
        phase = .capture
        statusMessage = "Présentez un reçu devant la caméra, "
            + "puis déclenchez."
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
        refreshOutboxCount()
        self.photo = nil
        phase = .capture
        let sent = await flush(token: token)
        statusMessage = sent.contains(numero)
            ? "Reçu \(numero) envoyé ✓"
            : "Reçu \(numero) gardé dans la file d'envoi — "
                + "l'envoi reprendra tout seul dès que le "
                + "réseau ou le serveur répondra."
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
        return await outbox.flush(
            send: ReceiptUploader.sender(token: token))
    }

    /// Le bouton « Réessayer l'envoi » du panneau.
    @MainActor
    func retryFlush(token: String) async {
        let sent = await flush(token: token)
        if !sent.isEmpty {
            statusMessage = outboxCount == 0
                ? "File d'envoi vidée ✓ (\(sent.count) reçu(s) parti(s))"
                : "\(sent.count) reçu(s) envoyé(s) — il en "
                    + "reste \(outboxCount) dans la file."
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

    // Capture : le déclencheur, par-dessus l'aperçu partagé.
    private var captureContent: some View {
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
                    Button(session.cropMode
                           ? "✂ Ciseaux : actifs"
                           : "✂ Ciseaux") {
                        session.cropMode.toggle()
                    }
                    .controlSize(.large)
                    .background(session.cropMode
                                ? Color.yellow.opacity(0.35)
                                : Color.clear)
                    .cornerRadius(6)
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

    // Le crop : assombrissement extérieur, bordure, et en mode
    // ciseaux la surface de déplacement + les 8 poignées.
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
                .stroke(Color.yellow,
                        lineWidth: session.cropMode ? 2 : 1)
                .allowsHitTesting(false)
            if session.cropMode {
                Color.white.opacity(0.001)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .gesture(handleDrag(.interior, fit: fit))
                ForEach(CropHandle.allCases, id: \.self) { handle in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.yellow)
                        .frame(width: 17, height: 17)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.black, lineWidth: 1))
                        .position(handlePoint(handle, in: rect))
                        .gesture(handleDrag(handle, fit: fit))
                }
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
    var session: ReceiptScanSession
    @AppStorage("receiptUploadToken") private var uploadToken = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.statusMessage)
                .font(.system(size: 15, weight: .medium))
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
