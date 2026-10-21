import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import Observation

// MARK: - Banque de matériel d'entraînement (2026-10-21)

/// Une photo coffrée dans la banque : l'image elle-même vit
/// dans le coffre, adressée par l'empreinte SHA-256 de son
/// fichier (une reprise du même reçu ne stocke l'image
/// qu'une fois).
struct BankPhoto: Codable, Identifiable {
    var id: String
    /// Numéro du reçu auquel la photo appartient (les photos
    /// d'un même reçu sont groupées : 5 par reçu, typiquement).
    var group: Int
    var sha256: String
    /// Nom du fichier dans le coffre (images/<2 car.>/<file>).
    var file: String
    var width: Int
    var height: Int
    var ts: String
}

/// Une copie TOURNÉE générée à partir d'une photo coffrée
/// (30 par photo, à « Next scan ») : rotation à toile
/// élargie — le reçu n'est JAMAIS coupé, les coins ne
/// sortent pas de l'image générée. L'angle appliqué est
/// enregistré : c'est l'étiquette de géométrie de la copie,
/// gratuite par construction.
struct BankDerived: Codable, Identifiable {
    var id: String
    /// La photo source (BankPhoto.id).
    var sourceId: String
    var group: Int
    /// Angle de rotation appliqué, en degrés (0,1° près).
    var angle: Double
    var sha256: String
    var file: String
    var width: Int
    var height: Int
    var ts: String
}

/// La banque de matériel du GÉNÉRATEUR (menu « Générer
/// matériel ») : les frames figées de la webcam y sont
/// coffrées telles quelles, groupées par reçu. C'est la
/// matière première de l'entraînement des IA — les
/// étiquettes viendront plus tard, sur ces images.
///
/// Stockage (décisions de Muse, budget 20 Go de Grégoire) :
/// - coffre local : ~/Library/Application Support/
///   ScanRecus/Atelier/ (jamais synchronisé — les images
///   restent sur le Mac) ;
/// - image master HEIF (repli JPEG), plafond 1600 px ;
/// - stockage adressé par SHA-256 (dédup gratuite) ;
/// - manifeste banque.jsonl APPEND-ONLY au coffre, miroité
///   dans le dossier du journal (Drive « Codage ») pour que
///   Muse puisse vérifier la banque après les sessions.
@Observable
final class TrainingBank {

    private(set) var photos: [BankPhoto] = []
    private(set) var derived: [BankDerived] = []
    private(set) var currentGroup: Int = 1
    private(set) var totalBytes: Int = 0
    /// Note de génération en cours (affichée au panneau).
    private(set) var generationNote = ""

    var totalMaterial: Int { photos.count + derived.count }

    func derived(for photo: BankPhoto) -> [BankDerived] {
        derived.filter { $0.sourceId == photo.id }
    }

