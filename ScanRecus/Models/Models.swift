import Foundation
import SwiftData

// MARK: - Entreprise

/// Une entreprise = un ensemble isolé de catégories, reçus et règles
/// d'apprentissage. Remplace l'ancien modèle « un fichier .db par entreprise ».
@Model
final class Company {
    var name: String
    var createdAt: Date
    /// Pour rouvrir la dernière entreprise consultée au lancement.
    var lastOpenedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Category.company)
    var categories: [Category] = []

    @Relationship(deleteRule: .cascade, inverse: \ReceiptItem.company)
    var receipts: [ReceiptItem] = []

    @Relationship(deleteRule: .cascade, inverse: \MerchantRule.company)
    var merchantRules: [MerchantRule] = []

    @Relationship(deleteRule: .cascade, inverse: \MerchantAlias.company)
    var merchantAliases: [MerchantAlias] = []

    init(name: String) {
        self.name = name
        let now = Date()
        self.createdAt = now
        self.lastOpenedAt = now
    }

    // MARK: Catégories

    /// Trouve ou crée une catégorie (insensible à la casse et aux espaces).
    @discardableResult
    func findOrCreateCategory(named rawName: String) -> Category? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let existing = categories.first(where: {
            $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }) {
            return existing
        }
        let cat = Category(name: name)
        categories.append(cat)  // l'inverse (cat.company) est mis à jour auto.
        return cat
    }

    var categoryNames: [String] {
        categories.map(\.name).sorted {
            $0.compare($1, options: .caseInsensitive) == .orderedAscending
        }
    }

    // MARK: Apprentissage commerce → catégorie

    /// Catégorie apprise pour ce commerce, sinon nil.
    func suggestCategory(for merchant: String) -> String? {
        let key = ReceiptParser.normalizeMerchant(merchant)
        guard !key.isEmpty else { return nil }
        return merchantRules.first(where: { $0.merchantKey == key })?.category
    }

    /// Retient que ce commerce → cette catégorie (nourri par les corrections
    /// de l'utilisateur dans l'écran de confirmation).
    func learn(merchant: String, category: String) {
        let key = ReceiptParser.normalizeMerchant(merchant)
        let cat = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !cat.isEmpty else { return }
        if let rule = merchantRules.first(where: { $0.merchantKey == key }) {
            rule.category = cat
            rule.hits += 1
        } else {
            merchantRules.append(MerchantRule(merchantKey: key, category: cat))
        }
    }

    // MARK: Alias de commerce (corrections de lecture OCR)

    /// Nom corrigé appris pour ce nom brut lu par l'OCR, sinon nil.
    /// Ex. l'OCR lit « TIM H0RTONS », l'utilisateur corrige en
    /// « Tim Hortons » : la prochaine fois, le nom lu sera remplacé.
    func correctedMerchantName(forRaw raw: String) -> String? {
        let key = ReceiptParser.normalizeMerchant(raw)
        guard !key.isEmpty else { return nil }
        return merchantAliases.first(where: { $0.rawKey == key })?.correctedName
    }

    /// Retient une correction de nom : « quand l'OCR lit ceci, le vrai
    /// nom est cela ». N'apprend rien si le nom corrigé, une fois
    /// normalisé, est identique au nom lu (simple différence de casse).
    func learnMerchantAlias(raw: String, corrected: String) {
        let key = ReceiptParser.normalizeMerchant(raw)
        let name = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !name.isEmpty,
              ReceiptParser.normalizeMerchant(name) != key else { return }
        if let alias = merchantAliases.first(where: { $0.rawKey == key }) {
            alias.correctedName = name
        } else {
            merchantAliases.append(
                MerchantAlias(rawKey: key, correctedName: name))
        }
    }

    // MARK: Reçus

    /// Enregistre un reçu. Crée la catégorie à la volée si elle est inédite
    /// (ex. « repas - en voyage » pour un reçu ramassé à l'étranger).
    @discardableResult
    func addReceipt(date: Date, merchant: String, category: String,
                    total: Double, currency: String = "CAD") -> ReceiptItem {
        if !category.isEmpty {
            findOrCreateCategory(named: category)
        }
        let receipt = ReceiptItem(date: date, merchant: merchant,
                                  category: category, total: total,
                                  currency: currency)
        receipts.append(receipt)
        if !merchant.isEmpty, !category.isEmpty {
            learn(merchant: merchant, category: category)
        }
        return receipt
    }

    /// Reçus d'un trimestre civil, triés par catégorie puis date croissante
    /// (format du rapport trimestriel).
    func receipts(year: Int, quarter: Int,
                  calendar: Calendar = .current) -> [ReceiptItem] {
        guard let bounds = QuarterHelper.quarterBounds(
            year: year, quarter: quarter, calendar: calendar) else { return [] }
        return receipts
            .filter { $0.date >= bounds.start && $0.date <= bounds.end }
            .sorted {
                let cmp = $0.category.compare($1.category,
                                              options: .caseInsensitive)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return $0.date < $1.date
            }
    }

    /// Reçus de plus de 10 ans, à supprimer via le ModelContext
    /// (avec confirmation explicite dans l'UI).
    func receiptsOlderThan10Years(
        calendar: Calendar = .current) -> [ReceiptItem] {
        let cutoff = QuarterHelper.tenYearsCutoff(calendar: calendar)
        return receipts.filter { $0.date < cutoff }
    }

    /// Nombre de reçus de plus de 10 ans (purge, avec confirmation).
    func countOlderThan10Years(calendar: Calendar = .current) -> Int {
        receiptsOlderThan10Years(calendar: calendar).count
    }
}

