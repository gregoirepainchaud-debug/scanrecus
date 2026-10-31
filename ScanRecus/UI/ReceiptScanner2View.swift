import AppKit
import CoreGraphics
import SwiftUI

/// SCANNER 2 (build 165, 2026-10-30) — demandé par Grégoire :
/// « à côté du scanner, un scanner 2, il prend la photo
/// automatiquement, bouton recommencer le scan si j'ai raté,
/// ça upload le scan complet sur le site ».
///
/// Le scan COMPLET : la photo BRUTE, pleine et non modifiée —
/// aucune rotation, aucun cadrage, aucun réglage d'image ici.
/// C'est Muse, côté serveur, qui fera la luminosité, le
/// redressement et le découpage, puis l'interprétation.
/// Scanner 2 est donc volontairement minimal : la même
/// plomberie caméra et le même jugement de capture automatique
/// que le Scanner (StillFrameGrabber + ReceiptAutoTrigger,
/// inchangés), un aperçu tel quel, deux boutons.
///
/// L'envoi suit EXACTEMENT le contrat du Scanner : même file
/// d'envoi (ReceiptOutbox, même dossier), même expéditeur
/// (ReceiptUploader.sender), même jeton (le réglage d'envoi du
/// panneau Scanner — aucun second réglage), même numérotation
/// (ReceiptNumbering, séquence du jour partagée), même
/// endpoint POST /api/recus/televerser. L'encodage réutilise
/// ReceiptPhotoRenderer.renderRawJPEG : la politique du rendu
/// final du Scanner (plus long côté 1600 px, JPEG qualité 0,8)
/// SANS aucune transformation — c'est la fonction que le
/// build 161 avait créée pour la photo brute d'entraînement.
///
/// Pas d'envoi « brut » séparé vers la banque d'entraînement :
/// ici, le téléversement principal EST déjà la photo brute.
///
/// BUILD 166 (2026-10-30) — « Reprendre ce scan », en miroir
/// du build 162 du Scanner : le panneau affiche le dernier
/// scan envoyé DEPUIS le Scanner 2 et offre de le retirer
/// (de la file s'il y est encore, du serveur sinon) pour
/// rescanner le même reçu. Sans ça, un scan complet dont
/// Grégoire doute de la lisibilité ne pouvait pas être
/// repris — il rescanait par-dessus et doublait la boîte
/// (vécu le premier soir : un reçu plié envoyé deux fois).
/// Le numéro est persisté sous SA PROPRE clé UserDefaults
/// (« receipt2LastScanNumero ») : un scan du Scanner ne se
/// reprend pas d'ici, et vice versa. Pas de file de bruts
/// ici : le retrait ne touche que la file principale et le
/// serveur, qui supprime la ligne et la photo.
///
/// Même build 166 — RACCOURCIS CLAVIER de l'aperçu, pour
/// trancher sans souris quand le reçu est encore en main :
/// Entrée ou Espace = « Envoyer », Maj (seule) =
/// « Recommencer le scan ». Ils ne vivent QU'en phase
/// aperçu : un moniteur d'événements local (voir la scène)
/// est installé à l'apparition de l'aperçu et retiré à sa
/// disparition, et il revérifie la phase avant d'agir.

// MARK: - Session du Scanner 2

/// État et gestes du Scanner 2 : capture automatique, aperçu
/// brut, envoi du scan complet.
@Observable
final class ReceiptScan2Session {

    enum Phase { case capture, apercu }

    private(set) var phase: Phase = .capture
    private(set) var photo: CGImage?
    var statusMessage = "Présentez un reçu : il se "
        + "photographiera tout seul dès qu'il sera stable."
    private(set) var outboxCount = 0
    private(set) var isFlushing = false

    /// Le dernier scan complet parti DEPUIS le Scanner 2
    /// (build 166), persisté sur ce Mac : le panneau offre
    /// « Reprendre ce scan » — retirer un scan dont on doute
    /// de la lisibilité (de la file s'il y est encore, du
    /// serveur sinon) pour rescanner le même reçu. Clé
    /// PROPRE au Scanner 2, distincte de celle du Scanner
    /// (« receiptLastScanNumero ») : les deux derniers scans
    /// ne se mélangent jamais.
    var dernierScanNumero: String? {
        didSet {
            if let dernierScanNumero {
                UserDefaults.standard.set(
                    dernierScanNumero,
                    forKey: "receipt2LastScanNumero")
            } else {
                UserDefaults.standard.removeObject(
                    forKey: "receipt2LastScanNumero")
            }
        }
    }

