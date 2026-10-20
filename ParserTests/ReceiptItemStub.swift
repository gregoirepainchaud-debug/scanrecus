import Foundation

/// Talon minimal de ReceiptItem pour les tests du parseur :
/// QuarterHelper.distinctYears n'utilise que sa propriété
/// `date`. Le vrai ReceiptItem est un modèle SwiftData
/// (Models.swift) — inutile et hors de portée pour un binaire
/// de test en ligne de commande. Ce fichier n'est JAMAIS
/// compilé dans l'app (il vit hors du dossier ScanRecus/).
final class ReceiptItem {
    var date: Date
    init(date: Date = Date()) { self.date = date }
}
