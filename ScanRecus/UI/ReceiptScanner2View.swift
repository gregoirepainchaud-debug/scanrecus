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
///
/// BUILD 167 (2026-10-30) — STABILISATION : « en faire une
/// vraie app de bureau » (Grégoire) ; l'app restera ensuite
/// telle quelle quelques trimestres, le temps que la banque
/// de reçus grossisse. Quatre chantiers : (1) « Recommencer
/// le scan » réparé — le réarmement immédiat
/// re-photographiait le mauvais reçu encore tenu devant la
/// caméra (voir recommencer()) ; (2) raccourcis clavier
/// fiabilisés — le moniteur vit au niveau de la scène et sa
/// logique est une fonction nommée (voir installerMoniteur-
/// Clavier et raccourci) ; (3) « Next scan », le bouton de
/// la barre du bas, est de retour dans la section
/// Scanner 2 (voir CompositeScanView) ; (4) les sections
/// héritées — Scanner 1 compris — sont grisées tant que
/// « Outils hérités » est fermé (voir CompositeScanView).

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

    /// « Recommencer le scan » : jette la photo, rend la
    /// webcam en direct et réarme la capture automatique —
    /// le prochain reçu repart de zéro.
    ///
    /// CORRECTIF build 167 — le réarmement était IMMÉDIAT :
    /// le mauvais reçu, toujours tenu devant la caméra au
    /// moment d'appuyer, re-déclenchait la photo après ~3
    /// images stables (~0,5 s). L'aperçu revenait avec une
    /// image jumelle de la mauvaise, et Grégoire ne voyait
    /// jamais le flux en direct : « ça loadait le calque au
    /// lieu de repartir la webcam et de flusher la mauvaise
    /// image ». La correction rend d'abord la main : la
    /// photo est jetée (elle n'a jamais été déposée dans
    /// la file — rien à retirer), la scène repasse en
    /// capture donc le flux caméra redevient visible, et la
    /// détection reste DÉSACTIVÉE pendant un délai de
    /// grâce (1,5 s) — le temps de repositionner le reçu —
    /// avant le réarmement à zéro, même état qu'à
    /// l'ouverture de la section. Même patron que le délai
    /// de 2,5 s après un envoi (voir envoyer()).
    func recommencer() {
        photo = nil
        phase = .capture
        // Désarmement immédiat : sans lui, la détection
        // repartirait sur la scène inchangée avant même
        // que le délai de grâce commence.
        grabber.armed = false
        statusMessage = "Mauvaise photo jetée — la webcam "
            + "est en direct. Repositionnez le reçu : la "
            + "détection repart dans un instant…"
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 1.5) { [weak self] in
            // Seulement si on est toujours en capture : un
            // déclenchement manuel entre-temps rend le
            // réarmement inutile, et un envoi a le sien.
            guard let self, self.phase == .capture else { return }
            self.statusMessage = "Présentez un reçu : il se "
                + "photographiera tout seul dès qu'il sera "
                + "stable."
            self.rearm()
        }
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
    /// de l'aperçu (build 166 ; fiabilisé au build 167) :
    /// installé tant que la section Scanner 2 est à l'écran,
    /// retiré quand on la quitte — voir
    /// installerMoniteurClavier().
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
        // Le moniteur vit au niveau de la SCÈNE (build
        // 167) : il ne dépend plus du montage/démontage de
        // la branche aperçu dans le ZStack — il existe de
        // façon certaine tant que la section est là. Ce
        // qui borne les raccourcis à l'aperçu, c'est le
        // garde de phase du gestionnaire (voir raccourci).
        .onAppear { installerMoniteurClavier() }
        .onDisappear { retirerMoniteurClavier() }
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
    }

    // MARK: - Raccourcis clavier de l'aperçu (builds 166-167)

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
    /// Portée et fiabilité (build 167) : le moniteur est
    /// installé au niveau de la SCÈNE du Scanner 2 — le
    /// onAppear/onDisappear de la scène, ci-dessus — et non
    /// plus sur la branche aperçu (build 166) : son
    /// existence ne dépend plus du moment exact où SwiftUI
    /// monte ou démonte l'aperçu dans le ZStack. Il vit
    /// tant que la section Scanner 2 est à l'écran, et il
    /// est retiré quand on la quitte — jamais actif dans
    /// les autres sections. Ce qui borne les raccourcis à
    /// l'aperçu, c'est le garde `phase == .apercu` de
    /// raccourci() : en capture, les mêmes touches
    /// traversent sans aucun effet. Le jeton est lu frais
    /// dans UserDefaults (le même stockage que le
    /// @AppStorage « receiptUploadToken » des panneaux) au
    /// moment de la touche. (Au build 166, Grégoire
    /// doutait que Maj « marchât » : le geste tirait
    /// recommencer(), mais le réarmement immédiat
    /// re-photographiait le même reçu — rien ne semblait
    /// se passer. Le correctif est dans recommencer() ;
    /// ici, le mécanisme est rendu démontrable : une
    /// fonction nommée, un seul garde, aucun état caché.)
    private func installerMoniteurClavier() {
        retirerMoniteurClavier()
        moniteurClavier = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged]) {
            [session] event in
            ReceiptScanner2Stage.raccourci(
                event, session: session)
        }
    }

    private func retirerMoniteurClavier() {
        if let moniteurClavier {
            NSEvent.removeMonitor(moniteurClavier)
            self.moniteurClavier = nil
        }
    }

    /// Le juge des raccourcis de l'aperçu : retourne nil
    /// pour AVALER l'événement traité (Entrée/Espace =
    /// Envoyer — le bouton focalisé, s'il y en a un, ne le
    /// recevra pas : pas de double geste), l'événement
    /// inchangé dans tous les autres cas. Fonction statique
    /// sans état propre, pour que la logique se lise et se
    /// démontre sans la vue autour.
    private static func raccourci(
        _ event: NSEvent,
        session: ReceiptScan2Session
    ) -> NSEvent? {
        // Le seul garde de portée : hors aperçu, on ne
        // touche à rien.
        guard session.phase == .apercu else { return event }
        if event.type == .flagsChanged {
            // Maj seule, à l'APPUI : le keyCode dit quelle
            // touche de modification a changé (56 = Maj
            // gauche, 60 = Maj droite) et les drapeaux
            // portent l'état APRÈS le changement — à
            // l'appui ils contiennent .shift, au
            // relâchement non. « Seule » : les drapeaux
            // pertinents valent exactement [.shift].
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
        // ou Espace (49), sans AUCUN modificateur — Maj
        // compris (build 167) : pendant le geste Maj, qui
        // vient de déclencher « Recommencer », un
        // Entrée/Espace ne doit pas en plus envoyer.
        let mods = event.modifierFlags
            .intersection([.command, .control, .option,
                           .shift, .function])
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
