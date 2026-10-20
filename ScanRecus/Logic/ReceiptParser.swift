import Foundation

// MARK: - Petit utilitaire

private extension String {
    /// Tout le range, en NSRange (pour NSRegularExpression).
    var nsRange: NSRange { NSRange(startIndex..<endIndex, in: self) }
}

// MARK: - Résultat de détection

/// Champs extraits d'un reçu. Les champs valent nil/"" si non détectés
/// (l'utilisateur les corrige dans l'écran de confirmation).
struct DetectionResult {
    var date: Date?
    var merchant: String = ""
    var category: String = ""
    var total: Double?
    var rawText: String = ""

    /// Date par défaut = 1er jour du trimestre civil précédent quand
    /// l'OCR n'a trouvé aucune date.
    mutating func applyDefaults(calendar: Calendar = .current) {
        if date == nil {
            date = QuarterHelper.previousQuarterStart(calendar: calendar)
        }
    }

    /// Détection vide (ex. OCR indisponible) avec la date par défaut.
    static func empty(calendar: Calendar = .current) -> DetectionResult {
        var det = DetectionResult()
        det.applyDefaults(calendar: calendar)
        return det
    }
}

// MARK: - Parsing du texte OCR

/// Extraction des champs d'un reçu à partir du texte OCR.
/// Portage fidèle de ocr_parse.py (Python) : mêmes règles, mêmes priorités.
/// (En phase 2, le texte viendra de Vision/VNRecognizeTextRequest ;
/// ce module ne travaille que sur du texte.)
enum ReceiptParser {

    // MARK: Accents / normalisation

    /// « Café Délice » → « Cafe Delice ».
    static func removeAccents(_ s: String) -> String {
        s.folding(options: .diacriticInsensitive,
                  locale: Locale(identifier: "fr"))
    }

