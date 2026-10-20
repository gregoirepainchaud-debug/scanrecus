import Foundation

// Suite de tests PERMANENTE de la logique d'extraction
// (ReceiptParser) — demandée par Grégoire le 2026-10-20 :
// « il faudrait que notre logique soit béton ».
// Roule au CI à chaque push (étape dédiée du workflow) :
// swiftc ReceiptParser.swift QuarterHelper.swift main.swift.
// Chaque reçu ci-dessous est un CONTRAT : si un changement au
// parseur casse un de ces cas réels, le CI passe au rouge et
// les échecs sortent dans le journal avec le préfixe « error: ».

var failures = 0
var checks = 0

func check(_ cond: Bool, _ label: String) {
    checks += 1
    if !cond {
        failures += 1
        print("error: TEST ÉCHOUÉ — \(label)")
    }
}

func expectTotal(_ text: String, _ expected: Double,
                 verified: Bool, _ label: String) {
    let hit = ReceiptParser.parseTotal(text)
    check(hit != nil && abs(hit!.value - expected) < 0.001,
          "\(label) : total attendu \(expected), "
          + "obtenu \(hit?.value ?? -1)")
    let v = ReceiptParser.parseTotalVerified(text) != nil
    check(v == verified,
          "\(label) : preuve attendue \(verified), obtenue \(v)")
}

func expectDate(_ text: String, _ y: Int, _ m: Int, _ d: Int,
                _ label: String) {
    let date = ReceiptParser.parseDate(text)
    var ok = false
    if let date {
        let c = Calendar.current.dateComponents(
            [.year, .month, .day], from: date)
        ok = c.year == y && c.month == m && c.day == d
    }
    check(ok, "\(label) : date attendue \(y)-\(m)-\(d), "
          + "obtenue \(String(describing: date))")
}

// — 1. Le reçu de référence de Grégoire (Postes Canada /
// pharmacie, testé le 2026-10-19) : la preuve doit partir,
// ses parties doivent être le sous-total et les deux taxes,
// et la ligne du total doit être TOTAL, pas DÉBIT.
let postesCanada = """
PHARMACIE MYRIAM CHAPUT INC.
302-2700 BOUL LAURIER
QUEBEC QC G1V 2L8
2025/09/30 14:19:25
ARTICLE 1 21,60
SOUS-TOTAL 21,60
TPS 1,08
TVQ 2,16
TOTAL 24,84
DÉBIT 24,84
MERCI
"""
expectTotal(postesCanada, 24.84, verified: true, "Postes Canada")
expectDate(postesCanada, 2025, 9, 30, "Postes Canada")
if let proof = ReceiptParser.parseTotalVerified(postesCanada) {
    let parts = proof.parts.map(\.value)
    check(parts.count == 3
          && abs(parts[0] - 21.60) < 0.001
          && abs(parts[1] - 1.08) < 0.001
          && abs(parts[2] - 2.16) < 0.001,
          "Postes Canada : parties attendues [21.60, 1.08, 2.16], "
          + "obtenues \(parts)")
    check(proof.lineIndex == 8,
          "Postes Canada : le total doit siéger sur la ligne TOTAL "
          + "(8), pas DÉBIT — obtenu \(proof.lineIndex)")
} else {
    check(false, "Postes Canada : aucune preuve trouvée")
}
check(ReceiptParser.parseMerchant(postesCanada)?
        .contains("PHARMACIE") == true,
      "Postes Canada : commerce doit contenir PHARMACIE")

// — 2. CANAC : enseigne en lettres espacées — le répertoire
// la canonise (« C A N A C » → « CANAC »). Date JJ/MM/AAAA.
let canac = """
C A N A C
123 RUE DES FORGES
DRUMMONDVILLE QC
2026/08/14
VIS 50,00
SOUS-TOTAL 50,00
TPS 2,50
TVQ 4,99
TOTAL 57,49
"""
expectTotal(canac, 57.49, verified: true, "CANAC")
expectDate(canac, 2026, 8, 14, "CANAC")
check(ReceiptParser.parseMerchant(canac) == "CANAC",
      "CANAC : commerce attendu « CANAC », obtenu "
      + "\(ReceiptParser.parseMerchant(canac) ?? "nil")")