    /// SON capteur d'image fixe (le routeur aiguille les
    /// frames vers lui seulement dans la section Scanner 2) :
    /// la détection automatique du Scanner reste la sienne,
    /// les deux ne se marchent pas dessus.
    let grabber = StillFrameGrabber()
    /// La file d'envoi PARTAGÉE avec le Scanner (même dossier
    /// par défaut) : un scan complet en attente y voisine les
    /// reçus préparés, et n'importe lequel des deux panneaux
    /// peut la vider.
    let outbox = ReceiptOutbox()

    init() {
        dernierScanNumero = UserDefaults.standard.string(
            forKey: "receipt2LastScanNumero")
        refreshOutboxCount()
        grabber.onAutoTrigger = { [weak self] in
            self?.autoShutter()
        }
        grabber.onAutoStatus = { [weak self] message in
            guard let self, self.phase == .capture else { return }
            self.statusMessage = message
        }
        // La détection est le mode normal du Scanner 2 (pas
        // d'interrupteur ici) : armée dès l'ouverture, en phase
        // capture.
        grabber.rearmAuto()
        grabber.armed = true
    }

    /// Réarme la détection à zéro (disposition, compte,
    /// verrou de tir) — à chaque retour en capture.
    private func rearm() {
        grabber.rearmAuto()
        grabber.armed = true
    }

    /// Tir automatique : même geste que le bouton, venu du
    /// capteur. Ignoré hors phase capture (un tir en vol
    /// pendant l'aperçu ne doit rien photographier).
    func autoShutter() {
        guard phase == .capture else { return }
        shutter()
    }

    /// Déclencheur : photographie l'image courante de la
    /// caméra, TELLE QUELLE — elle ne sera ni tournée, ni
    /// cadrée, ni retouchée, ni ici ni à l'envoi.
    func shutter() {
        guard let frame = grabber.snapshot() else {
            statusMessage = "La caméra n'a pas encore d'image "
                + "— un petit instant…"
            return
        }
        grabber.armed = false
        photo = frame
        phase = .apercu
        statusMessage = "Photo prise ✓ — c'est le scan "
            + "complet, tel quel. « Envoyer » (Entrée) le "
            + "téléverse ; « Recommencer le scan » (Maj) si "
            + "vous l'avez raté."
    }

    /// « Recommencer le scan » : jette la photo et réarme la
    /// capture automatique — le prochain reçu repart de zéro.
    func recommencer() {
        photo = nil
        phase = .capture
        statusMessage = "Présentez un reçu : il se "
            + "photographiera tout seul dès qu'il sera stable."
        rearm()
    }

