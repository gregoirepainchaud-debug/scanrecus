import SwiftUI
import SwiftData

// MARK: - Écran de scan (capture → révision libre)

/// NOUVELLE LOGIQUE — deux phases :
///
/// CAPTURE : le reçu est présenté à la caméra ; l'app accumule les
/// meilleures lectures de toutes les images (pastilles rouge/jaune/vert
/// par champ). Quand commerce + total sont nets et stables ~0,8 s, le
/// scan se FIGE tout seul. Figeage manuel : ESPACE, ENTRÉE, clic sur
/// l'image ou bouton. Survol souris : la ligne OCR sous le curseur
/// s'encadre en orange et son texte s'affiche à l'endroit.
///
/// RÉVISION : le scan figé est révisé LIBREMENT dans 4 champs texte.
///   TAB     passe d'un champ à l'autre ;
///   ENTRÉE  confirme le champ en cours (✓) ;
///   ENTRÉE ou ESPACE, aucun champ en édition = NEXT (enregistrer) ;
///   ÉCHAP   hors champ : jeter le scan et rescanner.
/// Les lignes du scan figé sont listées à l'endroit : cliquer une ligne
/// la verse dans le champ en cours d'édition. Le dernier reçu
/// enregistré peut être modifié ou supprimé (zone du bas).
///
/// APERÇU commutable (bouton, choix mémorisé) : miroir = déplacements
/// intuitifs mais texte inversé ; normal = texte lisible mais
/// déplacements inversés — avec une caméra de face, on ne peut pas
/// avoir les deux (il faudrait une caméra plongeante).
struct ScanDebugView: View {
    @State private var camera = CameraManager()
    @StateObject private var engine = ScanEngine()
    @StateObject private var flow = ScanFlowController()
    @FocusState private var viewFocused: Bool
    /// Champ de révision en cours d'édition (nil = aucun).
    @FocusState private var focus: ScanFlowController.ReviewField?
    /// Position du curseur sur l'image (nil hors de l'image).
    @State private var hoverPoint: CGPoint?
    /// Mode d'aperçu mémorisé : vrai = miroir (déplacements intuitifs,
    /// texte inversé), faux = normal (texte lisible, déplacements inversés).
    @AppStorage("previewMirrored") private var previewMirrored = true

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.locale = Locale(identifier: "fr_CA")
        return f
    }()

    /// Chemin réel de la base SwiftData (diagnostic : Drive ou local ?).
    private var databasePath: String {
        Persistence.shared.configurations.first?.url.path ?? "inconnu"
    }

    private var isReviewing: Bool { flow.phase == .reviewing }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack {
                    CameraPreviewView(session: camera.session)
                        // Miroir commutable, appliqué au niveau SwiftUI
                        // (le rendu de la vue), indépendant d'AVFoundation.
                        // Les données OCR, elles, restent non miroitée.
                        .scaleEffect(x: previewMirrored ? -1 : 1, y: 1,
                                     anchor: .center)
                        .opacity(isReviewing ? 0.35 : 1)
                    ScanOverlayView(quad: isReviewing ? nil : engine.receiptQuad,
                                    totalBox: isReviewing ? nil : engine.totalBox,
                                    hoverRect: isReviewing
                                        ? nil : hoverRect(in: geo.size),
                                    mirrored: previewMirrored,
                                    size: geo.size)
                    // Texte de la ligne survolée, affiché À L'ENDROIT.
                    if !isReviewing, let line = hoveredLine(in: geo.size) {
                        Text(line.text)
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: .topLeading)
                            .padding(10)
                            .allowsHitTesting(false)
                    }
                    if isReviewing {
                        Text("SCAN FIGÉ — révision en cours")
                            .font(.system(size: 15, weight: .bold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .allowsHitTesting(false)
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoverPoint = location
                    case .ended:
                        hoverPoint = nil
                    }
                }
                .onTapGesture {
                    // En capture, cliquer l'image fige le scan.
                    if !isReviewing {
                        flow.freeze()
                        viewFocused = true
                    }
                }
            }
            .frame(minHeight: 200)

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

                if isReviewing {
                    reviewPanel
                } else {
                    capturePanel
                }

                Divider()

                HStack(spacing: 16) {
                    Text("Entreprise : \(flow.companyName)")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                    Text("Base : \(databasePath)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(previewMirrored
                           ? "Aperçu : miroir" : "Aperçu : texte lisible") {
                        previewMirrored.toggle()
                    }
                    .focusable(false)
                }

                Text("Drive : \(Persistence.driveStatus)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                // Dernière entrée : résumé + correction après coup.
                if let summary = flow.lastEntrySummary {
                    Divider()
                    if flow.isEditingLastEntry {
                        lastEntryEditor
                    } else {
                        HStack(spacing: 12) {
                            Text(summary)
                                .font(.system(size: 14))
                            Spacer()
                            Button("Modifier la dernière entrée") {
                                flow.beginEditLastEntry()
                            }
                            .focusable(false)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
            .layoutPriority(1)
        }
        .frame(minWidth: 780, minHeight: 800)
        .focusable()
        .focused($viewFocused)
        .onAppear {
            camera.start(delegate: engine)
            // Différé d'un tour de boucle : attacher le flux (qui publie
            // l'entreprise et les catégories) et demander le focus
            // PENDANT le rafraîchissement initial provoque l'avertissement
            // « Publishing changes from within view updates ».
            DispatchQueue.main.async {
                flow.attach(engine: engine)
                viewFocused = true
            }
        }
        .onDisappear { camera.stop() }
        .onKeyPress(.return) {
            if flow.isEditingLastEntry { return .ignored }
            if focus != nil { return .ignored }  // le champ confirme via onSubmit
            if isReviewing { attemptNext() } else { flow.freeze() }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: " ")) { _ in
            if flow.isEditingLastEntry { return .ignored }
            if focus != nil { return .ignored }  // espace dans le texte du champ
            if isReviewing { attemptNext() } else { flow.freeze() }
            return .handled
        }
        .onKeyPress(.escape) {
            if flow.isEditingLastEntry {
                flow.cancelLastEntryEdit()
                return .handled
            }
            if focus != nil {
                focus = nil  // sortir du champ sans confirmer
                return .handled
            }
            if isReviewing { flow.rescan() }
            return .handled
        }
        .alert("Doublon détecté", isPresented: $flow.duplicatePending) {
            Button("Procéder quand même") { flow.proceedWithSaveAnyway() }
            Button("Annuler", role: .cancel) { flow.cancelSave() }
        } message: {
            Text(flow.duplicateDescription)
        }
    }

    // MARK: - Panneau capture

    @ViewBuilder
    private var capturePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            captureRow(title: "Commerce",
                       value: flow.accMerchant.isEmpty
                          ? "—" : flow.accMerchant,
                       level: flow.accMerchantLevel)
            captureRow(title: "Date",
                       value: Self.dateFormatter.string(from: flow.accDate),
                       level: flow.accDateLevel)
            captureRow(title: "Total",
                       value: flow.accTotal.map {
                          String(format: "%.2f $", $0)
                       } ?? "—",
                       level: flow.accTotalLevel)
            captureRow(title: "Catégorie",
                       value: flow.accCategory.isEmpty
                          ? "—" : flow.accCategory,
                       level: flow.accCategory.isEmpty ? .low : .high)

            HStack(spacing: 12) {
                Text(flow.captureHint)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                Spacer()
                if let saved = flow.savedMessage {
                    Text(saved)
                        .foregroundColor(.green)
                        .font(.system(size: 15, weight: .medium))
                }
                Button("Figer le scan et réviser (Espace)") { flow.freeze() }
                    .controlSize(.large)
                    .focusable(false)
            }

            Text("Analyses : \(engine.analysesCount)  •  max 5/s  •  Les lectures nettes (vert) sont conservées : l'app assemble le meilleur de chaque image.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func captureRow(title: String, value: String,
                            level: ConfidenceLevel) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Self.color(for: level))
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(
                    Color.secondary.opacity(0.35), lineWidth: 1))
            Text(title)
                .font(.system(size: 16))
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.system(size: 17))
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.clear)
        .cornerRadius(8)
    }

    // MARK: - Panneau révision

    @ViewBuilder
    private var reviewPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Révision du scan figé")
                .font(.system(size: 17, weight: .bold))
            Text("TAB : champ suivant  •  ENTRÉE : confirmer le champ (✓)  •  ENTRÉE ou ESPACE hors champ : Next  •  ÉCHAP : rescanner")
                .font(.system(size: 12.5))
                .foregroundColor(.secondary)

            reviewRow(field: .merchant, title: "Commerce", hint: nil)
            reviewRow(field: .date, title: "Date",
                      hint: "AAAA-MM-JJ ou JJ/MM/AAAA")
            reviewRow(field: .total, title: "Total", hint: nil)
            reviewRow(field: .category, title: "Catégorie", hint: nil)

            if !flow.categoryNames.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Catégories existantes — cliquez pour choisir :")
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130),
                                                 spacing: 6)],
                              alignment: .leading, spacing: 6) {
                        ForEach(flow.categoryNames, id: \.self) { name in
                            Button(name) { flow.pickCategory(name) }
                                .font(.system(size: 14))
                                .focusable(false)
                        }
                    }
                }
            }

            if !flow.frozenLines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Texte du scan figé — cliquez une ligne pour la verser dans le champ en édition :")
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(flow.frozenLines.enumerated()),
                                    id: \.offset) { _, line in
                                Button(line) {
                                    if let f = focus {
                                        flow.applyLine(line, to: f)
                                    }
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 12.5, design: .monospaced))
                                .focusable(false)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 84)
                }
            }

            HStack(spacing: 12) {
                Button("✓ Next — enregistrer le reçu") { attemptNext() }
                    .controlSize(.large)
                    .focusable(false)
                Button("Rescanner") {
                    focus = nil
                    flow.rescan()
                }
                .controlSize(.large)
                .focusable(false)
                Spacer()
                Text("Confirmés : \(flow.confirmed.count)/4")
                    .font(.system(size: 12.5))
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func reviewRow(field: ScanFlowController.ReviewField,
                           title: String, hint: String?) -> some View {
        let isConfirmed = flow.confirmed.contains(field)
        HStack(spacing: 10) {
            Image(systemName: isConfirmed
                  ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isConfirmed ? .green : .secondary)
                .font(.system(size: 15))
            Text(title)
                .font(.system(size: 16,
                              weight: focus == field ? .bold : .regular))
                .frame(width: 92, alignment: .leading)
            TextField(title, text: draftBinding(field))
                .font(.system(size: 16))
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: field)
                .onSubmit { confirmAndRelease(field) }
            if let hint {
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    /// Liaison d'un champ du brouillon : écrire « déconfirme » le champ
    /// (voir ScanFlowController.setText) ; les écritures programmées
    /// (figeage) passent par les propriétés, pas par ici.
    private func draftBinding(
        _ field: ScanFlowController.ReviewField) -> Binding<String> {
        Binding(get: { flow.text(for: field) },
                set: { flow.setText($0, for: field) })
    }

    /// ENTRÉE dans un champ : le confirme ; si la valeur est illisible,
    /// le focus reste dans le champ.
    private func confirmAndRelease(_ field: ScanFlowController.ReviewField) {
        if flow.confirmField(field) {
            focus = nil
        }
    }

    /// NEXT : si le total est illisible, focus sur le champ Total.
    private func attemptNext() {
        if flow.next() {
            focus = nil
        } else {
            focus = .total
        }
    }

    // MARK: - Éditeur de la dernière entrée

    @ViewBuilder
    private var lastEntryEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Modifier la dernière entrée")
                .font(.system(size: 15, weight: .semibold))
            lastEditRow(label: "Commerce",
                        text: $flow.lastEditMerchant, hint: nil)
            lastEditRow(label: "Date", text: $flow.lastEditDateText,
                        hint: "AAAA-MM-JJ ou JJ/MM/AAAA")
            lastEditRow(label: "Total", text: $flow.lastEditTotalText,
                        hint: nil)
            lastEditRow(label: "Catégorie", text: $flow.lastEditCategory,
                        hint: nil)
            HStack(spacing: 12) {
                Button("Enregistrer") { flow.commitLastEntryEdit() }
                    .focusable(false)
                Button("Annuler") { flow.cancelLastEntryEdit() }
                    .focusable(false)
                Spacer()
                Button("Supprimer l'entrée", role: .destructive) {
                    flow.deleteLastEntry()
                }
                .focusable(false)
            }
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private func lastEditRow(label: String, text: Binding<String>,
                             hint: String?) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 15))
                .frame(width: 84, alignment: .leading)
            TextField(label, text: text)
                .font(.system(size: 15))
                .textFieldStyle(.roundedBorder)
                .onSubmit { flow.commitLastEntryEdit() }
            if let hint {
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Survol souris (phase capture)

    /// Ligne OCR sous le curseur (la plus petite si plusieurs se
    /// chevauchent — les lignes d'un reçu ne se chevauchent guère).
    private func hoveredLine(in size: CGSize) -> OCRLine? {
        guard let hoverPoint else { return nil }
        var best: OCRLine?
        var bestArea = CGFloat.greatestFiniteMagnitude
        for line in engine.ocrLines {
            let rect = screenRect(line.box, in: size)
            if rect.contains(hoverPoint) {
                let area = rect.width * rect.height
                if area < bestArea {
                    bestArea = area
                    best = line
                }
            }
        }
        return best
    }

    private func hoverRect(in size: CGSize) -> CGRect? {
        hoveredLine(in: size).map { screenRect($0.box, in: size) }
    }

    private static func color(for level: ConfidenceLevel) -> Color {
        switch level {
        case .low: return .red
        case .medium: return .yellow
        case .high: return .green
        }
    }

    /// Vision (normalisé 0…1, origine bas-gauche, image NON miroitée)
    /// → écran (origine haut-gauche ; X inversé seulement en mode miroir).
    private func screenRect(_ r: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: (previewMirrored ? 1 - r.maxX : r.minX) * size.width,
               y: (1 - r.maxY) * size.height,
               width: r.width * size.width,
               height: r.height * size.height)
    }
}