// — 3. Épicerie : sommes pièges (4 + 6 = 10, un prix d'article).
// La signature fiscale doit faire gagner le vrai total.
let epicerie = """
IGA EXTRA
ARTICLE A 4,00
ARTICLE B 6,00
ARTICLE C 10,00
ARTICLE D 22,15
SOUS-TOTAL 42,15
TPS 2,11
TVQ 4,20
TOTAL 48,46
"""
expectTotal(epicerie, 48.46, verified: true, "Épicerie piège")

// — 4. Reçu américain : date MM/JJ/AAAA (échange quand le
// jour/mois est impossible) et montants à point décimal.
let americain = """
CORNER STORE
08/14/2026
SUBTOTAL 21.60
GST 1.08
QST 2.16
TOTAL 24.84
"""
expectTotal(americain, 24.84, verified: true, "Américain")
expectDate(americain, 2026, 8, 14, "Américain")

// — 5. « TOTAL » seul sur sa ligne, montant à la ligne suivante :
// la preuve passe par les montants au-dessus du montant final.
let totalSeul = """
BOULANGERIE
CROISSANTS 10,00
SOUS-TOTAL 10,00
TPS 0,50
TVQ 1,00
TOTAL
11,50
"""
expectTotal(totalSeul, 11.50, verified: true, "TOTAL seul")

// — 6. Aucune preuve possible (rabais lu sans son signe moins :
// aucun sous-ensemble ne donne le total) → repli mot-clé.
let rabais = """
KIOSQUE
JOURNAL 5,25
REVUE 8,00
RABAIS -1,00
TOTAL 12,25
"""
expectTotal(rabais, 12.25, verified: false, "Rabais (repli)")

// — 7. Montants espacés par l'OCR (« 24, 84 ») : invisibles au
// motif strict, la preuve doit quand même partir.
let espaces = """
DEP ANNEUR
SOUS-TOTAL 21, 60
TPS 1, 08
TVQ 2, 16
TOTAL 24, 84
"""
expectTotal(espaces, 24.84, verified: true, "Montants espacés")

// — 8. Lignes fusionnées par Vision : tout le bloc fiscal sur
// une seule ligne. Les parties partagent la ligne du total.
let fusionne = """
RESTO BELLE VUE
2026-02-11
REPAS 21,60
SOUS-TOTAL 21,60 TPS 1,08 TVQ 2,16 TOTAL 24,84
CARTE 24,84
"""
expectTotal(fusionne, 24.84, verified: true, "Lignes fusionnées")
expectDate(fusionne, 2026, 2, 11, "Lignes fusionnées")

// — 9. Date nommée en français ; trop peu de montants pour une
// preuve → repli mot-clé.
let nommee = """
LIBRAIRIE
5 janvier 2026
TOTAL 9,99
ARTICLE 9,99
"""
expectTotal(nommee, 9.99, verified: false, "Date nommée")
expectDate(nommee, 2026, 1, 5, "Date nommée")

// — 10. Arrondis du terminal : la somme des parties tombe à un
// cent du total imprimé — la tolérance ± 1 cent doit l'attraper.
let arrondi = """
CAFE
SOUS-TOTAL 33,33
TPS 1,67
TVQ 3,33
TOTAL 38,32
"""
expectTotal(arrondi, 38.32, verified: true, "Arrondi ±1 cent")

