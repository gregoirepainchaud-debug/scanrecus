import Foundation
import SwiftData
import Combine

// MARK: - Flux capture → scan figé → révision libre

/// Date par défaut du flux : 1er jour du trimestre civil précédent
/// (QuarterHelper la rend optionnelle ; repli sur aujourd'hui).
private func scanDefaultDate() -> Date {
    QuarterHelper.previousQuarterStart() ?? Date()
}

/// NOUVELLE LOGIQUE (2026-10-18, demandée par Grégoire) — deux phases.
///
/// PHASE CAPTURE : l'utilisateur présente le reçu à la caméra, vite.
/// L'app accumule les MEILLEURES lectures de toutes les images
/// analysées (5/s) : un champ lu nettement (vert) est conservé et
/// n'est remplacé que par une lecture meilleure. C'est l'« assemblage »
/// des images — au niveau des lectures plutôt que des pixels — qui
/// produit le scan temporaire : complet, net, sans stocker d'image.
///
/// FIGEAGE : quand commerce + total sont nets (verts) et stables
/// ~0,8 s, le scan se fige tout seul. Figeage manuel à tout moment
/// (ESPACE / ENTRÉE / clic sur l'image / bouton).
///
/// PHASE RÉVISION : révision LIBRE des champs du scan figé.
/// TAB passe d'un champ à l'autre ; ENTRÉE confirme le champ en cours
/// (✓) ; ENTRÉE ou ESPACE quand aucun champ n'est en édition = NEXT
/// (enregistre, avec contrôle des doublons, puis retour en capture).
/// ÉCHAP hors champ = jeter le scan et rescanner. Les lignes OCR du
/// scan figé sont affichées à l'endroit ; cliquer une ligne la verse
/// dans le champ en cours d'édition.
///
/// APPRENTISSAGE des corrections faites en révision :
/// - commerce → catégorie (comme avant, via addReceipt) ;
/// - nom de commerce corrigé → alias : la prochaine fois que l'OCR
///   lira le même nom brut, le nom corrigé sera proposé d'emblée.
@MainActor
final class ScanFlowController: ObservableObject {

    enum Phase {
        case capturing, reviewing
    }

    enum ReviewField: CaseIterable, Hashable {
        case merchant, date, total, category
    }

    // MARK: Phase capture (meilleures lectures accumulées)

    @Published private(set) var phase: Phase = .capturing
    @Published private(set) var accMerchant = ""
    @Published private(set) var accMerchantLevel: ConfidenceLevel = .low
    @Published private(set) var accDate: Date = scanDefaultDate()
    @Published private(set) var accDateLevel: ConfidenceLevel = .low
    @Published private(set) var accTotal: Double?
    @Published private(set) var accTotalLevel: ConfidenceLevel = .low
    /// Catégorie suggérée pour le commerce accumulé.
    @Published private(set) var accCategory = ""
    @Published private(set) var captureHint = "Présentez un reçu à la caméra…"

    private var accRawMerchant = ""       // nom OCR brut (pour les alias)
    private var accDateIsPlaceholder = true
    private var lastRawText = ""
    private var stableSignature: String?
    private var stableSince: Date?

    // MARK: Phase révision (scan figé, brouillon éditable)

    @Published var draftMerchant = ""
    @Published var draftDateText = ""
    @Published var draftTotalText = ""
    @Published var draftCategory = ""
    /// Champs confirmés par l'utilisateur (ou nets dès le figeage).
    @Published private(set) var confirmed: Set<ReviewField> = []
    /// Lignes OCR du scan figé, affichées à l'endroit pour la révision.
    @Published private(set) var frozenLines: [String] = []
    private var frozenRawMerchant = ""

    // MARK: Commun

    @Published private(set) var savedMessage: String?
    @Published private(set) var companyName: String = "…"
    /// Catégories existantes de l'entreprise (pastilles cliquables).
    @Published private(set) var categoryNames: [String] = []
    /// Vrai quand un doublon attend la décision de l'utilisateur.
    @Published var duplicatePending = false
    @Published private(set) var duplicateDescription = ""

    // MARK: Dernière entrée enregistrée (correction après coup)

    @Published private(set) var lastEntrySummary: String?
    @Published var isEditingLastEntry = false
    @Published var lastEditMerchant = ""
    @Published var lastEditDateText = ""
    @Published var lastEditTotalText = ""
    @Published var lastEditCategory = ""
    private var lastSavedReceipt: ReceiptItem?

    private var context: ModelContext?
    private var company: Company?
    private var subscription: AnyCancellable?

