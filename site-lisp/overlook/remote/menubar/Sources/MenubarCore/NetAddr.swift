import Darwin

/// A network interface's name and IPv4 addresses, as four bytes each.
public struct Interface: Sendable {
    public var name: String
    public var addrs: [[UInt8]]

    public init(name: String, addrs: [[UInt8]]) {
        self.name = name
        self.addrs = addrs
    }
}

/// The IPv4 address in ifaces a phone should open: Tailscale's (100.64.0.0/10), else an en interface's, else any
/// other that is neither loopback nor link-local; "" when there is none. Mirrors internal/netaddr.Preferred.
public func preferredAddress(_ ifaces: [Interface]) -> String {
    var en = "", other = ""
    for ifc in ifaces {
        for a in ifc.addrs where a.count == 4 {
            if a[0] == 127 || (a[0] == 169 && a[1] == 254) { continue }
            let s = a.map(String.init).joined(separator: ".")
            if a[0] == 100 && a[1] & 0xC0 == 64 { return s }
            if en.isEmpty && ifc.name.hasPrefix("en") {
                en = s
            } else if other.isEmpty {
                other = s
            }
        }
    }
    return en.isEmpty ? other : en
}

/// The up interfaces of this machine with their IPv4 addresses.
public func interfaces() -> [Interface] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return [] }
    defer { freeifaddrs(head) }
    var order: [String] = []
    var byName: [String: [[UInt8]]] = [:]
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let ifa = p.pointee
        guard ifa.ifa_flags & UInt32(IFF_UP) != 0, let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET)
        else { continue }
        let name = String(cString: ifa.ifa_name)
        let bytes = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
            withUnsafeBytes(of: sin.pointee.sin_addr.s_addr) { Array($0) }
        }
        if byName[name] == nil { order.append(name) }
        byName[name, default: []].append(bytes)
    }
    return order.map { Interface(name: $0, addrs: byName[$0] ?? []) }
}

/// preferredAddress of this machine's interfaces.
public func preferredHost() -> String { preferredAddress(interfaces()) }
