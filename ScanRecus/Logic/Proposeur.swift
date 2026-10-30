import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Proposition du TRACEUR (build 134) : demande au
/// réseau de contours entraîné (contours-v0.pt,
/// dans l'atelier partagé avec le juge) son lasso
/// de départ pour une image, via le script Python
/// de l'atelier (contours.py --devine).
/// Trois issues distinguées (build 135) :
/// .aucunModele (rien à tenter — la boîte neutre
/// est le comportement normal), .echec (un modèle
/// existe mais la proposition a échoué — à
/// MONTRER, pas à taire) et .lasso (la proposition).
/// Appel BLOQUANT (démarrage de Python +
/// inférence, quelques secondes) : toujours
/// l'appeler hors du fil principal.
enum Proposeur {
    enum Proposition {
        case aucunModele
        case echec
        case lasso([CGPoint])
    }

    static func propose(image: CGImage) -> Proposition {
        let fm = FileManager.default
        guard let base = fm.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first?
            .appendingPathComponent("ScanRecus",
                                    isDirectory: true)
        else { return .aucunModele }
        let atelier = base.appendingPathComponent(
            "Juge", isDirectory: true)
        let python = atelier.appendingPathComponent(
            "venv/bin/python3")
        let modele = Self.cheminModeleChoisi(
            atelier: atelier)
        guard fm.fileExists(atPath: python.path),
              fm.fileExists(atPath: modele.path)
        else { return .aucunModele }
        // Le script, TOUJOURS réécrit depuis la
        // source embarquée (build 135) : au build
        // 134, il n'était écrit que s'il manquait —
        // l'atelier gardait donc la version du
        // build 133, sans le mode --devine, et
        // chaque appel échouait en silence.
        let script = atelier.appendingPathComponent(
            "contours.py")
        try? ContoursScript.source.write(
            to: script, atomically: true,
            encoding: .utf8)
        // L'image décodée, en PNG temporaire.
        let tmp = atelier.appendingPathComponent(
            "proposition.png")
        guard let dest = CGImageDestinationCreateWithURL(
            tmp as CFURL,
            UTType.png.identifier as CFString, 1, nil)
        else { return .echec }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest)
        else { return .echec }
        // L'œil courant (build 156) : le devine
        // regarde la photo à la même résolution
        // que celle du champ « Œil » de l'onglet
        // Contours (défaut 256, mêmes bornes et
        // même arrondi que le pilote).
        let oeilBrut = UserDefaults.standard.string(
            forKey: "contoursOeil") ?? "256"
        var oeil = Int(oeilBrut) ?? 256
        oeil = min(1024, max(20, oeil))
        oeil = ((oeil + 2) / 4) * 4
        // L'appel, avec garde-fou de durée.
        let proc = Process()
        proc.executableURL = python
        proc.arguments = [script.path,
                          "--devine", tmp.path,
                          "--sortie", atelier.path,
                          "--modele", modele.path,
                          "--taille", String(oeil)]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return .echec }
        let sema = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            proc.waitUntilExit()
            sema.signal()
        }
        if sema.wait(timeout: .now() + 90) == .timedOut {
            proc.terminate()
            return .echec
        }
        guard proc.terminationStatus == 0
        else { return .echec }
        let data = pipe.fileHandleForReading
            .readDataToEndOfFile()
        guard let texte = String(data: data,
                                 encoding: .utf8)
        else { return .echec }
        // La dernière ligne JSON du flux (le script
        // peut imprimer un avertissement avant le
        // résultat).
        for ligne in texte.split(separator: "\n")
            .reversed() {
            let l = ligne.trimmingCharacters(
                in: .whitespaces)
            guard l.hasPrefix("{"),
                  let d = l.data(using: .utf8),
                  let obj = try? JSONSerialization
                    .jsonObject(with: d)
                    as? [String: Any],
                  let pts = obj["lasso"]
                    as? [[NSNumber]]
            else { continue }
            let poly = pts.compactMap {
                p -> CGPoint? in
                guard p.count == 2 else { return nil }
                return CGPoint(x: p[0].doubleValue,
                               y: p[1].doubleValue)
            }
            if poly.count >= 4 { return .lasso(poly) }
        }
        return .echec
    }

    // ---- Sélecteur d'IA (build 152) ----
    // Chaque époque d'entraînement produit
    // une IA unique, archivée sous
    // archives/<course>/epoque-NN.pt ; le
    // sélecteur du premier onglet choisit
    // laquelle propose les lassos. Le choix
    // est un chemin complet, mémorisé dans
    // les préférences.

    struct ModeleIA: Identifiable {
        let nom: String
        let chemin: URL
        var id: String { chemin.path }
    }

    static let cleIAChoisie = "proposeurIAChoisie"

    static var dossierAtelier: URL? {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first?
            .appendingPathComponent(
                "ScanRecus", isDirectory: true)
            .appendingPathComponent(
                "Juge", isDirectory: true)
    }

    static func cheminModeleChoisi(
        atelier: URL
    ) -> URL {
        let defaut = atelier.appendingPathComponent(
            "contours-v0.pt")
        if let p = UserDefaults.standard.string(
               forKey: cleIAChoisie),
           FileManager.default.fileExists(
               atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return defaut
    }

    static func cheminChoisi() -> URL? {
        guard let atelier = dossierAtelier
        else { return nil }
        return cheminModeleChoisi(atelier: atelier)
    }

    static func modelesDisponibles()
        -> [ModeleIA] {
        guard let atelier = dossierAtelier
        else { return [] }
        let fm = FileManager.default
        var out: [ModeleIA] = []
        let racine = (try? fm.contentsOfDirectory(
            atPath: atelier.path)) ?? []
        let pts = racine.filter {
            $0.hasSuffix(".pt")
        }.sorted { a, b in
            if a == "contours-v0.pt" { return true }
            if b == "contours-v0.pt" { return false }
            return a < b
        }
        for nom in pts {
            let affiche = nom == "contours-v0.pt"
                ? "Servie — contours-v0"
                : (nom as NSString)
                    .deletingPathExtension
            out.append(ModeleIA(
                nom: affiche,
                chemin: atelier
                    .appendingPathComponent(nom)))
        }
        let archives = atelier.appendingPathComponent(
            "archives", isDirectory: true)
        let courses = ((try? fm
            .contentsOfDirectory(
                atPath: archives.path)) ?? [])
            .sorted(by: >)
        for course in courses {
            let dir = archives
                .appendingPathComponent(
                    course, isDirectory: true)
            let fichiers = ((try? fm
                .contentsOfDirectory(
                    atPath: dir.path)) ?? [])
                .filter { $0.hasSuffix(".pt") }
                .sorted()
            for f in fichiers {
                let ep = (f as NSString)
                    .deletingPathExtension
                out.append(ModeleIA(
                    nom: "\(course) · \(ep)",
                    chemin: dir
                        .appendingPathComponent(f)))
            }
        }
        return out
    }
}
