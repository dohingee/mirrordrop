import Darwin
import Foundation

enum NetworkInfo {
    /// IPv4 address of the Wi-Fi interface (en0), or another private en* address as fallback.
    static func wifiIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }

        var fallback: String?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(bitPattern: entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            let name = String(cString: entry.ifa_name)
            if name == "en0" { return ip }
            if name.hasPrefix("en"), fallback == nil, isPrivate(ip) { fallback = ip }
        }
        return fallback
    }

    /// True for addresses that can only be on the local network (RFC 1918, link-local, loopback, ULA).
    static func isPrivate(_ host: String) -> Bool {
        var address = host.lowercased()
        if let percent = address.firstIndex(of: "%") { address = String(address[..<percent]) }
        if address.hasPrefix("::ffff:") { address = String(address.dropFirst(7)) }

        let octets = address.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        if octets.count == 4 {
            guard octets.allSatisfy({ $0 != nil && $0! >= 0 && $0! <= 255 }) else { return false }
            let a = octets[0]!, b = octets[1]!
            return a == 10
                || (a == 172 && (16...31).contains(b))
                || (a == 192 && b == 168)
                || (a == 169 && b == 254)
                || a == 127
        }
        guard address.contains(":") else { return false }
        return address == "::1"
            || address.hasPrefix("fe8") || address.hasPrefix("fe9") || address.hasPrefix("fea") || address.hasPrefix("feb")
            || address.hasPrefix("fc") || address.hasPrefix("fd")
    }
}

enum MemoryInfo {
    /// The number iOS compares against the extension memory limit.
    static func physFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func physFootprintMB() -> Double {
        Double(physFootprintBytes()) / 1_048_576
    }
}
