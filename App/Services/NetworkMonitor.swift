import Foundation
import Network
import Observation

/// Observes network reachability so download strategies (like "WiFi only")
/// can gate transfers.
///
/// On a Mac the active path is usually WiFi or ethernet — unmetered — so the
/// "WiFi only" strategy blocks only when tethered to an expensive/constrained
/// link (a phone hotspot, say).
@MainActor
@Observable
final class NetworkMonitor {

    /// The shared monitor, injected at the app root.
    static let shared = NetworkMonitor()

    /// Whether any usable path exists.
    private(set) var isOnline = true
    /// Whether the active path is metered (cellular / personal hotspot).
    private(set) var isExpensive = false
    /// Whether the path is in Low Data / constrained mode.
    private(set) var isConstrained = false

    /// A path safe for large downloads: online and neither metered nor
    /// constrained.
    var isUnmetered: Bool { isOnline && !isExpensive && !isConstrained }

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let queue = DispatchQueue(label: "com.francoisdubois.neonmic.network")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.isOnline = path.status == .satisfied
                self.isExpensive = path.isExpensive
                self.isConstrained = path.isConstrained
            }
        }
        monitor.start(queue: queue)
    }
}