    var receiptCount: Int { Set(photos.map(\.group)).count }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalBytes),
                                  countStyle: .file)
    }

    private let root: URL
    private let imagesDir: URL
    private let manifestURL: URL

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory,
                  in: .userDomainMask).first!
        root = base.appendingPathComponent("ScanRecus/Atelier",
                                           isDirectory: true)
        imagesDir = root.appendingPathComponent("images",
                                                isDirectory: true)
        manifestURL = root.appendingPathComponent("banque.jsonl")
        try? FileManager.default.createDirectory(
            at: imagesDir, withIntermediateDirectories: true)
        load()
    }

    // MARK: Manifeste (append-only)

    private struct ManifestLine: Codable {
        var type: String
        var photo: BankPhoto?
        var photoId: String?
        var current: Int?
        var derive: BankDerived?
    }

    /// Les écritures au manifeste et au coffre sont
    /// sérialisées (la génération tourne en arrière-plan).
    private let ioLock = NSLock()
    private let generationQueue = DispatchQueue(
        label: "scanrecus.banque.generation")
    private var generationRunning = false

    private func appendManifest(_ line: ManifestLine) {
        ioLock.lock()
        defer { ioLock.unlock() }
        guard let data = try? JSONEncoder().encode(line)
        else { return }
        var payload = data
        payload.append(0x0A)
        for url in [manifestURL, mirrorURL()].compactMap({ $0 }) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: payload)
            } else {
                try? payload.write(to: url)
            }
        }
    }

    /// Le miroir du manifeste, à côté du journal des scans
    /// (dossier choisi dans la vue, sinon Drive « My Drive »).
    private func mirrorURL() -> URL? {
        let fm = FileManager.default
        var folder: URL?
        if let chosen = UserDefaults.standard.string(
            forKey: "journalFolderPath"), !chosen.isEmpty {
            folder = URL(fileURLWithPath: chosen)
        } else {
            let cloud = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/CloudStorage")
            if let entries = try? fm.contentsOfDirectory(
                at: cloud, includingPropertiesForKeys: nil) {
                for entry in entries
                where entry.lastPathComponent
                    .hasPrefix("GoogleDrive") {
                    let drive = entry
                        .appendingPathComponent("My Drive")
                    if fm.fileExists(atPath: drive.path) {
                        folder = drive
                        break
                    }
                }
            }
        }
        return folder?.appendingPathComponent(
            "banque-materiel.jsonl")
    }

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL),
              let text = String(data: data, encoding: .utf8)
        else { return }
        var byId: [String: BankPhoto] = [:]
        var order: [String] = []
        var derives: [BankDerived] = []
        var group = 1
        for raw in text.split(separator: "\n") {
            guard let lineData = raw.data(using: .utf8),
                  let line = try? JSONDecoder()
                    .decode(ManifestLine.self, from: lineData)
            else { continue }
            switch line.type {
            case "photo":
                if let p = line.photo {
                    if byId[p.id] == nil { order.append(p.id) }
                    byId[p.id] = p
                    group = max(group, p.group)
                }
            case "retrait":
                if let id = line.photoId {
                    byId.removeValue(forKey: id)
                    order.removeAll { $0 == id }
                }
            case "groupe":
                if let c = line.current { group = max(group, c) }
            case "derive":
                if let d = line.derive { derives.append(d) }
            default:
                break
            }
        }
        photos = order.compactMap { byId[$0] }
        // Les copies d'une photo retirée ne comptent plus.
        derived = derives.filter { byId[$0.sourceId] != nil }
        currentGroup = group
        refreshBytes()
    }

    // MARK: Coffrage

    /// Coffre une frame figée (la meilleure image retenue
    /// par l'échantillonneur) sous le reçu courant. Rend la
    /// photo enregistrée, ou nil si l'écriture a échoué.
    @discardableResult
    func bank(cgImage: CGImage) -> BankPhoto? {
        let scaled = Self.downscale(cgImage, maxWidth: 1600)
        let tmp = root.appendingPathComponent(
            "tmp-\(UUID().uuidString)")
        let ext: String
        if Self.writeImage(scaled, to: tmp, heif: true) {
            ext = "heic"
        } else if Self.writeImage(scaled, to: tmp, heif: false) {
            ext = "jpg"
        } else {
            return nil
        }
        guard let data = try? Data(contentsOf: tmp) else {
            try? FileManager.default.removeItem(at: tmp)
            return nil
        }
        let sha = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        let name = "\(sha).\(ext)"
        let sub = imagesDir.appendingPathComponent(
            String(sha.prefix(2)), isDirectory: true)
        try? FileManager.default.createDirectory(
            at: sub, withIntermediateDirectories: true)
        let dest = sub.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) {
            // Déjà coffrée (reprise à l'identique) : on
            // référence le même fichier, on ne le recopie pas.
            try? FileManager.default.removeItem(at: tmp)
        } else {
            try? FileManager.default.moveItem(at: tmp, to: dest)
        }
        let photo = BankPhoto(
            id: UUID().uuidString, group: currentGroup,
            sha256: sha, file: name, width: scaled.width,
            height: scaled.height,
            ts: ISO8601DateFormatter().string(from: Date()))
        appendManifest(ManifestLine(type: "photo", photo: photo))
        photos.append(photo)
        refreshBytes()
        return photo
    }

    /// Passe au reçu suivant : les prochaines photos seront
    /// groupées sous un nouveau numéro.
    func nextReceipt() {
        currentGroup += 1
        appendManifest(ManifestLine(type: "groupe",
                                    current: currentGroup))
    }

    /// Retire la dernière photo coffrée (ligne de retrait au
    /// manifeste — l'historique reste append-only ; le
    /// fichier image est supprimé si plus aucune photo ne le
    /// référence).
    func removeLast() {
        guard let last = photos.last else { return }
        appendManifest(ManifestLine(type: "retrait",
                                    photoId: last.id))
        photos.removeLast()
        // Ses copies tournées partent avec elle.
        let orphans = derived.filter { $0.sourceId == last.id }
        derived.removeAll { $0.sourceId == last.id }
        if !photos.contains(where: { $0.sha256 == last.sha256 }) {
            deleteFile(sha: last.sha256, name: last.file)
        }
        for orphan in orphans
        where !derived.contains(where: {
            $0.sha256 == orphan.sha256 })
            && !photos.contains(where: {
                $0.sha256 == orphan.sha256 }) {
            deleteFile(sha: orphan.sha256, name: orphan.file)
        }
        refreshBytes()
    }

    private func deleteFile(sha: String, name: String) {
        let path = imagesDir
            .appendingPathComponent(String(sha.prefix(2)))
            .appendingPathComponent(name)
        try? FileManager.default.removeItem(at: path)
    }

    private func vaultURL(sha: String, name: String) -> URL {
        imagesDir.appendingPathComponent(String(sha.prefix(2)))
            .appendingPathComponent(name)
    }

    private func refreshBytes() {
        var total = 0
        var seen = Set<String>()
        for (sha, name) in photos.map({ ($0.sha256, $0.file) })
            + derived.map({ ($0.sha256, $0.file) })
        where !seen.contains(sha) {
            seen.insert(sha)
            let path = vaultURL(sha: sha, name: name)
            if let attrs = try? FileManager.default
                .attributesOfItem(atPath: path.path),
               let size = attrs[.size] as? Int {
                total += size
            }
        }
        totalBytes = total
    }

    // MARK: Génération des copies tournées

    /// Génère `count` copies tournées d'une photo coffrée
    /// (défaut : 30, demandé par Grégoire), en arrière-plan.
    /// Angles aléatoires distincts au 0,1° sur 360°. Chaque
    /// copie est une rotation à TOILE ÉLARGIE : le reçu
    /// entier reste dans l'image, aucun coin coupé. Sans
    /// effet si la photo a déjà ses copies.
    func generateDerived(for photo: BankPhoto, count: Int = 30) {
        ioLock.lock()
        if generationRunning
            || derived.contains(where: {
                $0.sourceId == photo.id }) {
            ioLock.unlock()
            return
        }
        generationRunning = true
        ioLock.unlock()
        generationNote = "Génération des \(count) copies "
            + "tournées du reçu nº \(photo.group)…"
        let sourceURL = vaultURL(sha: photo.sha256,
                                 name: photo.file)
        generationQueue.async { [weak self] in
            guard let self else { return }
            var made: [BankDerived] = []
            if let source = Self.loadImage(at: sourceURL) {
                var tenths = Set<Int>()
                while tenths.count < count {
                    tenths.insert(Int.random(in: 0..<3600))
                }
                let context = CIContext()
                for tenth in tenths.sorted() {
                    let angle = Double(tenth) / 10.0
                    if let entry = self.makeDerived(
                        source: source, photo: photo,
                        angleDegrees: angle, context: context) {
                        made.append(entry)
                    }
                    let done = made.count
                    DispatchQueue.main.async { [weak self] in
                        self?.generationNote =
                            "Génération des copies du reçu "
                            + "nº \(photo.group)… \(done)/\(count)"
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.derived.append(contentsOf: made)
                self.refreshBytes()
                self.generationRunning = false
                self.generationNote = made.isEmpty
                    ? "Génération impossible (image source "
                        + "illisible)."
                    : "Copies du reçu nº \(photo.group) : "
                        + "\(made.count) rotations générées."
            }
        }
    }

    /// Fabrique UNE copie tournée : rotation à toile élargie,
    /// plafond 1600 px au plus grand côté, HEIF, coffrage
    /// adressé par empreinte, ligne au manifeste.
    private func makeDerived(source: CGImage, photo: BankPhoto,
                             angleDegrees: Double,
                             context: CIContext)
        -> BankDerived? {
        let radians = CGFloat(angleDegrees * .pi / 180)
        var image = CIImage(cgImage: source)
        // Rotation autour du centre puis translation à
        // l'origine : l'extent résultant contient TOUTE
        // l'image tournée (aucun coin coupé).
        let centre = CGAffineTransform(
            translationX: image.extent.midX,
            y: image.extent.midY)
        let back = CGAffineTransform(
            translationX: -image.extent.midX,
            y: -image.extent.midY)
        image = image
            .transformed(by: back)
            .transformed(by: CGAffineTransform(
                rotationAngle: radians))
            .transformed(by: centre)
        image = image.transformed(by: CGAffineTransform(
            translationX: -image.extent.minX,
            y: -image.extent.minY))
        guard let rendered = context.createCGImage(
            image, from: image.extent)
        else { return nil }
        let scaled = Self.downscaleToFit(rendered, maxSide: 1600)
        let tmp = root.appendingPathComponent(
            "tmp-\(UUID().uuidString)")
        let ext: String
        if Self.writeImage(scaled, to: tmp, heif: true) {
            ext = "heic"
        } else if Self.writeImage(scaled, to: tmp,
                                  heif: false) {
            ext = "jpg"
        } else {
            return nil
        }
        guard let data = try? Data(contentsOf: tmp) else {
            try? FileManager.default.removeItem(at: tmp)
            return nil
        }
        let sha = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        let name = "\(sha).\(ext)"
        let dest = vaultURL(sha: sha, name: name)
        try? FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: tmp)
        } else {
            try? FileManager.default.moveItem(at: tmp, to: dest)
        }
        let entry = BankDerived(
            id: UUID().uuidString, sourceId: photo.id,
            group: photo.group, angle: angleDegrees,
            sha256: sha, file: name, width: scaled.width,
            height: scaled.height,
            ts: ISO8601DateFormatter().string(from: Date()))
        appendManifest(ManifestLine(type: "derive",
                                    derive: entry))
        return entry
    }

    private static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: Écriture d'image

    private static func downscale(_ image: CGImage,
                                  maxWidth: Int) -> CGImage {
        guard image.width > maxWidth else { return image }
        let height = Int((Double(image.height)
            * Double(maxWidth) / Double(image.width)).rounded())
        guard let ctx = CGContext(
            data: nil, width: maxWidth, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo
                .premultipliedLast.rawValue)
        else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: maxWidth,
                                   height: height))
        return ctx.makeImage() ?? image
    }

    /// Réduit pour que le plus grand côté ne dépasse pas
    /// `maxSide` (les copies tournées voient leur toile
    /// grandir d'environ 1,41× à 45°).
    private static func downscaleToFit(_ image: CGImage,
                                       maxSide: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxSide else { return image }
        let scale = Double(maxSide) / Double(longest)
        let w = Int((Double(image.width) * scale).rounded())
        let h = Int((Double(image.height) * scale).rounded())
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo
                .premultipliedLast.rawValue)
        else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w,
                                   height: h))
        return ctx.makeImage() ?? image
    }

    private static func writeImage(_ image: CGImage, to url: URL,
                                   heif: Bool) -> Bool {
        let type = (heif ? "public.heic" : "public.jpeg")
            as CFString
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, type, 1, nil)
        else { return false }
        let options: [CFString: Any] =
            [kCGImageDestinationLossyCompressionQuality: 0.82]
        CGImageDestinationAddImage(dest, image,
                                   options as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}
