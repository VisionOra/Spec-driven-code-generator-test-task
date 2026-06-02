import Foundation
import Network

class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "network-monitor")
    private var simulatedState: Bool? = nil

    var isOnline: Bool = true
    var onStatusChange: ((Bool) -> Void)?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            // Real path changes only apply if not in simulated mode
            if self.simulatedState == nil {
                let online = path.status == .satisfied
                self.isOnline = online
                self.onStatusChange?(online)
            }
        }
        monitor.start(queue: queue)
    }

    func simulateOffline() {
        simulatedState = false
        isOnline = false
        onStatusChange?(false)
    }

    func simulateOnline() {
        simulatedState = nil
        isOnline = true
        onStatusChange?(true)
    }
}
