import Foundation

/// Numérotation des reçus du nouveau Scanner (2026-10-30) :
/// AAAAMMJJ.NNNN — date du jour (fuseau local) + séquence du jour
/// sur 4 chiffres (la marge de sécurité de Grégoire : on ne
/// dépassera jamais 1000 reçus par jour, mais le format ne
/// coûtait rien à prévoir large).
///
/// Le numéro est l'identité du reçu partout : nom du fichier
/// dans la file d'envoi, en-tête X-Recu-Numero du téléversement,
/// référence dans la section « Reçus » de l'app Gestion — et
/// c'est lui qui fait l'anti-doublon côté serveur.
///
/// Logique pure (Foundation seulement) : testée sous Linux.
enum ReceiptNumbering {

    /// Préfixe des clés UserDefaults, une clé par jour :
    /// « receiptSeq.20261030 » → dernier numéro de séquence émis.
    static let keyPrefix = "receiptSeq."

    /// Code du jour « AAAAMMJJ » dans le fuseau du calendrier
    /// fourni (par défaut : calendrier courant, donc fuseau
    /// local de la machine). Composantes plutôt que
    /// DateFormatter : aucun piège de locale.
    static func dayCode(for date: Date,
                        calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day],
                                        from: date)
        return String(format: "%04d%02d%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Forme finale du numéro : « AAAAMMJJ.NNNN ».
    static func format(dayCode: String, sequence: Int) -> String {
        String(format: "%@.%04d", dayCode, sequence)
    }

    /// Prochain numéro du jour : lit le compteur persisté,
    /// l'incrémente, le réécrit. Un numéro émis n'est jamais
    /// réutilisé le même jour, même si l'envoi échoue — le reçu
    /// garde SON numéro dans la file d'envoi.
    static func next(now: Date = Date(),
                     defaults: UserDefaults = .standard,
                     calendar: Calendar = .current) -> String {
        let day = dayCode(for: now, calendar: calendar)
        let key = keyPrefix + day
        let sequence = defaults.integer(forKey: key) + 1
        defaults.set(sequence, forKey: key)
        return format(dayCode: day, sequence: sequence)
    }

    /// Validation de forme (même expression que le serveur) :
    /// 8 chiffres, un point, 4 chiffres.
    static func isValid(_ numero: String) -> Bool {
        let parts = numero.split(separator: ".",
                                 omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].count == 8, parts[0].allSatisfy(\.isNumber),
              parts[1].count == 4, parts[1].allSatisfy(\.isNumber)
        else { return false }
        return true
    }
}
