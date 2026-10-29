import Darwin
import Foundation
import os

struct DiscoveredTV: Identifiable, Hashable, Sendable {
    let host: String
    let name: String
    let model: String?

    var id: String { host }
}

/// Finds Frame TVs on the local network without the user typing an IP address.
enum TVDiscovery {
    private static let log = Logger(subsystem: "com.kay2ventures.FrameUploader", category: "discovery")

    struct Result {
        var tvs: [DiscoveredTV] = []
        /// macOS blocked the search; finding nothing says nothing about whether a TV is there.
        var localNetworkDenied = false
    }

    /// SSDP (UPnP) first, which Samsung TVs answer within a second or two. If nothing replies — some
    /// routers block multicast — every address on the Mac's local subnet is asked for TV info instead.
    static func findFrameTVs() async -> Result {
        let announced = await Task.detached(priority: .userInitiated) {
            ssdpSearch(timeout: 2.5)
        }.value
        log.info("SSDP found \(announced.count) Samsung device(s)")

        var found = await frameTVs(among: announced, timeout: 3)
        if found.tvs.isEmpty {
            let subnet = localSubnetHosts()
            log.info("Sweeping \(subnet.count) local addresses")
            let swept = await frameTVs(among: subnet, timeout: 1.5)
            found.tvs = swept.tvs
            found.localNetworkDenied = found.localNetworkDenied || swept.localNetworkDenied
        }
        if found.localNetworkDenied && found.tvs.isEmpty {
            log.error("Local network access is denied")
        }
        found.tvs.sort { $0.host.localizedStandardCompare($1.host) == .orderedAscending }
        return found
    }

    /// Keeps the hosts that answer as a Samsung TV with Art Mode support.
    private static func frameTVs(among hosts: Set<String>, timeout: TimeInterval) async -> Result {
        enum Probe { case frameTV(DiscoveredTV), denied, nothing }
        return await withTaskGroup(of: Probe.self) { group in
            for host in hosts {
                group.addTask {
                    do {
                        let info = try await TVDeviceInfo.fetch(host: host, timeout: timeout)
                        guard info.isFrameTV else { return .nothing }
                        return .frameTV(DiscoveredTV(host: host, name: info.displayName, model: info.device?.modelName))
                    } catch FrameTVError.localNetworkDenied {
                        return .denied
                    } catch {
                        return .nothing
                    }
                }
            }
            var result = Result()
            for await probe in group {
                switch probe {
                case .frameTV(let tv): result.tvs.append(tv)
                case .denied: result.localNetworkDenied = true
                case .nothing: break
                }
            }
            return result
        }
    }

    // MARK: - SSDP

    private static func ssdpSearch(timeout: TimeInterval) -> Set<String> {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var receiveTimeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
        var ttl: UInt8 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = in_port_t(1900).bigEndian
        destination.sin_addr.s_addr = inet_addr("239.255.255.250")

        let searchTargets = [
            "urn:samsung.com:device:RemoteControlReceiver:1",
            "urn:dial-multiscreen-org:service:dial:1",
            "urn:schemas-upnp-org:device:MediaRenderer:1",
        ]
        // UDP can drop packets, so each search goes out twice.
        for target in searchTargets + searchTargets {
            let message = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(target)\r\n\r\n"
            let bytes = Array(message.utf8)
            _ = withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    sendto(fd, bytes, bytes.count, 0, address, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var hosts = Set<String>()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var sender = sockaddr_in()
            var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    recvfrom(fd, &buffer, bufferSize, 0, address, &senderLength)
                }
            }
            guard count > 0 else { continue }
            let reply = String(decoding: buffer[0..<count], as: UTF8.self).lowercased()
            if reply.contains("samsung") {
                hosts.insert(String(cString: inet_ntoa(sender.sin_addr)))
            }
        }
        return hosts
    }

    // MARK: - Subnet sweep

    /// Every other address on the /24 of each Wi-Fi or Ethernet interface with a private IPv4 address.
    private static func localSubnetHosts() -> Set<String> {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }

        var hosts = Set<String>()
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET),
                  String(cString: interface.pointee.ifa_name).hasPrefix("en")
            else {
                continue
            }
            let own = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            guard isPrivate(own) else { continue }
            let base = own & 0xFFFF_FF00
            for last in UInt32(1)...254 where base | last != own {
                hosts.insert(dotted(base | last))
            }
        }
        return hosts
    }

    private static func isPrivate(_ address: UInt32) -> Bool {
        address >> 24 == 10
            || address >> 20 == (172 << 4 | 1)
            || address >> 16 == (192 << 8 | 168)
    }

    private static func dotted(_ address: UInt32) -> String {
        "\(address >> 24).\(address >> 16 & 0xFF).\(address >> 8 & 0xFF).\(address & 0xFF)"
    }
}
