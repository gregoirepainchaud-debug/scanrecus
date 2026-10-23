/// Identifiant du build, affiché à l'écran.
///
/// RÈGLE (Grégoire, 2026-10-20) : ce numéro augmente à chaque
/// build livré, et Muse l'annonce dans son rapport. C'est le
/// nombre de commits sur la branche main du dépôt, celui-ci
/// compris. Si le numéro lu à l'écran ne correspond pas à celui
/// annoncé, le Pull ou la recompilation n'a pas pris le dernier
/// code — c'est ce test qui tranche, pas une impression.
enum BuildInfo {
    static let stamp = "build 99 · 2026-10-23"
}
