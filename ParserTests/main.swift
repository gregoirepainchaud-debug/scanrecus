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

// — 2. CANAC : enseigne en lettres espacées (le parseur retourne
// la ligne telle quelle ; la canonisation « Canac » viendra de
// l'apprentissage de l'étape 2). Date JJ/MM/AAAA.
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
check(ReceiptParser.parseMerchant(canac) == "C A N A C",
      "CANAC : commerce attendu « C A N A C », obtenu "
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

// — Sanité de base des montants.
check(ReceiptParser.allAmounts("TOTAL 24,84").count == 1,
      "allAmounts : un montant dans « TOTAL 24,84 »")

print("TESTS DU PARSEUR : \(checks - failures)/\(checks) réussis")
exit(failures == 0 ? 0 : 1)
