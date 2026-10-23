import Foundation
import Combine
import Darwin

/// Témoin d'activité du processeur — demandé par
/// Grégoire (2026-10-23) : « une roue qui tourne
/// quand le processeur travaille fort, un témoin de
/// ce qui se passe, sans rien empêcher ».
///
/// Ce moniteur ne fait que REGARDER : il échantillonne
/// la charge CPU du processus (somme des usages des
/// threads, via Mach) toutes les ~0,35 s et publie
/// `busy`. Il ne bloque, ne verrouille et ne déclenche
/// rien. Hystérésis (allumage à 50 % d'un cœur,
/// extinction sous 25 %) pour éviter le clignotement.
/// Son propre coût : quelques appels système par
/// échantillon — négligeable.
@MainActor
final class CPUMonitor: ObservableObject {

    /// Vrai quand le processus travaille fort.
    @Published private(set) var busy = false

    /// La charge mesurée au dernier échantillon, en
    /// pourcentage d'UN cœur (peut dépasser 100 %
    /// quand plusieurs cœurs travaillent).
    @Published private(set) var percent: Double = 0

    private var timer: Timer?

    init() {
        let t = Timer.scheduledTimer(
            withTimeInterval: 0.35, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sample()
            }
        }
        t.tolerance = 0.1
        timer = t
    }

    deinit {
        timer?.invalidate()
    }

    private func sample() {
        let pct = Self.processCPUPercent()
        percent = pct
        if pct >= 50 {
            busy = true
        } else if pct < 25 {
            busy = false
        }
    }

    /// Charge CPU du processus, en % d'un cœur :
    /// la somme des `cpu_usage` des threads (échelle
    /// Mach : TH_USAGE_SCALE = 100 %).
    static func processCPUPercent() -> Double {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threadList,
                           &threadCount) == KERN_SUCCESS,
              let threads = threadList
        else { return 0 }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: threads),
                vm_size_t(threadCount)
                    * vm_size_t(MemoryLayout<thread_act_t>
                        .stride))
        }
        var total: Double = 0
        for i in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(
                THREAD_BASIC_INFO_COUNT)
            let kr = withUnsafeMutablePointer(to: &info) {
                ptr in
                ptr.withMemoryRebound(
                    to: integer_t.self,
                    capacity: Int(count)) { intPtr in
                    thread_info(
                        threads[i],
                        thread_flavor_t(THREAD_BASIC_INFO),
                        intPtr, &count)
                }
            }
            if kr == KERN_SUCCESS {
                total += Double(info.cpu_usage)
                    / Double(TH_USAGE_SCALE) * 100.0
            }
        }
        return total
    }
}