    /// « Envoyer » : encode le frame brut en JPEG (politique
    /// du rendu final du Scanner, aucune transformation), lui
    /// assigne son numéro, le dépose dans la file d'envoi
    /// (sûreté d'abord), revient à la capture, puis tente
    /// l'envoi. Sans jeton : message clair, rien n'est
    /// consommé ni envoyé — la photo reste à l'écran.
    @MainActor
    func envoyer(token: String) async {
        guard let photo else { return }
        let token = token.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            statusMessage = "⚠️ Jeton d'envoi manquant : ouvrez "
                + "« Réglages d'envoi » dans le panneau du "
                + "Scanner et collez le jeton — rien n'a été "
                + "envoyé, la photo est toujours là."
            return
        }
        guard let jpeg = ReceiptPhotoRenderer.renderRawJPEG(
            photo: photo) else {
            statusMessage = "⚠️ L'encodage de la photo a "
                + "échoué — recommencez le scan."
            return
        }
        let numero = ReceiptNumbering.next()
        do {
            try outbox.enqueue(jpeg: jpeg, numero: numero)
        } catch {
            statusMessage = "⚠️ Impossible de garder le scan "
                + "\(numero) dans la file d'envoi : "
                + error.localizedDescription
            return
        }
        dernierScanNumero = numero
        refreshOutboxCount()
        self.photo = nil
        phase = .capture
        let sent = await flush(token: token)
        statusMessage = sent.contains(numero)
            ? "Scan complet \(numero) envoyé ✓"
            : "Scan complet \(numero) gardé dans la file "
                + "d'envoi — l'envoi reprendra tout seul dès "
                + "que le réseau ou le serveur répondra."
        // Réarmer la détection, mais pas tout de suite : le
        // verdict doit rester lisible un moment avant que la
        // chasse au prochain reçu reprenne ses propres
        // messages (même délai que le Scanner).
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 2.5) { [weak self] in
            guard let self, self.phase == .capture else { return }
            self.rearm()
        }
    }

    /// Tente de vider la file d'envoi partagée (au lancement
    /// de la section, à chaque envoi, au bouton « Réessayer »).
    /// Retourne les numéros partis.
    @MainActor
    @discardableResult
    func flush(token: String) async -> [String] {
        let token = token.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !token.isEmpty, !isFlushing else { return [] }
        isFlushing = true
        defer {
            isFlushing = false
            refreshOutboxCount()
        }
        return await outbox.flush(
            send: ReceiptUploader.sender(token: token))
    }

    /// Le bouton « Réessayer l'envoi » du panneau : il dit
    /// TOUJOURS son verdict (même leçon que le Scanner).
    @MainActor
    func retryFlush(token: String) async {
        let avant = outboxCount
        let sent = await flush(token: token)
        if !sent.isEmpty {
            statusMessage = outboxCount == 0
                ? "File d'envoi vidée ✓ (\(sent.count) reçu(s) parti(s))"
                : "\(sent.count) reçu(s) envoyé(s) — il en "
                    + "reste \(outboxCount) dans la file."
        } else if avant > 0 {
            statusMessage = token.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty
                ? "⚠️ Aucun envoi : le jeton est manquant "
                    + "(voir « Réglages d'envoi » du Scanner)."
                : "⚠️ L'envoi a échoué — jeton refusé ou "
                    + "réseau muet. Le scan reste dans la file."
        }
    }

    func refreshOutboxCount() {
        outboxCount = outbox.count
    }

    /// « Reprendre ce scan » (build 166, miroir du build 162
    /// du Scanner) : retire le dernier scan complet parti —
    /// de la file d'envoi s'il y est encore (rien n'est
    /// jamais parti), du serveur sinon (POST
    /// /api/recus/retirer) — pour que Grégoire rescanne le
    /// même reçu au lieu de le doubler dans la boîte. Un
    /// reçu déjà RÉVISÉ ne se reprend pas d'ici : sa dépense
    /// existe, ça se règle dans l'app Gestion. Pas de file
    /// de bruts dans le Scanner 2 : le téléversement EST le
    /// brut, le serveur supprime la ligne et la photo.
    @MainActor
    func reprendreDernierScan(token: String) async {
        guard let numero = dernierScanNumero else { return }
        let token = token.trimmingCharacters(
            in: .whitespacesAndNewlines)
        if outbox.items().contains(where: { $0.numero == numero }) {
            outbox.remove(numero: numero)
            dernierScanNumero = nil
            refreshOutboxCount()
            statusMessage = "Scan \(numero) repris : il était "
                + "encore dans la file, rien n'est parti. "
                + "Rescannez le reçu."
            return
        }
        guard !token.isEmpty else {
            statusMessage = "⚠️ Pour retirer le scan \(numero) "
                + "du serveur, il faut le jeton — voir "
                + "« Réglages d'envoi »."
            return
        }
        switch await ReceiptUploader.retirer(
            numero: numero, token: token) {
        case .retire, .introuvable:
            dernierScanNumero = nil
            statusMessage = "Scan \(numero) retiré — "
                + "rescannez le reçu."
        case .dejaRevise:
            statusMessage = "⚠️ Le reçu \(numero) est déjà "
                + "RÉVISÉ : il ne se reprend plus d'ici. Si "
                + "c'est une erreur, supprimez-le dans "
                + "l'app Gestion."
        case .failed:
            statusMessage = "⚠️ Le retrait du scan \(numero) "
                + "a échoué (réseau ou serveur muet) — il est "
                + "toujours dans la boîte. Réessayez, ou "
                + "supprimez-le dans l'app Gestion."
        }
    }
}

// MARK: - Scène (zone du haut)

