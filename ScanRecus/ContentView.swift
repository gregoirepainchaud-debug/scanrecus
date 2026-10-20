import SwiftUI

/// ÉTAPE 1 : on règle le SCAN, une chose à la fois.
///
/// L'écran actif est celui du scan composite : détection stable
/// du reçu → fenêtre de capture → image finale (composite par
/// homographies, ou moyenne recalée si la scène est stable) →
/// extraction affichée dans le panneau « Ce que je lis ».
///
/// L'ancien flux (ScanFlow / ScanEngine / ScanDebugView) a été
/// SUPPRIMÉ le 2026-10-20 (lot 3 des audits) : ses règles
/// divergeaient et rien ne le branchait. Ses idées utiles pour
/// l'étape 2 (confirmation au clavier, contrôle de doublon,
/// édition de la dernière entrée) sont notées dans
/// salvage-ancien-pipeline.md (dossier de travail de Muse).
///
/// L'étape 2 branchera la confirmation + l'enregistrement
/// (base locale versionnée — voir Persistence, Models.swift).
struct ContentView: View {
    var body: some View {
        CompositeScanView()
    }
}
