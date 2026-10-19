# ScanReçus — projet Xcode (Swift natif, macOS)

App macOS native de scan de reçus pour rapports trimestriels de taxes.
**Aucune image de reçu conservée** — seules les données extraites vont
en base (SwiftData, locale) ; les reçus papier restent la preuve.

## Contenu

- `Sources/Models/Models.swift` — SwiftData : `Company`, `Category`,
  `ReceiptItem`, `MerchantRule` + `Persistence` (conteneur unique).
  Logique métier : catégories créées à la volée, apprentissage
  commerce → catégorie, rapports par trimestre (tri catégorie puis date),
  purge > 10 ans.
- `Sources/Logic/QuarterHelper.swift` — trimestres civils : 1er jour du
  trimestre précédent (date par défaut), bornes d'un trimestre, seuil
  de purge 10 ans, années distinctes.
- `Sources/Logic/ReceiptParser.swift` — extraction depuis le texte OCR :
  total (ligne « total » la plus basse, sinon plus grand montant), date
  (formats FR/EN), commerce. Portage fidèle de l'ancien `ocr_parse.py`.
- `Docs/Creer-le-projet-Xcode.md` — création du projet pas à pas.

## Phases

- [x] **Phase 1** : modèles + logique trimestres + parsing (présent lot —
      compilable, sans UI).
- [x] **Phase 2** : caméra (AVFoundation) + moteur de scan 5 Hz
      (Vision : `VNDetectRectanglesRequest`, `VNRecognizeTextRequest` ;
      `CameraManager`, `ScanEngine`, écran de test `ScanDebugView`).
- [ ] **Phase 3** : interface SwiftUI — menu multi-entreprises, scan
      temps réel (total surligné), confirmation (catégorie éditable),
      rapports trimestriels.
- [ ] **Phase 4** : export Excel (CoreXLSX via SPM), purge 10 ans,
      mises à jour.

## Règles de travail (Muse ↔ Grégoire)

- Muse écrit les fichiers ici ; Grégoire crée le projet Xcode (voir
  `Docs/`), compile et remonte les erreurs.
- Ne pas compiler pendant l'écriture d'un lot (Muse prévient quand prêt).
- Fichiers ajoutés **par référence** dans Xcode (pas copiés).
- `DerivedData` hors du Drive (défaut Xcode).