// — 11. Répertoire d'entreprises (intégré le 2026-10-20,
// validé par Grégoire) : le nom canonique gagne contre les
// bouts de phrases du reçu, attrape l'enseigne mal lue, et
// fait retomber les variantes sur la bannière de base.
func expectMerchant(_ text: String, _ expected: String?,
                    line: Int?, _ label: String) {
    let m = ReceiptParser.parseMerchant(text)
    check(m == expected,
          "\(label) : commerce attendu \(expected ?? "nil"), "
          + "obtenu \(m ?? "nil")")
    if let line {
        let hit = ReceiptParser.parseMerchantMatch(text)
        check(hit?.lineIndex == line,
              "\(label) : ligne du commerce attendue \(line), "
              + "obtenue \(hit?.lineIndex ?? -1)")
    }
}

let fragment = """
MERCI DE VOTRE VISITE
WITHIN 30 DAYS OF PURCHASE
TIM HORTONS
123 RUE PRINCIPALE
TOTAL 5,75
"""
expectMerchant(fragment, "Tim Hortons", line: 2,
               "Répertoire/fragment")

let metroPlus = """
METRO PLUS
456 RUE ST-JEAN
TOTAL 20,00
"""
expectMerchant(metroPlus, "Metro", line: 0, "Répertoire/Metro Plus")

let petro = """
PETRO CANADA
TOTAL 40,00
"""
expectMerchant(petro, "Petro-Canada", line: 0, "Répertoire/Petro")

let malLu = """
CANA C DRUMMONDVILLE
TOTAL 57,49
"""
expectMerchant(malLu, "CANAC", line: 0, "Répertoire/mal lu")

let navigateur = """
NAVIGATEUR GPS INCLUS
SHELL
TOTAL 30,00
"""
expectMerchant(navigateur, "Shell", line: 1, "Répertoire/IGA piège")

let inconnu = """
BOULANGERIE CHEZ PIT
TOTAL 8,50
"""
expectMerchant(inconnu, "BOULANGERIE CHEZ PIT", line: nil,
               "Répertoire/inconnu (repli)")

// — 12. Durcissement post-audit (2026-10-20) : les reçus des
// trois rapports critiques deviennent des contrats.

// É1 — Lignes de paiement : la somme tendue ne doit pas se
// « prouver » elle-même (10 + 10 = l'ARGENT de 20,00).
let paiement = """
DÉPANNEUR CHEZ RAYMOND
ARTICLE 10,00
TOTAL 10,00
ARGENT 20,00
MONNAIE 10,00
"""
expectTotal(paiement, 10.00, verified: false, "Audit/ARGENT")

// Une partie ARGENT seule ne doit pas fabriquer une preuve.
let argentPart = """
ARTICLE 30,00
ARGENT 22,89
TOTAL 52,89
"""
expectTotal(argentPart, 52.89, verified: false, "Audit/ARGENT part")

// É2 — Épicerie détaxée : la « preuve » 4,50+3,50+5,00 = 13,00
// (trois articles, aucune structure fiscale) doit être vétée
// par la vraie ligne TOTAL.
let detaxe = """
METRO
LAIT 4,50
PAIN 3,50
OEUFS 5,00
FROMAGE 13,00
TOTAL 26,00
"""
if let proof = ReceiptParser.parseTotalVerified(detaxe) {
    check(abs(proof.value - 13.00) < 0.001 && !proof.structured,
          "Audit/détaxé : la fausse preuve doit exister mais "
          + "être non structurée, obtenue \(proof.value)")
} else {
    check(false, "Audit/détaxé : une fausse preuve était attendue")
}
let detaxeTotal = ReceiptParser.parseTotal(detaxe)
check(detaxeTotal != nil
      && abs(detaxeTotal!.value - 26.00) < 0.001,
      "Audit/détaxé : veto TOTAL attendu 26,00, obtenu "
      + "\(detaxeTotal?.value ?? -1)")

// É3 — Quantité × prix : « 2 24,84 » ne fusionne plus, le
// vrai prix survit et la preuve se fait dessus.
let quantite = """
DÉPANNEUR CHEZ RAYMOND
BIÈRE QTÉ 2 24,84
TPS 1,24
TVQ 2,48
28,56
"""
expectTotal(quantite, 28.56, verified: true, "Audit/QTÉ")
check(ReceiptParser.allAmounts(quantite)
        .contains { abs($0.value - 24.84) < 0.001 },
      "Audit/QTÉ : 24,84 doit exister comme montant")
