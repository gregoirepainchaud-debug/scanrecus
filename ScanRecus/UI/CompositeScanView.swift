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
/// - CAPTURE (1,2 s) : le flux reste affiché, une barre de
///   progression montre la fenêtre d'échantillonnage ; la
///   meilleure image est retenue, les autres sont jetées.
/// - FIGÉ : dès l'échantillonnage terminé, la session caméra
///   COUPE pour vrai (plus besoin de tenir le reçu pendant
///   l'analyse) et l'écran montre l'image retenue, puis le scan
///   redressé, caractères à l'endroit, qui remplit la zone sur
///   fond noir. Le panneau du bas montre alors ce que le
///   programme LIT du scan (champs extraits + texte brut),
///   sans rien sauvegarder.
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
    /// Éclairage de scan : pendant la recherche et la capture, le
    /// panneau du bas devient blanc — l'écran sert de panneau
    /// d'éclairage pour le reçu, présenté face à lui (demandé par
    /// Grégoire le 2026-10-19 : le scan manquait de lumière).
    /// Avant le 2026-10-20, un champ blanc entourait aussi la
    /// visée ; la visée occupe maintenant toute la zone (sa
    /// demande du même jour), il ne reste que le panneau.
    /// Aucune API publique ne permet à une app de monter la
    /// luminosité système ; le blanc est le levier fiable.
    @AppStorage("scanLighting") private var scanLighting = true
    /// En mode figé : afficher le scan AMÉLIORÉ (par défaut) ou
    /// l'original brut, pour comparer l'effet de l'amélioration.
    @State private var showEnhanced = true

    /// Les sections de l'app (menu, 2026-10-21) : le scanner
    /// d'origine ; « Générer matériel » — la banque de photos
    /// d'entraînement (la webcam fige et coffre, sans rituel
    /// ni analyse) ; « Entraînement IA » — annoncé au menu,
    /// pas encore codé (il le sera pendant que Grégoire
    /// génère le matériel).
    private enum AppSection {
        case scanner, materiel, entrainement
    }
    @State private var appSection: AppSection = .scanner
    @State private var bank = TrainingBank()
    @State private var lasso = LassoSession()
    /// Le zoom d'affichage du jeu du lasso (1× à
    /// 4×) : pour MIEUX VOIR, pas pour juger autrement
    /// — les coordonnées du lasso restent relatives
    /// à l'image, le zoom ne change que l'affichage.
    @State private var lassoZoom: Double = 1
    @State private var vertexDragActive = false
    /// La grille quadrillée de 5 mm sur le canevas du jeu
    /// (affichée par défaut, commutable au panneau).

    private var isDone: Bool { scanner.state == .done }

    /// Panneau lumineux actif hors phase figée.
    private var lightPanelActive: Bool {
        scanLighting && !isDone && appSection != .entrainement
    }

    var body: some View {
        GeometryReader { full in
            VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack {
                    Color.black
                    // L'aperçu caméra occupe TOUTE la zone et
                    // reste TOUJOURS dans la hiérarchie (demande
                    // de Grégoire, 2026-10-20 : maximiser la vue,
                    // étiquettes par-dessus l'image). Il est
                    // seulement COUVERT par le scan figé — le
                    // reconstruire à chaque bascule pendant que
                    // la session s'arrête et redémarre, c'est ce
                    // qui plantait (2026-10-19) ; le garder en
                    // place rend la coupure du flux sûre. Le champ
                    // d'éclairage blanc autour de la visée
                    // disparaît : la lumière vient du panneau du
                    // bas, resté blanc en mode éclairage.
                    CameraPreviewView(session: camera.session)
                        .scaleEffect(x: previewMirrored ? -1 : 1, y: 1,
                                     anchor: .center)
                    if !isDone {
                        ScanOverlayView(quad: scanner.quad,
                                        totalBox: nil,
                                        hoverRect: nil,
                                        mirrored: previewMirrored,
                                        size: geo.size)
                        // Étiquette d'état par-dessus l'image.
                        VStack {
                            HStack {
                                Text(scanner.statusText)
                                    .font(.system(size: 14,
                                                  weight: .medium))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        Color.black.opacity(0.55))
                                    .cornerRadius(8)
                                Spacer()
                            }
                            Spacer()
                        }
                        .padding(12)
                    }
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
                    // Le canevas du JEU couvre la zone dans la
                    // section Entraînement IA (l'aperçu reste
                    // dans la hiérarchie en dessous).
                    if appSection == .entrainement {
                        lassoCanvas(
                            containerSize: geo.size)
                    }
                    if isDone, appSection != .entrainement {
                        // Le scan figé, par-dessus l'aperçu
                        // (caméra déjà coupée) : d'abord la
                        // meilleure image retenue pendant que
                        // l'analyse court, puis le scan redressé
                        // avec ses carrés jaunes et ses extraits
                        // ZOOMÉS (ZoomReviewView).
                        ZStack {
                            Color.black
                            if let image = (showEnhanced
                                ? scanner.finalImage
                                : scanner.rawFinalImage)
                                ?? scanner.finalImage {
                                ZoomReviewView(
                                    image: image,
                                    boxes: scanner.extraction?
                                        .answerBoxes ?? [],
                                    crops: scanner.extraction?
                                        .answerCrops ?? [],
                                    proofBoxes: scanner.extraction?
                                        .proofBoxes ?? [])
                                .padding(10)
                            } else if let frozen = scanner.livePreview {
                                Image(frozen, scale: 1,
                                      label: Text("Scan en analyse"))
                                    .resizable()
                                    .scaledToFit()
                                    .padding(10)
                            }
                        }
                        // Épinglé à TOUTE la zone disponible
                        // (sinon l'image se retrouvait à
                        // droite, tassée sur son contenu —
                        // vu par Grégoire pendant la phase
                        // de test, 2026-10-21) : l'image reste
                        // maximisée, au centre.
                        .frame(width: geo.size.width,
                               height: geo.size.height)
                    }
                }
            }
            .frame(minHeight: 220)

            Divider()

            // Le bas de l'écran : 15 % de la hauteur,
            // DÉFILABLE (Grégoire, 2026-10-23) — le
            // panneau entier y vit, on y descend pour
            // les détails au lieu de l'étouffer.
            ScrollView(.vertical, showsIndicators: true) {
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
                        Text("ScanReçus — \(BuildInfo.stamp)")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(.secondary)

                        HStack(alignment: .center, spacing: 14) {
                        Picker("", selection: $appSection) {
                            Text("Scanner").tag(AppSection.scanner)
                            Text("Générer matériel")
                                .tag(AppSection.materiel)
                            Text("Entraînement IA")
                                .tag(AppSection.entrainement)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 560)
                        Button("Exit") {
                            NSApplication.shared.terminate(nil)
                        }
                        .controlSize(.large)
                        }

                        Text(scanner.statusText)
                            .font(.system(size: 16, weight: .medium))

                        journalRow

                        if appSection == .materiel {
                            materielPanel
                        } else if appSection == .entrainement {
                            lassoPanel
                        } else if isDone,
                                  let ex = scanner.extraction {
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

                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(lightPanelActive
                        ? Color.white
                        : Color(nsColor: .windowBackgroundColor))
            .frame(height: full.size.height * 0.15)
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
        .onChange(of: appSection) { oldSection, section in
            scanner.setBankingMode(section == .materiel)
            if section == .entrainement {
                // Pendant l'entraînement, caméra et
                // scanner S'ARRÊTENT : chercher un reçu
                // sous le jeu brûlait le CPU et rendait
                // le jeu poussif (Grégoire, 2026-10-23).
                camera.stop()
                lasso.prepare(bank: bank)
            } else if oldSection == .entrainement {
                camera.start(delegate: scanner)
            }
        }
        .onChange(of: scanner.frozenFrameStamp) { _, _ in
            guard appSection == .materiel,
                  let frame = scanner.frozenRawFrame,
                  let photo = bank.bank(cgImage: frame)
            else { return }
            let inGroup = bank.photos
                .filter { $0.group == photo.group }.count
            scanner.showStatus(
                "Photo coffrée — reçu nº \(photo.group) : "
                + "\(inGroup) photo(s). « Next scan » pour "
                + "la suivante, « Reçu suivant » pour "
                + "changer de reçu.")
        }
        // La caméra coupe dès que le scan se fige — l'état .done
        // est publié dès le DÉBUT de l'analyse — et redémarre au
        // retour en recherche (demande de Grégoire, 2026-10-20).
        // L'arrêt au figé avait causé un plantage en 2026-10-19
        // (course avec la reconstruction du calque d'aperçu) ;
        // le calque n'est plus jamais reconstruit (il reste sous
        // le scan figé), donc la coupure est sûre.
        .onChange(of: scanner.state) { _, newState in
            if newState == .done {
                camera.stop()
            } else if newState == .searching {
                camera.start(delegate: scanner)
            }
        }
    }

    /// Panneau « Ce que je lis » : les champs extraits du scan
    /// figé et le texte OCR brut, pour juger sur pièces ce que le
    /// programme sait lire. Affichage seulement — rien n'est
    /// sauvegardé à cette étape.
    /// Dossier du journal des scans (même clé UserDefaults
    /// que CompositeScanner.journalFolderKey) : les données de
    /// contrôle n'encombrent plus l'écran, elles s'accumulent
    /// dans scanrecus-journal.txt, sur Drive idéalement.
    @AppStorage("journalFolderPath") private var journalFolderPath = ""

    /// Panneau « Générer matériel » : la banque de photos
    /// d'entraînement. La capture reste celle du scanner
    /// (présenter un reçu → la frame se fige → elle est
    /// coffrée automatiquement) ; ici on groupe les photos
    /// par reçu et on surveille la banque.
    private var materielPanel: some View {
        let inGroup = bank.photos
            .filter { $0.group == bank.currentGroup }.count
        return VStack(alignment: .leading, spacing: 6) {
            Text("Présentez un reçu : la photo se fige et se "
                + "coffre toute seule. Groupez les photos par "
                + "reçu — « Reçu suivant » quand vous changez "
                + "de papier.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Text("Reçu nº \(bank.currentGroup)"
                + " · photos de ce reçu : \(inGroup)")
                .font(.system(size: 14, weight: .medium))
            Text("Scans uniques dans le répertoire : "
                + "\(bank.photos.count)"
                + " · scans générés : \(bank.derived.count)"
                + " · total matériel : "
                + "\(bank.totalMaterial) images"
                + " · \(bank.receiptCount) reçu(s)"
                + " · \(bank.sizeText)")
                .font(.system(size: 14, weight: .medium))
            if !bank.generationNote.isEmpty {
                Text(bank.generationNote)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 12) {
                Button("Reçu suivant") { bank.nextReceipt() }
                    .controlSize(.large)
                Button("Retirer la dernière photo") {
                    bank.removeLast()
                }
                .disabled(bank.photos.isEmpty)
                Button("Sauvegarder la banque vers Drive") {
                    bank.backupVaultToDrive()
                }
            }
            if !bank.backupNote.isEmpty {
                Text(bank.backupNote)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
        }
    }

    /// Le canevas du JEU DU LASSO : l'image, le
    /// fantôme pâle (le lasso précédent, point de
    /// comparaison) et le lasso courant en jaune.
    /// Aucun geste : on ne corrige plus à la main,
    /// on juge.
    private func lassoCanvas(containerSize: CGSize)
    -> some View {
        ZStack {
            Color.black
            if let img = lasso.displayImage {
                let fit = aspectFitRect(
                    imageSize: lasso.imageSize,
                    in: containerSize, inset: 5)
                // Le zoom (1× à 4×) grandit le rectangle
                // autour de son centre : l'image, les
                // tracés et les conversions de gestes
                // partagent le même rectangle, donc
                // tout reste cohérent à tout zoom.
                let rect = CGRect(
                    x: fit.midX - fit.width * lassoZoom / 2,
                    y: fit.midY - fit.height * lassoZoom / 2,
                    width: fit.width * lassoZoom,
                    height: fit.height * lassoZoom)
                Image(img, scale: 1,
                      label: Text("Image à juger"))
                    .resizable()
                    .frame(width: rect.width,
                           height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                let toScreen: (CGPoint) -> CGPoint = { pt in
                    CGPoint(
                        x: rect.minX + pt.x * rect.width,
                        y: rect.minY + pt.y * rect.height)
                }
                if let ghost = lasso.ghost, ghost.count >= 3 {
                    Path { path in
                        path.move(to: toScreen(ghost[0]))
                        for pt in ghost.dropFirst() {
                            path.addLine(to: toScreen(pt))
                        }
                        path.closeSubpath()
                    }
                    .stroke(Color.white.opacity(0.45),
                            lineWidth: 1.5)
                }
                if lasso.current.count >= 3 {
                    Path { path in
                        path.move(
                            to: toScreen(lasso.current[0]))
                        for pt in lasso.current.dropFirst() {
                            path.addLine(to: toScreen(pt))
                        }
                        path.closeSubpath()
                    }
                    .stroke(Color.yellow, lineWidth: 2.5)
                    // Zone de clic des arêtes : un clic
                    // près d'une arête (≤ 20 pt) y fait
                    // naître un sommet, au point projeté.
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: containerSize.width,
                               height: containerSize.height)
                        .contentShape(Rectangle())
                        .onTapGesture(
                            coordinateSpace: .named(
                                "lassoCanvas")) { location in
                            let pts = lasso.current.map(
                                toScreen)
                            var bestEdge = -1
                            var bestDist
                                = Double.greatestFiniteMagnitude
                            var bestProj = CGPoint.zero
                            for i in 0..<pts.count {
                                let a = pts[i]
                                let b = pts[(i + 1)
                                    % pts.count]
                                let abx = b.x - a.x
                                let aby = b.y - a.y
                                let len2 = max(1e-9,
                                    abx * abx + aby * aby)
                                var t = ((location.x - a.x)
                                    * abx + (location.y - a.y)
                                    * aby) / len2
                                t = min(1, max(0, t))
                                let proj = CGPoint(
                                    x: a.x + t * abx,
                                    y: a.y + t * aby)
                                let d = hypot(
                                    location.x - proj.x,
                                    location.y - proj.y)
                                if d < bestDist {
                                    bestDist = d
                                    bestEdge = i
                                    bestProj = proj
                                }
                            }
                            let presSommet = pts
                                .map { hypot(
                                    location.x - $0.x,
                                    location.y - $0.y) }
                                .min() ?? 999
                            if bestEdge >= 0, bestDist <= 20,
                               presSommet > 24 {
                                let n = CGPoint(
                                    x: (bestProj.x
                                        - rect.minX)
                                        / rect.width,
                                    y: (bestProj.y
                                        - rect.minY)
                                        / rect.height)
                                lasso.insertVertex(
                                    onEdge: bestEdge, at: n)
                            }
                        }
                    ForEach(0..<lasso.current.count,
                            id: \.self) { i in
                        Circle()
                            .fill(Color.yellow)
                            .frame(width: 7, height: 7)
                            .frame(width: 20, height: 20)
                            .contentShape(Circle())
                            .position(
                                toScreen(lasso.current[i]))
                            .gesture(
                                DragGesture(
                                    minimumDistance: 0,
                                    coordinateSpace: .named(
                                        "lassoCanvas"))
                                .onChanged { value in
                                    if NSEvent.modifierFlags
                                        .contains(.option) {
                                        return
                                    }
                                    if !vertexDragActive {
                                        vertexDragActive = true
                                        lasso.beginVertexDrag()
                                    }
                                    let n = CGPoint(
                                        x: (value.location.x
                                            - rect.minX)
                                            / rect.width,
                                        y: (value.location.y
                                            - rect.minY)
                                            / rect.height)
                                    lasso.moveVertex(i, to: n)
                                }
                                .onEnded { _ in
                                    vertexDragActive = false
                                    lasso.endVertexDrag()
                                })
                            .simultaneousGesture(
                                TapGesture()
                                    .modifiers(.option)
                                    .onEnded {
                                        lasso.deleteVertex(i)
                                    })
                    }
                }
            } else {
                Text("…")
                    .foregroundColor(.white)
            }
        }
        .frame(width: containerSize.width,
               height: containerSize.height)
        .clipped()
        .coordinateSpace(name: "lassoCanvas")
    }

    /// Le rectangle où l'image s'affiche (ajustée, centrée)
    /// dans un conteneur, avec un inset tout le tour.
    private func aspectFitRect(imageSize: CGSize,
                               in container: CGSize,
                               inset: CGFloat) -> CGRect {
        let availW = max(container.width - inset * 2, 1)
        let availH = max(container.height - inset * 2, 1)
        let scale = min(availW / max(imageSize.width, 1),
                        availH / max(imageSize.height, 1))
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: (container.width - w) / 2,
                      y: (container.height - h) / 2,
                      width: w, height: h)
    }

    /// La grille quadrillée : traits fins tous les 5 mm
    /// (≈ 14,17 pt à l'écran), traits forts tous les 25 mm.
    /// Le panneau du JEU DU LASSO : les quatre notes
    /// relatives et Next. Rien d'autre — l'ancien
    /// panneau de corrections a été supprimé.
    private var lassoPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Entraînement IA — LE LASSO"
                + " · image \(lasso.positionText)"
                + " · \(lasso.instanceLabel)")
                .font(.system(size: 14, weight: .medium))
            Text("Le réseau propose un contour fermé. "
                + "Note chaque tentative VIS-À-VIS de la "
                + "précédente (en pâle) : −1 moins bon, "
                + "0 équivalent, +1 mieux, +2 assez "
                + "bon pour l'usage "
                + "(l'image est finie, on passe à la "
                + "suivante). "
                + "Tu peux aussi TIRER un sommet du "
                + "lasso : c'est une suggestion pour la "
                + "recherche, pas un ordre — ta note "
                + "décide ensuite si elle la suit. "
                + "Ce qu'elle fait de tes notes : +1, "
                + "elle resserre ; 0, elle croise les "
                + "deux tracés (mouvement latéral) ; "
                + "−1, elle élargit. "
                + "Clic sur une arête : un sommet naît. "
                + "Option+clic sur un sommet : il "
                + "s'efface (jamais moins de 4). "
                + "Reste sur l'image aussi longtemps que "
                + "tu veux ; Next pour la suivante.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                CPUWheelView()
                Text(lasso.statusText)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 10) {
                Text("Zoom")
                    .font(.system(size: 12.5))
                    .foregroundColor(.secondary)
                Slider(value: $lassoZoom, in: 1...4,
                       step: 0.05)
                    .frame(maxWidth: 260)
                Text("\(Int((lassoZoom * 100).rounded())) %")
                    .font(.system(size: 12.5,
                                  design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
            }
            HStack(spacing: 12) {
                Button("−1") { lasso.rate(-1) }
                    .keyboardShortcut("1", modifiers: [])
                Button("0") { lasso.rate(0) }
                    .keyboardShortcut("2", modifiers: [])
                Button("+1") { lasso.rate(1) }
                    .keyboardShortcut("3", modifiers: [])
                Button("+2") { lasso.rate(2) }
                    .keyboardShortcut("4", modifiers: [])
                Button("Next") { lasso.next() }
                    .controlSize(.large)
                    .keyboardShortcut("n", modifiers: [])
                Button("Nouveau deck") {
                    lasso.reshuffle()
                }
            }
            .disabled(lasso.current.isEmpty)
            Text(lasso.statsText)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            if let note = lasso.lastRating {
                Text("✓ Note enregistrée : "
                    + (note > 0 ? "+\(note)" : "\(note)"))
                    .font(.system(size: 13,
                                weight: .semibold))
                    .foregroundColor(.green)
            }
            Divider()
            let prog = lasso.progress
            VStack(alignment: .leading, spacing: 3) {
                Text("Progression — prochaine étape : "
                    + "le juge artificiel (il apprendra à "
                    + "noter comme toi, puis l'IA pourra "
                    + "s'entraîner sans toi)")
                    .font(.system(size: 12,
                                weight: .semibold))
                Text("Images terminées (élites) : "
                    + "\(prog.imagesTerminees) / 100 · "
                    + "\(prog.recusDistincts) reçu(s) "
                    + "distinct(s)")
                Text("Notes au journal : "
                    + "\(prog.notes) / 300")
                if let pct = prog.coherencePct {
                    Text("Cohérence (doublons identiques) : "
                        + "\(prog.sondesIdentiquesOK)/"
                        + "\(prog.sondesIdentiques) notés "
                        + "0 (\(pct) %)")
                } else {
                    Text("Cohérence des doublons : "
                        + "en attente de sondes")
                }
                if let med = prog.cyclesMedian {
                    Text("Cycles médians par image : "
                        + "\(med)")
                }
                Text(prog.jugePret
                    ? "JALON ATTEINT : assez de matière "
                        + "pour le juge v1 — dis-le à Muse."
                    : "Pour le jalon du juge : encore "
                        + "\(max(0, 300 - prog.notes)) "
                        + "note(s) et "
                        + "\(max(0, 30 - prog.imagesTerminees)) "
                        + "image(s) terminée(s).")
                    .fontWeight(.medium)
            }
            .font(.system(size: 12))
            .foregroundColor(.secondary)
        }
    }

    private var journalRow: some View {
        HStack(spacing: 8) {
            Text(journalFolderPath.isEmpty
                 ? "Journal des scans : dossier automatique (Drive si détecté)"
                 : "Journal des scans : \(journalFolderPath)")
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Choisir le dossier…") { chooseJournalFolder() }
                .controlSize(.small)
        }
    }

    private func chooseJournalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choisir"
        panel.message = "Dossier où s'accumulera le journal des scans (scanrecus-journal.txt) — idéalement un dossier Google Drive."
        if panel.runModal() == .OK, let url = panel.url {
            journalFolderPath = url.path
        }
    }

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
                Text("Le scan se présentait à l'envers : il a été retourné pour s'afficher à l'endroit.")
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
        f.locale = Locale(identifier: "fr-CA")
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
        if ex.totalVerified, ex.totalParts.count >= 2 {
            let parts = ex.totalParts
                .map { String(format: "%.2f", $0)
                    .replacingOccurrences(of: ".", with: ",") }
                .joined(separator: " + ")
            return amount + "  ✓ preuve : \(parts)"
        }
        return amount
            + (ex.totalVerified ? "  ✓ vérifié par addition" : "")
    }

    /// Abandonne le test en cours (quel que soit l'état) et repart
    /// en recherche pour le scénario suivant.
    private func nextScan() {
        // En « Générer matériel » : quitter un scan lance la
        // génération de ses 30 copies tournées (arrière-plan,
        // reçu jamais coupé) — demandé par Grégoire.
        if appSection == .materiel, let last = bank.photos.last {
            bank.generateDerived(for: last)
        }
        // Le redémarrage de la caméra suit l'état (onChange) :
        // reset() republie .searching, qui relance la session.
        scanner.reset()
    }

    /// Passe la fenêtre en plein écran (à l'ouverture de l'app —
    /// la grande surface sert aussi le panneau d'éclairage).
    /// Différé : à onAppear, la fenêtre n'est pas toujours déjà là.
    private func enterFullScreen(attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let window = NSApp.keyWindow ?? NSApp.mainWindow
                ?? NSApp.windows.first { $0.isVisible }
            if let window {
                if !window.styleMask.contains(.fullScreen) {
                    window.toggleFullScreen(nil)
                }
            } else if attempt < 8 {
                // La fenêtre n'existe pas toujours encore au
                // onAppear (constaté le 2026-10-19 : plein écran
                // une fois sur deux) — quelques réessais brefs.
                enterFullScreen(attempt: attempt + 1)
            }
        }
    }
        }
}


