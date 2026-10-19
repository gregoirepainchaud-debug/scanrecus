import Foundation

/// Trimestres civils : T1 = jan–mar, T2 = avr–juin, T3 = juil–sep,
/// T4 = oct–déc. Portage de db.py (quarter_bounds, cutoff_10y) et
/// ocr_parse.py (prev_quarter_start).
enum QuarterHelper {

    /// 1er jour du trimestre civil précédent (à minuit).
    /// Ex. le 6 oct. 2026 (T4) → 1er juil. 2026.
    /// Gère le passage d'année : en janvier (T1) → 1er oct. année précédente.
    /// C'est la date par défaut quand l'OCR ne trouve aucune date
    /// (l'exactitude importe peu pour des rapports trimestriels de taxes).
    static func previousQuarterStart(from date: Date = Date(),
                                     calendar: Calendar = .current) -> Date? {
        let comps = calendar.dateComponents([.year, .month], from: date)
        guard var year = comps.year, let month = comps.month else { return nil }
        var prevQuarter0 = (month - 1) / 3 - 1  // trimestre précédent, base 0
        if prevQuarter0 < 0 {
            prevQuarter0 = 3
            year -= 1
        }
        let startMonth = prevQuarter0 * 3 + 1
        let start = calendar.date(from: DateComponents(
            year: year, month: startMonth, day: 1))
        return start.map { calendar.startOfDay(for: $0) }
    }

    /// Bornes d'un trimestre civil : début à 00:00:00, fin à 23:59:59.
    static func quarterBounds(year: Int, quarter: Int,
                              calendar: Calendar = .current)
        -> (start: Date, end: Date)?
    {
        guard (1...4).contains(quarter) else { return nil }
        let startMonth = (quarter - 1) * 3 + 1
        guard let start = calendar.date(from: DateComponents(
                year: year, month: startMonth, day: 1)),
              let nextQuarter = calendar.date(byAdding: .month, value: 3,
                                              to: start),
              let end = calendar.date(byAdding: .second, value: -1,
                                      to: nextQuarter)
        else { return nil }
        return (calendar.startOfDay(for: start), end)
    }

    /// Trimestre civil courant (1…4).
    static func currentQuarter(calendar: Calendar = .current,
                               date: Date = Date()) -> Int {
        let month = calendar.component(.month, from: date)
        return (month - 1) / 3 + 1
    }

    /// Seuil de purge : tout ce qui est strictement avant est supprimable
    /// (données de plus de 10 ans).
    static func tenYearsCutoff(from date: Date = Date(),
                               calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .year, value: -10, to: date) ?? date
    }

    /// Années distinctes présentes dans les reçus, en ordre décroissant
    /// (année courante incluse) — pour le sélecteur du rapport trimestriel.
    static func distinctYears(in receipts: [ReceiptItem],
                              calendar: Calendar = .current) -> [Int] {
        var years = Set(receipts.map {
            calendar.component(.year, from: $0.date)
        })
        years.insert(calendar.component(.year, from: Date()))
        return years.sorted(by: >)
    }
}