check(!ReceiptParser.allAmounts(quantite)
        .contains { abs($0.value - 224.84) < 0.001 },
      "Audit/QTÉ : 224,84 ne doit pas exister")

// Le monstre du 2026-10-19, en régression : plafonné partout.
let monstre = """
KIOSQUE
TOTAL 2 008 102,00
"""
check(ReceiptParser.parseTotal(monstre) == nil,
      "Audit/monstre : rien ne doit sortir d'un montant ≥ 100 000")

// M4 — Consigne : 4 parties exigées, repli mot-clé propre.
let consigne = """
DÉPANNEUR
BIÈRE 10,00
CONSIGNE 0,60
TPS 0,53
TVQ 1,06
TOTAL 12,19
"""
expectTotal(consigne, 12.19, verified: false, "Audit/consigne")

// M5 — « TOTAL ÉCONOMISÉ » (ligne la plus basse) ne doit pas
// gagner contre le vrai total quand la preuve est cassée.
let economise = """
PROVIGO
SOUS-TOTAL 46,00
TPS 2,80
TVQ 4,59
TOTAL 52,89
DÉBIT 52,89
TOTAL ÉCONOMISÉ 6,50
"""
expectTotal(economise, 52.89, verified: false, "Audit/économisé")

// M7 — Montant espacé dans un millier : pas de fantôme, et
// le total groupé se lit par le mot-clé.
let milliers = """
BOUCHERIE
ARTICLE A 100,00
GROS ARTICLE 2 450, 75
ARTICLE B 550,75
ARTICLE C 25,00
TOTAL 3 126,50
"""
check(!ReceiptParser.spacedAmounts(milliers)
        .contains { abs($0.value - 450.75) < 0.001 },
      "Audit/milliers : 450,75 fantôme ne doit pas exister")
expectTotal(milliers, 3126.50, verified: false, "Audit/milliers")
let grosMontant = ReceiptParser.allAmounts("TOTAL 1 234,56")
check(grosMontant.count == 1
      && abs(grosMontant[0].value - 1234.56) < 0.001,
      "Audit/milliers : « 1 234,56 » doit donner 1234,56")

// É4 — Un bordereau qui commence par DATE ne devient plus
// « Dante » (plancher du flou relevé).
let bordereau = """
DATE 2026-10-19
HEURE 14:19
TERMINAL 123456
TOTAL 42,00
"""
check(ReceiptParser.parseMerchantMatch(bordereau) == nil,
      "Audit/DATE : aucun match du répertoire attendu")
check(ReceiptParser.parseMerchant(bordereau) != "Dante",
      "Audit/DATE : le commerce ne doit pas être Dante")

// É5 — Adresse « No 900 » et notice « AVIS » ne rebaptisent
// plus un commerce non listé.
let adresse900 = """
BOULANGERIE DU COIN
NO 900 BOUL HAMEL
TOTAL 9,00
"""
check(ReceiptParser.parseMerchantMatch(adresse900) == nil,
      "Audit/No 900 : l'adresse ne doit pas matcher la pizzeria")
let noticeAvis = """
BOUCHERIE LEBLANC
AVIS : LES PRIX PEUVENT CHANGER SANS PRÉAVIS
TOTAL 9,00
"""
check(ReceiptParser.parseMerchantMatch(noticeAvis) == nil,
      "Audit/AVIS : la notice ne doit pas matcher la location")

// F5 — « A&W » nu (2 lettres) doit matcher son entrée.
let aw = """
A&W
TOTAL 9,99
"""
check(ReceiptParser.parseMerchant(aw) == "A&W",
      "Audit/A&W : l'enseigne de 2 lettres doit matcher")

