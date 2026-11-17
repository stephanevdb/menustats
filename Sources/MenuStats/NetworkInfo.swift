import Foundation
import CoreWLAN
import CoreLocation
import SystemConfiguration

struct InterfaceInfo: Identifiable, Equatable {
    let bsdName: String
    let displayName: String
    var ipv4: [String] = []
    var ipv6: [String] = []
    var id: String { bsdName }
}

struct WiFiDetails: Equatable {
    var channel: Int?
    var band: String?
    var widthMHz: Int?
    var standard: String?
    var noise: Int?
    var security: String?
}

struct NetworkDetails: Equatable {
    var wifiName: String?
    var wifiConnected = false
    var rssi: Int?
    var txRate: Double?
    var wifiDetails = WiFiDetails()
    /// BSD name of the Wi‑Fi interface (usually en0), to attach the Wi‑Fi link rate to it.
    var wifiInterface: String?
    var interfaces: [InterfaceInfo] = []
    var publicIP: String?
    var publicIPv6: String?
    var pingMs: Double?
}

enum NetworkInfo {
    static func wifi(into d: inout NetworkDetails) {
        guard let iface = CWWiFiClient.shared().interface(), iface.powerOn() else {
            d.wifiConnected = false
            return
        }
        d.wifiInterface = iface.interfaceName
        let rssi = iface.rssiValue()
        d.wifiConnected = rssi != 0
        d.rssi = rssi != 0 ? rssi : nil
        // ssid() is nil unless the app has Location Services permission.
        d.wifiName = iface.ssid()
        d.txRate = iface.transmitRate() > 0 ? iface.transmitRate() : nil

        let channel = iface.wlanChannel()
        let noise = iface.noiseMeasurement()
        d.wifiDetails = WiFiDetails(
            channel: channel?.channelNumber,
            band: channel.flatMap { band($0.channelBand) },
            widthMHz: channel.flatMap { width($0.channelWidth) },
            standard: standard(iface.activePHYMode()),
            noise: noise != 0 ? noise : nil,
            security: security(iface.security())
        )
    }

    private static func band(_ band: CWChannelBand) -> String? {
        switch band {
        case .band2GHz: "2.4 GHz"
        case .band5GHz: "5 GHz"
        case .band6GHz: "6 GHz"
        default: nil
        }
    }

    private static func width(_ width: CWChannelWidth) -> Int? {
        switch width {
        case .width20MHz: 20
        case .width40MHz: 40
        case .width80MHz: 80
        case .width160MHz: 160
        default: nil
        }
    }

    private static func standard(_ mode: CWPHYMode) -> String? {
        switch mode {
        case .mode11a: "802.11a"
        case .mode11b: "802.11b"
        case .mode11g: "802.11g"
        case .mode11n: "Wi‑Fi 4 (n)"
        case .mode11ac: "Wi‑Fi 5 (ac)"
        case .mode11ax: "Wi‑Fi 6 (ax)"
        default: mode.rawValue == 7 ? "Wi‑Fi 7 (be)" : nil
        }
    }

    private static func security(_ security: CWSecurity) -> String? {
        switch security {
        case .none: "Open"
        case .WEP, .dynamicWEP: "WEP"
        case .wpaPersonal, .wpaPersonalMixed: "WPA Personal"
        case .wpa2Personal, .personal: "WPA2 Personal"
        case .wpa3Personal: "WPA3 Personal"
        case .wpa3Transition: "WPA2/WPA3 Personal"
        case .wpaEnterprise, .wpaEnterpriseMixed: "WPA Enterprise"
        case .wpa2Enterprise, .enterprise: "WPA2 Enterprise"
        case .wpa3Enterprise: "WPA3 Enterprise"
        case .OWE, .oweTransition: "Enhanced Open"
        default: nil
        }
    }

    /// Every interface that is up and has a usable address, in system order.
    /// Link-local addresses (169.254.x.x, fe80::) are left out.
    static func interfaces() -> [InterfaceInfo] {
        var displayNames: [String: String] = [:]
        for interface in SCNetworkInterfaceCopyAll() as NSArray as? [SCNetworkInterface] ?? [] {
            if let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
               let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? {
                displayNames[bsd] = name
            }
        }

        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return [] }
        defer { freeifaddrs(addrs) }

        var order: [String] = []
        var found: [String: InterfaceInfo] = [:]
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr,
                  ifa.ifa_flags & UInt32(IFF_UP) != 0,
                  ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0
            else { continue }
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            // IPv6 scoped addresses come back as "addr%en0".
            let ip = String(String(cString: host).split(separator: "%").first ?? "")
            if ip.hasPrefix("169.254") || ip.lowercased().hasPrefix("fe80") { continue }

            let bsd = String(cString: ifa.ifa_name)
            if found[bsd] == nil {
                order.append(bsd)
                let vpn = bsd.hasPrefix("utun") || bsd.hasPrefix("ipsec") || bsd.hasPrefix("ppp")
                // feth = virtual Ethernet, used by ZeroTier and similar tools.
                let fallback = vpn ? "VPN" : bsd.hasPrefix("feth") ? "Virtual network" : bsd
                found[bsd] = InterfaceInfo(bsdName: bsd, displayName: displayNames[bsd] ?? fallback)
            }
            if family == AF_INET { found[bsd]?.ipv4.append(ip) } else { found[bsd]?.ipv6.append(ip) }
        }
        return order.compactMap { found[$0] }
    }

    static func publicIP(v6: Bool = false) async -> String? {
        guard let url = URL(string: v6 ? "https://api6.ipify.org" : "https://api.ipify.org") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        let ip = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return ip.isEmpty ? nil : ip
    }

    /// Round-trip time to 1.1.1.1 using the system ping tool.
    static func ping() async -> Double? {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/sbin/ping")
            process.arguments = ["-c", "1", "-t", "2", "-q", "1.1.1.1"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            // "round-trip min/avg/max/stddev = 12.345/12.345/12.345/0.000 ms"
            let output = String(decoding: data, as: UTF8.self)
            guard let line = output.split(separator: "\n").first(where: { $0.contains("round-trip") }),
                  let values = line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces),
                  let avg = values.split(separator: "/").dropFirst().first
            else { return nil }
            return Double(avg)
        }.value
    }
}

/// Requests Location Services so CoreWLAN can return the Wi‑Fi name.
@MainActor
final class LocationPermission: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var status: CLAuthorizationStatus
    private let manager = CLLocationManager()

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
        // Ask on first use so the Wi‑Fi name shows without an extra click.
        if status == .notDetermined { request() }
    }

    func request() {
        manager.requestWhenInUseAuthorization()
        // macOS may only show the prompt once a location is actually requested.
        manager.requestLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.status = status }
    }
}