    /// Clé d'apprentissage commerce → catégorie : minuscules, sans accents,
    /// espaces normalisés.
    static func normalizeMerchant(_ name: String) -> String {
        let folded = removeAccents(name).lowercased()
        let spaced = folded.replacingOccurrences(
            of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
        return spaced.split(separator: " ").joined(separator: " ")
    }

    // MARK: Montants

    /// « 12,34 », « 12.34 », « $1 234,56 », « 1,234.56 », « 1.234,56 »
    /// → Double. Quand '.' et ',' coexistent, le dernier est la décimale.
    static func parseAmount(_ raw: String) -> Double? {
        var s = raw.replacingOccurrences(of: "$", with: "")
        s = s.replacingOccurrences(of: "\u{00A0}", with: "")  // espace insécable
        s = s.replacingOccurrences(of: "\u{202F}", with: "")  // espace fine insécable
        s = s.replacingOccurrences(of: " ", with: "")
        s = s.replacingOccurrences(of: "[^0-9.,]", with: "",
                                   options: .regularExpression)
        guard !s.isEmpty else { return nil }
        let hasComma = s.contains(",")
        let hasDot = s.contains(".")
        if hasComma && hasDot {
            if let lc = s.lastIndex(of: ","), let ld = s.lastIndex(of: ".") {
                if lc > ld {
                    // « 1.234,56 » → la virgule est décimale.
                    s = s.replacingOccurrences(of: ".", with: "")
                    s = s.replacingOccurrences(of: ",", with: ".")
                } else {
                    // « 1,234.56 » → le point est décimal.
                    s = s.replacingOccurrences(of: ",", with: "")
                }
            }
        } else if hasComma {
            s = s.replacingOccurrences(of: ",", with: ".")
        }
        return Double(s)
    }

    private static let totalKeywords: NSRegularExpression = {
        // Comparé sur le texte sans accents et en minuscules (« débit »
        // devient « debit »). Sur les reçus québécois, la ligne « DÉBIT
        // 24,84 » porte le montant réellement payé : un excellent indice.
        try! NSRegularExpression(
            pattern: #"\b(total|montant|a payer|solde|debit|amount due|balance due)\b"#)
    }()

    private static let amountRegex: NSRegularExpression = {
        // 12,34 | 12.34 | $12.34 | 1 234,56 $ | 1,234.56 …
        try! NSRegularExpression(pattern: #"\$?\s*\d[\d\s.,]*[.,]\d{2}\b"#)
    }()

    /// Le total : d'abord la ligne contenant « total »/« montant »/
    /// « débit »… la plus basse du reçu (le mot-clé et le montant doivent
    /// être sur la MÊME ligne ; les lignes « sous-total » sont exclues),
    /// sinon le plus grand montant du texte.
    /// Retourne (valeur, indexDeLigne) ou nil.
    static func parseTotal(_ text: String) -> (value: Double, lineIndex: Int)? {
        guard !text.isEmpty else { return nil }
        // La preuve d'addition d'abord (voir parseTotalVerified) :
        // elle prime sur la ligne à mot-clé.
        if let verified = parseTotalVerified(text) {
            return (verified.value, verified.lineIndex)
        }
        if let best = totalCandidates(text)
            .max(by: { $0.lineIndex < $1.lineIndex }) {
            return best
        }
        var best: Double?
        for match in amountRegex.matches(in: text, range: text.nsRange) {
            if let r = Range(match.range, in: text),
               let v = parseAmount(String(text[r])),
               // Garde-fou : l'OCR fusionne parfois plusieurs
               // nombres en un monstre (vu au retest du 2026-10-19 :
               // un « total » de 2 008 102,00 $). Au-delà de
               // 100 000 $, ce n'est pas un montant de reçu — la
               // voie normale reste la ligne à mot-clé.
               v < 100_000,
               best == nil || v > best! {
                best = v
            }
        }
        return best.map { ($0, -1) }
    }

    /// Montants portés par une ligne à mot-clé « total », hors
    /// « sous-total »/« subtotal » (qui contient « total » mais n'est
    /// justement PAS le total).
    static func totalCandidates(_ text: String)
    -> [(value: Double, lineIndex: Int)] {
        guard !text.isEmpty else { return [] }
        var out: [(value: Double, lineIndex: Int)] = []
        let lines = text.components(separatedBy: .newlines)
        for (i, line) in lines.enumerated() {
            let folded = removeAccents(line).lowercased()
            if folded.contains("sous-total") || folded.contains("sous total")
                || folded.contains("subtotal") {
                continue
            }
            guard totalKeywords.firstMatch(in: folded,
                                           range: folded.nsRange) != nil
            else { continue }
            var foundOnLine = false
            for match in amountRegex.matches(in: line, range: line.nsRange) {
                if let r = Range(match.range, in: line),
                   let v = parseAmount(String(line[r])) {
                    out.append((v, i))
                    foundOnLine = true
                }
            }
            // L'OCR sépare souvent le mot-clé de son montant
            // (« TOTAL » seul sur sa ligne, le montant lu à la
            // ligne suivante — sur le papier, l'écart est grand) :
            // le montant de la ligne suivante immédiate compte
            // alors, sauf si elle porte son propre mot-clé.
            if !foundOnLine, i + 1 < lines.count {
                let next = lines[i + 1]
                let foldedNext = removeAccents(next).lowercased()
                if !foldedNext.contains("sous-total"),
                   !foldedNext.contains("subtotal"),
                   totalKeywords.firstMatch(
                    in: foldedNext, range: foldedNext.nsRange) == nil,
                   let match = amountRegex.firstMatch(
                    in: next, range: next.nsRange),
                   let r = Range(match.range, in: next),
                   let v = parseAmount(String(next[r])) {
                    out.append((v, i))
                }
            }
        }
        return out
    }

    /// Tous les montants du texte, avec l'index de leur ligne.
    static func allAmounts(_ text: String)
    -> [(value: Double, lineIndex: Int)] {
        guard !text.isEmpty else { return [] }
        var out: [(value: Double, lineIndex: Int)] = []
        for (i, line) in text.components(separatedBy: .newlines).enumerated() {
            for match in amountRegex.matches(in: line, range: line.nsRange) {
                if let r = Range(match.range, in: line),
                   let v = parseAmount(String(line[r])) {
                    out.append((v, i))
                }
            }
        }
        return out
    }

    /// Le total par la PREUVE D'ADDITION — doctrine de Grégoire
    /// (2026-10-20) : « on force l'addition des taxes pour trouver
    /// le total… des fois l'info est mal extraite, l'addition des
    /// chiffres probables est la preuve finale ». On cherche un
    /// montant qui est la somme de 2 ou 3 autres montants situés
    /// AU-DESSUS de lui (à 10 lignes près), en préférant les
    /// sommes qui passent par les lignes d'impôts (TPS/TVQ) et de
    /// sous-total — la structure québécoise classique
    /// (21,60 + 1,08 + 2,16 = 24,84). Ni un montant d'impôt ni un
    /// sous-total ne peuvent être le total cherché. Tolérance
    /// d'un cent (arrondis et lectures imparfaites). Retourne le
    /// total, sa ligne et ses parties (avec leurs lignes).
    static func parseTotalVerified(_ text: String)
    -> (value: Double, lineIndex: Int,
        parts: [(value: Double, lineIndex: Int)])? {
        let amounts = allAmounts(text)
            .filter { $0.value > 0 && $0.value < 100_000 }
        guard amounts.count >= 3 else { return nil }
        let lines = text.components(separatedBy: .newlines)
        func folded(_ i: Int) -> String {
            lines.indices.contains(i)
                ? removeAccents(lines[i]).lowercased() : ""
        }
        let taxRe = try! NSRegularExpression(
            pattern: #"\b(tps|gst|tvq|qst)\b"#)
        func isTaxLine(_ i: Int) -> Bool {
            let f = folded(i)
            return taxRe.firstMatch(in: f, range: f.nsRange) != nil
        }
        func isSubLine(_ i: Int) -> Bool {
            let f = folded(i)
            return f.contains("sous-total") || f.contains("sous total")
                || f.contains("subtotal")
        }
        // Montants indexés par valeur en cents (recherche rapide,
        // ± 1 cent de tolérance au moment de la recherche).
        var byCents: [Int: [Int]] = [:]
        for (idx, a) in amounts.enumerated() {
            byCents[Int((a.value * 100).rounded()), default: []]
                .append(idx)
        }
        func findAmount(cents: Int, notIn excluded: Set<Int>,
                        aboveLine: Int, minLine: Int) -> Int? {
            for c in (cents - 1)...(cents + 1) {
                for idx in byCents[c] ?? [] {
                    let line = amounts[idx].lineIndex
                    if !excluded.contains(idx),
                       line < aboveLine, line >= minLine {
                        return idx
                    }
                }
            }
            return nil
        }
        struct Solution {
            var totalIdx: Int
            var partIdxs: [Int]
            var score: Int
        }
        var best: Solution?
        func consider(totalIdx: Int, partIdxs: [Int]) {
            var score = partIdxs.count * 5
                + amounts[totalIdx].lineIndex
            if partIdxs.contains(
                where: { isTaxLine(amounts[$0].lineIndex) }) {
                score += 100
            }
            if partIdxs.contains(
                where: { isSubLine(amounts[$0].lineIndex) }) {
                score += 40
            }
            if best == nil || score > best!.score {
                best = Solution(totalIdx: totalIdx,
                                partIdxs: partIdxs, score: score)
            }
        }
        for ti in amounts.indices {
            let total = amounts[ti]
            guard !isTaxLine(total.lineIndex),
                  !isSubLine(total.lineIndex) else { continue }
            let totalCents = Int((total.value * 100).rounded())
            let minLine = total.lineIndex - 10
            for i in amounts.indices {
                let a = amounts[i]
                guard a.lineIndex < total.lineIndex,
                      a.lineIndex >= minLine,
                      a.value < total.value else { continue }
                let rest = totalCents - Int((a.value * 100).rounded())
                // Somme de 2 parties : a + autre = total.
                if let j = findAmount(cents: rest, notIn: [ti, i],
                                      aboveLine: total.lineIndex,
                                      minLine: minLine),
                   amounts[j].value < total.value {
                    consider(totalIdx: ti, partIdxs: [i, j])
                }
                // Somme de 3 parties : a + b + autre = total.
                for j in amounts.indices where j != i {
                    let b = amounts[j]
                    guard b.lineIndex < total.lineIndex,
                          b.lineIndex >= minLine,
                          b.value < total.value else { continue }
                    let rest2 = rest - Int((b.value * 100).rounded())
                    if rest2 > 0,
                       let k = findAmount(cents: rest2,
                                          notIn: [ti, i, j],
                                          aboveLine: total.lineIndex,
                                          minLine: minLine),
                       amounts[k].value < total.value {
                        consider(totalIdx: ti, partIdxs: [i, j, k])
                    }
                }
            }
        }
        guard let best else { return nil }
        let parts = best.partIdxs
            .map { amounts[$0] }
            .sorted { $0.lineIndex < $1.lineIndex }
        let total = amounts[best.totalIdx]
        return (total.value, total.lineIndex, parts)
    }

    /// Preuve par addition : vrai si `total` est la somme de 2 ou 3
    /// AUTRES montants du reçu — le cas classique « sous-total + TPS »
    /// ou « sous-total + TPS + TVQ » (ex. 21,60 + 1,08 + 2,16 = 24,84).
    /// Tolérance d'un cent (arrondis des taxes).
    static func isSumVerified(total: Double, amounts: [Double]) -> Bool {
        // On retire une occurrence du total lui-même (sa propre ligne)
        // et les montants nuls, qui fausseraient la preuve.
        var pool = amounts.filter { $0 > 0 }
        if let idx = pool.firstIndex(where: { abs($0 - total) < 0.005 }) {
            pool.remove(at: idx)
        }
        let tolerance = 0.011
        let n = pool.count
        guard n >= 2 else { return false }
        for i in 0..<n {
            for j in (i + 1)..<n {
                if abs(pool[i] + pool[j] - total) < tolerance { return true }
                for k in (j + 1)..<n
                where abs(pool[i] + pool[j] + pool[k] - total) < tolerance {
                    return true
                }
            }
        }
        return false
    }

    // MARK: Dates

    private static let monthNumbers: [String: Int] = [
        "janvier": 1, "janv": 1, "jan": 1, "january": 1,
        "fevrier": 2, "fevr": 2, "fev": 2, "february": 2,
        "mars": 3, "mar": 3, "march": 3,
        "avril": 4, "avr": 4, "april": 4, "apr": 4,
        "mai": 5, "may": 5,
        "juin": 6, "jun": 6, "june": 6,
        "juillet": 7, "juil": 7, "jul": 7, "july": 7,
        "aout": 8, "aug": 8, "august": 8,
        "septembre": 9, "sept": 9, "sep": 9, "september": 9,
        "octobre": 10, "oct": 10, "october": 10,
        "novembre": 11, "nov": 11, "november": 11,
        "decembre": 12, "dec": 12, "december": 12,
    ]

    private static let dateYMD = try! NSRegularExpression(
        pattern: #"(?<!\d)(\d{4})[/\-.](\d{1,2})[/\-.](\d{1,2})(?!\d)"#)
    private static let dateDMY = try! NSRegularExpression(
        pattern: #"(?<!\d)(\d{1,2})[/\-.](\d{1,2})[/\-.](\d{2,4})(?!\d)"#)
    private static let dateNamed = try! NSRegularExpression(
        pattern: #"(?<!\d)(\d{1,2})[\s/\-.]+([A-Za-zéèêûâîôàç]+)[\s/\-.]+(\d{4})(?!\d)"#,
        options: .caseInsensitive)

    /// Première date plausible du texte, sinon nil.
    /// Formats : AAAA-MM-JJ, JJ/MM/AAAA (ou avec - .), « 12 oct 2026 »,
    /// « 3 février 2027 ». Année entre 2000 et année courante + 1.
    static func parseDate(_ text: String,
                          calendar: Calendar = .current) -> Date? {
        guard !text.isEmpty else { return nil }
        let maxYear = calendar.component(.year, from: Date()) + 1
        let full = text.nsRange
        // (position, année, mois, jour)
        var candidates: [(Int, Int, Int, Int)] = []

        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            guard let r = Range(m.range(at: i), in: text) else { return nil }
            return String(text[r])
        }

        for m in dateYMD.matches(in: text, range: full) {
            if let y = group(m, 1).flatMap(Int.init),
               let mo = group(m, 2).flatMap(Int.init),
               let d = group(m, 3).flatMap(Int.init) {
                candidates.append((m.range.location, y, mo, d))
            }
        }
        for m in dateDMY.matches(in: text, range: full) {
            if var y = group(m, 3).flatMap(Int.init),
               let mo = group(m, 2).flatMap(Int.init),
               let d = group(m, 1).flatMap(Int.init) {
                if y < 100 { y += 2000 }
                var dd = d, mm = mo
                // Format anglophone MM/JJ/AAAA (vu sur un reçu le
                // 2026-10-19 : « 08/14/26 ») : si le mois lu
                // « jour d'abord » est impossible (> 12) mais que
                // l'échange donne une date valide, on échange.
                // Les dates ambiguës (05/06) restent JJ/MM —
                // convention québécoise d'abord.
                if mm > 12, dd <= 12 { swap(&dd, &mm) }
                candidates.append((m.range.location, y, mm, dd))
            }
        }
        for m in dateNamed.matches(in: text, range: full) {
            if let d = group(m, 1).flatMap(Int.init),
               let rawMonth = group(m, 2),
               let y = group(m, 3).flatMap(Int.init),
               let mo = monthNumbers[removeAccents(rawMonth).lowercased()] {
                candidates.append((m.range.location, y, mo, d))
            }
        }
        candidates.sort { $0.0 < $1.0 }
        for (_, y, mo, d) in candidates {
            guard (2000...maxYear).contains(y), (1...12).contains(mo)
            else { continue }
            var comps = DateComponents()
            comps.year = y
            comps.month = mo
            comps.day = d
            // Valide le jour (rejette ex. 30 février) par aller-retour.
            if let date = calendar.date(from: comps) {
                let back = calendar.dateComponents([.year, .month, .day],
                                                   from: date)
                if back.year == y && back.month == mo && back.day == d {
                    return calendar.startOfDay(for: date)
                }
            }
        }
        return nil
    }

    // MARK: Commerce

    /// Première ligne non vide significative dans le tiers supérieur :
    /// au moins 3 lettres, pas un montant, pas une simple date.
    static func parseMerchant(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        for line in lines.prefix(max(1, lines.count / 3)) {
            guard line.filter({ $0.isLetter }).count >= 3 else { continue }
            if amountRegex.firstMatch(in: line, range: line.nsRange) != nil {
                continue
            }
            if parseDate(line) != nil { continue }  // juste une date
            return String(line.prefix(80))
        }
        return nil
    }
}
