import AVFoundation
import Vision
import Combine
import Foundation

// MARK: - Niveau de confiance

/// Degré de confiance d'un champ détecté (affiché rouge / jaune / vert).
enum ConfidenceLevel {
    case low     // rouge
    case medium  // jaune
    case high    // vert — la valeur se fige (voir ScanFlowController)
}

/// Une analyse complète : champs parsés + confiance par champ.
struct ScanDetection {
    var result: DetectionResult
    var merchantLevel: ConfidenceLevel
    var dateLevel: ConfidenceLevel
    var totalLevel: ConfidenceLevel
}

/// Une ligne de texte reconnue par l'OCR, avec sa boîte
/// (coordonnées normalisées Vision). Sert à la sélection à la souris :
/// survoler une ligne l'encadre, cliquer l'utilise comme valeur.
struct OCRLine {
    var text: String
    var box: CGRect
}

// MARK: - Moteur de scan (5 Hz)

/// Reçoit les images de la caméra (via CameraManager), détecte le reçu
/// avec Vision (VNDetectRectanglesRequest), fait l'OCR
/// (VNRecognizeTextRequest) et parse les champs avec ReceiptParser.
///
/// Rythme : 5 analyses/seconde maximum — tout est local, aucun réseau.
/// Le travail Vision tourne directement sur la file série du délégué de
/// capture ; seuls les résultats publiés (@Published) transitent par le main.
final class ScanEngine: NSObject, ObservableObject,
                        AVCaptureVideoDataOutputSampleBufferDelegate,
                        @unchecked Sendable {

    /// Intervalle minimum entre deux analyses (0,2 s = 5 Hz).
    private let analysisInterval: CFTimeInterval = 0.2

    /// Dernière analyse complète (champs + confiances).
    /// Nil quand aucun texte n'est visible.
    @Published private(set) var scan: ScanDetection?
    /// Quadrilatère du reçu détecté (coordonnées normalisées 0…1,
    /// origine en bas à gauche — convention Vision).
    @Published private(set) var receiptQuad: [CGPoint]?
    /// Boîte de la ligne du total (même système de coordonnées) —
    /// l'UI la trace en vert.
    @Published private(set) var totalBox: CGRect?
    /// Toutes les lignes OCR de la dernière analyse (sélection souris).
    @Published private(set) var ocrLines: [OCRLine] = []
    /// Compteur d'analyses (permet de vérifier le rythme dans l'écran de scan).
    @Published private(set) var analysesCount = 0

    // Accédés uniquement sur la file série du délégué — pas de concurrence.
    private var lastAnalysisStart: CFTimeInterval = 0
    private var isAnalyzing = false

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Déjà sur une file série : le throttle suffit, pas de file d'attente.
        let now = CFAbsoluteTimeGetCurrent()
        guard !isAnalyzing, now - lastAnalysisStart >= analysisInterval else {
            return
        }
        isAnalyzing = true
        lastAnalysisStart = now
        defer { isAnalyzing = false }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        let quad = detectReceiptQuad(in: pixelBuffer)
        let lines = recognizeLines(in: pixelBuffer)
        let text = lines.map(\.text).joined(separator: "\n")

        var detection: ScanDetection?
        var greenBox: CGRect?
        if !text.isEmpty {
            var total = ReceiptParser.parseTotal(text)
            // Preuve par addition : si UN SEUL candidat « total » égale la
            // somme d'autres montants (sous-total + taxes), c'est lui —
            // même si le parser avait choisi une autre ligne.
            let amountValues = ReceiptParser.allAmounts(text).map(\.value)
            let verifiedCandidates = ReceiptParser.totalCandidates(text)
                .filter {
                    ReceiptParser.isSumVerified(total: $0.value,
                                                amounts: amountValues)
                }
            if verifiedCandidates.count == 1, let proven = verifiedCandidates.first {
                total = proven
            }
            let sumVerified = total.map {
                ReceiptParser.isSumVerified(total: $0.value,
                                            amounts: amountValues)
            } ?? false

            var det = DetectionResult()
            det.rawText = text
            det.total = total?.value
            det.merchant = ReceiptParser.parseMerchant(text) ?? ""
            let rawDate = ReceiptParser.parseDate(text)
            // Vieux reçu jamais traité : une date ANTÉRIEURE au trimestre
            // à fermer est ramenée au 1er jour de ce trimestre — le reçu
            // devient une dépense du trimestre en cours de fermeture.
            let quarterStart = QuarterHelper.previousQuarterStart()
            var parsedDate = rawDate
            var dateWasSnapped = false
            if let raw = rawDate, let start = quarterStart, raw < start {
                parsedDate = start
                dateWasSnapped = true
            }
            det.date = parsedDate
            det.applyDefaults()  // date par défaut = 1er jour du trimestre précédent

            // Confiances : retrouver la ligne source de chaque champ.
            let merchantConf = lines.first { $0.text == det.merchant }?
                .confidence ?? 0
            var dateConf: Float = 0
            if let parsedDate {
                for line in lines
                where ReceiptParser.parseDate(line.text) == parsedDate {
                    dateConf = line.confidence
                    break
                }
            }

            let merchantLevel: ConfidenceLevel = det.merchant.isEmpty
                ? .low : Self.level(for: merchantConf)
            // Date par défaut OU ramenée du passé = choix du flux → jaune.
            let dateLevel: ConfidenceLevel = (parsedDate == nil || dateWasSnapped)
                ? .medium : Self.level(for: dateConf)
            let totalLevel: ConfidenceLevel
            if det.total == nil {
                totalLevel = .low
            } else if sumVerified {
                // Prouvé par addition (sous-total + taxes) : vert.
                totalLevel = .high
                if let lineIndex = total?.lineIndex,
                   lineIndex >= 0, lineIndex < lines.count {
                    greenBox = lines[lineIndex].box
                }
            } else if let lineIndex = total?.lineIndex,
                      lineIndex >= 0, lineIndex < lines.count {
                // Total lu sur sa ligne « total » : confiance de la ligne.
                totalLevel = Self.level(for: lines[lineIndex].confidence)
                greenBox = lines[lineIndex].box
            } else {
                // Total = plus grand montant (devinette) : jamais vert.
                totalLevel = .medium
            }

            detection = ScanDetection(result: det,
                                      merchantLevel: merchantLevel,
                                      dateLevel: dateLevel,
                                      totalLevel: totalLevel)
        }

        // CGRect/[CGPoint] sont des types valeur Sendable : capture sûre.
        let publishedLines = lines.map { OCRLine(text: $0.text, box: $0.box) }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scan = detection
            self.receiptQuad = quad
            self.totalBox = greenBox
            self.ocrLines = publishedLines
            self.analysesCount += 1
        }
    }

    // MARK: - Confiance

    private static func level(for confidence: Float) -> ConfidenceLevel {
        if confidence >= 0.75 { return .high }
        if confidence >= 0.45 { return .medium }
        return .low
    }

    // MARK: - Vision

    /// Le plus grand rectangle plausible = le reçu.
    private func detectReceiptQuad(in pixelBuffer: CVPixelBuffer) -> [CGPoint]? {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.2  // les reçus sont plutôt allongés
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.25        // le reçu doit bien remplir l'image
        request.maximumObservations = 3
        request.minimumConfidence = 0.5
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        let best = request.results?.max {
            ($0.boundingBox.width * $0.boundingBox.height)
                < ($1.boundingBox.width * $1.boundingBox.height)
        }
        guard let rect = best else { return nil }
        return [rect.topLeft, rect.topRight, rect.bottomRight, rect.bottomLeft]
    }

    /// OCR ligne par ligne : texte + boîte + confiance de chaque ligne,
    /// triées haut → bas (l'ordre que ReceiptParser attend : l'index de
    /// ligne de parseTotal pointe dans ce même tableau).
    private func recognizeLines(in pixelBuffer: CVPixelBuffer)
    -> [(text: String, box: CGRect, confidence: Float)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["fr-FR", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }

        // Vision ne garantit pas l'ordre : on trie haut → bas, gauche → droite.
        let observations = (request.results ?? []).sorted {
            let dy = $0.boundingBox.midY - $1.boundingBox.midY
            if abs(dy) > 0.01 { return dy > 0 }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }

        var lines: [(text: String, box: CGRect, confidence: Float)] = []
        for obs in observations {
            guard let candidate = obs.topCandidates(1).first else { continue }
            // Une ligne OCR = une ligne de texte : on neutralise les "\n"
            // internes pour garder l'alignement avec parseTotal (index de ligne).
            let line = candidate.string
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            lines.append((line, obs.boundingBox, candidate.confidence))
        }
        return lines
    }
}