// MARK: - Surcouche graphique

/// Dessine le contour du reçu (jaune), la boîte du total (vert) et le
/// cadre de sélection souris (orange, déjà en coordonnées écran).
///
/// Conversions de coordonnées : Vision travaille en normalisé 0…1,
/// origine en bas à gauche, image NON miroitée ; Y est toujours inversé
/// (origine haut-gauche de SwiftUI), X seulement en mode miroir.
struct ScanOverlayView: View {
    let quad: [CGPoint]?
    let totalBox: CGRect?
    let hoverRect: CGRect?
    let mirrored: Bool
    let size: CGSize

    private func screenPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (mirrored ? 1 - p.x : p.x) * size.width,
                y: (1 - p.y) * size.height)
    }

    private func screenRect(_ r: CGRect) -> CGRect {
        CGRect(x: (mirrored ? 1 - r.maxX : r.minX) * size.width,
               y: (1 - r.maxY) * size.height,
               width: r.width * size.width,
               height: r.height * size.height)
    }

    var body: some View {
        ZStack {
            if let quad, quad.count == 4 {
                // Contour du reçu.
                Path { path in
                    path.move(to: screenPoint(quad[0]))
                    for p in quad.dropFirst() {
                        path.addLine(to: screenPoint(p))
                    }
                    path.closeSubpath()
                }
                .stroke(Color.yellow, lineWidth: 2)
            }
            if let hoverRect {
                // Ligne OCR survolée (phase capture).
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: hoverRect.width, height: hoverRect.height)
                    .position(x: hoverRect.midX, y: hoverRect.midY)
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.orange, lineWidth: 2.5)
                    .frame(width: hoverRect.width, height: hoverRect.height)
                    .position(x: hoverRect.midX, y: hoverRect.midY)
            }
            if let box = totalBox {
                let rect = screenRect(box)
                Rectangle()
                    .stroke(Color.green, lineWidth: 3)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
    }
}