// MARK: - Catégorie

@Model
final class Category {
    var name: String
    var company: Company?

    init(name: String, company: Company? = nil) {
        self.name = name
        self.company = company
    }
}

// MARK: - Reçu

@Model
final class ReceiptItem {
    var date: Date
    var merchant: String
    var category: String
    var total: Double
    var currency: String
    var createdAt: Date
    var updatedAt: Date
    var company: Company?

    init(date: Date, merchant: String, category: String, total: Double,
         currency: String = "CAD", company: Company? = nil) {
        self.date = date
        self.merchant = merchant
        self.category = category
        self.total = total
        self.currency = currency
        let now = Date()
        self.createdAt = now
        self.updatedAt = now
        self.company = company
    }
}

// MARK: - Règle d'apprentissage

/// « Ce commerce → cette catégorie », avec compteur de renforcements.
@Model
final class MerchantRule {
    var merchantKey: String
    var category: String
    var hits: Int
    var company: Company?

    init(merchantKey: String, category: String, company: Company? = nil) {
        self.merchantKey = merchantKey
        self.category = category
        self.hits = 1
        self.company = company
    }
}

// MARK: - Alias de commerce

/// « Quand l'OCR lit ce nom brut, le vrai nom est celui-ci » —
/// appris quand l'utilisateur corrige le nom d'un commerce en révision.
@Model
final class MerchantAlias {
    var rawKey: String
    var correctedName: String
    var company: Company?

    init(rawKey: String, correctedName: String, company: Company? = nil) {
        self.rawKey = rawKey
        self.correctedName = correctedName
        self.company = company
    }
}

// MARK: - Persistance

/// Schéma versionné V1 (lot 3, 2026-10-20) : les modèles actuels,
/// figés sous ce numéro. Tout changement futur de modèle passe
/// par une V2 et une étape de migration dans le plan ci-dessous —
/// jamais par une modification silencieuse de V1.
enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Company.self, Category.self, ReceiptItem.self,
         MerchantRule.self, MerchantAlias.self]
    }
}

enum ScanRecusMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self]
    }

    static var stages: [MigrationStage] { [] }
}

/// Conteneur SwiftData unique, LOCAL (lot 3, 2026-10-20).
///
/// Avant : la base vivait dans le dossier « ScanReçus » du Google
/// Drive synchronisé de l'utilisateur (décision « pour l'instant »
/// du 2026-10-18), avec repli SILENCIEUX sur l'emplacement par
/// défaut quand ça échouait. Un fichier SQLite/WAL n'a rien à
/// faire dans un dossier synchronisé (corruption possible,
/// copies conflictuelles), et un repli muet rendait l'emplacement
/// réel inconnaissable. La base vit maintenant dans Application
/// Support, hors de toute synchronisation. Si elle ne peut pas
/// s'y ouvrir, l'échec est DIT dans `status` et le repli est en
/// mémoire seulement : l'app peut scanner, mais `isAvailable`
/// reste faux — rien ne doit annoncer « ✓ Enregistré » tant
/// qu'il l'est (l'ancien code faisait `try? save()` puis
/// annonçait le succès sans condition).
enum Persistence {
    /// État de la base, en mots — à lire avant tout message de
    /// confirmation d'enregistrement (étape 2).
    private(set) static var status = "non initialisée"
    /// Emplacement réel du fichier de base (sur disque local).
    private(set) static var storeURL: URL?
    /// Vrai seulement si la vraie base, sur disque, est ouverte.
    private(set) static var isAvailable = false

    static let shared: ModelContainer = {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let fm = FileManager.default
        let folder = fm.urls(for: .applicationSupportDirectory,
                             in: .userDomainMask)[0]
            .appendingPathComponent("ScanRecus", isDirectory: true)
        do {
            try fm.createDirectory(at: folder,
                                   withIntermediateDirectories: true)
        } catch {
            status = "BASE INDISPONIBLE — dossier local impossible "
                + "à créer (\(error.localizedDescription))"
        }
        let url = folder.appendingPathComponent("ScanRecus.sqlite")
        storeURL = url
        let configuration = ModelConfiguration(schema: schema, url: url)
        do {
            let container = try ModelContainer(
                for: schema, migrationPlan: ScanRecusMigrationPlan.self,
                configurations: [configuration])
            status = "base locale ouverte : \(url.path)"
            isAvailable = true
            return container
        } catch {
            status = "BASE INDISPONIBLE — la base locale n'a pas pu "
                + "s'ouvrir (\(error.localizedDescription)) ; "
                + "repli en mémoire, rien ne sera sauvegardé"
            let memory = ModelConfiguration(
                schema: schema, isStoredInMemoryOnly: true)
            if let container = try? ModelContainer(
                for: schema, configurations: [memory]) {
                return container
            }
            fatalError("Impossible de créer la base SwiftData : \(error)")
        }
    }()
}