/// La zone d'image du Scanner 2. En capture, elle est
/// transparente : l'aperçu caméra partagé (toujours dans la
/// hiérarchie, sous la scène) montre le flux, la scène ne pose
/// que l'état de la détection et le déclencheur manuel. En
/// aperçu, elle montre la photo PLEINE ET NON MODIFIÉE, sur
/// fond noir, avec les deux boutons.
struct ReceiptScanner2Stage: View {
    @Bindable var session: ReceiptScan2Session
    var containerSize: CGSize
    @AppStorage("receiptUploadToken") private var uploadToken = ""

    /// Moniteur d'événements clavier local des raccourcis
    /// de l'aperçu (build 166) : installé seulement pendant
    /// que l'aperçu est à l'écran, retiré dès qu'il en sort
    /// — voir installerMoniteurClavier().
    @State private var moniteurClavier: Any?

    var body: some View {
        ZStack {
            if session.phase == .apercu, let photo = session.photo {
                apercuContent(photo: photo)
            } else {
                captureContent
            }
        }
        .frame(width: containerSize.width,
               height: containerSize.height)
    }

    // Capture : l'état de la détection en haut (visible
    // pendant qu'il tient le reçu à deux mains — « stabilisez…
    // (2/3) » lui dit où en est le compte), le déclencheur
    // manuel en bas, par-dessus l'aperçu partagé — comme le
    // Scanner.
    private var captureContent: some View {
        ZStack {
            VStack {
                HStack {
                    Text(session.statusMessage)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.55))
                        .cornerRadius(8)
                    Spacer()
                }
                Spacer()
            }
            .padding(12)
            VStack {
                Spacer()
                Button {
                    session.shutter()
                } label: {
                    ZStack {
                        Circle()
                            .stroke(Color.white, lineWidth: 4)
                            .frame(width: 76, height: 76)
                        Circle()
                            .fill(Color.white)
                            .frame(width: 60, height: 60)
                    }
                    .shadow(color: .black.opacity(0.5), radius: 4)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 26)
            }
        }
        .frame(width: containerSize.width,
               height: containerSize.height)
    }

    // Aperçu : la photo brute, pleine, à l'endroit où la
    // caméra l'a prise — AUCUN redressement d'affichage non
    // plus, ce qui part est ce qui se voit. Les deux boutons
    // en bas : recommencer, ou envoyer (le principal).
    private func apercuContent(photo: CGImage) -> some View {
        ZStack {
            Color.black
            Image(photo, scale: 1, label: Text("Scan complet"))
                .resizable()
                .scaledToFit()
                .padding(10)
            VStack {
                HStack {
                    Text("Scan complet — photo brute, sans "
                        + "redressement ni cadrage : la "
                        + "préparation se fera côté serveur.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.55))
                        .cornerRadius(8)
                    Spacer()
                }
                Spacer()
            }
            .padding(12)
            .allowsHitTesting(false)
            VStack {
                Spacer()
                HStack(spacing: 12) {
                    Button("Recommencer le scan") {
                        session.recommencer()
                    }
                    .controlSize(.large)
                    Spacer()
                    Button("Envoyer ✓") {
                        Task {
                            await session.envoyer(
                                token: uploadToken)
                        }
                    }
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [])
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
        .onAppear { installerMoniteurClavier() }
        .onDisappear { retirerMoniteurClavier() }
    }

    // MARK: - Raccourcis clavier de l'aperçu (build 166)

    /// Installe le moniteur local qui donne ses raccourcis
    /// à l'aperçu : Entrée ou Espace = Envoyer, Maj seule =
    /// Recommencer le scan.
    ///
    /// Pourquoi un moniteur NSEvent plutôt que des
    /// .keyboardShortcut : (1) la touche Maj SEULE ne produit
    /// aucun keyDown — seuls les événements .flagsChanged la
    /// signalent, et SwiftUI n'y donne pas accès ; (2) le
    /// piège du focus — si un bouton a le focus clavier,
    /// Espace « clique » le bouton focalisé : le moniteur
    /// local voit l'événement AVANT la chaîne de réponse et
    /// l'avale (retour nil), donc Espace déclenche toujours
    /// Envoyer, jamais le bouton focalisé, et jamais deux
    /// fois. Le .keyboardShortcut(.return) du bouton
    /// « Envoyer » reste en place comme filet : le moniteur
    /// avale Entrée avant lui, il ne tire qu'en dernier
    /// recours.
    ///
    /// Portée : le moniteur n'existe que pendant que
    /// l'aperçu est à l'écran (onAppear/onDisappear de
    /// l'aperçu) et son gestionnaire revérifie
    /// `phase == .apercu` avant chaque geste — en capture
    /// et dans les autres sections, ces touches ne font
    /// donc rien de spécial. Le jeton est lu frais dans
    /// UserDefaults (le même stockage que le @AppStorage
    /// « receiptUploadToken » des panneaux) au moment de la
    /// touche.
    private func installerMoniteurClavier() {
        retirerMoniteurClavier()
        moniteurClavier = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged]) {
            [session] event in
            guard session.phase == .apercu else { return event }
            if event.type == .flagsChanged {
                // Maj seule, à l'APPUI : le keyCode dit
                // quelle touche de modification a changé
                // (56 = Maj gauche, 60 = Maj droite) et les
                // drapeaux portent l'état APRÈS le changement
                // — à l'appui ils contiennent .shift, au
                // relâchement non. « Seule » : aucun autre
                // modificateur pertinent en même temps.
                let pertinents = event.modifierFlags
                    .intersection([.command, .control, .option,
                                   .shift, .function])
                if (event.keyCode == 56 || event.keyCode == 60),
                   pertinents == [.shift] {
                    session.recommencer()
                }
                // Ne pas avaler : le suivi des modificateurs
                // par le reste de l'interface continue.
                return event
            }
            // keyDown : Entrée (36, ou 76 au pavé numérique)
            // ou Espace (49), sans modificateur de commande.
            let mods = event.modifierFlags
                .intersection([.command, .control, .option,
                               .function])
            guard mods.isEmpty,
                  event.keyCode == 49 || event.keyCode == 36
                    || event.keyCode == 76
            else { return event }
            let jeton = UserDefaults.standard.string(
                forKey: "receiptUploadToken") ?? ""
            Task { await session.envoyer(token: jeton) }
            // Avalé : le bouton focalisé, s'il y en a un, ne
            // recevra pas la touche — pas de double geste.
            return nil
        }
    }

    private func retirerMoniteurClavier() {
        if let moniteurClavier {
            NSEvent.removeMonitor(moniteurClavier)
            self.moniteurClavier = nil
        }
    }
}

