import Foundation
import Combine

/// Pilote de l'atelier du juge (build 121) : prépare
/// l'environnement Python (venv + torch) dans
/// Application Support/ScanRecus/Juge, lance
/// l'entraînement (juge.py, MPS si disponible) et
/// suit sa progression via les lignes « PROGRES n »
/// du script. Le bulletin (bulletin.json, calculé
/// sur le banc figé) est relu après chaque
/// entraînement. Aucune donnée ne sort du Mac.
final class JugeRunner: ObservableObject {
    @Published var logLines: [String] = []
    @Published var progress: Double = -1
    @Published var phase: String = ""
    @Published var running = false
    @Published var atelierPret = false
    @Published var bulletin: [String: Any]?

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
        refreshState()
    }

    var venvPython: URL {
        jugeDir.appendingPathComponent("venv/bin/python3")
    }
    var scriptURL: URL {
        jugeDir.appendingPathComponent("juge.py")
    }

    func refreshState() {
        atelierPret = FileManager.default
            .fileExists(atPath: venvPython.path)
        loadBulletin()
        if bulletin != nil { mirrorBulletin() }
    }

    func loadBulletin() {
        let url = jugeDir.appendingPathComponent(
            "bulletin.json")
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

    func entrainer() {
        guard !running, atelierPret else { return }
        writeScript()
        progress = 0
        run(executable: venvPython.path,
            args: [scriptURL.path,
                   "--racine", racine.path,
                   "--sortie", jugeDir.path,
                   "--epochs", "40"],
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
            "bulletin.json")
        guard fm.fileExists(atPath: src.path) else { return }
        guard let folder = driveFolder() else {
            log("Miroir Drive : dossier introuvable — "
                + "bulletin en local seulement.")
            return
        }
        let dst = folder.appendingPathComponent(
            "bulletin-juge.json")
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
                + "(bulletin-juge.json).")
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
        try? JugeScript.source.write(
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
