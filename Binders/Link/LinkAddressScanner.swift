import Darwin
import Foundation
import SystemConfiguration
import BindersKit

/// This Mac's network as a phone could see it: every address on its interfaces, and a VPN's own word about it.
struct LinkAddressScan: Equatable, Sendable {
    var interfaces: [LinkInterface]
    var vpns: [LinkVPNStatus]

    /// Made-up addresses for throwaway folders (the self-tests, drawings of Settings › iPhone, the demo Mac the iPhone's
    /// screenshots are taken with), as the demo Mac's name is made up.
    static let demo = LinkAddressScan(interfaces: [LinkInterface(name: "en0", address: "192.168.1.20", medium: .wifi),
                                                   LinkInterface(name: "utun4", address: "100.101.102.103", isPointToPoint: true)],
                                      vpns: [])
}

/// Reads this Mac's interfaces, and asks Tailscale about itself when it's installed. Covee, or any other VPN, needs no
/// tool: its tunnel and its addresses are on the list like any interface's.
enum LinkAddressScanner {
    /// This Mac's interfaces: getifaddrs, on whatever thread calls it (quick; the Wi-Fi or Ethernet lookup is kept, and
    /// made again only for an interface it hasn't seen), with a VPN's own name where it registered one.
    static func interfaces() -> [LinkInterface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        let names = vpnNames()
        var result: [LinkInterface] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            var text = String(cString: host)
            if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
            let name = String(cString: entry.ifa_name)
            let flags = entry.ifa_flags
            result.append(LinkInterface(name: name, address: text, isUp: flags & UInt32(IFF_UP) != 0,
                                        isLoopback: flags & UInt32(IFF_LOOPBACK) != 0,
                                        isPointToPoint: flags & UInt32(IFF_POINTOPOINT) != 0,
                                        medium: Media.shared.medium(of: name),
                                        vpnName: name.hasPrefix("en") || name.hasPrefix("lo") ? nil : names[name]))
        }
        return result
    }

    /// The name a VPN registered with the system goes by, by its interface ("Covee" for utun0), from the network
    /// configuration: the service whose state names that interface, and that service's own name. A VPN that registers
    /// nothing, as a homegrown one may not, has none, and its addresses say "VPN".
    static func vpnNames() -> [String: String] {
        guard let store = SCDynamicStoreCreate(nil, "Binders" as CFString, nil, nil) else { return [:] }
        var names: [String: String] = [:]
        for pattern in ["State:/Network/Service/[^/]+/IPv4", "State:/Network/Service/[^/]+/IPv6"] {
            guard let keys = SCDynamicStoreCopyKeyList(store, pattern as CFString) as? [String] else { continue }
            for key in keys {
                let parts = key.split(separator: "/")
                guard parts.count == 5,
                      let state = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                      let interface = state["InterfaceName"] as? String, names[interface] == nil,
                      let setup = SCDynamicStoreCopyValue(store, "Setup:/Network/Service/\(parts[3])" as CFString) as? [String: Any],
                      let name = (setup["UserDefinedName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty else { continue }
                names[interface] = String(name.prefix(40))
            }
        }
        return names
    }

    /// The same, on a utility queue.
    static func readInterfaces() async -> [LinkInterface] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: interfaces()) }
        }
    }

    /// Where Tailscale's tool is: nil in a throwaway folder, before anything is looked at, so no self-test or demo Mac
    /// ever starts it; else the first of the places it's installed, never a search of PATH.
    static var tailscaleTool: URL? {
        guard !AppPaths.isDemo else { return nil }
        let places = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]
        return places.first(where: FileManager.default.isExecutableFile(atPath:)).map { URL(fileURLWithPath: $0) }
    }

    /// Runs `tool status --json --peers=false` (small however big the tailnet) and reads its answer: nil when it fails,
    /// says something else, or takes longer than `timeout`. Its output is read while it runs, so a long answer can't
    /// stall it; past the timeout it's told to stop, then killed half a second later if it hasn't, and this returns at
    /// once. The tool is an argument so the self-test can run stand-ins.
    static func tailscale(tool: URL, timeout: TimeInterval = 2) -> LinkVPNStatus? {
        let process = Process()
        process.executableURL = tool
        process.arguments = ["status", "--json", "--peers=false"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let deadline = DispatchTime.now() + timeout
        do {
            try process.run()
        } catch {
            return nil
        }
        let output = Output()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            output.data = pipe.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        guard exited.wait(timeout: deadline) == .success else {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
            return nil
        }
        // A child that kept the pipe open can hold the drain: its answer is dropped.
        guard drained.wait(timeout: deadline) == .success, process.terminationStatus == 0 else { return nil }
        return LinkVPNStatus.tailscale(output.data)
    }

    /// The same, on a utility queue: never the main thread, nor the pool async work shares, as it can take its timeout.
    static func askTailscale(tool: URL) async -> LinkVPNStatus? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: tailscale(tool: tool)) }
        }
    }

    /// The tool's output, written by the queue that drains it and read once that's done.
    private final class Output: @unchecked Sendable {
        var data = Data()
    }

    /// Which interfaces are Wi-Fi and which Ethernet, as the system configuration says.
    private final class Media: @unchecked Sendable {
        static let shared = Media()
        private let lock = NSLock()
        private var media: [String: LinkInterface.Medium] = [:]
        private var seen: Set<String> = []

        func medium(of name: String) -> LinkInterface.Medium {
            lock.withLock {
                if !seen.contains(name) {
                    reload()
                    seen.insert(name)
                }
                return media[name] ?? .unknown
            }
        }

        private func reload() {
            guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return }
            for interface in all {
                guard let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                      let type = SCNetworkInterfaceGetInterfaceType(interface) as String? else { continue }
                seen.insert(name)
                if type == kSCNetworkInterfaceTypeIEEE80211 as String {
                    media[name] = .wifi
                } else if type == kSCNetworkInterfaceTypeEthernet as String {
                    media[name] = .wired
                }
            }
        }
    }
}

/// Says when any interface's addresses or state change, every VPN's included, from the kernel's routing socket: it sees
/// a homegrown VPN's tunnel whether or not that VPN tells the system about itself.
final class LinkRouteWatch: @unchecked Sendable {
    private let source: DispatchSourceRead

    init?(queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) {
        let socket = Darwin.socket(PF_ROUTE, SOCK_RAW, AF_UNSPEC)
        guard socket >= 0 else { return nil }
        _ = fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
        source.setEventHandler {
            // One message a read, each starting msglen (2 bytes), version, type.
            var buffer = [UInt8](repeating: 0, count: 2048)
            var changed = false
            while true {
                let count = read(socket, &buffer, buffer.count)
                guard count > 0 else { break }
                if count >= 4, [RTM_NEWADDR, RTM_DELADDR, RTM_IFINFO].contains(Int32(buffer[3])) { changed = true }
            }
            if changed { onChange() }
        }
        source.setCancelHandler { close(socket) }
        source.resume()
    }

    func cancel() {
        source.cancel()
    }

    deinit {
        source.cancel()
    }
}