// MARK: - Panneau (bas de l'écran)

/// Le panneau du Scanner 2 : le message d'état et la file
/// d'envoi partagée. PAS de réglages d'envoi ici : le jeton se
/// règle une seule fois, dans le panneau du Scanner (même clé
/// UserDefaults, lue telle quelle).
struct ReceiptScanner2Panel: View {
    @Bindable var session: ReceiptScan2Session
    @AppStorage("receiptUploadToken") private var uploadToken = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.statusMessage)
                .font(.system(size: 15, weight: .medium))
            Text("Scanner 2 envoie la photo COMPLÈTE et brute, "
                + "sans préparation : la luminosité, le "
                + "redressement et le découpage se font côté "
                + "serveur. Le jeton d'envoi est celui des "
                + "« Réglages d'envoi » du Scanner — il n'y en "
                + "a qu'un.")
                .font(.system(size: 12.5))
                .foregroundColor(.secondary)
            if session.outboxCount > 0 {
                HStack(spacing: 10) {
                    Text("📤 \(session.outboxCount) reçu(s) "
                        + "en attente d'envoi")
                        .font(.system(size: 14))
                    Button("Réessayer l'envoi") {
                        Task {
                            await session.retryFlush(
                                token: uploadToken)
                        }
                    }
                    .disabled(session.isFlushing
                              || uploadToken.isEmpty)
                    if uploadToken.isEmpty {
                        Text("(jeton manquant — voir les "
                            + "réglages du Scanner)")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }
            }
            if let numero = session.dernierScanNumero {
                HStack(spacing: 10) {
                    Text("Dernier scan : \(numero)")
                        .font(.system(size: 14))
                    Button("Reprendre ce scan") {
                        Task {
                            await session.reprendreDernierScan(
                                token: uploadToken)
                        }
                    }
                    .disabled(session.isFlushing)
                }
            }
        }
        .onAppear {
            session.refreshOutboxCount()
            if session.outboxCount > 0 {
                Task { await session.flush(token: uploadToken) }
            }
        }
    }
}
