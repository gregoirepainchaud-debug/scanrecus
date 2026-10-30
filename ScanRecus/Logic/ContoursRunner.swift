import Foundation
import Combine

/// Pilote de l'atelier du TRACEUR de contours
/// (build 133) : même atelier Python que le juge
/// (dossier « Juge », venv et torch partagés),
/// mais lance contours.py — le premier réseau
/// qui apprend les contours de Grégoire depuis
/// ses seules élites (+2). Le bulletin
/// (bulletin-contours.json, photos jamais
/// entraînées contre boîte neutre) est relu
/// après chaque entraînement et miré sur
/// Drive. Aucune donnée ne sort du Mac.
final class ContoursRunner: ObservableObject {
    @Published var logLines: [String] = []
    @Published var progress: Double = -1
    @Published var phase: String = ""
    @Published var running = false
    @Published var atelierPret = false
    @Published var bulletin: [String: Any]?
    @Published var tournoiRapport: [String: Any]?
    @Published var megaRapport: [String: Any]?
    @Published var oracleRapport: [String: Any]?
    /// Nombre d'époques demandé : champ de
    /// l'onglet, persisté, validé au lancement
    /// (1 à 500, défaut 60).
    @Published var epochsText: String = "60"
    @Published var rotationsText: String = "0"
    @Published var limiteText: String = ""
    /// Case « Ignorer les synthétiques »
    /// (build 151) : persistée, transmise au
    /// script à l'entraînement.
    @Published var ignorerSynths: Bool = false
    @Published var synthInfo: [String: Any]?

