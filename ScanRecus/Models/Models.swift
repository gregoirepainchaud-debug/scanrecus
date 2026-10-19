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

/// Conteneur SwiftData unique.
enum Persistence {
    /// Nom comparé sans accents ni casse (le « ê » de « ScanReçus » peut
    /// être codé de plusieurs façons sur le disque).
    private static func folded(_ s: String) -> String {
        s.folding(options: .diacriticInsensitive,
                  locale: Locale(identifier: "fr"))
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
    }

    /// Cherche le dossier « ScanReçus » à la racine du Google Drive
    /// local EN LISANT LES NOMS RÉELS sur le disque (plutôt qu'en
    /// construisant le chemin de toutes pièces) : insensible aux
    /// accents, à la casse et à la normalisation Unicode.
    private static func driveFolderURL() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var roots: [URL] = []
        // Emplacement moderne : ~/Library/CloudStorage/GoogleDrive-<compte>/
        let cloud = home.appendingPathComponent("Library/CloudStorage")
        if let accounts = try? fm.contentsOfDirectory(
            at: cloud, includingPropertiesForKeys: nil) {
            roots += accounts.filter {
                $0.lastPathComponent.hasPrefix("GoogleDrive")
            }
        }
        // Ancien emplacement (Backup & Sync) : ~/Google Drive/
        roots.append(home.appendingPathComponent("Google Drive"))

        for root in roots {
            // Niveau 1 : la racine elle-même, ou « Mon Drive »/« My Drive ».
            var bases: [URL] = [root]
            if let children = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil) {
                bases += children.filter {
                    let name = folded($0.lastPathComponent)
                    return name == "mon drive" || name == "my drive"
                }
            }
            for base in bases {
                guard let children = try? fm.contentsOfDirectory(
                    at: base, includingPropertiesForKeys: nil)
                else { continue }
                guard let match = children.first(where: {
                    folded($0.lastPathComponent) == "scanrecus"
                }) else { continue }
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: match.path, isDirectory: &isDir),
                   isDir.boolValue {
                    return match
                }
            }
        }
        return nil
    }

    private static var _driveStatus = "non tenté"

    /// Ce que la recherche du dossier Drive a donné (affiché à l'écran).
    static var driveStatus: String {
        _ = shared  // force l'initialisation (et donc la recherche)
        return _driveStatus
    }

    /// Base entreposée dans le dossier « ScanReçus » à la racine du
    /// Google Drive de l'utilisateur (décision du 2026-10-18, « pour
    /// l'instant »). Repli silencieux sur l'emplacement par défaut
    /// (Application Support) si le Drive est introuvable ou si la base
    /// ne peut pas s'y ouvrir — l'app ne doit jamais planter pour ça.
    static let shared: ModelContainer = {
        let schema = Schema([
            Company.self,
            Category.self,
            ReceiptItem.self,
            MerchantRule.self,
            MerchantAlias.self,
        ])
        if let folder = driveFolderURL() {
            let url = folder.appendingPathComponent("ScanRecus.sqlite")
            let configuration = ModelConfiguration(schema: schema, url: url)
            if let container = try? ModelContainer(
                for: schema, configurations: [configuration]) {
                _driveStatus = "dossier trouvé, base ouverte dans le Drive"
                return container
            }
            _driveStatus = "dossier trouvé (\(folder.path)) " +
                "mais la base n'a pas pu s'ouvrir là-bas"
        } else {
            _driveStatus = "dossier « ScanReçus » introuvable sur ce Mac"
        }
        let configuration = ModelConfiguration(
            schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema,
                                      configurations: [configuration])
        } catch {
            fatalError("Impossible de créer la base SwiftData : \(error)")
        }
    }()
}
