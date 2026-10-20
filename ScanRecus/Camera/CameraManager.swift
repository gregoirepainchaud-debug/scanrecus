import AVFoundation
import Observation
import SwiftUI

// MARK: - Gestion de la caméra (AVFoundation)

/// Possède la session de capture, gère l'autorisation macOS
/// et expose la prévisualisation vidéo pour SwiftUI.
///
/// Le délégué (ScanEngine) reçoit les images brutes ; la prévisualisation
/// est en mode MIROIR (comme un vrai miroir : le reçu déplacé à droite va
/// à droite à l'écran) pour un positionnement intuitif. Les images
/// analysées par l'OCR restent NON miroitée — l'UI inverse donc les
/// coordonnées X des cadres (voir ScanOverlayView).
@Observable
final class CameraManager: NSObject, @unchecked Sendable {

    private(set) var isAuthorized = false
    private(set) var isRunning = false
    private(set) var errorMessage: String?

    /// Diagnostic matériel (nom de la caméra, format réellement
    /// actif, meilleur format offert) — pour trancher « le code ou
    /// la caméra ? » quand la résolution livrée ne suit pas.
    private(set) var formatInfo: String?

    /// La session est thread-safe (documentation Apple) : on peut la lire
    /// depuis le main pour la prévisualisation pendant qu'elle tourne.
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "ca.scanrecus.camera")

    private var captureDevice: AVCaptureDevice?
    /// Format haute résolution retenu à la configuration ; il est
    /// appliqué APRÈS le démarrage de la session (voir
    /// applyPreferredFormat), pas pendant la configuration.
    private var preferredFormat: AVCaptureDevice.Format?

    /// Demande l'autorisation si besoin puis démarre la session.
    /// - Parameter delegate: reçoit les images (ScanEngine).
    ///   L'appelant doit le retenir (le output ne le retient pas).
    func start(delegate: AVCaptureVideoDataOutputSampleBufferDelegate) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart(delegate: delegate)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.configureAndStart(delegate: delegate)
                    } else {
                        self.publishDenied()
                    }
                }
            }
        case .denied, .restricted:
            publishDenied()
        @unknown default:
            publishDenied()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    // MARK: - Privé

    private func publishDenied() {
        // Écriture différée : start() est appelé depuis onAppear,
        // possiblement pendant une mise à jour de vue SwiftUI.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.errorMessage = "Accès à la caméra refusé. Ouvrez Réglages Système > " +
                "Confidentialité et sécurité > Caméra, puis activez ScanReçus."
            self.isAuthorized = false
        }
    }

    private func configureAndStart(
        delegate: AVCaptureVideoDataOutputSampleBufferDelegate
    ) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                // La configuration ne se fait qu'une fois.
                if self.session.inputs.isEmpty {
                    try self.configure(delegate: delegate)
                }
                // Ne redémarrer que si la session est arrêtée. Le
                // cycle arrêter/redémarrer entre deux scans a déjà
                // planté l'app : au « Next scan », la vue reconstruit
                // son calque d'aperçu pendant que startRunning
                // énumère les connexions de la session — « Collection
                // was mutated while being enumerated » (2026-10-19).
                // La session reste donc en marche d'un scan à
                // l'autre ; c'est la VUE qui coupe l'affichage du
                // flux une fois le scan figé.
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                // Le format haute résolution s'applique MAINTENANT
                // que la session tourne : posé pendant la
                // configuration, il était écrasé par le preset 720p
                // à la mise en route (retest du 2026-10-19 : la
                // caméra livrait toujours du 1280 × 720).
                self.applyPreferredFormat()
                DispatchQueue.main.async {
                    self.isAuthorized = true
                    self.errorMessage = nil
                    self.isRunning = self.session.isRunning
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage =
                        "Caméra inutilisable : \(error.localizedDescription)"
                }
            }
        }
    }

    /// Applique le format haute résolution mémorisé à la
    /// configuration, maintenant que la session tourne, puis publie
    /// le diagnostic matériel : nom de la caméra, format réellement
    /// actif et meilleur format que la caméra offre. Sur la file
    /// de session.
    private func applyPreferredFormat() {
        guard let device = captureDevice else { return }
        if let format = preferredFormat, device.activeFormat != format {
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                device.unlockForConfiguration()
            } catch {
                // On continue avec le format du preset ; le
                // diagnostic ci-dessous montre le format actif réel.
            }
        }
        let active = CMVideoFormatDescriptionGetDimensions(
            device.activeFormat.formatDescription)
        var best: CMVideoDimensions?
        var bestPixels = -1
        for format in device.formats {
            let d = CMVideoFormatDescriptionGetDimensions(
                format.formatDescription)
            let px = Int(d.width) * Int(d.height)
            if px > bestPixels {
                bestPixels = px
                best = d
            }
        }
        var info = "\(device.localizedName) • format actif : "
            + "\(active.width) × \(active.height)"
        if let best {
            info += " • meilleur offert : \(best.width) × \(best.height)"
        }
        DispatchQueue.main.async { self.formatInfo = info }
    }

    private enum SetupError: LocalizedError {
        case noCamera
        case cannotAddInput
        case cannotAddOutput

        var errorDescription: String? {
            switch self {
            case .noCamera: return "aucune caméra détectée"
            case .cannotAddInput: return "entrée vidéo refusée"
            case .cannotAddOutput: return "sortie vidéo refusée"
            }
        }
    }

    private func configure(
        delegate: AVCaptureVideoDataOutputSampleBufferDelegate
    ) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard let device = AVCaptureDevice.default(for: .video) else {
            throw SetupError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw SetupError.cannotAddInput }
        session.addInput(input)

        // Résolution : le meilleur format de la caméra qui garde un
        // débit fluide (≥ 20 img/s), plafonné à 2560 px de large.
        // Le 720p fixe d'origine laissait le scan final trop mou
        // pour l'OCR (constat de Grégoire, 2026-10-19) ; les seuils
        // de calibrage du scanner sont exprimés en pixels et mis à
        // l'échelle en conséquence (voir CompositeScanner.pxScale).
        // Le format retenu est MÉMORISÉ ici et appliqué APRÈS le
        // démarrage de la session (voir applyPreferredFormat) :
        // posé pendant la configuration, il était écrasé par le
        // preset 720p à la mise en route (retest du 2026-10-19).
        session.sessionPreset = .hd1280x720
        captureDevice = device
        let fluid = device.formats.filter { format in
            format.videoSupportedFrameRateRanges.contains {
                $0.maxFrameRate >= 20
            }
        }
        let pixels: (AVCaptureDevice.Format) -> Int = { format in
            let d = CMVideoFormatDescriptionGetDimensions(
                format.formatDescription)
            return Int(d.width) * Int(d.height)
        }
        let capped = fluid.filter {
            CMVideoFormatDescriptionGetDimensions(
                $0.formatDescription).width <= 2560
        }
        preferredFormat = (capped.isEmpty ? fluid : capped)
            .max(by: { pixels($0) < pixels($1) })

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(
            delegate, queue: DispatchQueue(label: "ca.scanrecus.frames"))
        guard session.canAddOutput(output) else {
            throw SetupError.cannotAddOutput
        }
        session.addOutput(output)

        // Images NON MIROITÉES : l'OCR doit voir le texte à l'endroit.
        for connection in output.connections
        where connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }
}

// MARK: - Prévisualisation SwiftUI

/// Affiche le flux caméra via un AVCaptureVideoPreviewLayer (GPU, zéro copie).
struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewHostView {
        PreviewHostView(session: session)
    }

    func updateNSView(_ nsView: PreviewHostView, context: Context) {}
}

/// NSView dont le calque d'affichage est directement le calque vidéo.
final class PreviewHostView: NSView {
    private let session: AVCaptureSession

    init(session: AVCaptureSession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) n'est pas supporté")
    }

    override func makeBackingLayer() -> CALayer {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        // Pas de retournement ici : le miroir est appliqué par la vue
        // SwiftUI (scaleEffect dans ScanDebugView, plan C) — les réglages
        // AVFoundation (connexion, transformation du calque) n'ont eu
        // aucun effet observable sur ce Mac.
        return layer
    }
}
