import SwiftUI
import AppKit  // NSApplication, pour le bouton Exit

// MARK: - Écran de test du scan composite (ÉTAPE 1)

/// Cet écran ne sert qu'à régler le SCAN (voir CompositeScanner) :
/// aucune extraction d'information à cette étape, et RIEN n'est écrit
/// dans la base de données (aucun accès SwiftData ici).
///
/// Déroulement affiché :
/// - RECHERCHE : flux caméra brut (aperçu miroir commutable, comme
///   avant) + contour jaune du reçu détecté ; quand le quadrilatère
///   bouge peu ~0,5 s, le scan démarre tout seul.
/// - CAPTURE (2 s) : le flux reste affiché, une barre de progression
///   montre la fenêtre ; à droite, le composite s'assemble en direct
///   (tuiles remplies, remplissage du rectangle englobant).
/// - FIGÉ : le flux caméra COUPE (la session est arrêtée) et le scan
///   redressé, caractères à l'endroit, remplit l'écran sur fond noir.
///
/// Boutons toujours visibles : « Next scan » abandonne le test en
/// cours et repart en recherche (pour enchaîner les scénarios) ;
/// « Exit » ferme l'application.
struct CompositeScanView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var scanner = CompositeScanner()
    /// Aperçu commutable (choix mémorisé, partagé avec l'ancien écran) :
    /// vrai = miroir (déplacements intuitifs, texte inversé),
    /// faux = normal (texte lisible, déplacements inversés).
    /// Ne concerne que l'aperçu pendant la recherche/capture — le scan
    /// final est toujours affiché à l'endroit.
    @AppStorage("previewMirrored") private var previewMirrored = true

    private var isDone: Bool { scanner.state == .done }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack {
                    Color.black
                    if isDone, let image = scanner.finalImage {
                        Image(image, scale: 1, label: Text("Scan du reçu"))
                            .resizable()
                            .scaledToFit()
                            .padding(10)
                    } else {
                        CameraPreviewView(session: camera.session)
                            .scaleEffect(x: previewMirrored ? -1 : 1, y: 1,
                                         anchor: .center)
                        ScanOverlayView(quad: scanner.quad,
                                        totalBox: nil,
                                        hoverRect: nil,
                                        mirrored: previewMirrored,
                                        size: geo.size)
                        if scanner.state == .capturing {
                            VStack {
                                Spacer()
                                ProgressView(value: scanner.progress)
                                    .progressViewStyle(.linear)
                                    .tint(.yellow)
                                    .padding(.horizontal, 24)
                                    .padding(.bottom, 14)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 220)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                if let message = camera.errorMessage {
                    Text(message)
                        .foregroundColor(.red)
                        .font(.system(size: 15))
                } else if !camera.isAuthorized {
                    Text("Demande d'accès à la caméra…")
                        .foregroundColor(.secondary)
                        .font(.system(size: 15))
                }

                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(scanner.statusText)
                            .font(.system(size: 16, weight: .medium))

                        if scanner.state == .capturing || isDone {
                            Text("Tuiles remplies : \(scanner.filledTiles)  •  remplissage du rectangle : \(scanner.fillPercent) %")
                                .font(.system(size: 13.5))
                                .foregroundColor(.secondary)
                        }

                        Text(scanner.statsText)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(.secondary)

                        HStack(spacing: 12) {
                            Button("Next scan") { nextScan() }
                                .controlSize(.large)
                            Button("Exit") {
                                NSApplication.shared.terminate(nil)
                            }
                            .controlSize(.large)
                            Spacer()
                            Button(previewMirrored
                                   ? "Aperçu : miroir" : "Aperçu : texte lisible") {
                                previewMirrored.toggle()
                            }
                            .focusable(false)
                        }
                    }

                    // Le composite en train de s'assembler (capture) —
                    // en mode figé il est déjà affiché en grand.
                    if scanner.state == .capturing,
                       let preview = scanner.livePreview {
                        VStack(spacing: 4) {
                            Text("Composite en cours")
                                .font(.system(size: 11.5))
                                .foregroundColor(.secondary)
                            Image(preview, scale: 1,
                                  label: Text("Composite en cours"))
                                .resizable()
                                .scaledToFit()
                                .frame(width: 210, height: 130)
                                .background(Color.black)
                                .cornerRadius(6)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
            .layoutPriority(1)
        }
        .frame(minWidth: 780, minHeight: 760)
        .onAppear {
            camera.start(delegate: scanner)
        }
        .onDisappear { camera.stop() }
        .onChange(of: scanner.state) { _, newState in
            // Le flux caméra coupe quand le scan est figé.
            if newState == .done { camera.stop() }
        }
    }

    /// Abandonne le test en cours (quel que soit l'état) et repart
    /// en recherche pour le scénario suivant.
    private func nextScan() {
        scanner.reset()
        camera.start(delegate: scanner)
    }
}