// M1 — Fourchette promotionnelle : la transaction gagne
// contre les bornes « valide du … au … » sur la même ligne.
let promo = """
MAXI
OFFRE VALIDE DU 2026-12-28 AU 2027-01-03
2027-01-02 10:15
TOTAL 26,00
"""
expectDate(promo, 2027, 1, 2, "Audit/promo")

// M2 — Date nommée mois en tête ; JJ/MM épinglé ; 30 février
// rejeté au profit du candidat suivant.
expectDate("STORE\nOctober 5, 2026\nTOTAL 9,99",
           2026, 10, 5, "Audit/mois en tête")
expectDate("REÇU\n05/06/2026\nTOTAL 9,99",
           2026, 6, 5, "Audit/JJ-MM épinglé")
expectDate("REÇU\n30/02/2026\n15/03/2026\nTOTAL 9,99",
           2026, 3, 15, "Audit/30 février")
expectDate("REÇU\n2026-12-28\nTOTAL 9,99",
           2026, 12, 28, "Audit/date AAAA seule")

// — 13. QuarterHelper : il décide de la date de tout reçu
// sans date et du seuil de purge — il avait ZÉRO test.
var utcCal = Calendar(identifier: .gregorian)
utcCal.timeZone = TimeZone(identifier: "UTC")!

func expectPrevQuarter(_ y: Int, _ m: Int, _ d: Int,
                       _ ey: Int, _ em: Int, _ label: String) {
    let ref = utcCal.date(from: DateComponents(
        year: y, month: m, day: d, hour: 12))!
    let got = QuarterHelper.previousQuarterStart(
        from: ref, calendar: utcCal)
    var ok = false
    if let got {
        let c = utcCal.dateComponents([.year, .month, .day],
                                      from: got)
        ok = c.year == ey && c.month == em && c.day == 1
    }
    check(ok, "\(label) : attendu \(ey)-\(em)-01")
}
expectPrevQuarter(2026, 10, 6, 2026, 7, "QH/T4→T3")
expectPrevQuarter(2027, 1, 15, 2026, 10, "QH/janvier→octobre")
expectPrevQuarter(2026, 4, 1, 2026, 1, "QH/T2→T1")
expectPrevQuarter(2026, 2, 28, 2025, 10, "QH/T1→T4 année -1")
if let b = QuarterHelper.quarterBounds(year: 2026, quarter: 4,
                                       calendar: utcCal) {
    let s = utcCal.dateComponents([.year, .month, .day],
                                  from: b.start)
    let e = utcCal.dateComponents(
        [.year, .month, .day, .hour, .minute, .second],
        from: b.end)
    check(s.year == 2026 && s.month == 10 && s.day == 1
          && e.year == 2026 && e.month == 12 && e.day == 31
          && e.hour == 23 && e.minute == 59 && e.second == 59,
          "QH/bornes T4 2026")
} else {
    check(false, "QH/bornes T4 2026 : nil inattendu")
}
check(QuarterHelper.quarterBounds(year: 2026, quarter: 5,
                                  calendar: utcCal) == nil,
      "QH/bornes : trimestre 5 rejeté")
let refDate = utcCal.date(from: DateComponents(
    year: 2026, month: 10, day: 20, hour: 12))!
check(QuarterHelper.currentQuarter(calendar: utcCal,
                                   date: refDate) == 4,
      "QH/trimestre courant")
let cutoffC = utcCal.dateComponents(
    [.year, .month, .day],
    from: QuarterHelper.tenYearsCutoff(from: refDate,
                                       calendar: utcCal))
check(cutoffC.year == 2016 && cutoffC.month == 10
      && cutoffC.day == 20,
      "QH/seuil 10 ans")

// — Sanité de base des montants.
check(ReceiptParser.allAmounts("TOTAL 24,84").count == 1,
      "allAmounts : un montant dans « TOTAL 24,84 »")

print("TESTS DU PARSEUR : \(checks - failures)/\(checks) réussis")
exit(failures == 0 ? 0 : 1)
