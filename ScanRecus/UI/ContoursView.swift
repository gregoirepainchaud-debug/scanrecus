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
        let titre = "Bulletin — traceur v0 (\(nE) "
            + "élites / \(nP) photos d'entraînement, "
            + "appareil : \(app)\(epTxt))"
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
        lignes.append("Entraînement : \(nE) élites / "
            + "\(nP) photos · appareil \(app) · "
            + epTxt)
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
