import AVFoundation
import Combine
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
final class CameraManager: NSObject, ObservableObject, @unchecked Sendable {

    @Published private(set) var isAuthorized = false
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?

    /// La session est thread-safe (documentation Apple) : on peut la lire
    /// depuis le main pour la prévisualisation pendant qu'elle tourne.
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "ca.scanrecus.camera")

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
        errorMessage = "Accès à la caméra refusé. Ouvrez Réglages Système > " +
            "Confidentialité et sécurité > Caméra, puis activez ScanReçus."
        isAuthorized = false
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
                self.session.startRunning()
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
        // 720p : bon compromis vitesse/qualité pour l'OCR à 5 Hz.
        session.sessionPreset = .hd1280x720

        guard let device = AVCaptureDevice.default(for: .video) else {
            throw SetupError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw SetupError.cannotAddInput }
        session.addInput(input)

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