/// Trait de marqueur (demande de Grégoire, 2026-10-20) : le
/// même « mouvement » pour toutes les régions — une bande aux
/// bords légèrement courbes et aux extrémités effilées, plutôt
/// qu'une étiquette rectangulaire parfaite. Aucune animation :
/// la forme est fixe, seule sa taille suit la région.
private struct MarkerStroke: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * w, y: rect.minY + y * h)
        }
        var p = Path()
        p.move(to: pt(0.012, 0.30))
        p.addQuadCurve(to: pt(0.988, 0.16), control: pt(0.5, 0.0))
        p.addQuadCurve(to: pt(1.0, 0.58), control: pt(1.0, 0.38))
        p.addQuadCurve(to: pt(0.02, 0.84), control: pt(0.5, 1.0))
        p.addQuadCurve(to: pt(0.0, 0.44), control: pt(0.0, 0.62))
        p.closeSubpath()
        return p
    }
}

/// Vue de révision du scan final (demande de Grégoire,
/// 2026-10-20) : l'image au centre, ses régions SURLIGNÉES
/// comme au marqueur — les réponses (commerce, date, total)
/// en VERT, les montants de la preuve (sous-total, TPS, TVQ)
/// en JAUNE — et chaque RÉPONSE ressort en EXTRAIT AGRANDI
/// dans les colonnes latérales, en alternance droite, gauche,
/// droite… reliée à sa région par un trait de sa couleur ;
/// l'extrait porte une étiquette rectangulaire de surlignage
/// verte. La preuve, elle, n'est pas agrandie : son jaune
/// reste sur le reçu seulement.
/// Le but : lire les réponses du programme sans plisser les
/// yeux, et VOIR la preuve, pas seulement la lire.
struct ZoomReviewView: View {
    let image: CGImage
    let boxes: [CGRect]
    let crops: [CGImage]
    let proofBoxes: [CGRect]