    /// À appeler une fois : charge l'entreprise (la dernière consultée,
    /// sinon en crée une) et s'abonne au moteur de scan.
    func attach(engine: ScanEngine) {
        if context == nil {
            let ctx = ModelContext(Persistence.shared)
            context = ctx
            loadCompany(ctx)
        }
        subscription = engine.$scan
            .receive(on: DispatchQueue.main)
            .sink { [weak self] scan in
                guard let self else { return }
                Task { @MainActor in self.ingest(scan) }
            }
    }

    // MARK: - Capture : accumulation des meilleures lectures

    private static func rank(_ level: ConfidenceLevel) -> Int {
        switch level {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    private func ingest(_ scan: ScanDetection?) {
        // En révision (ou en correction de la dernière entrée), la
        // capture est suspendue : le scan figé ne bouge plus.
        guard phase == .capturing, !isEditingLastEntry else { return }
        guard let scan else {
            stableSignature = nil
            stableSince = nil
            return
        }
        let r = scan.result
        lastRawText = r.rawText

        // Commerce : alias appris d'abord ; la meilleure confiance gagne
        // (à confiance égale, la première lecture nette est conservée).
        if !r.merchant.isEmpty {
            let corrected = company?.correctedMerchantName(forRaw: r.merchant)
            let name = corrected ?? r.merchant
            if accMerchant.isEmpty
                || Self.rank(scan.merchantLevel) > Self.rank(accMerchantLevel) {
                accMerchant = name
                accRawMerchant = r.merchant
                accMerchantLevel = scan.merchantLevel
            }
        }
        // Date : première lecture réelle acceptée, ensuite seules les
        // meilleures remplacent.
        if let d = r.date {
            if accDateIsPlaceholder
                || Self.rank(scan.dateLevel) > Self.rank(accDateLevel) {
                accDate = d
                accDateLevel = scan.dateLevel
                accDateIsPlaceholder = false
            }
        }
        // Total : la meilleure lecture gagne — un total prouvé par
        // addition (vert) n'est jamais remplacé par moins bon.
        if let t = r.total {
            if accTotal == nil
                || Self.rank(scan.totalLevel) > Self.rank(accTotalLevel) {
                accTotal = t
                accTotalLevel = scan.totalLevel
            }
        }
        accCategory = company?.suggestCategory(for: accMerchant) ?? ""
        updateCaptureHint()
        checkAutoFreeze()
    }

    private func updateCaptureHint() {
        if accMerchant.isEmpty && accTotal == nil {
            captureHint = "Présentez un reçu à la caméra…"
        } else if accTotal == nil {
            captureHint = "Reçu détecté — à la recherche du total…"
        } else if accMerchantLevel != .high || accTotalLevel != .high {
            captureHint = "Lecture en cours — stabilisez le reçu pour figer le scan…"
        } else {
            captureHint = "Tout est net — figeage du scan…"
        }
    }

    /// Figeage automatique : commerce + total nets (verts) et contenu
    /// stable depuis ~0,8 s.
    private func checkAutoFreeze() {
        let signature = "\(accMerchant)|\(accDate.timeIntervalSince1970)|\(accTotal ?? -1)"
        if signature != stableSignature {
            stableSignature = signature
            stableSince = Date()
            return
        }
        guard accMerchantLevel == .high, accTotalLevel == .high,
              let since = stableSince,
              Date().timeIntervalSince(since) >= 0.8 else { return }
        freeze()
    }

    // MARK: - Figeage

    /// Fige le scan temporaire et passe en révision. Le brouillon part
    /// des meilleures lectures ; les champs nets sont déjà confirmés.
    func freeze() {
        guard phase == .capturing, !isEditingLastEntry else { return }
        phase = .reviewing
        savedMessage = nil
        frozenRawMerchant = accRawMerchant
        frozenLines = lastRawText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        draftMerchant = accMerchant
        draftDateText = Self.editDateFormatter.string(from: accDate)
        draftTotalText = accTotal.map { String(format: "%.2f", $0) } ?? ""
        draftCategory = accCategory
        confirmed = []
        if accMerchantLevel == .high, !accMerchant.isEmpty {
            confirmed.insert(.merchant)
        }
        if accDateLevel == .high { confirmed.insert(.date) }
        if accTotalLevel == .high, accTotal != nil {
            confirmed.insert(.total)
        }
        if !draftCategory.isEmpty { confirmed.insert(.category) }
    }

    /// Jette le scan figé et repart en capture (ÉCHAP / bouton Rescanner).
    func rescan() {
        guard phase == .reviewing else { return }
        phase = .capturing
        resetAccumulator()
    }

    private func resetAccumulator() {
        accMerchant = ""
        accMerchantLevel = .low
        accRawMerchant = ""
        accDate = scanDefaultDate()
        accDateLevel = .low
        accDateIsPlaceholder = true
        accTotal = nil
        accTotalLevel = .low
        accCategory = ""
        lastRawText = ""
        stableSignature = nil
        stableSince = nil
        captureHint = "Présentez un reçu à la caméra…"
    }

    // MARK: - Révision : accès aux champs du brouillon

    func text(for field: ReviewField) -> String {
        switch field {
        case .merchant: return draftMerchant
        case .date: return draftDateText
        case .total: return draftTotalText
        case .category: return draftCategory
        }
    }

    /// Écriture par l'utilisateur (clavier) : toute modification
    /// « déconfirme » le champ — ENTRÉE le re-confirmera.
    func setText(_ newValue: String, for field: ReviewField) {
        switch field {
        case .merchant: draftMerchant = newValue
        case .date: draftDateText = newValue
        case .total: draftTotalText = newValue
        case .category: draftCategory = newValue
        }
        confirmed.remove(field)
    }

    /// ENTRÉE dans un champ : valide et confirme le champ.
    /// Retourne faux si la valeur est illisible (date/montant) — la vue
    /// garde alors le focus dans le champ.
    @discardableResult
    func confirmField(_ field: ReviewField) -> Bool {
        switch field {
        case .merchant:
            draftMerchant = draftMerchant
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case .date:
            guard let d = ReceiptParser.parseDate(draftDateText)
            else { return false }
            draftDateText = Self.editDateFormatter.string(from: d)
        case .total:
            guard let v = ReceiptParser.parseAmount(draftTotalText)
            else { return false }
            draftTotalText = String(format: "%.2f", v)
        case .category:
            draftCategory = draftCategory
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        confirmed.insert(field)
        return true
    }

    /// Pastille de catégorie cliquée : choisie et confirmée.
    func pickCategory(_ name: String) {
        draftCategory = name
        confirmed.insert(.category)
    }

    /// Ligne du scan figé cliquée : versée dans le champ en édition
    /// (si elle contient quelque chose d'exploitable pour ce champ).
    func applyLine(_ line: String, to field: ReviewField) {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch field {
        case .merchant:
            setText(text, for: .merchant)
        case .date:
            if let d = ReceiptParser.parseDate(text) {
                setText(Self.editDateFormatter.string(from: d), for: .date)
            }
        case .total:
            if let v = ReceiptParser.allAmounts(text).map(\.value).last {
                setText(String(format: "%.2f", v), for: .total)
            }
        case .category:
            setText(text, for: .category)
        }
    }

    // MARK: - Next : enregistrer le scan révisé

    /// Valeurs finales du brouillon (date illisible → date accumulée,
    /// elle-même par défaut le 1er jour du trimestre à fermer).
    private var finalMerchant: String {
        draftMerchant.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var finalDate: Date {
        ReceiptParser.parseDate(draftDateText) ?? accDate
    }
    private var finalCategory: String {
        let cat = draftCategory
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cat.isEmpty ? "Sans catégorie" : cat
    }

    /// NEXT (ENTRÉE/ESPACE hors champ, ou bouton) : enregistre le reçu.
    /// Retourne faux seulement si le total est manquant/illisible —
    /// la vue met alors le focus sur le champ Total.
    @discardableResult
    func next() -> Bool {
        guard phase == .reviewing else { return true }
        guard ReceiptParser.parseAmount(draftTotalText) != nil
        else { return false }
        if let duplicate = findDuplicate() {
            duplicateDescription =
                "Un reçu identique existe déjà : \(duplicate.merchant) — " +
                "\(Self.displayDateFormatter.string(from: duplicate.date)) — " +
                "\(String(format: "%.2f", duplicate.total)) $. " +
                "Voulez-vous procéder quand même ?"
            duplicatePending = true
            return true
        }
        save()
        return true
    }

    /// Reçu déjà en base ? Même commerce (normalisé), même jour,
    /// même montant.
    private func findDuplicate() -> ReceiptItem? {
        guard let company,
              let amount = ReceiptParser.parseAmount(draftTotalText)
        else { return nil }
        let key = ReceiptParser.normalizeMerchant(finalMerchant)
        let calendar = Calendar.current
        let date = finalDate
        return company.receipts.first { existing in
            calendar.isDate(existing.date, inSameDayAs: date)
                && abs(existing.total - amount) < 0.005
                && ReceiptParser.normalizeMerchant(existing.merchant) == key
        }
    }

    /// Réponse « Procéder quand même » à l'alerte de doublon.
    func proceedWithSaveAnyway() {
        duplicatePending = false
        save()
    }

    /// Réponse « Annuler » à l'alerte de doublon : on reste en révision.
    func cancelSave() {
        duplicatePending = false
    }

    private func save() {
        guard let company, let context,
              let amount = ReceiptParser.parseAmount(draftTotalText)
        else { return }
        let merchant = finalMerchant
        // addReceipt crée la catégorie à la volée si elle est nouvelle
        // et apprend commerce → catégorie.
        let saved = company.addReceipt(date: finalDate, merchant: merchant,
                                       category: finalCategory, total: amount)
        // Apprentissage du nom : si le nom final diffère du nom brut lu
        // par l'OCR, retenir l'alias pour les prochains reçus.
        if !frozenRawMerchant.isEmpty, !merchant.isEmpty {
            company.learnMerchantAlias(raw: frozenRawMerchant,
                                       corrected: merchant)
        }
        try? context.save()
        refreshCategoryNames()
        lastSavedReceipt = saved
        lastEntrySummary = Self.summary(for: saved)
        savedMessage = "✓ Enregistré : \(merchant.isEmpty ? "Reçu" : merchant) — \(String(format: "%.2f", amount)) $"
        phase = .capturing
        resetAccumulator()
    }

    // MARK: - Dernière entrée : modifier / supprimer

    func beginEditLastEntry() {
        guard let r = lastSavedReceipt else { return }
        lastEditMerchant = r.merchant
        lastEditDateText = Self.editDateFormatter.string(from: r.date)
        lastEditTotalText = String(format: "%.2f", r.total)
        lastEditCategory = r.category
        isEditingLastEntry = true
    }

    /// ENTRÉE dans l'éditeur : applique les corrections à la dernière
    /// entrée. Date/montant illisibles → on reste dans l'éditeur.
    func commitLastEntryEdit() {
        guard let r = lastSavedReceipt, let company, let context
        else { return }
        guard let d = ReceiptParser.parseDate(lastEditDateText),
              let v = ReceiptParser.parseAmount(lastEditTotalText)
        else { return }
        r.merchant = lastEditMerchant
            .trimmingCharacters(in: .whitespacesAndNewlines)
        r.date = d
        r.total = v
        let cat = lastEditCategory
            .trimmingCharacters(in: .whitespacesAndNewlines)
        r.category = cat.isEmpty ? "Sans catégorie" : cat
        r.updatedAt = Date()
        company.findOrCreateCategory(named: r.category)
        if !r.merchant.isEmpty {
            company.learn(merchant: r.merchant, category: r.category)
        }
        try? context.save()
        refreshCategoryNames()
        lastEntrySummary = Self.summary(for: r)
        isEditingLastEntry = false
    }

    func cancelLastEntryEdit() {
        isEditingLastEntry = false
    }

    /// Supprime complètement la dernière entrée enregistrée.
    func deleteLastEntry() {
        guard let r = lastSavedReceipt, let context else { return }
        context.delete(r)
        try? context.save()
        lastSavedReceipt = nil
        lastEntrySummary = nil
        isEditingLastEntry = false
        savedMessage = "Dernière entrée supprimée."
    }

    private static func summary(for r: ReceiptItem) -> String {
        let name = r.merchant.isEmpty ? "—" : r.merchant
        return "Dernier reçu : \(name) • " +
            "\(displayDateFormatter.string(from: r.date)) • " +
            "\(String(format: "%.2f", r.total)) $ • \(r.category)"
    }

    // MARK: - Entreprise

    private func loadCompany(_ ctx: ModelContext) {
        let descriptor = FetchDescriptor<Company>(
            sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)])
        let companies = (try? ctx.fetch(descriptor)) ?? []
        if let first = companies.first {
            company = first
            first.lastOpenedAt = Date()
        } else {
            // Phase transitoire : la gestion multi-entreprises arrive
            // avec l'interface complète (phase 3).
            let created = Company(name: "Mon entreprise")
            ctx.insert(created)
            company = created
        }
        try? ctx.save()
        companyName = company?.name ?? "—"
        refreshCategoryNames()
    }

    private func refreshCategoryNames() {
        categoryNames = company?.categoryNames ?? []
    }

    // MARK: - Formats

    /// Format de saisie de la date (l'analyse accepte aussi JJ/MM/AAAA).
    private static let editDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_CA")
        return f
    }()

    private static let displayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.locale = Locale(identifier: "fr_CA")
        return f
    }()
}
