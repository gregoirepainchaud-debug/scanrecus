import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// File des photos BRUTES + « chemins » pour la banque
/// d'entraînement (décision de Grégoire, 2026-10-30) : à chaque
/// « Next », en plus du reçu redressé qui part vers la boîte de
/// révision, la photo NON retouchée et les deux gestes de
/// Grégoire (l'angle du bouton rotatif, le cadre de cadrage)
/// sont gardés ici puis envoyés au serveur (POST
/// /api/recus/brut). À la révision, le serveur joint le tout
/// aux champs vérifiés : l'échantillon complet — brut, chemin,
/// résultat, extraction vérifiée — servira à apprendre à une
/// IA l'orientation, le cadrage, puis l'extraction.
///
/// Même philosophie que la file des reçus : aucune perte si le
/// réseau tombe, on réessaie à chaque vidange. Mais un brut
/// n'est que de l'entraînement : son échec ne bloque JAMAIS le
/// reçu lui-même.
///
/// Foundation seulement : testée sous Linux.
final class ReceiptBrutOutbox {

    struct Item: Equatable {
        let numero: String
        let jpegURL: URL
        let paramsURL: URL
    }

    let directory: URL

    /// Dossier par défaut :
    /// Application Support/ScanRecus/OutboxBruts.
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ScanRecus/OutboxBruts",
                                           isDirectory: true)
    }

    init(directory: URL = ReceiptBrutOutbox.defaultDirectory()) {
        self.directory = directory
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    /// Dépose un brut et son chemin (angle en degrés, cadre
    /// normalisé [x, y, largeur, hauteur]) sous le numéro du
    /// reçu. Écritures atomiques.
    func enqueue(jpeg: Data, numero: String,
                 angleDegrees: Double, crop: CGRect) throws {
        let params: [String: Any] = [
            "angle_deg": angleDegrees,
            "crop": [Double(crop.origin.x), Double(crop.origin.y),
                     Double(crop.size.width), Double(crop.size.height)],
        ]
        let paramsData = try JSONSerialization.data(
            withJSONObject: params)
        try jpeg.write(
            to: directory.appendingPathComponent("\(numero).jpg"),
            options: [.atomic])
        try paramsData.write(
            to: directory.appendingPathComponent("\(numero).json"),
            options: [.atomic])
    }

    /// Les bruts en attente (JPEG accompagné de son JSON),
    /// en ordre de numéro croissant.
    func items() -> [Item] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .map { Item(numero: $0.deletingPathExtension()
                            .lastPathComponent,
                        jpegURL: $0,
                        paramsURL: $0.deletingPathExtension()
                            .appendingPathExtension("json")) }
            .filter {
                ReceiptNumbering.isValid($0.numero)
                    && FileManager.default.fileExists(
                        atPath: $0.paramsURL.path)
            }
            .sorted { $0.numero < $1.numero }
    }

    var count: Int { items().count }

    func remove(numero: String) {
        for ext in ["jpg", "json"] {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent(
                    "\(numero).\(ext)"))
        }
    }

    /// Lit un brut et son chemin ; nil si illisible (le
    /// vidange le retirera plutôt que boucler dessus).
    func read(_ item: Item) -> (jpeg: Data, angleDegrees: Double,
                                crop: [Double])? {
        guard let jpeg = try? Data(contentsOf: item.jpegURL),
              let paramsData = try? Data(contentsOf: item.paramsURL),
              let params = (try? JSONSerialization.jsonObject(
                with: paramsData)) as? [String: Any],
              let angle = (params["angle_deg"] as? NSNumber)?
                .doubleValue,
              let cropRaw = params["crop"] as? [Any],
              cropRaw.count == 4
        else { return nil }
        let crop = cropRaw.compactMap {
            ($0 as? NSNumber)?.doubleValue
        }
        guard crop.count == 4 else { return nil }
        return (jpeg, angle, crop)
    }

    /// Vide la file dans l'ordre ; au premier échec on
    /// s'arrête. Retourne les numéros effectivement envoyés.
    @discardableResult
    func flush(send: (Data, String, Double, [Double]) async
               -> Bool) async -> [String] {
        var sent: [String] = []
        for item in items() {
            guard let brut = read(item) else {
                remove(numero: item.numero)
                continue
            }
            guard await send(brut.jpeg, item.numero,
                             brut.angleDegrees, brut.crop)
            else { break }
            remove(numero: item.numero)
            sent.append(item.numero)
        }
        return sent
    }
}
