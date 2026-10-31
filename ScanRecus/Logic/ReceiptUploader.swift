import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // URLSession sous Linux (vérification locale)
#endif

/// Téléversement d'un reçu vers l'app Gestion (contrat figé,
/// vérifié bout en bout côté serveur) :
///   POST https://app.gregoirepainchaud.ca/api/recus/televerser
///   En-têtes : X-Recus-Token: <jeton>
///              X-Recu-Numero: <AAAAMMJJ.NNNN>
///   Corps : les octets JPEG, sans multipart.
///   200 {"ok": true} — reçu. 200 {"ok": true, "deja": true}
///   — doublon déjà rendu : AUSSI un succès (le serveur a le
///   reçu, la file peut le retirer).
///   401 = jeton refusé, 400 = numéro invalide : des échecs
///   francs, l'envoi reste dans la file.
///
/// Le jeton vient des réglages de l'app (saisi par Grégoire,
/// gardé en local) — JAMAIS codé en dur : le dépôt est public.
enum ReceiptUploader {

    static let endpoint = URL(
        string: "https://app.gregoirepainchaud.ca/api/recus/televerser")!

    enum Outcome: Equatable {
        case sent           // 200, nouveau reçu
        case alreadyThere   // 200, doublon déjà reçu
        case failed         // réseau, 4xx/5xx, réponse illisible
    }

    /// Un essai d'envoi. Le corps de la réponse est lu pour
    /// distinguer « deja » d'un envoi neuf — les deux valent
    /// succès pour la file d'envoi.
    static func upload(jpeg: Data, numero: String, token: String,
                       session: URLSession = .shared) async -> Outcome {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-Recus-Token")
        request.setValue(numero, forHTTPHeaderField: "X-Recu-Numero")
        request.setValue("image/jpeg",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = jpeg
        request.timeoutInterval = 30
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200 else { return .failed }
            if let object = try? JSONSerialization.jsonObject(
                with: data) as? [String: Any],
               object["deja"] as? Bool == true {
                return .alreadyThere
            }
            return .sent
        } catch {
            return .failed
        }
    }

    /// L'expéditeur que la file d'envoi consomme : vrai dès que
    /// le serveur a le reçu (neuf ou doublon).
    static func sender(token: String) -> (Data, String) async -> Bool {
        { data, numero in
            await upload(jpeg: data, numero: numero,
                         token: token) != .failed
        }
    }

    // ------------------------------------------------ photo brute

    static let brutEndpoint = URL(
        string: "https://app.gregoirepainchaud.ca/api/recus/brut")!

    /// Envoi d'une photo BRUTE et de son « chemin » (angle en
    /// degrés, cadre normalisé [x, y, largeur, hauteur]) vers la
    /// banque d'entraînement. Mêmes en-têtes et même lecture de
    /// la réponse que le téléversement du reçu. Les nombres sont
    /// formatés en locale POSIX : un « 12,5 » à la française
    /// serait refusé par le serveur.
    static func uploadBrut(jpeg: Data, numero: String,
                           angleDegrees: Double, crop: [Double],
                           token: String,
                           session: URLSession = .shared)
        async -> Outcome {
        let posix = Locale(identifier: "en_US_POSIX")
        var request = URLRequest(url: brutEndpoint)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-Recus-Token")
        request.setValue(numero, forHTTPHeaderField: "X-Recu-Numero")
        request.setValue(
            String(format: "%.3f", locale: posix, angleDegrees),
            forHTTPHeaderField: "X-Recu-Angle")
        let cropJSON = "[" + crop.map {
            String(format: "%.5f", locale: posix, $0)
        }.joined(separator: ",") + "]"
        request.setValue(cropJSON, forHTTPHeaderField: "X-Recu-Crop")
        request.setValue("image/jpeg",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = jpeg
        request.timeoutInterval = 30
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200 else { return .failed }
            if let object = try? JSONSerialization.jsonObject(
                with: data) as? [String: Any],
               object["deja"] as? Bool == true {
                return .alreadyThere
            }
            return .sent
        } catch {
            return .failed
        }
    }

    /// L'expéditeur que la file des bruts consomme.
    static func brutSender(token: String)
        -> (Data, String, Double, [Double]) async -> Bool {
        { data, numero, angle, crop in
            await uploadBrut(jpeg: data, numero: numero,
                             angleDegrees: angle, crop: crop,
                             token: token) != .failed
        }
    }
}
