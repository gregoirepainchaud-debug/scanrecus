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
        // Les espaces/points/virgules internes ne sont admis que
        // comme groupes de milliers (3 chiffres) : la classe
        // large d'avant avalait « QTÉ 2 24,84 » en un seul
        // « montant » de 224,84 (audit du 2026-10-20).
        try! NSRegularExpression(
            pattern: #"\$?\s*(?:\d{1,3}(?:[ .,\u00A0]\d{3})+|\d+)[.,]\d{2}\b"#)
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
            // Veto de la ligne TOTAL (audit du 2026-10-20) : une
            // « preuve » dont aucune partie n'est un impôt ni un
            // sous-total peut être fabriquée par le reçu
            // (articles qui s'additionnent par hasard) ; si une
            // vraie ligne TOTAL porte un AUTRE montant, c'est
            // elle qui a raison.
            if !verified.structured {
                let receiptLines = text.components(
                    separatedBy: .newlines)
                let veto = totalCandidates(text)
                    .filter { candidate in
                        guard abs(candidate.value - verified.value)
                                > 0.005,
                              receiptLines.indices.contains(
                                candidate.lineIndex)
                        else { return false }
                        let f = removeAccents(
                            receiptLines[candidate.lineIndex])
                            .lowercased()
                        return f.contains("total")
                            && !isSubtotalLine(f)
                            && !f.contains("economis")
                    }
                    .max(by: { $0.lineIndex < $1.lineIndex })
                if let veto { return veto }
            }
            return (verified.value, verified.lineIndex)
        }
        let candidates = totalCandidates(text)
        if !candidates.isEmpty {
            // La ligne qui dit « TOTAL » prime sur les autres
            // lignes à mot-clé : DÉBIT porte le même montant, une
            // ligne plus bas (journal du 2026-10-20 : le carré
            // jaune entourait DÉBIT). La preuve tranche déjà
            // ainsi par son score ; le repli fait pareil, pour
            // le montant comme pour la ligne rapportée (le carré).
            let receiptLines = text.components(
                separatedBy: .newlines)
            func isTotalLine(_ i: Int) -> Bool {
                guard receiptLines.indices.contains(i)
                else { return false }
                let f = removeAccents(receiptLines[i]).lowercased()
                return f.contains("total")
                    && !isSubtotalLine(f)
                    && !f.contains("economis")
            }
            let pool = candidates.filter {
                isTotalLine($0.lineIndex)
            }
            let chosen = (pool.isEmpty ? candidates : pool)
                .max(by: { $0.lineIndex < $1.lineIndex })
            if let chosen { return chosen }
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

    /// Ligne de sous-total : l'OCR écrit parfois « SOUS -TOTAL »
    /// (espace avant le tiret — journal du 2026-10-20) ; on
    /// normalise les tirets avant de comparer, partout où le
    /// sous-total est testé.
    static func isSubtotalLine(_ folded: String) -> Bool {
        let n = folded
            .replacingOccurrences(of: " -", with: "-")
            .replacingOccurrences(of: "- ", with: "-")
        return n.contains("sous-total") || n.contains("sous total")
            || n.contains("subtotal")
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
            if isSubtotalLine(folded)
                || folded.contains("economis")
                || folded.contains("taxable") {
                continue
            }
            guard totalKeywords.firstMatch(in: folded,
                                           range: folded.nsRange) != nil
            else { continue }
            var foundOnLine = false
            for match in amountRegex.matches(in: line, range: line.nsRange) {
                if let r = Range(match.range, in: line),
                   let v = parseAmount(String(line[r])),
                   v > 0, v < 100_000 {
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
                   let v = parseAmount(String(next[r])),
                   v > 0, v < 100_000 {
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

    /// Montants « espacés » que l'OCR produit parfois (« 24, 84 »,
    /// « 24 ,84 ») et que le motif strict de allAmounts rate.
    /// Réservés à la preuve d'addition : un faux positif éventuel
    /// doit quand même compléter une somme exacte pour nuire —
    /// risque quasi nul, robustesse réelle.
    static func spacedAmounts(_ text: String)
    -> [(value: Double, lineIndex: Int)] {
        let re = try! NSRegularExpression(
            pattern: #"\d{1,6},\s\d{2}|\d{1,6}\s,\d{2}"#)
        var out: [(value: Double, lineIndex: Int)] = []
        let lines = text.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            for m in re.matches(in: line, range: line.nsRange) {
                // Garde anti-fantôme (audit du 2026-10-20) : si
                // le motif tombe sur la queue d'un plus grand
                // nombre (« 2 450, 75 » → « 450, 75 »), ce n'est
                // pas un montant espacé, c'est un millier coupé.
                let ns = line as NSString
                let start = m.range.location
                if start >= 1 {
                    let p1 = ns.character(at: start - 1)
                    if p1 >= 48, p1 <= 57 { continue }
                    if p1 == 32, start >= 2 {
                        let p2 = ns.character(at: start - 2)
                        if p2 >= 48, p2 <= 57 { continue }
                    }
                }
                if let v = parseAmount(ns.substring(with: m.range)) {
                    out.append((v, index))
                }
            }
        }
        return out
    }

    /// Montants FRAGMENTÉS par l'OCR entre deux lignes (« 21 »
    /// puis « ,60 ») — invisibles au motif strict comme aux
    /// montants espacés, qui travaillent ligne par ligne. Vu au
    /// journal du 2026-10-20 sur le reçu Postes Canada : le
    /// sous-total coupé en deux tuait la preuve d'addition, et
    /// sans preuve l'arbitre d'orientation perdait son meilleur
    /// critère. Réservés à la preuve, comme les montants
    /// espacés : un faux positif devrait encore compléter une
    /// somme exacte pour nuire. L'index rapporté est celui de
    /// la ligne des unités.
    static func fragmentAmounts(_ text: String)
    -> [(value: Double, lineIndex: Int)] {
        guard !text.isEmpty else { return [] }
        let wholeRe = try! NSRegularExpression(
            pattern: #"^\s*\$?\s*(\d{1,6})\s*$"#)
        let fracRe = try! NSRegularExpression(
            pattern: #"^\s*[.,](\d{2})(?:\s*\$)?\s*$"#)
        // Variante vue au journal (2026-10-20) : la virgule du
        // fragment est lue comme un « 1 » — « ,60 » devient
        // « 160 $ ». Même recolle, mêmes garde-fous (bassin de
        // la preuve seulement).
        let fracOneRe = try! NSRegularExpression(
            pattern: #"^\s*1(\d{2})(?:\s*\$)?\s*$"#)
        var out: [(value: Double, lineIndex: Int)] = []
        let lines = text.components(separatedBy: .newlines)
        guard lines.count > 1 else { return out }
        for i in 0..<(lines.count - 1) {
            let a = lines[i], b = lines[i + 1]
            guard let ma = wholeRe.firstMatch(in: a,
                                              range: a.nsRange),
                  let ra = Range(ma.range(at: 1), in: a),
                  let whole = Double(a[ra])
            else { continue }
            var cents: Double?
            if let mb = fracRe.firstMatch(in: b,
                                          range: b.nsRange),
               let rb = Range(mb.range(at: 1), in: b) {
                cents = Double(b[rb])
            } else if let mb = fracOneRe.firstMatch(
                in: b, range: b.nsRange),
                      let rb = Range(mb.range(at: 1), in: b) {
                cents = Double(b[rb])
            }
            guard let cents else { continue }
            let v = whole + cents / 100
            if v > 0, v < 100_000 { out.append((v, i)) }
        }
        return out
    }

    /// Le total par la PREUVE D'ADDITION — doctrine de Grégoire
    /// (2026-10-20) : « on force l'addition des taxes pour trouver
    /// le total… des fois l'info est mal extraite, l'addition des
    /// chiffres probables est la preuve finale ». On cherche un
    /// montant qui est la somme de 2 à 4 autres montants situés
    /// (4 seulement si la somme est structurée)
    /// AU-DESSUS de lui (à 10 lignes près), en préférant les
    /// sommes qui passent par les lignes d'impôts (TPS/TVQ) et de
    /// sous-total — la structure québécoise classique
    /// (21,60 + 1,08 + 2,16 = 24,84). Ni un montant d'impôt ni un
    /// sous-total ne peuvent être le total cherché. Tolérance
    /// d'un cent (arrondis et lectures imparfaites). Retourne le
    /// total, sa ligne et ses parties (avec leurs lignes).
    static func parseTotalVerified(_ text: String)
    -> (value: Double, lineIndex: Int,
        parts: [(value: Double, lineIndex: Int)],
        structured: Bool)? {
        let amounts = (allAmounts(text) + spacedAmounts(text)
                       + fragmentAmounts(text))
            .filter { $0.value > 0 && $0.value < 100_000 }
        guard amounts.count >= 3 else { return nil }
        let lines = text.components(separatedBy: .newlines)
        func folded(_ i: Int) -> String {
            lines.indices.contains(i)
                ? removeAccents(lines[i]).lowercased() : ""
        }
        let taxRe = try! NSRegularExpression(
            pattern: #"\b(tps|gst|tvq|qst)\b"#)
        /// L'étiquette qui gouverne un montant : le texte plié
        /// de sa propre ligne — ou, quand le montant siège SEUL
        /// sur sa ligne (l'OCR sépare souvent les colonnes
        /// étiquette et montant des reçus étroits — journal du
        /// 2026-10-20 : « TPS/GST » au-dessus de « 1,08 » nu),
        /// celui de la ligne juste au-dessus.
        func labelFolded(_ i: Int) -> String {
            let own = folded(i)
            if own.contains(where: { $0.isLetter }) { return own }
            return i > 0 ? folded(i - 1) : own
        }
        func isTaxLine(_ i: Int) -> Bool {
            let f = folded(i)
            return taxRe.firstMatch(in: f, range: f.nsRange) != nil
        }
        /// Variante « partie de preuve » de isTaxLine :
        /// l'étiquette voisine compte (un impôt lu seul sous
        /// son étiquette doit être reconnu comme impôt). La
        /// GARDE du total, elle, reste sur la ligne propre :
        /// un total nu sous une ligne TVQ existe (reçu « QTÉ »
        /// de l'audit) et ne doit pas être disqualifié.
        func partIsTaxLine(_ i: Int) -> Bool {
            let f = labelFolded(i)
            return taxRe.firstMatch(in: f, range: f.nsRange) != nil
        }
        // Le sous-total, lui, garde l'étiquette voisine même
        // pour la garde : un montant nu sous l'étiquette
        // « SOUS-TOTAL » EST le sous-total (le total a toujours
        // ses taxes ou son étiquette entre les deux) — c'est
        // ce qui disqualifie le faux total fragmenté.
        func isSubLine(_ i: Int) -> Bool {
            isSubtotalLine(labelFolded(i))
        }
        // Lignes de PAIEMENT (audit du 2026-10-20) : la somme
        // tendue et la monnaie rendue ne sont pas des montants
        // d'achat — « ARGENT 20,00 » se « prouvait » tout seul
        // (10 + 10) et doublait le total. Elles sont exclues
        // du bassin des parties, et une ligne de tendu ne peut
        // pas être le total cherché.
        let paymentRe = try! NSRegularExpression(
            pattern: #"\b(argent|monnaie|remis|rendu|change|comptant|cash|tender)\b"#)
        let partBlockRe = try! NSRegularExpression(
            pattern: #"\b(argent|monnaie|remis|rendu|change|comptant|cash|tender|carte|visa|mastercard|amex|interac|debit|paye|rabais|remise|escompte|coupon)\b"#)
        func isPaymentLine(_ i: Int) -> Bool {
            let f = labelFolded(i)
            return paymentRe.firstMatch(in: f, range: f.nsRange)
                != nil
        }
        func isPartBlockedLine(_ i: Int) -> Bool {
            let f = labelFolded(i)
            return partBlockRe.firstMatch(in: f, range: f.nsRange)
                != nil
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
                       line <= aboveLine, line >= minLine,
                       !isPartBlockedLine(line) {
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
            // Une somme de 4 parties n'est recevable que
            // STRUCTURÉE (un impôt ou un sous-total parmi les
            // parties) : à 4 nombres, les coïncidences entre
            // articles deviennent plausibles — la structure
            // fiscale reste la preuve (journal du 2026-10-20 :
            // reçu au sous-total illisible, articles + TPS +
            // TVQ étaient la seule preuve possible).
            if partIdxs.count == 4,
               !partIdxs.contains(where: {
                   partIsTaxLine(amounts[$0].lineIndex)
                       || isSubLine(amounts[$0].lineIndex)
               }) {
                return
            }
            var score = partIdxs.count * 5
                + amounts[totalIdx].lineIndex
            if partIdxs.contains(
                where: { partIsTaxLine(amounts[$0].lineIndex) }) {
                score += 100
            }
            if partIdxs.contains(
                where: { isSubLine(amounts[$0].lineIndex) }) {
                score += 40
            }
            // Signature fiscale québécoise : si une partie peut
            // être le sous-total et que d'autres parties valent
            // ≈ TPS (5 %) et ≈ TVQ (9,975 %) de celle-ci
            // (± 0,02 — les terminaux arrondissent par article,
            // ex. TVQ réelle 2,16 pour 2,1546 théorique), la
            // somme a la structure exacte d'un vrai reçu taxé :
            // presque impossible à obtenir par hasard. C'est le
            // garde-fou « béton » contre les additions fortuites
            // sur les reçus à beaucoup d'articles.
            for (pi, pIdx) in partIdxs.enumerated() {
                let base = amounts[pIdx].value
                var hasTPS = false, hasTVQ = false
                for (qi, qIdx) in partIdxs.enumerated() where qi != pi {
                    let v = amounts[qIdx].value
                    if abs(v - base * 0.05) <= 0.02 { hasTPS = true }
                    if abs(v - base * 0.09975) <= 0.02 { hasTVQ = true }
                }
                if hasTPS && hasTVQ { score += 80 }
                else if hasTPS || hasTVQ { score += 30 }
            }
            // À preuve égale, le total qui siège sur la vraie
            // ligne « TOTAL » bat celui de la ligne « DÉBIT »
            // (même montant, juste en dessous — constaté au test
            // du 2026-10-20 : la boîte entourait DÉBIT).
            let totalFolded = labelFolded(amounts[totalIdx].lineIndex)
            if totalFolded.contains("total"),
               !isSubLine(amounts[totalIdx].lineIndex) {
                score += 30
            }
            if best == nil || score > best!.score {
                best = Solution(totalIdx: totalIdx,
                                partIdxs: partIdxs, score: score)
            }
        }
        for ti in amounts.indices {
            let total = amounts[ti]
            guard !isTaxLine(total.lineIndex),
                  !isSubLine(total.lineIndex),
                  !isPaymentLine(total.lineIndex) else { continue }
            let totalCents = Int((total.value * 100).rounded())
            let minLine = total.lineIndex - 10
            for i in amounts.indices {
                let a = amounts[i]
                guard a.lineIndex <= total.lineIndex,
                      a.lineIndex >= minLine,
                      a.value < total.value,
                      !isPartBlockedLine(a.lineIndex)
                else { continue }
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
                    guard b.lineIndex <= total.lineIndex,
                          b.lineIndex >= minLine,
                          b.value < total.value,
                          !isPartBlockedLine(b.lineIndex)
                    else { continue }
                    let rest2 = rest - Int((b.value * 100).rounded())
                    if rest2 > 0,
                       let k = findAmount(cents: rest2,
                                          notIn: [ti, i, j],
                                          aboveLine: total.lineIndex,
                                          minLine: minLine),
                       amounts[k].value < total.value {
                        consider(totalIdx: ti, partIdxs: [i, j, k])
                    }
                    // Somme de 4 parties : a + b + c + autre.
                    for k in amounts.indices
                    where k != i && k != j {
                        let c = amounts[k]
                        guard c.lineIndex <= total.lineIndex,
                              c.lineIndex >= minLine,
                              c.value < total.value,
                              !isPartBlockedLine(c.lineIndex)
                        else { continue }
                        let rest3 = rest2
                            - Int((c.value * 100).rounded())
                        if rest3 > 0,
                           let m = findAmount(
                            cents: rest3, notIn: [ti, i, j, k],
                            aboveLine: total.lineIndex,
                            minLine: minLine),
                           amounts[m].value < total.value {
                            consider(totalIdx: ti,
                                     partIdxs: [i, j, k, m])
                        }
                    }
                }
            }
        }
        guard let best else { return nil }
        let parts = best.partIdxs
            .map { amounts[$0] }
            .sorted { $0.lineIndex < $1.lineIndex }
        let total = amounts[best.totalIdx]
        // « Structurée » = au moins une partie est un impôt ou
        // un sous-total : la somme a la forme d'un vrai bloc
        // fiscal. Sinon, elle reste suspecte (veto possible
        // dans parseTotal).
        let structured = parts.contains {
            partIsTaxLine($0.lineIndex) || isSubLine($0.lineIndex)
        }
        return (total.value, total.lineIndex, parts, structured)
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
    private static let dateNamedFirst = try! NSRegularExpression(
        pattern: #"(?<!\d)([A-Za-zéèêûâîôàç]+)\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})(?!\d)"#,
        options: .caseInsensitive)
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

        // Plages des dates AAAA-MM-JJ : un fragment JJ/MM lu
        // dedans est un artefact à écarter (voir plus bas).
        var ymdRanges: [NSRange] = []
        for m in dateYMD.matches(in: text, range: full) {
            ymdRanges.append(m.range)
            if let y = group(m, 1).flatMap(Int.init),
               let mo = group(m, 2).flatMap(Int.init),
               let d = group(m, 3).flatMap(Int.init) {
                candidates.append((m.range.location, y, mo, d))
            }
        }
        for m in dateDMY.matches(in: text, range: full) {
            // Un fragment JJ/MM À L'INTÉRIEUR d'une date
            // AAAA-MM-JJ (« 2026-12-28 » lu « 20/12/2028 »)
            // est un artefact, pas un candidat.
            if ymdRanges.contains(where: {
                NSIntersectionRange($0, m.range).length > 0
            }) { continue }
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
        // Dates nommées mois en tête (« October 5, 2026 ») —
        // invisibles aux autres motifs avant l'audit.
        for m in dateNamedFirst.matches(in: text, range: full) {
            if let rawMonth = group(m, 1),
               let mo = monthNumbers[removeAccents(rawMonth)
                .lowercased()],
               let d = group(m, 2).flatMap(Int.init),
               let y = group(m, 3).flatMap(Int.init) {
                candidates.append((m.range.location, y, mo, d))
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
        // Fourchettes promotionnelles (audit du 2026-10-20) :
        // deux candidats sur la MÊME ligne, à 1–45 jours
        // d'écart (« OFFRE VALIDE DU 2026-12-28 AU 2027-01-03 »),
        // sont les bornes d'un intervalle, pas la transaction.
        // Ils passent APRÈS les candidats ordinaires, mais
        // restent utilisables s'il n'y a rien d'autre.
        func lineIndex(of pos: Int) -> Int {
            (text as NSString).substring(to: pos)
                .components(separatedBy: "\n").count - 1
        }
        var bounds = Set<Int>()
        for a in candidates.indices {
            for b in candidates.indices where b > a {
                guard lineIndex(of: candidates[a].0)
                        == lineIndex(of: candidates[b].0)
                else { continue }
                var da = DateComponents()
                da.year = candidates[a].1
                da.month = candidates[a].2
                da.day = candidates[a].3
                var db = DateComponents()
                db.year = candidates[b].1
                db.month = candidates[b].2
                db.day = candidates[b].3
                guard let dateA = calendar.date(from: da),
                      let dateB = calendar.date(from: db)
                else { continue }
                let gap = abs(dateA.timeIntervalSince(dateB))
                if gap >= 86_400, gap <= 45 * 86_400 {
                    bounds.insert(a)
                    bounds.insert(b)
                }
            }
        }
        let ordered = candidates.indices.sorted {
            (bounds.contains($0) ? 1 : 0, candidates[$0].0)
                < (bounds.contains($1) ? 1 : 0, candidates[$1].0)
        }
        for ci in ordered {
            let (_, y, mo, d) = candidates[ci]
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

    // MARK: Répertoire d'entreprises

    /// Répertoire d'amorçage des commerces québécois — validé
    /// par Grégoire le 2026-10-20 (document source :
    /// noms-entreprises-quebec.md). Forme canonique « enseigne
    /// seulement » — son principe : la bannière de base suffit
    /// (« Metro », pas « Metro Plus »), la correspondance
    /// ci-dessous attrape les variantes sur les reçus.
    static let merchantDirectoryText = """
    IGA
    Metro
    Super C
    Provigo
    Maxi
    Loblaws
    Marché Richelieu
    Marché Tradition
    Bonichoix
    Marché Ami
    Adonis
    Kim Phat
    Marchés Tau
    Avril Supermarché Santé
    Rachel Béry
    Fruiterie 440
    Walmart
    Costco
    Tigre Géant
    Aubut
    Euromarché
    Fermes Lufa
    Shell
    Petro-Canada
    Petro-Pass
    Ultramar
    Esso
    Irving
    Couche-Tard
    Provi-Soir
    Boni-Soir
    Voisin
    Beau-Soir
    Crevier
    Sonic
    Harnois
    Pétro-T
    Marché Express
    On the Run
    Dépanneur 7 Jours
    Pétroles Bélisle
    MacEwen Petroleum
    McDonald's
    Tim Hortons
    PFK
    KFC
    Burger King
    Wendy's
    A&W
    Harvey's
    Subway
    Pizza Hut
    Domino's
    Pizza Salvatore
    Boston Pizza
    St-Hubert
    Scores
    Benny&Co.
    Poulet Rouge
    Thaï Express
    Sushi Shop
    Mikes
    Pacini
    La Cage
    Bâton Rouge
    Valentine
    Lafleur
    La Belle Province
    Dic Ann's
    Dairy Queen
    Five Guys
    Popeyes
    Taco Bell
    Boustan
    Amir
    Basha
    Chez Ashton
    Starbucks
    Second Cup
    Café Dépôt
    Van Houtte
    Presse Café
    Columbus Café & Co
    Café Morgane
    Cora
    Ben & Florentine
    Allô mon Coco
    Eggsquis
    Tutti Frutti
    Normandin
    Casa Grecque
    Giorgio Ristorante
    Buffet des Continents
    Le Keg
    Gibbys
    Moishes
    Schwartz's
    St-Viateur Bagel
    Fairmount Bagel
    La Banquise
    Poutineville
    Au Pied de Cochon
    Joe Beef
    Damas
    Le Serpent
    Wilensky's
    Les 3 Brasseurs
    East Side Mario's
    Le Cosmos
    Shaker
    Archibald
    La Korrigane
    Le Bureau de Poste
    Chez Boulay
    Le Saint-Amour
    Battuto
    Albacore
    Nina Pizza Napolitaine
    No 900
    Dixie Lee
    Jean Coutu
    Pharmaprix
    Uniprix
    Familiprix
    Brunet
    Proxim
    Accès Pharma
    Nautilus Plus
    Énergie Cardio
    Éconofitness
    CANAC
    RONA
    Réno-Dépôt
    BMR
    Patrick Morin
    Home Depot
    Home Hardware
    Potvin & Bouchard
    Laferté
    Castle
    Timber Mart
    Fenplast
    Vaillancourt
    Lou-Tec
    Simplex
    MSP Musique
    Denis Musique
    Long & McQuade
    Steve's Music
    Archambault
    Twigg Musique
    Musique Gagné
    Italmelodie
    La Zone Musicale
    Studio Economik
    Moog Audio
    Drum Bazar
    Musique Max
    La Boîte à Musique
    Pianos Bolduc
    Piano Expert
    Pianos André Bolduc
    Pianos Esmonde White
    Pianovertu
    Maison Adam
    Fillion Électronique
    Radio St-Hubert
    Layton Audio
    Centre Hi-Fi
    Yamaha Canada Musique
    Roland Canada
    Erikson Music
    SFM
    Jules Saint-Michel
    Schonau & Tardif
    Archeterie Morency
    Bureau en Gros
    Best Buy
    La Source
    Apple
    DeSerres
    Michaels
    Renaud-Bray
    Librairie Pantoute
    Librairie St-Jean-Baptiste
    Librairie Gallimard
    Librairie Drawn & Quarterly
    Coopsco
    Buropro Citation
    Hamster
    Indigo
    Toys R Us
    Club Jouet
    Benjo
    Imaginaire
    Le Valet d'Coeur
    Randolph
    Ameublements Tanguay
    Brault & Martineau
    Meubles RD
    Germain Larivière
    Structube
    IKEA
    Bouclair
    Stokes
    Linen Chest
    Corbeil Électroménagers
    Léon
    The Brick
    Dormez-vous
    Matelas Dauphin
    Jysk
    Arthur Quentin
    Dante
    Ares Cuisine
    Mobilia
    Must Société
    Simons
    La Baie d'Hudson
    Winners
    Marshalls
    HomeSense
    L'Aubainerie
    Hart
    Penningtons
    Reitmans
    RW&CO
    Laura
    Ardene
    Garage
    Dynamite
    Sports Experts
    Atmosphere
    SAIL
    La Cordée
    Altitude Sports
    Décathlon
    MEC
    L'Équipeur
    Yellow
    Chaussures Pop
    Aldo
    Browns
    NAPA
    Point S
    OK Pneus
    Midas
    Monsieur Muffler
    VitroPlus
    Lebeau
    Fix Auto
    ProColor
    Canadian Tire
    Robert Bernard
    U-Haul
    Discount Location d'Autos
    Enterprise
    Budget
    Avis
    Hertz
    Sauvageau
    Communauto
    Globe Location d'Autos
    Postes Canada
    Purolator
    FedEx
    UPS
    DHL
    Intelcom
    Nationex
    SAQ
    SQDC
    Mondou
    Chico
    Safari
    Global Pitou Minou et Compagnons
    Pattes et Griffes
    Université Laval
    Best Western
    Holiday Inn
    Comfort Inn
    Quality Inn
    Days Inn
    Super 8
    Travelodge
    Hampton Inn
    Hilton
    Marriott
    Château Frontenac
    Le Germain
    Auberge Saint-Antoine
    Motel Adam
    Hôtels Gouverneur
    Le Dauphin
    Première Moisson
    Au Pain Doré
    Boulangerie Ange
    Arhoma
    Mamie Clafoutis
    Fromagerie Hamel
    Fromagerie Atwater
    Pâtisserie Rhubarbe
    Boulangerie Guillaume
    Le Paltoquet
    Chocolats Favoris
    Chocolato
    VIA Rail
    Air Canada
    WestJet
    Porter Airlines
    Orléans Express
    RTC
    Société de Transport de Montréal
    Exo
    Uber
    Taxis Coop Québec
    Traverse Québec-Lévis
    Copilote+
    SPAQ
    Impark
    Stationnement de Montréal
    ParkLink
    Park'N Fly
    """

    /// Entrées pré-normalisées : (nom canonique, mots, collé).
    private static let merchantEntries:
        [(name: String, tokens: [String], joined: String)] = {
        merchantDirectoryText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { name in
                let key = merchantMatchKey(name)
                return (name, key.tokens, key.joined)
            }
    }()

    /// Clé de correspondance : majuscules, sans accents, tout ce
    /// qui n'est pas lettre ou chiffre devient une espace.
    /// « Petro-Canada » → mots [PETRO, CANADA], collé
    /// « PETROCANADA » ; « C A N A C » → collé « CANAC ».
    static func merchantMatchKey(_ s: String)
    -> (tokens: [String], joined: String) {
        let folded = removeAccents(s).uppercased()
        var cleaned = ""
        for ch in folded {
            if ch.isLetter || ch.isNumber { cleaned.append(ch) }
            else { cleaned.append(" ") }
        }
        let tokens = cleaned.split(separator: " ").map(String.init)
        return (tokens, tokens.joined())
    }

    /// Distance de Levenshtein (correspondance approchée).
    private static func editDistance(_ a: String, _ b: String) -> Int {
        let ac = Array(a), bc = Array(b)
        if ac.isEmpty { return bc.count }
        if bc.isEmpty { return ac.count }
        var prev = Array(0...bc.count)
        var cur = [Int](repeating: 0, count: bc.count + 1)
        for i in 1...ac.count {
            cur[0] = i
            for j in 1...bc.count {
                let cost = ac[i - 1] == bc[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1,
                             prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[bc.count]
    }

    /// Mots du répertoire qui sont AUSSI des mots de la langue
    /// courante : en correspondance exacte d'un seul mot, ils
    /// n'attrapent que sur une ligne courte (≤ 3 mots) — une
    /// notice (« AVIS : LES PRIX PEUVENT CHANGER… ») n'est pas
    /// une enseigne. (Audit du 2026-10-20.)
    private static let genericMerchantWords: Set<String> =
        ["AVIS", "BUDGET", "GARAGE", "VOISIN", "SOURCE"]

    /// La ligne se termine-t-elle par la séquence de mots ?
    private static func endsWithTokens(_ line: [String],
                                       _ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= line.count
        else { return false }
        return Array(line.suffix(needle.count)) == needle
    }

    /// Le nom (un seul mot) se reconstitue-t-il en collant 2 ou
    /// 3 mots voisins de la ligne ? (« CANA C » → CANAC — les
    /// enseignes espacées ou coupées par l'OCR.)
    private static func concatMatch(tokens: [String],
                                    joined: String) -> Bool {
        guard tokens.count >= 2 else { return false }
        for start in tokens.indices {
            var acc = ""
            for k in start..<min(start + 3, tokens.count) {
                acc += tokens[k]
                if acc == joined { return true }
                if acc.count > joined.count { break }
            }
        }
        return false
    }

    /// La ligne contient-elle la séquence de mots, contiguë ?
    private static func containsTokens(_ line: [String],
                                       _ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= line.count
        else { return false }
        for start in 0...(line.count - needle.count) {
            if Array(line[start..<(start + needle.count)]) == needle {
                return true
            }
        }
        return false
    }

    /// Correspondance APPROCHÉE d'une entrée sur les mots d'une
    /// ligne : nom d'un mot de 5 lettres et plus lu de travers
    /// (« CANAG » pour CANAC, distance 1 ; 7 lettres et plus,
    /// distance 2), ou nom de deux mots comparé collé, paire de
    /// mots voisins par paire (« TIM HORTON » → Tim Hortons).
    private static func fuzzyMatch(
        lineTokens: [String],
        entry: (tokens: [String], joined: String)) -> Bool {
        if entry.tokens.count == 1 {
            let name = entry.joined
            // Plancher relevé (audit du 2026-10-20) : à 5
            // lettres et distance 1, « DATE » devenait « Dante ».
            guard name.count >= 7 else { return false }
            let allowed = name.count >= 9 ? 2 : 1
            for token in lineTokens {
                if abs(token.count - name.count) <= allowed,
                   editDistance(token, name) <= allowed {
                    return true
                }
            }
        } else if entry.tokens.count == 2, entry.joined.count >= 9 {
            guard lineTokens.count >= 2 else { return false }
            for k in 0..<(lineTokens.count - 1) {
                let pair = lineTokens[k] + lineTokens[k + 1]
                if abs(pair.count - entry.joined.count) <= 2,
                   editDistance(pair, entry.joined) <= 2 {
                    return true
                }
            }
        }
        return false
    }

    /// Cherche un commerce du RÉPERTOIRE dans le haut du reçu
    /// (16 premières lignes) — c'est lui qui élimine les « noms »
    /// absurdes de l'ancienne heuristique : les bouts de phrases
    /// du reçu (« within 30 days of purchase »…) ne figurent
    /// dans aucun répertoire. Trois voies, de la plus sûre à la
    /// plus tolérante : forme collée égale ou contenue (noms de
    /// 6 lettres et plus), séquence de mots contiguë, puis
    /// distance d'édition. Retourne le nom CANONIQUE et
    /// l'index de la ligne source (pour le carré jaune — le nom
    /// canonique n'est pas le préfixe de la ligne brute,
    /// ex. « C A N A C »).
    static func parseMerchantMatch(_ text: String)
    -> (name: String, lineIndex: Int)? {
        guard !text.isEmpty else { return nil }
        let lines = text.components(separatedBy: .newlines)
        var best: (name: String, lineIndex: Int, score: Int)?
        for (i, raw) in lines.enumerated() where i < 16 {
            let line = raw.trimmingCharacters(
                in: .whitespacesAndNewlines)
            let letterCount = line.filter({ $0.isLetter }).count
            guard letterCount >= 2 else { continue }
            // Ligne de 2 lettres (« A&W ») : seule l'égalité
            // complète de la forme collée compte.
            let exactOnly = letterCount == 2
            let key = merchantMatchKey(line)
            guard !key.tokens.isEmpty else { continue }
            for entry in merchantEntries {
                var exact = key.joined == entry.joined
                    || (entry.joined.count >= 6
                        && key.joined.contains(entry.joined))
                if !exact, entry.tokens.count == 1,
                   entry.joined.count >= 4 {
                    exact = concatMatch(tokens: key.tokens,
                                        joined: entry.joined)
                }
                if !exact {
                    // Une entrée qui finit par un nombre
                    // (« No 900 », « Fruiterie 440 ») ne matche
                    // qu'en FIN de ligne : « NO 900 BOUL HAMEL »
                    // est une adresse, pas la pizzeria.
                    if entry.tokens.last?
                        .allSatisfy({ $0.isNumber }) == true {
                        exact = endsWithTokens(key.tokens,
                                               entry.tokens)
                    } else {
                        exact = containsTokens(key.tokens,
                                               entry.tokens)
                    }
                }
                if exact, entry.tokens.count == 1,
                   genericMerchantWords.contains(entry.joined),
                   key.tokens.count > 3 {
                    exact = false
                }
                if exactOnly {
                    exact = key.joined == entry.joined
                }
                let fuzzy = !exact && !exactOnly && fuzzyMatch(
                    lineTokens: key.tokens,
                    entry: (entry.tokens, entry.joined))
                guard exact || fuzzy else { continue }
                // Exact d'abord, puis ligne haute, puis nom
                // long (plus spécifique).
                let score = (fuzzy ? 0 : 10_000) - i * 100
                    + entry.joined.count
                if best == nil || score > best!.score {
                    best = (entry.name, i, score)
                }
            }
        }
        return best.map { ($0.name, $0.lineIndex) }
    }

    // MARK: Commerce

    /// Le commerce : d'abord le RÉPERTOIRE (nom canonique,
    /// ex. « C A N A C » → « CANAC », « METRO PLUS » →
    /// « Metro »). À défaut, l'ancienne heuristique : première
    /// ligne non vide significative dans le tiers supérieur —
    /// au moins 3 lettres, pas un montant, pas une simple date.
    static func parseMerchant(_ text: String) -> String? {
        if let hit = parseMerchantMatch(text) { return hit.name }
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
            // Ni une adresse (la ligne commence par un numéro
            // civique ou un téléphone) ni une formule d'accueil :
            // ce n'est pas une enseigne. (Audit du 2026-10-20.)
            if line.first?.isNumber == true { continue }
            let foldedLine = removeAccents(line).lowercased()
            if foldedLine.hasPrefix("bienvenue")
                || foldedLine.hasPrefix("welcome")
                || foldedLine.hasPrefix("bonjour") {
                continue
            }
            return String(line.prefix(80))
        }
        return nil
    }
}
