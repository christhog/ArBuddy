//
//  NetworkMonitor.swift
//  ARBuddy
//
//  Created by Claude on 14.04.26.
//

import Foundation
import Network
import Combine

/// Monitors network connectivity status for hybrid Cloud/Offline mode
@MainActor
class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    // MARK: - Published Properties

    @Published private(set) var isConnected: Bool = true
    @Published private(set) var connectionType: ConnectionType = .unknown

    // MARK: - Connection Type

    enum ConnectionType: String {
        case wifi = "WiFi"
        case cellular = "Mobilfunk"
        case ethernet = "Ethernet"
        case unknown = "Unbekannt"
        case none = "Keine Verbindung"

        var icon: String {
            switch self {
            case .wifi: return "wifi"
            case .cellular: return "antenna.radiowaves.left.and.right"
            case .ethernet: return "cable.connector"
            case .unknown: return "network"
            case .none: return "wifi.slash"
            }
        }
    }

    // MARK: - Private Properties

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.arbuddy.networkmonitor")

    // MARK: - Initialization

    private init() {
        startMonitoring()
    }

    deinit {
        // monitor.cancel() is thread-safe, so we can call it directly in deinit
        monitor.cancel()
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self = self else { return }

                let wasConnected = self.isConnected
                self.isConnected = path.status == .satisfied

                // Determine connection type
                if path.usesInterfaceType(.wifi) {
                    self.connectionType = .wifi
                } else if path.usesInterfaceType(.cellular) {
                    self.connectionType = .cellular
                } else if path.usesInterfaceType(.wiredEthernet) {
                    self.connectionType = .ethernet
                } else if path.status == .satisfied {
                    self.connectionType = .unknown
                } else {
                    self.connectionType = .none
                }

                // Log connectivity changes
                if wasConnected != self.isConnected {
                    print("[NetworkMonitor] Connection changed: \(self.isConnected ? "Connected" : "Disconnected") (\(self.connectionType.rawValue))")
                }
            }
        }

        monitor.start(queue: monitorQueue)
        print("[NetworkMonitor] Started monitoring network status")
    }

    private func stopMonitoring() {
        monitor.cancel()
        print("[NetworkMonitor] Stopped monitoring")
    }

    // MARK: - Public Methods

    /// Checks if the network is suitable for cloud services (not expensive/constrained)
    var isSuitableForCloudServices: Bool {
        guard isConnected else { return false }

        // Could add additional checks here, e.g., for expensive connections
        // For now, any connection is suitable
        return true
    }

    /// Returns a localized status description
    var statusDescription: String {
        if isConnected {
            return "Verbunden (\(connectionType.rawValue))"
        } else {
            return "Offline"
        }
    }
}
