import SwiftUI

/// ÉTAPE 1 (2026-10-19) : on règle le SCAN, une chose à la fois.
///
/// La logique de flux (ScanFlow, écran ScanDebugView) est DÉSACTIVÉE —
/// les modules sont conservés dans le projet, rien n'est supprimé.
/// L'écran actif est celui du scan composite : détection stable du
/// reçu → fenêtre de capture de 2 s → composite redressé affiché.
///
/// Quand le scan sera satisfaisant, l'étape 2 branchera l'extraction
/// d'informations sur le composite, et cet écran redeviendra l'écran
/// de test du scan.
struct ContentView: View {
    var body: some View {
        CompositeScanView()
    }
}