    let jugeDir: URL
    let racine: URL
    private var process: Process?
    private var buffer = Data()

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory,
                  in: .userDomainMask).first!
            .appendingPathComponent("ScanRecus",
                                    isDirectory: true)
        jugeDir = base.appendingPathComponent(
            "Juge", isDirectory: true)
        racine = base.appendingPathComponent(
            "Atelier", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: jugeDir, withIntermediateDirectories: true)
        if let saved = UserDefaults.standard.string(
            forKey: "contoursEpochs"), !saved.isEmpty {
            epochsText = saved
        }
        if let savedR = UserDefaults.standard.string(
            forKey: "contoursRotations"), !savedR.isEmpty {
            rotationsText = savedR
        }
        if let savedL = UserDefaults.standard.string(
            forKey: "contoursLimite"), !savedL.isEmpty {
            limiteText = savedL
        }
        ignorerSynths = UserDefaults.standard.bool(
            forKey: "contoursIgnorerSynths")
        refreshState()
        loadSynthInfo()
    }

    var venvPython: URL {
        jugeDir.appendingPathComponent("venv/bin/python3")
    }
    var scriptURL: URL {
        jugeDir.appendingPathComponent("contours.py")
    }

    func refreshState() {
        atelierPret = FileManager.default
            .fileExists(atPath: venvPython.path)
        loadBulletin()
        loadTournoi()
        loadMega()
        loadOracle()
        if bulletin != nil { mirrorBulletin() }
    }

    func loadTournoi() {
        let url = jugeDir.appendingPathComponent(
            "tournoi-rapport.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization
                .jsonObject(with: data) as? [String: Any]
        else { tournoiRapport = nil; return }
        tournoiRapport = obj
    }

    func loadMega() {
        let url = jugeDir.appendingPathComponent(
            "mega-rapport.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization
                .jsonObject(with: data) as? [String: Any]
        else { megaRapport = nil; return }
        megaRapport = obj
    }

    func loadOracle() {
        let url = jugeDir.appendingPathComponent(
            "oracle-rapport.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization
                .jsonObject(with: data) as? [String: Any]
        else { oracleRapport = nil; return }
        oracleRapport = obj
    }

    func loadBulletin() {
        let url = jugeDir.appendingPathComponent(
            "bulletin-contours.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization
                .jsonObject(with: data) as? [String: Any]
        else { bulletin = nil; return }
        bulletin = obj
    }

    func log(_ line: String) {
        logLines.append(line)
        if logLines.count > 400 {
            logLines.removeFirst(logLines.count - 400)
        }
    }

    // MARK: Actions

    func preparer() {
        guard !running else { return }
        guard let sys = pythonSysteme() else {
            log("Python 3 introuvable sur ce Mac.")
            return
        }
        writeScript()
        progress = -1
        run(executable: sys,
            args: ["-m", "venv",
                   jugeDir.appendingPathComponent("venv")
                    .path],
            phase: "Création de l'environnement…") {
            [weak self] status in
            guard let self else { return }
            if status == 0 {
                self.run(
                    executable: self.venvPython.path,
                    args: ["-m", "pip", "install",
                           "torch", "numpy", "pillow",
                           "pillow-heif"],
                    phase: "Installation de PyTorch "
                        + "(plusieurs minutes)…") {
                    [weak self] status2 in
                    guard let self else { return }
                    if status2 == 0 {
                        self.log("Atelier prêt.")
                    }
                    self.refreshState()
                }
            } else {
                self.refreshState()
            }
        }
    }

    /// Valeur validée du champ époques : un entier
    /// entre 1 et 500, sinon le défaut (60).
    var epochsValides: Int {
        let t = epochsText.trimmingCharacters(
            in: .whitespaces)
        guard let v = Int(t) else { return 60 }
        return min(500, max(1, v))
    }

    /// Valeur validée du champ rotations :
    /// un entier entre 0 et 50, sinon le
    /// défaut (0 — rotations en veille).
    var rotationsValides: Int {
        let t = rotationsText.trimmingCharacters(
            in: .whitespaces)
        guard let v = Int(t) else { return 0 }
        return min(50, max(0, v))
    }

    func entrainer() {
        guard !running, atelierPret else { return }
        writeScript()
        let ep = epochsValides
        epochsText = String(ep)
        UserDefaults.standard.set(epochsText,
                                  forKey: "contoursEpochs")
        let rot = rotationsValides
        rotationsText = String(rot)
        UserDefaults.standard.set(rotationsText,
                                  forKey: "contoursRotations")
        UserDefaults.standard.set(
            ignorerSynths,
            forKey: "contoursIgnorerSynths")
        var args = [scriptURL.path,
                    "--racine", racine.path,
                    "--sortie", jugeDir.path,
                    "--epochs", String(ep),
                    "--rotations", String(rot)]
        if ignorerSynths {
            args.append("--ignorer-synthetiques")
        }
        progress = 0
        run(executable: venvPython.path,
            args: args,
            phase: "Démarrage…") { [weak self] status in
            guard let self else { return }
            if status == 0 {
                self.progress = 100
                self.phase = "Terminé — bulletin à jour."
            } else {
                self.phase = "Échec (code \(status)) — "
                    + "voir le journal."
            }
            self.loadBulletin()
            if status == 0 { self.mirrorBulletin() }
        }
    }

    /// Évaluation seule (build 140) : régénère le
    /// bulletin depuis le modèle existant, sans
    /// entraîner — le geste qui rend les réglages
    /// d'extraction mesurables en ~1 minute.
    func evaluer() {
        guard !running, atelierPret else { return }
        writeScript()
        progress = 0
        run(executable: venvPython.path,
            args: [scriptURL.path,
                   "--racine", racine.path,
                   "--sortie", jugeDir.path,
                   "--evalue"],
            phase: "Évaluation seule…") {
            [weak self] status in
            guard let self else { return }
            if status == 0 {
                self.progress = 100
                self.phase = "Terminé — bulletin "
                    + "d'évaluation à jour."
            } else {
                self.phase = "Échec (code \(status)) — "
                    + "voir le journal."
            }
            self.loadBulletin()
            if status == 0 { self.mirrorBulletin() }
        }
    }

    /// Le TOURNOI (build 143) : des variantes des
    /// constantes d'extraction compétitionnent sur
    /// dev+banc, verdict sur le strict scellé. Le
    /// champion, s'il y en a un, est écrit par le
    /// script dans extraction-champion.json et
    /// s'applique ensuite partout (jeu, bulletins).
    func tournoi() {
        guard !running, atelierPret else { return }
        writeScript()
        progress = 0
        run(executable: venvPython.path,
            args: [scriptURL.path,
                   "--racine", racine.path,
                   "--sortie", jugeDir.path,
                   "--tournoi"],
            phase: "Tournoi des constantes…") {
            [weak self] status in
            guard let self else { return }
            if status == 0 {
                self.progress = 100
                self.phase = "Terminé — tournoi "
                    + "bouclé, rapport à jour."
            } else {
                self.phase = "Échec (code \(status)) — "
                    + "voir le journal."
            }
            self.loadTournoi()
            if status == 0 { self.mirrorTournoi() }
        }
    }

    /// Le MÉGA-TOURNOI (build 144) : prospection
    /// massive sur la photo 67 (des dizaines de
    /// milliers d'enfants, échantillonnage qui
    /// apprend des échecs), séries sur la
    /// sélection, verdict sur le strict scellé.
    /// Le rapport est réécrit à chaque lot : un
    /// arrêt en cours de route laisse sa récolte,
    /// qui est quand même mirée sur Drive.
    func mega() {
        guard !running, atelierPret else { return }
        writeScript()
        progress = 0
        run(executable: venvPython.path,
            args: [scriptURL.path,
                   "--racine", racine.path,
                   "--sortie", jugeDir.path,
                   "--mega", "--photo", "67"],
            phase: "Méga-tournoi — prospection "
                + "photo 67…") {
            [weak self] status in
            guard let self else { return }
            if status == 0 {
                self.progress = 100
                self.phase = "Terminé — méga-tournoi "
                    + "bouclé, rapport à jour."
            } else {
                self.phase = "Arrêt ou échec "
                    + "(code \(status)) — récolte "
                    + "au dernier point de contrôle."
            }
            self.loadMega()
            self.mirrorMega()
        }
    }

    /// L'ÉCART ORACLE (build 145) : pour chaque
    /// photo des examens, le meilleur tenant du
    /// portefeuille (défauts, champion, tenants
    /// du méga), en pleine précision. Une mesure
    /// du plafond d'un sélecteur par photo —
    /// n'écrit aucun champion.
    func oracle() {
        guard !running, atelierPret else { return }
        writeScript()
        progress = 0
        run(executable: venvPython.path,
            args: [scriptURL.path,
                   "--racine", racine.path,
                   "--sortie", jugeDir.path,
                   "--oracle"],
            phase: "Écart oracle — meilleur "
                + "tenant par photo…") {
            [weak self] status in
            guard let self else { return }
            if status == 0 {
                self.progress = 100
                self.phase = "Terminé — écart "
                    + "oracle mesuré."
            } else {
                self.phase = "Échec (code \(status)) — "
                    + "voir le journal."
            }
            self.loadOracle()
            if status == 0 { self.mirrorOracle() }
        }
    }

    /// État de la banque synthétique
    /// permanente (Atelier/Synthetique),
    /// lu depuis son info écrite par la
    /// fabrique.
    func loadSynthInfo() {
        let url = racine.appendingPathComponent(
            "Synthetique/banque-synth-info.json")
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization
            .jsonObject(with: data)
            as? [String: Any] {
            synthInfo = obj
        } else {
            synthInfo = nil
        }
    }

    /// Titre du bouton fabrique : le contenu
    /// actuel de la banque, quand elle existe.
    var synthBoutonTitre: String {
        if let n = (synthInfo?["n"] as? NSNumber)?.intValue {
            return "Banque synthétique : \(n) "
                + "images — compléter"
        }
        return "Fabriquer la banque synthétique"
    }

    /// Fabrique (build 150, moteur v4) :
    /// construit ou
    /// complète la banque synthétique
    /// permanente (6 fonds × 10 angles par
    /// élite d'entraînement).
    func fabriquer() {
        guard !running, atelierPret else { return }
        writeScript()
        progress = 0
        var fabArgs: [String] = [scriptURL.path,
                   "--racine", racine.path,
                   "--sortie", jugeDir.path,
                   "--fabrique"]
        let lim = Int(limiteText.trimmingCharacters(
            in: .whitespaces)) ?? 0
        UserDefaults.standard.set(limiteText,
            forKey: "contoursLimite")
        if lim > 0 {
            fabArgs += ["--limite", String(lim)]
        }
        run(executable: venvPython.path,
            args: fabArgs,
            phase: "Fabrique de la banque "
                + "synthétique…") {
            [weak self] status in
            guard let self else { return }
            if status == 0 {
                self.progress = 100
                self.phase = "Terminé — banque "
                    + "synthétique à jour."
            } else {
                self.phase = "Échec (code "
                    + String(status)
                    + ") — voir le journal."
            }
            self.loadSynthInfo()
        }
    }

    func arreter() {
        process?.terminate()
    }

    // MARK: Miroir Drive du bulletin

    /// Recopie le bulletin à côté du journal sur
    /// Drive (build 122), pour que Muse puisse le
    /// lire sans que Grégoire ait à l'envoyer.
    func mirrorBulletin() {
        let fm = FileManager.default
        let src = jugeDir.appendingPathComponent(
            "bulletin-contours.json")
        guard fm.fileExists(atPath: src.path) else { return }
        guard let folder = driveFolder() else {
            log("Miroir Drive : dossier introuvable — "
                + "bulletin en local seulement.")
            return
        }
        let dst = folder.appendingPathComponent(
            "bulletin-contours.json")
        let srcSize = (try? fm.attributesOfItem(
            atPath: src.path))?[.size] as? NSNumber
        let dstSize = (try? fm.attributesOfItem(
            atPath: dst.path))?[.size] as? NSNumber
        if srcSize != nil, srcSize == dstSize { return }
        do {
            if fm.fileExists(atPath: dst.path) {
                try fm.removeItem(at: dst)
            }
            try fm.copyItem(at: src, to: dst)
            log("Bulletin recopié vers Drive "
                + "(bulletin-contours.json).")
        } catch {
            log("Miroir Drive : échec ("
                + error.localizedDescription + ")")
        }
    }

    /// Miroir Drive du rapport de tournoi (même
    /// principe que le bulletin) : Muse le lit
    /// pour annoncer le verdict sans que Grégoire
    /// ait à l'envoyer.
    func mirrorTournoi() {
        let fm = FileManager.default
        let src = jugeDir.appendingPathComponent(
            "tournoi-rapport.json")
        guard fm.fileExists(atPath: src.path) else { return }
        guard let folder = driveFolder() else {
            log("Miroir Drive : dossier introuvable — "
                + "rapport de tournoi en local seulement.")
            return
        }
        let dst = folder.appendingPathComponent(
            "tournoi-rapport.json")
        let srcSize = (try? fm.attributesOfItem(
            atPath: src.path))?[.size] as? NSNumber
        let dstSize = (try? fm.attributesOfItem(
            atPath: dst.path))?[.size] as? NSNumber
        if srcSize != nil, srcSize == dstSize { return }
        do {
            if fm.fileExists(atPath: dst.path) {
                try fm.removeItem(at: dst)
            }
            try fm.copyItem(at: src, to: dst)
            log("Rapport de tournoi recopié vers Drive "
                + "(tournoi-rapport.json).")
        } catch {
            log("Miroir Drive : échec ("
                + error.localizedDescription + ")")
        }
    }

    /// Miroir Drive du rapport de méga-tournoi
    /// (même principe que le tournoi).
    func mirrorMega() {
        let fm = FileManager.default
        let src = jugeDir.appendingPathComponent(
            "mega-rapport.json")
        guard fm.fileExists(atPath: src.path)
        else { return }
        guard let folder = driveFolder() else {
            log("Miroir Drive : dossier introuvable — "
                + "rapport de méga-tournoi en local "
                + "seulement.")
            return
        }
        let dst = folder.appendingPathComponent(
            "mega-rapport.json")
        let srcSize = (try? fm.attributesOfItem(
            atPath: src.path))?[.size] as? NSNumber
        let dstSize = (try? fm.attributesOfItem(
            atPath: dst.path))?[.size] as? NSNumber
        if srcSize != nil, srcSize == dstSize { return }
        do {
            if fm.fileExists(atPath: dst.path) {
                try fm.removeItem(at: dst)
            }
            try fm.copyItem(at: src, to: dst)
            log("Rapport de méga-tournoi recopié "
                + "vers Drive (mega-rapport.json).")
        } catch {
            log("Miroir Drive : échec ("
                + error.localizedDescription + ")")
        }
    }

    /// Miroir Drive du rapport d'écart oracle
    /// (même principe que le tournoi).
    func mirrorOracle() {
        let fm = FileManager.default
        let src = jugeDir.appendingPathComponent(
            "oracle-rapport.json")
        guard fm.fileExists(atPath: src.path)
        else { return }
        guard let folder = driveFolder() else {
            log("Miroir Drive : dossier introuvable — "
                + "rapport oracle en local seulement.")
            return
        }
        let dst = folder.appendingPathComponent(
            "oracle-rapport.json")
        let srcSize = (try? fm.attributesOfItem(
            atPath: src.path))?[.size] as? NSNumber
        let dstSize = (try? fm.attributesOfItem(
            atPath: dst.path))?[.size] as? NSNumber
        if srcSize != nil, srcSize == dstSize { return }
        do {
            if fm.fileExists(atPath: dst.path) {
                try fm.removeItem(at: dst)
            }
            try fm.copyItem(at: src, to: dst)
            log("Rapport oracle recopié vers Drive "
                + "(oracle-rapport.json).")
        } catch {
            log("Miroir Drive : échec ("
                + error.localizedDescription + ")")
        }
    }

    /// Même résolution que la banque : dossier
    /// choisi (journalFolderPath) ou Drive détecté
    /// dans CloudStorage.
    private func driveFolder() -> URL? {
        let fm = FileManager.default
        if let chosen = UserDefaults.standard.string(
            forKey: "journalFolderPath"),
           !chosen.isEmpty {
            return URL(fileURLWithPath: chosen)
        }
        let cloud = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage")
        if let entries = try? fm.contentsOfDirectory(
            at: cloud, includingPropertiesForKeys: nil) {
            for entry in entries
            where entry.lastPathComponent
                .hasPrefix("GoogleDrive") {
                let drive = entry.appendingPathComponent(
                    "My Drive")
                if fm.fileExists(atPath: drive.path) {
                    return drive
                }
            }
        }
        return nil
    }

    // MARK: Mécanique des processus

    private func writeScript() {
        try? ContoursScript.source.write(
            to: scriptURL, atomically: true,
            encoding: .utf8)
    }

    private func pythonSysteme() -> String? {
        ["/usr/bin/python3", "/opt/homebrew/bin/python3",
         "/usr/local/bin/python3"].first {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    private func run(executable: String, args: [String],
                     phase initialPhase: String,
                     onExit: @escaping (Int32) -> Void) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        let handle = pipe.fileHandleForReading
        buffer = Data()
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                self?.ingest(data)
            }
        }
        proc.terminationHandler = { [weak self] p in
            handle.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.flushBuffer()
                self.running = false
                self.process = nil
                onExit(p.terminationStatus)
            }
        }
        phase = initialPhase
        log("$ " + executable + " " + args.joined(
            separator: " "))
        do {
            try proc.run()
            process = proc
            running = true
        } catch {
            log("Lancement impossible : "
                + error.localizedDescription)
            onExit(-1)
        }
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<nl]
            buffer.removeSubrange(...nl)
            handleLine(String(
                decoding: lineData, as: UTF8.self))
        }
    }

    private func flushBuffer() {
        guard !buffer.isEmpty else { return }
        handleLine(String(decoding: buffer, as: UTF8.self))
        buffer = Data()
    }

    private func handleLine(_ raw: String) {
        let line = raw.trimmingCharacters(
            in: .whitespacesAndNewlines)
        if line.hasPrefix("PROGRES ") {
            if let v = Double(line.dropFirst(8)) {
                progress = v
            }
            return
        }
        if line.hasPrefix("PHASE ") {
            phase = String(line.dropFirst(6))
            log(line)
            return
        }
        if !line.isEmpty { log(line) }
    }
}
