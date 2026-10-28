import SwiftUI
import AppKit

/// Onglet « Contours » (build 133) : le TEST
/// DÉCISIF — un premier réseau qui apprend les
/// contours de reçus de Grégoire depuis ses
/// seules élites (+2), jamais depuis ses notes.
/// Bulletin sur des photos jamais entraînées
/// (banc de fortune + le vrai banc, encore
/// mince), comparé à la boîte neutre : la
/// « première proposition » actuelle du jeu.
struct ContoursView: View {
    // @StateObject, PAS @State : ContoursRunner
    // est un ObservableObject (leçon du build 115).
    @StateObject private var runner = ContoursRunner()
    @State private var rapportCopie = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Réseau de contours — v0 (élites seulement)")
                .font(.system(size: 15, weight: .semibold))
            Text("Le traceur apprend tes tracés finis "
                 + "(tes +2) : on lui enseigne des "
                 + "destinations, pas une procédure. "
                 + "Son bulletin est calculé sur des "
                 + "photos jamais entraînées, contre "
                 + "la boîte neutre — le point de "
                 + "départ actuel du jeu.")
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("Préparer l'atelier") {
                    runner.preparer()
                }
                .disabled(runner.running
                          || runner.atelierPret)
                Button("Entraîner le traceur") {
                    runner.entrainer()
                }
                .disabled(runner.running
                          || !runner.atelierPret)
                Button("Évaluer seulement") {
                    runner.evaluer()
                }
                .disabled(runner.running
                          || !runner.atelierPret)
                Button("Lancer le tournoi") {
                    runner.tournoi()
                }
                .disabled(runner.running
                          || !runner.atelierPret)
                Button("Méga-tournoi (photo 67)") {
                    runner.mega()
                }
                .disabled(runner.running
                          || !runner.atelierPret)
                if runner.running {
                    Button("Arrêter") { runner.arreter() }
                }
                Text("Époques :")
                    .font(.system(size: 11.5))
                TextField("", text: $runner.epochsText)
                    .frame(width: 52)
                    .textFieldStyle(.roundedBorder)
                    .disabled(runner.running)
                Text("(défaut 60 — l'atelier est le "
                     + "même que celui du juge)")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                Text(runner.atelierPret
                     ? "Atelier : prêt"
                     : "Atelier : à préparer (une seule "
                       + "fois, quelques minutes)")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
            }

            if runner.running || runner.progress >= 0 {
                HStack(spacing: 10) {
                    if runner.progress < 0 {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        ProgressView(
                            value: max(runner.progress, 0),
                            total: 100)
                            .frame(maxWidth: 320)
                    }
                    Text(runner.progress >= 0
                         ? "\(Int(runner.progress)) % — "
                           + runner.phase
                         : runner.phase)
                        .font(.system(size: 11.5,
                                      design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            if let b = runner.bulletin {
                bulletinCard(b)
            }

            if let t = runner.tournoiRapport {
                tournoiCard(t)
            }

            if let m = runner.megaRapport {
                megaCard(m)
            }

            ScrollView {
                Text(runner.logLines.joined(separator: "\n"))
                    .font(.system(size: 10.5,
                                  design: .monospaced))
                    .frame(maxWidth: .infinity,
                           alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 100)
            .background(Color(nsColor: .textBackgroundColor))
            .border(Color.secondary.opacity(0.3))
        }
        .onAppear { runner.refreshState() }
    }

    private func bulletinCard(_ b: [String: Any]) -> some View {
        func num(_ dict: [String: Any]?, _ cle: String)
            -> Double? {
            (dict?[cle] as? NSNumber)?.doubleValue
        }
        let dev = b["dev"] as? [String: Any]
        let box = dev?["boite_neutre"] as? [String: Any]
        let banc = b["banc"] as? [String: Any]
        let nE = (b["n_train_elites"] as? NSNumber)?
            .intValue ?? 0
        let nP = (b["n_train_photos"] as? NSNumber)?
            .intValue ?? 0
        let app = (b["appareil"] as? String) ?? "?"
        let ep = (b["epochs"] as? NSNumber)?.intValue
        let epTxt = ep != nil ? ", \(ep!) époques" : ""
        var modeTxt = (b["mode"] as? String)
            == "evaluation"
            ? " — ÉVALUATION SEULE du modèle existant"
            : ""
        let raffinage = b["raffinage"] as? [String: Any]
        if (raffinage?["params_source"] as? String)
            == "tournoi" {
            modeTxt += " · constantes du tournoi"
        }
        let titre = "Bulletin — traceur v0 (\(nE) "
            + "élites / \(nP) photos d'entraînement, "
            + "appareil : \(app)\(epTxt))" + modeTxt
        func ligne(_ nom: String,
                   _ dict: [String: Any]?) -> String {
            guard let e = num(dict, "erreur_mediane_pct"),
                  let i = num(dict, "iou_mediane")
            else { return nom + " : —" }
            var base = String(
                format: "%@ : erreur médiane %.1f %% "
                    + "· IoU %.2f", nom, e, i)
            if let sv = num(dict,
                            "servi_erreur_mediane_pct") {
                base += String(
                    format: " · servi %.1f %%", sv)
            }
            if let dp = num(dict,
                            "servi_depl_mediane_pct") {
                base += String(
                    format: " · dépl. %.2f %%", dp)
            }
            return base
        }
        let nDev = (dev?["n"] as? NSNumber)?.intValue ?? 0
        let nBanc = (banc?["n"] as? NSNumber)?.intValue ?? 0
        let verdict = verdictTexte(dev: dev, box: box)
        return VStack(alignment: .leading, spacing: 2) {
            Text(titre)
                .font(.system(size: 12, weight: .semibold))
            Text(ligne("Banc de fortune (\(nDev) "
                       + "photos jamais entraînées)",
                       dev))
            Text(ligne("Boîte neutre (point de départ "
                       + "actuel)", box))
            Text(ligne("Vrai banc (\(nBanc) élites — "
                       + "encore trop peu pour "
                       + "conclure)", banc))
            if let st = b["strict"] as? [String: Any] {
                let nSt = (st["n"] as? NSNumber)?
                    .intValue ?? 0
                Text(ligne("Examen strict — reçu "
                           + "jamais vu (\(nSt) élites)",
                           st))
            }
            if !verdict.isEmpty {
                Text(verdict).fontWeight(.semibold)
            }
            Button(rapportCopie ? "Rapport copié ✓"
                   : "Copier le rapport") {
                copierRapport(b)
            }
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(8)
        .background(Color.secondary.opacity(0.08))
    }

    /// La carte du dernier tournoi (build 143) :
    /// tenant contre champion, sur la sélection
    /// (dev+banc) et sur le strict scellé — le
    /// verdict qui dit si les nouvelles constantes
    /// généralisent ou si elles ont seulement
    /// mémorisé la sélection.
    private func tournoiCard(_ t: [String: Any])
        -> some View {
        func num(_ d: [String: Any]?, _ k: String)
            -> String {
            guard let v = (d?[k] as? NSNumber)?
                .doubleValue
            else { return "—" }
            return String(format: "%.2f", v)
        }
        let ten = t["tenant"] as? [String: Any]
        let ch = t["champion"] as? [String: Any]
        let nouveau = (ch?["nouveau"] as? Bool) ?? false
        let genere = (t["genere"] as? String) ?? "?"
        let nGen = (t["generations"] as? NSNumber)?
            .intValue ?? 0
        let nEnf = (t["enfants"] as? NSNumber)?
            .intValue ?? 0
        let l1 = "Tournoi des constantes — \(genere)"
            + " · \(nGen) générations × \(nEnf) enfants"
        let l2 = "Tenant : sélection "
            + "\(num(ten, "score_selection")) % · strict "
            + "\(num(ten, "score_strict")) %"
        let verdict = nouveau
            ? " — nouvelles constantes actives partout"
            : " — le tenant garde son titre"
        let l3 = "Champion : sélection "
            + "\(num(ch, "score_selection")) % · strict "
            + "\(num(ch, "score_strict")) %" + verdict
        return VStack(alignment: .leading, spacing: 2) {
            Text(l1)
            Text(l2)
            Text(l3)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(8)
        .background(Color.secondary.opacity(0.08))
    }

    /// Carte du méga-tournoi (build 144) :
    /// l'arène (photo 67, pleine précision), les
    /// séries sur la sélection et le verdict du
    /// strict. Chaînes pré-calculées avant la
    /// vue (leçon des builds 143-144).
    private func megaCard(_ m: [String: Any])
        -> some View {
        func n3(_ d: [String: Any]?, _ k: String)
            -> String {
            guard let v = (d?[k] as? NSNumber)?
                .doubleValue
            else { return "—" }
            return String(format: "%.3f", v)
        }
        func n2(_ d: [String: Any]?, _ k: String)
            -> String {
            guard let v = (d?[k] as? NSNumber)?
                .doubleValue
            else { return "—" }
            return String(format: "%.2f", v)
        }
        let photo = (m["photo"] as? NSNumber)?
            .intValue ?? 0
        let faits = (m["evalues"] as? NSNumber)?
            .intValue ?? 0
        let budget = (m["budget"] as? NSNumber)?
            .intValue ?? 0
        let termine = (m["termine"] as? Bool)
            ?? false
        let arene = m["arene"] as? [String: Any]
        let strc = m["strict"] as? [String: Any]
        let gag = m["gagnant"] as? [String: Any]
        let nouveau = (m["nouveau_champion"]
            as? Bool) ?? false
        let selT = (m["tenant_selection"]
            as? NSNumber).map {
            String(format: "%.2f", $0.doubleValue)
        } ?? "—"
        let l1 = "Méga-tournoi — photo \(photo)"
            + " · \(faits)/\(budget) enfants"
            + (termine ? ""
               : " · en cours (point de contrôle)")
        let l2 = "Arène : défauts "
            + "\(n3(arene, "defauts")) % · tenant "
            + "\(n3(arene, "tenant")) % · meilleur "
            + "\(n3(arene, "meilleur")) %"
        var l3 = ""
        if termine {
            if nouveau, let g = gag {
                l3 = "Séries : sélection "
                    + "\(selT) → "
                    + "\(n2(g, "score_selection")) %"
                    + " · strict "
                    + "\(n2(strc, "tenant")) → "
                    + "\(n2(strc, "gagnant")) %"
                    + " — nouveau champion"
            } else {
                l3 = "Séries : le tenant garde son "
                    + "titre (sélection \(selT) %)"
            }
        }
        return VStack(alignment: .leading, spacing: 2) {
            Text(l1)
            Text(l2)
            if !l3.isEmpty { Text(l3) }
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(8)
        .background(Color.secondary.opacity(0.08))
    }

    private func verdictTexte(dev: [String: Any]?,
                              box: [String: Any]?)
        -> String {
        guard let e = (dev?["erreur_mediane_pct"]
                       as? NSNumber)?.doubleValue,
              let bx = (box?["erreur_mediane_pct"]
                        as? NSNumber)?.doubleValue,
              bx > 0
        else { return "" }
        let ratio = e / bx
        if ratio <= 0.5 {
            return "Verdict : signal net — le réseau "
                + "écrase le point de départ."
        }
        if ratio <= 0.85 {
            return "Verdict : signal faible — mieux "
                + "que la boîte, sans plus."
        }
        return "Verdict : pas de signal — le réseau "
            + "ne bat pas la boîte neutre."
    }

    /// Le rapport en texte brut, pour le
    /// presse-papiers (demande de Grégoire,
    /// build 134) : un clic, puis coller dans le
    /// chat — tout le bulletin, chiffres par
    /// photo compris.
    private func rapportTexte(_ b: [String: Any])
        -> String {
        func n(_ d: [String: Any]?, _ k: String)
            -> String {
            guard let v = (d?[k] as? NSNumber)?
                .doubleValue
            else { return "—" }
            return String(format: "%.2f", v)
        }
        let dev = b["dev"] as? [String: Any]
        let box = dev?["boite_neutre"] as? [String: Any]
        let banc = b["banc"] as? [String: Any]
        let nE = (b["n_train_elites"] as? NSNumber)?
            .intValue ?? 0
        let nP = (b["n_train_photos"] as? NSNumber)?
            .intValue ?? 0
        let app = (b["appareil"] as? String) ?? "?"
        let ep = (b["epochs"] as? NSNumber)?.intValue
        let epTxt = ep != nil ? "\(ep!) époques" : ""
        func details(_ d: [String: Any]?) -> [String] {
            guard let arr = d?["par_photo"]
                as? [[String: Any]] else { return [] }
            return arr.map { p in
                let num = (p["photo"] as? NSNumber)?
                    .intValue ?? 0
                var l = "  photo \(num) : erreur "
                    + "\(n(p, "erreur_pct")) % · IoU "
                    + "\(n(p, "iou"))"
                if p["servi_erreur_pct"] is NSNumber {
                    l += " · servi "
                        + "\(n(p, "servi_erreur_pct")) %"
                }
                return l
            }
        }
        func serviSuffix(_ d: [String: Any]?)
            -> String {
            guard d?["servi_erreur_mediane_pct"]
                is NSNumber else { return "" }
            var s = " · servi "
                + "\(n(d, "servi_erreur_mediane_pct")) % "
                + "(IoU \(n(d, "servi_iou_mediane")))"
            if d?["servi_depl_mediane_pct"]
                is NSNumber {
                s += " · dépl. méd. "
                    + "\(n(d, "servi_depl_mediane_pct")) %"
            }
            return s
        }
        var lignes: [String] = []
        lignes.append("Traceur v0 — bulletin du "
            + "\(b["genere"] as? String ?? "?")")
        if (b["mode"] as? String) == "evaluation" {
            lignes.append("Évaluation seule du "
                + "modèle existant (aucun "
                + "entraînement) : \(nE) élites / "
                + "\(nP) photos · appareil \(app)")
        } else {
            lignes.append("Entraînement : \(nE) "
                + "élites / \(nP) photos · appareil "
                + "\(app) · " + epTxt)
        }
        lignes.append("Banc de fortune ("
            + "\((dev?["n"] as? NSNumber)?.intValue ?? 0) "
            + "photos jamais entraînées) : erreur "
            + "médiane \(n(dev, "erreur_mediane_pct")) "
            + "% · IoU \(n(dev, "iou_mediane"))"
            + serviSuffix(dev))
        lignes += details(dev)
        lignes.append("Boîte neutre : erreur médiane "
            + "\(n(box, "erreur_mediane_pct")) % · IoU "
            + "\(n(box, "iou_mediane"))")
        lignes.append("Vrai banc ("
            + "\((banc?["n"] as? NSNumber)?.intValue ?? 0) "
            + "élites) : erreur médiane "
            + "\(n(banc, "erreur_mediane_pct")) % · "
            + "IoU \(n(banc, "iou_mediane"))"
            + serviSuffix(banc))
        lignes += details(banc)
        if let st = b["strict"] as? [String: Any] {
            lignes.append("Examen strict — reçu "
                + "jamais vu ("
                + "\((st["n"] as? NSNumber)?.intValue ?? 0) "
                + "élites) : erreur médiane "
                + "\(n(st, "erreur_mediane_pct")) % · "
                + "IoU \(n(st, "iou_mediane"))"
                + serviSuffix(st))
            lignes += details(st)
        }
        if let t = runner.tournoiRapport {
            let ten = t["tenant"] as? [String: Any]
            let ch = t["champion"] as? [String: Any]
            let tGen = (t["genere"] as? String) ?? "?"
            let tEval = (t["evaluations"] as? NSNumber)?
                .intValue ?? 0
            let selT = n(ten, "score_selection")
            let selC = n(ch, "score_selection")
            let strT = n(ten, "score_strict")
            let strC = n(ch, "score_strict")
            var tl = "Tournoi des constantes (\(tGen)"
                + " · \(tEval) évaluations) : sélection "
                + "\(selT) → \(selC) % · strict "
                + "\(strT) → \(strC) %"
            if (ch?["nouveau"] as? Bool) == true {
                tl += " — champion actif"
            } else {
                tl += " — le tenant garde son titre"
            }
            lignes.append(tl)
        }
        if let mg = runner.megaRapport {
            let mPhoto = (mg["photo"] as? NSNumber)?
                .intValue ?? 0
            let mEval = (mg["evalues"]
                as? NSNumber)?.intValue ?? 0
            let mArene = mg["arene"]
                as? [String: Any]
            let mStrc = mg["strict"]
                as? [String: Any]
            let mGag = mg["gagnant"]
                as? [String: Any]
            let aDef = n(mArene, "defauts")
            let aBest = n(mArene, "meilleur")
            var ml = "Méga-tournoi (photo "
                + "\(mPhoto) · \(mEval) enfants) : "
                + "arène \(aDef) → \(aBest) %"
            if let g = mGag {
                let selT2 = (mg["tenant_selection"]
                    as? NSNumber).map {
                    String(format: "%.2f",
                           $0.doubleValue)
                } ?? "—"
                let selG = n(g, "score_selection")
                let stT = n(mStrc, "tenant")
                let stG = n(mStrc, "gagnant")
                ml += " · sélection \(selT2) → "
                    + "\(selG) % · strict "
                    + "\(stT) → \(stG) %"
                if (mg["nouveau_champion"]
                    as? Bool) == true {
                    ml += " — nouveau champion (méga)"
                } else {
                    ml += " — le tenant garde "
                        + "son titre"
                }
            }
            lignes.append(ml)
        }
        let v = verdictTexte(dev: dev, box: box)
        if !v.isEmpty { lignes.append(v) }
        return lignes.joined(separator: "\n")
    }

    private func copierRapport(_ b: [String: Any]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            rapportTexte(b), forType: .string)
        rapportCopie = true
    }
}
