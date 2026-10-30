import Foundation

/// File d'envoi (« outbox ») du nouveau Scanner : chaque reçu
/// dont le téléversement n'a pas encore réussi vit ici, comme
/// un fichier JPEG nommé par son numéro, dans Application
/// Support. Aucune perte si le réseau tombe, si le serveur
/// répond 5xx ou si l'app se ferme : on réessaie au lancement
/// et à chaque « Next ».
///
/// Un envoi compte comme réussi quand le serveur répond 200 —
/// y compris {"deja": true} (le reçu était déjà rendu : le
/// retirer de la file, c'est exactement ce qu'il faut).
///
/// Foundation seulement : testée sous Linux, y compris la
/// vidange de la file avec un expéditeur factice.
final class ReceiptOutbox {

    /// Un reçu en attente : son numéro et son fichier.
    struct Item: Equatable {
        let numero: String
        let fileURL: URL
    }

    let directory: URL

    /// Dossier par défaut : Application Support/ScanRecus/Outbox.
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ScanRecus/Outbox",
                                           isDirectory: true)
    }

    init(directory: URL = ReceiptOutbox.defaultDirectory()) {
        self.directory = directory
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    /// Dépose un JPEG dans la file, sous le nom de son numéro.
    /// Écriture atomique : un fichier à moitié écrit ne doit
    /// jamais pouvoir être « envoyé ».
    func enqueue(jpeg: Data, numero: String) throws {
        let url = directory.appendingPathComponent("\(numero).jpg")
        try jpeg.write(to: url, options: [.atomic])
    }

    /// Les reçus en attente, en ordre de numéro croissant
    /// (la date en préfixe fait l'ordre chronologique).
    func items() -> [Item] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .map { Item(numero: $0.deletingPathExtension()
                            .lastPathComponent,
                        fileURL: $0) }
            .filter { ReceiptNumbering.isValid($0.numero) }
            .sorted { $0.numero < $1.numero }
    }

    var count: Int { items().count }

    func remove(numero: String) {
        let url = directory.appendingPathComponent("\(numero).jpg")
        try? FileManager.default.removeItem(at: url)
    }

    /// Vide la file dans l'ordre : pour chaque reçu, `send`
    /// tente l'envoi (vrai = reçu par le serveur, doublon
    /// compris). On retire les reçus confirmés ; au PREMIER
    /// échec on s'arrête (l'ordre est préservé, et marteler un
    /// serveur ou un réseau en panne ne sert à rien).
    /// Retourne les numéros effectivement envoyés.
    @discardableResult
    func flush(send: (Data, String) async -> Bool) async -> [String] {
        var sent: [String] = []
        for item in items() {
            guard let data = try? Data(contentsOf: item.fileURL)
            else {
                // Fichier illisible : il ne passera jamais —
                // le retirer plutôt que bloquer la file à jamais.
                remove(numero: item.numero)
                continue
            }
            guard await send(data, item.numero) else { break }
            remove(numero: item.numero)
            sent.append(item.numero)
        }
        return sent
    }
}