    /// Une région à surligner : sa boîte, son extrait agrandi
    /// (s'il a pu être découpé) et sa couleur de marqueur.
    private struct Item {
        let box: CGRect
        let crop: CGImage?
        let color: Color
    }

    private var items: [Item] {
        var out = boxes.indices.map {
            Item(box: boxes[$0],
                 crop: crops.indices.contains($0) ? crops[$0] : nil,
                 color: .green)
        }
        // Les montants de la preuve gardent leur surlignage
        // jaune SUR le reçu, mais ne sont PAS agrandis
        // (demande de Grégoire, 2026-10-20, 23 h) : aucun
        // extrait, donc aucun trait de liaison non plus.
        out += proofBoxes.indices.map {
            Item(box: proofBoxes[$0], crop: nil, color: .yellow)
        }
        return out
    }

    private func cardH(_ item: Item, colW: CGFloat) -> CGFloat {
        guard let c = item.crop, c.width > 0 else { return 30 }
        return max(20, colW * CGFloat(c.height) / CGFloat(c.width))
    }

    // Ordonnée du haut d'une carte dans sa colonne (pile
    // centrée verticalement) ; les cartes sont repérées par
    // leur rang dans la liste complète des régions.
    private func stackY(_ col: [(Int, Item)], _ rank: Int,
                        colW: CGFloat, height: CGFloat) -> CGFloat {
        let total = col.reduce(0) {
            $0 + cardH($1.1, colW: colW) + 18
        } - 18
        var y = max(0, (height - total) / 2)
        for (r, item) in col {
            if r == rank { break }
            y += cardH(item, colW: colW) + 18
        }
        return y
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let iw = CGFloat(image.width)
            let ih = CGFloat(image.height)
            let all = items
            let cards = all.enumerated()
                .filter { $0.element.crop != nil }
                .map { ($0.offset, $0.element) }
            let hasCrops = !cards.isEmpty
            let colW: CGFloat = hasCrops
                ? min(380, size.width * 0.26) : 0
            let gap: CGFloat = hasCrops ? 30 : 0
            let areaW = size.width - 2 * colW - 2 * gap
            let fit = min(areaW / iw, size.height / ih)
            let dw = iw * fit
            let dh = ih * fit
            let imgX = colW + gap + (areaW - dw) / 2
            let imgY = (size.height - dh) / 2
            let rightCards = cards.filter { $0.0 % 2 == 0 }
            let leftCards = cards.filter { $0.0 % 2 == 1 }

            ZStack(alignment: .topLeading) {
                // Traits de liaison région → extrait, chacun
                // de la couleur de sa région.
                if hasCrops {
                    ForEach(cards, id: \.0) { rank, item in
                        let onRight = rank % 2 == 0
                        let col = onRight ? rightCards : leftCards
                        let cardX: CGFloat = onRight
                            ? size.width - colW : 0
                        let cy = stackY(col, rank, colW: colW,
                                        height: size.height)
                            + cardH(item, colW: colW) / 2
                        let bx = imgX
                            + (onRight ? item.box.maxX
                                       : item.box.minX) * dw
                        let by = imgY + (1 - item.box.midY) * dh
                        Path { path in
                            path.move(to: CGPoint(x: bx, y: by))
                            path.addLine(to: CGPoint(
                                x: onRight ? cardX : cardX + colW,
                                y: cy))
                        }
                        .stroke(item.color, lineWidth: 1.5)
                    }
                }

                // Image principale et ses surlignages marqueur.
                Image(image, scale: 1, label: Text("Scan du reçu"))
                    .resizable()
                    .frame(width: dw, height: dh)
                    .offset(x: imgX, y: imgY)
                ForEach(all.indices, id: \.self) { i in
                    let b = all[i].box
                    MarkerStroke()
                        .fill(all[i].color.opacity(0.38))
                        .frame(width: b.width * dw,
                               height: b.height * dh)
                        .offset(x: imgX + b.minX * dw,
                                y: imgY + (1 - b.maxY) * dh)
                }

                // Extraits zoomés, encadrés de leur couleur.
                if hasCrops {
                    ForEach(cards, id: \.0) { rank, item in
                        let onRight = rank % 2 == 0
                        let col = onRight ? rightCards : leftCards
                        let cardX: CGFloat = onRight
                            ? size.width - colW : 0
                        let cy = stackY(col, rank, colW: colW,
                                        height: size.height)
                        Image(item.crop!, scale: 1,
                              label: Text("Extrait agrandi"))
                            .resizable()
                            .frame(width: colW,
                                   height: cardH(item, colW: colW))
                            // Étiquette rectangulaire de
                            // surlignage verte sur l'extrait
                            // même — pas un cadre, pas un
                            // trait de marqueur (demande de
                            // Grégoire, 2026-10-20, 23 h ;
                            // propre aux agrandis).
                            .overlay(Rectangle().fill(
                                item.color.opacity(0.3)))
                            .offset(x: cardX, y: cy)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }
}
