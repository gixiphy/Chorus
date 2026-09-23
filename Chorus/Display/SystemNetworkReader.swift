import ChorusCore
import Darwin
import Foundation
import SystemConfiguration

struct SystemNetworkReader: Sendable {
    /// Classified online physical interface counters, or nil on enumeration failure.
    func read() -> [NetworkInterfaceCounters]? {
        guard let allowlist = Self.physicalInterfaceAllowlist() else { return nil }
        guard let rows = Self.readIFList2() else { return nil }
        return rows.filter { allowlist.contains($0.name) }
    }

    // MARK: - Classification (testable)

    static func isExcludedVirtualName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower == "lo0" || lower.hasPrefix("lo") { return true }
        for prefix in ["utun", "bridge", "awdl", "llw", "ap", "gif", "stf", "p2p", "ipsec", "vmnet"] {
            if lower.hasPrefix(prefix) { return true }
        }
        return false
    }

    static func physicalInterfaceAllowlist() -> Set<String>? {
        guard let copy = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return nil }
        var names = Set<String>()
        let ethernet = kSCNetworkInterfaceTypeEthernet as String
        let wifi = kSCNetworkInterfaceTypeIEEE80211 as String
        for iface in copy {
            guard let bsd = SCNetworkInterfaceGetBSDName(iface) as String? else { continue }
            guard !isExcludedVirtualName(bsd) else { continue }
            let type = SCNetworkInterfaceGetInterfaceType(iface) as String?
            if type == ethernet || type == wifi {
                names.insert(bsd)
            }
        }
        return names
    }

    // MARK: - Routing table

    static func readIFList2() -> [NetworkInterfaceCounters]? {
        var length: size_t = 0
        var mib: [Int32] = [CTL_NET, AF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0 else { return nil }

        for _ in 0..<2 {
            var buffer = [UInt8](repeating: 0, count: max(Int(length) + 1024, 1024))
            var actual = buffer.count
            let status = buffer.withUnsafeMutableBytes { raw -> Int32 in
                sysctl(&mib, u_int(mib.count), raw.baseAddress, &actual, nil, 0)
            }
            if status == 0 {
                return parseIFList2(Data(buffer.prefix(actual)))
            }
            if errno == ENOMEM {
                length = size_t(actual * 2)
                continue
            }
            return nil
        }
        return nil
    }

    /// Pure parser seam for truncated / wrong-length fixtures.
    static func parseIFList2(_ data: Data) -> [NetworkInterfaceCounters]? {
        let headerSize = MemoryLayout<if_msghdr>.size
        if data.isEmpty { return [] }
        if data.count < headerSize { return nil }

        var result: [NetworkInterfaceCounters] = []
        var offset = 0
        let ifm2Size = MemoryLayout<if_msghdr2>.size

        while offset + headerSize <= data.count {
            let header: if_msghdr = data.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
            }
            let messageLength = Int(header.ifm_msglen)
            guard messageLength >= headerSize, offset + messageLength <= data.count else { return nil }

            if Int(header.ifm_type) == RTM_IFINFO2 {
                guard messageLength >= ifm2Size else { return nil }
                if let row = parseIFInfo2(data, offset: offset) {
                    result.append(row)
                }
            }
            offset += messageLength
        }
        // Trailing incomplete bytes mean a truncated dump.
        if offset != data.count { return nil }
        return result
    }

    private static func parseIFInfo2(_ data: Data, offset: Int) -> NetworkInterfaceCounters? {
        data.withUnsafeBytes { raw -> NetworkInterfaceCounters? in
            guard let base = raw.baseAddress else { return nil }
            let ifm = base.advanced(by: offset).assumingMemoryBound(to: if_msghdr2.self)
            let sdl = UnsafeRawPointer(ifm).advanced(by: MemoryLayout<if_msghdr2>.size)
                .assumingMemoryBound(to: sockaddr_dl.self)
            let nameLen = Int(sdl.pointee.sdl_nlen)
            guard nameLen > 0, nameLen < Int(IFNAMSIZ) else { return nil }

            var chars = [CChar](repeating: 0, count: Int(IFNAMSIZ))
            withUnsafeBytes(of: sdl.pointee.sdl_data) { bytes in
                for i in 0..<nameLen {
                    chars[i] = CChar(bitPattern: bytes[i])
                }
            }
            let name = String(cString: chars)
            return NetworkInterfaceCounters(
                index: UInt32(ifm.pointee.ifm_index),
                name: name,
                received: ifm.pointee.ifm_data.ifi_ibytes,
                sent: ifm.pointee.ifm_data.ifi_obytes
            )
        }
    }
}
