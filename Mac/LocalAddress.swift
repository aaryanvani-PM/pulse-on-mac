import Foundation

/// Best-effort primary IPv4 address of this Mac, shown for watch pairing.
enum LocalAddress {
    /// mDNS hostname — stable across DHCP renewals, so the watch's stored
    /// host keeps working even when the IP changes.
    static func localHostname() -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return nil }
        let name = String(cString: buffer)
        guard !name.isEmpty, name != "localhost" else { return nil }
        return name.contains(".") ? name : "\(name).local"
    }

    static func primaryIPv4() -> String? {
        var result: String?
        var ifaddrsPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrsPtr) == 0, let first = ifaddrsPtr else { return nil }
        defer { freeifaddrs(first) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let sockaddrPtr = current.pointee.ifa_addr,
                  sockaddrPtr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: current.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(
                sockaddrPtr,
                socklen_t(MemoryLayout<sockaddr_in>.size),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard rc == 0 else { continue }
            let cStringLength = host.firstIndex(of: 0) ?? host.count
            let ip = String(cString: Array(host[..<cStringLength]).map { UInt8(bitPattern: $0) })
            if ip != "127.0.0.1" {
                result = ip
                break
            }
        }
        return result
    }
}
