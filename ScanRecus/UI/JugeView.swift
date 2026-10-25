import SwiftUI

/// Onglet « Juge » (build 121) : l'entraînement du
/// juge artificiel, sans détour — préparation de
/// l'atelier Python, entraînement avec progression
/// en pourcentage, et le bulletin au banc figé
/// (photos jamais entraînées), comparé au juge
/// paresseux et au juge « géométrie seule ».
struct JugeView: View {
    // @StateObject, PAS @State : JugeRunner est un
    // ObservableObject (leçon du build 115).
    @StateObject private var runner = JugeRunner()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Entraînement du juge")
                .font(.system(size: 15, weight: .semibold))
            Text("Le juge apprend tes commentaires du "
                 + "jeu du lasso. Son bulletin est "
                 + "calculé uniquement sur les photos "
                 + "du banc — jamais entraînées.")
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("Préparer l'atelier") {
                    runner.preparer()
                }
                .disabled(runner.running
                          || runner.atelierPret)
                Button("Entraîner le juge") {
                    runner.entrainer()
                }
                .disabled(runner.running
                          || !runner.atelierPret)
                if runner.running {
                    Button("Arrêter") { runner.arreter() }
                }
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
        func ligne(_ nom: String, _ cle: String) -> String {
            guard let d = b[cle] as? [String: Any],
                  let acc = (d["acc"] as? NSNumber)?
                    .doubleValue,
                  let kap = (d["kappa"] as? NSNumber)?
                    .doubleValue
            else { return nom + " : —" }
            return String(
                format: "%@ : accord %.0f %% · kappa %.2f",
                nom, acc * 100, kap)
        }
        let nB = (b["n_bench"] as? NSNumber)?.intValue ?? 0
        let nT = (b["n_train"] as? NSNumber)?.intValue ?? 0
        let app = (b["appareil"] as? String) ?? "?"
        return VStack(alignment: .leading, spacing: 2) {
            Text("Bulletin — banc figé (\(nB) exemples "
                 + "d'examen, \(nT) d'entraînement, "
                 + "appareil : \(app))")
                .font(.system(size: 12, weight: .semibold))
            Text(ligne("Juge paresseux", "lazy"))
            Text(ligne("Juge géométrie seule", "knn_geom"))
            Text(ligne("Juge (voit l'image)", "juge_v0"))
                .fontWeight(.semibold)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(8)
        .background(Color.secondary.opacity(0.08))
    }
}
