import SwiftUI
import AppKit  // NSApplication, pour le bouton Exit

// MARK: - Écran de test du scan composite (ÉTAPE 1)

/// Cet écran sert à régler le SCAN (voir CompositeScanner). Le
/// scan figé est aussi LU (OCR + champs affichés dans le panneau
/// « Ce que je lis ») — affichage seulement : RIEN n'est écrit
/// dans la base de données (aucun accès SwiftData ici).
///
/// Déroulement affiché :
/// - RECHERCHE : flux caméra brut (aperçu miroir commutable) ;
///   quand du texte sur papier blanc est détecté dans l'image et
///   que la scène est stable ~0,5 s, le scan démarre tout seul.
///   Aucune boîte de sélection : le reçu est localisé APRÈS la
///   capture, dans le composite figé.
/// - CAPTURE (2 s) : le flux reste affiché, une barre de progression
///   montre la fenêtre ; à droite, le composite s'assemble en direct
///   (tuiles remplies, remplissage du rectangle englobant).
/// - FIGÉ : le flux caméra COUPE à l'écran (la session reste en
///   marche, voir CameraManager) et le scan
///   redressé, caractères à l'endroit, remplit l'écran sur fond noir.
///   Le panneau du bas montre alors ce que le programme LIT du
///   scan (champs extraits + texte brut), sans rien sauvegarder.
///
/// Boutons toujours visibles : « Next scan » abandonne le test en
/// cours et repart en recherche (pour enchaîner les scénarios) ;
/// « Exit » ferme l'application.
struct CompositeScanView: View {
    @State private var camera = CameraManager()
    @State private var scanner = CompositeScanner()
    /// Aperçu commutable (choix mémorisé, partagé avec l'ancien écran) :
    /// vrai = miroir (déplacements intuitifs, texte inversé),
    /// faux = normal (texte lisible, déplacements inversés).
    /// Ne concerne que l'aperçu pendant la recherche/capture — le scan
    /// final est toujours affiché à l'endroit.
    @AppStorage("previewMirrored") private var previewMirrored = true
    /// Éclairage de scan : pendant la recherche et la capture, tout
    /// ce qui entoure l'aperçu devient blanc — l'écran lui-même sert
    /// de panneau d'éclairage
    /// pour le reçu, présenté face à lui (demandé par Grégoire le
    /// 2026-10-19 : le scan manquait de lumière). Aucune API publique
    /// ne permet à une app de monter la luminosité système ; le
    /// blanc plein écran est le levier fiable.
    @AppStorage("scanLighting") private var scanLighting = true
    /// En mode figé : afficher le scan AMÉLIORÉ (par défaut) ou
    /// l'original brut, pour comparer l'effet de l'amélioration.
    @State private var showEnhanced = true

    private var isDone: Bool { scanner.state == .done }

    /// Panneau lumineux actif hors phase figée.
    private var lightPanelActive: Bool { scanLighting && !isDone }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { outer in
                ZStack {
                    // Champ d'éclairage blanc (ou fond noir du mode
                    // figé) sur toute la zone. La fenêtre de visée
                    // centrale reste modeste — environ la moitié de
                    // l'écran : assez pour enligner le reçu, et tout
                    // le reste est de la lumière (précision de
                    // Grégoire, 2026-10-19). Une fois le scan figé,
                    // la fenêtre reprend toute la place : le scan
                    // s'affiche bien gros au centre.
                    lightPanelActive ? Color.white : Color.black
                    GeometryReader { geo in
                        ZStack {
                            Color.black
                            if isDone, let image = (showEnhanced
                                ? scanner.finalImage
                                : scanner.rawFinalImage) ?? scanner.finalImage {
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
                                            .tint(lightPanelActive ? .orange : .yellow)
                                            .padding(.horizontal, 24)
                                            .padding(.bottom, 14)
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: lightPanelActive
                           ? outer.size.width * 0.52 : outer.size.width,
                           height: lightPanelActive
                           ? outer.size.height * 0.62 : outer.size.height)
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

                        if let info = camera.formatInfo {
                            Text(info)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundColor(.secondary)
                        }

                        if isDone, let ex = scanner.extraction {
                            extractionPanel(ex)
                        }

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
                            Button(scanLighting
                                   ? "Éclairage : oui" : "Éclairage : non") {
                                scanLighting.toggle()
                            }
                            .focusable(false)
                            if isDone, scanner.rawFinalImage != nil {
                                Button(showEnhanced
                                       ? "Image : améliorée" : "Image : originale") {
                                    showEnhanced.toggle()
                                }
                                .focusable(false)
                            }
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
            .background(lightPanelActive
                        ? Color.white
                        : Color(nsColor: .windowBackgroundColor))
            .layoutPriority(1)
        }
        .frame(minWidth: 780, minHeight: 760)
        .onAppear {
            camera.start(delegate: scanner)
            // Plein écran dès l'ouverture, toujours (demandé par
            // Grégoire le 2026-10-19) — indépendant du panneau
            // d'éclairage, qui ne contrôle que le champ blanc.
            enterFullScreen()
        }
        .onDisappear { camera.stop() }
        // Pas d'arrêt de session quand le scan se fige : la vue
        // bascule sur l'image finale (le flux « coupe » à l'écran),
        // mais la session reste en marche — l'arrêter puis la
        // redémarrer au « Next scan » a causé un plantage (course
        // avec la reconstruction du calque d'aperçu, 2026-10-19).
    }

    /// Panneau « Ce que je lis » : les champs extraits du scan
    /// figé et le texte OCR brut, pour juger sur pièces ce que le
    /// programme sait lire. Affichage seulement — rien n'est
    /// sauvegardé à cette étape.
    @ViewBuilder
    private func extractionPanel(
        _ ex: CompositeScanner.ScanExtraction
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ce que je lis")
                .font(.system(size: 14, weight: .semibold))
            HStack(alignment: .top, spacing: 22) {
                fieldRow("Commerce",
                         ex.merchant.isEmpty ? "—" : ex.merchant)
                fieldRow("Date", dateText(ex))
                fieldRow("Total", totalText(ex))
            }
            if ex.readUpsideDown {
                Text("Lu à l'envers : l'image affichée est restée inversée, la lecture s'en est accommodée.")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
            }
            ScrollView {
                Text(ex.text.isEmpty
                     ? "(aucun texte reconnu)" : ex.text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 110)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(6)
        }
        .padding(.top, 4)
    }

    private func fieldRow(_ label: String, _ value: String)
    -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .medium))
        }
    }

    private func dateText(_ ex: CompositeScanner.ScanExtraction)
    -> String {
        guard let date = ex.date else { return "—" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
            + (ex.dateIsDefault ? " (par défaut)" : "")
    }

    private func totalText(_ ex: CompositeScanner.ScanExtraction)
    -> String {
        guard let total = ex.total else { return "—" }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "CAD"
        let amount = f.string(from: NSNumber(value: total))
            ?? String(format: "%.2f $", total)
        return amount
            + (ex.totalVerified ? "  ✓ vérifié par addition" : "")
    }

    /// Abandonne le test en cours (quel que soit l'état) et repart
    /// en recherche pour le scénario suivant.
    private func nextScan() {
        scanner.reset()
        camera.start(delegate: scanner)
    }

    /// Passe la fenêtre en plein écran (à l'ouverture de l'app —
    /// la grande surface sert aussi le panneau d'éclairage).
    /// Différé : à onAppear, la fenêtre n'est pas toujours déjà là.
    private func enterFullScreen() {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
                  !window.styleMask.contains(.fullScreen)
            else { return }
            window.toggleFullScreen(nil)
        }
    }
}
