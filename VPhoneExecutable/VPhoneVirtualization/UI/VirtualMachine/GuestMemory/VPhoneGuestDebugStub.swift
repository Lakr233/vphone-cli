import Darwin
import Foundation

// MARK: - Kernel Debug Stub

/// The guest's vCPU registers, read through Virtualization's kernel GDB stub
/// while Virtualization holds the guest paused.
///
/// vphone configures the stub on every VM (`VPhoneVirtualMachine`); it
/// listens on a loopback port and speaks LLDB's dialect of gdb-remote:
/// - each vCPU is a thread, listed in the stop reply;
/// - `qRegisterInfo<n>` names register `n` (x0–x28, fp, lr, sp, pc, cpsr,
///   v0–v31, fpsr, fpcr, and system registers such as `ttbr1_el1`);
/// - after `QThreadSuffixSupported`, `p<n>;thread:<cpu>;` reads register `n`
///   of one vCPU.
///
/// Connecting halts the vCPUs; while Virtualization holds the guest paused
/// they are halted already, and the `D` that ends the session does not let
/// the guest run before Virtualization resumes it. See "Kernel registers" in
/// Research/Host/process_memory_dump.md.
enum VPhoneGuestDebugStub {
    /// Where the kernel is: the same on every vCPU once it has booted, and
    /// out of the guest's reach, unlike anything in its RAM.
    struct KernelRegisters: Sendable, Hashable {
        /// `TTBR1_EL1`: the kernel's root translation table, with the ASID
        /// in bits 48 and up.
        let ttbr1: UInt64
        /// `VBAR_EL1`: the kernel's exception vectors, in its `__TEXT_EXEC`.
        let vbar: UInt64

        /// The root table's physical address: 2048 entries, so 16 KB aligned.
        var root: UInt64 { ttbr1 & 0x0000_FFFF_FFFF_C000 }
    }

    enum Failure: LocalizedError, CustomStringConvertible {
        case unavailable(String)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case let .unavailable(reason): "The kernel debug stub is not available: \(reason)."
            case let .malformed(reason): "The kernel debug stub answered unexpectedly: \(reason)."
            }
        }

        var description: String { errorDescription ?? "kernel debug stub failed" }
    }

    /// Each reply must arrive within this; the stub answers in microseconds.
    static let replyTimeout = timeval(tv_sec: 1, tv_usec: 0)
    /// More registers than any target describes ends the enumeration.
    static let registerLimit = 1024
    /// The longest reply taken, before and after run-length decoding (each
    /// `*` pair can stand for up to 97 bytes).
    static let replyLimit = 1 << 20
    /// More `qsThreadInfo` replies than any vCPU list needs.
    static let threadListReplyLimit = 64

    static let kernelNames = ["ttbr1_el1", "vbar_el1"]

    /// The port Virtualization's AP stub listens on: the running VM's
    /// `_VZGDBDebugStub` (private). Its configuration holds only the port
    /// asked for, 0 when the system assigns one.
    @MainActor
    static func port(of machine: NSObject) -> Int? {
        let debugStub = NSSelectorFromString("_debugStub")
        guard machine.responds(to: debugStub),
              let stub = machine.perform(debugStub)?.takeUnretainedValue() as? NSObject,
              stub.responds(to: NSSelectorFromString("port")),
              let port = stub.value(forKey: "port") as? Int,
              (1 ... 65535).contains(port)
        else { return nil }
        return port
    }

    /// The kernel's registers, read from the stub at `port`.
    static func kernelRegisters(port: Int) throws -> KernelRegisters {
        let session = try Session.connect(port: port)
        defer { session.detach() }
        return try kernelRegisters(session)
    }

    /// Every vCPU must hold the same `TTBR1_EL1` and `VBAR_EL1`; a guest
    /// whose kernel has not set them up yet has none to give.
    static func kernelRegisters(_ session: Session) throws -> KernelRegisters {
        let cpus = try session.start()
        let numbers = try session.registerNumbers(Set(kernelNames))
        guard let ttbr1 = numbers["ttbr1_el1"], let vbar = numbers["vbar_el1"] else {
            throw Failure.malformed("no register " + kernelNames.filter { numbers[$0] == nil }.joined(separator: ", "))
        }
        var found: Set<KernelRegisters> = []
        for cpu in cpus {
            try found.insert(KernelRegisters(
                ttbr1: little(session.register(ttbr1, cpu: cpu)), vbar: little(session.register(vbar, cpu: cpu)),
            ))
        }
        guard found.count == 1, let registers = found.first else {
            throw Failure.malformed("the vCPUs disagree on TTBR1_EL1 or VBAR_EL1")
        }
        guard registers.root != 0, registers.vbar >> 47 != 0 else {
            throw Failure.unavailable("the guest kernel has not set up its page tables yet")
        }
        return registers
    }

    /// A comma-separated list of thread IDs. One that is not bare hex is
    /// refused rather than left out: every vCPU must be asked for its
    /// registers, or "the vCPUs agree" would hold for only some of them.
    static func threadIDs(_ list: some StringProtocol) throws -> [Int] {
        try list.split(separator: ",").map { text in
            guard let id = hex(text) else { throw Failure.malformed("thread ID \(text.prefix(16))") }
            return id
        }
    }

    /// `key:value;` pairs of a reply.
    static func fields(_ reply: String) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in reply.split(separator: ";") {
            guard let colon = pair.firstIndex(of: ":") else { continue }
            fields[String(pair[..<colon])] = String(pair[pair.index(after: colon)...])
        }
        return fields
    }

    /// A little-endian register value, up to 8 bytes.
    static func little(_ bytes: [UInt8]) -> UInt64 {
        bytes.prefix(8).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
    }

    /// A hexadecimal number as the protocol writes one: digits only, so no
    /// sign (`Int(_:radix:)` would read `-1`, which means all threads).
    static func hex(_ text: some StringProtocol) -> Int? {
        guard !text.isEmpty, text.utf8.count <= 15,
              text.utf8.allSatisfy({ UInt8(ascii: "0") ... UInt8(ascii: "9") ~= $0
                  || UInt8(ascii: "a") ... UInt8(ascii: "f") ~= $0 || UInt8(ascii: "A") ... UInt8(ascii: "F") ~= $0 })
        else { return nil }
        return Int(text, radix: 16)
    }

    /// The payload of a received packet: `}` escapes and `*` run lengths
    /// undone; nil if that makes it longer than `limit`.
    static func decode(_ raw: [UInt8], limit: Int = replyLimit) -> [UInt8]? {
        var out: [UInt8] = []
        var index = 0
        while index < raw.count {
            guard out.count <= limit else { return nil }
            let byte = raw[index]
            if byte == UInt8(ascii: "}"), index + 1 < raw.count {
                out.append(raw[index + 1] ^ 0x20)
                index += 2
            } else if byte == UInt8(ascii: "*"), index + 1 < raw.count, let last = out.last {
                let count = Int(raw[index + 1]) - 29
                if count > 0 { out += [UInt8](repeating: last, count: count) }
                index += 2
            } else {
                out.append(byte)
                index += 1
            }
        }
        return out.count <= limit ? out : nil
    }

    /// A packet as sent: `$payload#checksum`.
    static func frame(_ payload: String) -> [UInt8] {
        let bytes = Array(payload.utf8)
        let sum = bytes.reduce(UInt8(0)) { $0 &+ $1 }
        return [UInt8(ascii: "$")] + bytes + Array(String(format: "#%02x", sum).utf8)
    }

    // MARK: - Session

    /// One connection to the stub. Blocking, with a timeout on every reply:
    /// it runs while the guest is paused, so it must not wait long.
    final class Session {
        let descriptor: Int32
        private var buffer: [UInt8] = []
        private var acknowledging = true

        init(descriptor: Int32) {
            self.descriptor = descriptor
            var timeout = VPhoneGuestDebugStub.replyTimeout
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var on: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        }

        deinit { close(descriptor) }

        static func connect(port: Int) throws -> Session {
            let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            guard descriptor >= 0 else { throw Failure.unavailable(String(cString: strerror(errno))) }
            let session = Session(descriptor: descriptor)
            var on: Int32 = 1
            setsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else {
                throw Failure.unavailable("port \(port): \(String(cString: strerror(errno)))")
            }
            return session
        }

        func send(_ payload: String) throws {
            try write(VPhoneGuestDebugStub.frame(payload))
        }

        private func write(_ bytes: [UInt8]) throws {
            var done = 0
            while done < bytes.count {
                let result = bytes[done...].withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw Failure.unavailable("sending: \(String(cString: strerror(errno)))") }
                done += result
            }
        }

        /// The next packet's payload, acknowledged until no-ack mode is on.
        func receive() throws -> String {
            while true {
                if let start = buffer.firstIndex(of: UInt8(ascii: "$")),
                   let end = buffer[start...].firstIndex(of: UInt8(ascii: "#")),
                   buffer.count >= end + 3
                {
                    let raw = Array(buffer[(start + 1) ..< end])
                    let sum = String(bytes: buffer[(end + 1) ... (end + 2)], encoding: .ascii)
                        .flatMap { VPhoneGuestDebugStub.hex($0) }
                    buffer.removeFirst(end + 3)
                    if acknowledging {
                        guard sum == Int(raw.reduce(UInt8(0), { $0 &+ $1 })) else { throw Failure.malformed("bad checksum") }
                        try write([UInt8(ascii: "+")])
                    }
                    guard let payload = VPhoneGuestDebugStub.decode(raw) else {
                        throw Failure.malformed("a reply over 1 MB once decoded")
                    }
                    return String(decoding: payload, as: UTF8.self)
                }
                guard buffer.count < VPhoneGuestDebugStub.replyLimit else { throw Failure.malformed("a reply over 1 MB") }
                var chunk = [UInt8](repeating: 0, count: 4096)
                let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw Failure.unavailable(count == 0 ? "the stub closed the connection" : "no reply in time")
                }
                buffer += chunk[0 ..< count]
            }
        }

        func request(_ payload: String) throws -> String {
            try send(payload)
            return try receive()
        }

        func startNoAck() throws {
            try write([UInt8(ascii: "+")])
            if try request("QStartNoAckMode") == "OK" { acknowledging = false }
        }

        /// Starts the session: no-ack mode, then the vCPUs from the stop reply
        /// (or the thread list), with per-thread register reads switched on.
        func start() throws -> [Int] {
            try startNoAck()
            let stop = try request("?")
            guard stop.hasPrefix("T") || stop.hasPrefix("S") else {
                throw Failure.malformed("stop reply \(stop.prefix(32))")
            }
            var cpus = try VPhoneGuestDebugStub.fields(stop)["threads"].map { try VPhoneGuestDebugStub.threadIDs($0) } ?? []
            if cpus.isEmpty { cpus = try threadList() }
            guard !cpus.isEmpty else { throw Failure.malformed("no vCPUs") }
            guard try request("QThreadSuffixSupported") == "OK" else {
                throw Failure.malformed("no per-thread register reads")
            }
            return cpus
        }

        /// The vCPUs, when the stop reply does not list them. A list that
        /// does not end within `threadListReplyLimit` replies, or a reply
        /// that adds no vCPU, is refused.
        func threadList() throws -> [Int] {
            var cpus: [Int] = []
            var reply = try request("qfThreadInfo")
            for _ in 0 ..< VPhoneGuestDebugStub.threadListReplyLimit {
                guard reply.hasPrefix("m") else { return cpus }
                let added = try VPhoneGuestDebugStub.threadIDs(reply.dropFirst())
                guard !added.isEmpty else { throw Failure.malformed("a thread list reply without threads") }
                cpus += added
                reply = try request("qsThreadInfo")
            }
            throw Failure.malformed("a thread list that does not end")
        }

        /// The numbers of the registers named in `names` (by name or
        /// alt-name), stopping once all are found.
        func registerNumbers(_ names: Set<String>) throws -> [String: Int] {
            var numbers: [String: Int] = [:]
            for number in 0 ..< VPhoneGuestDebugStub.registerLimit {
                let reply = try request("qRegisterInfo" + String(number, radix: 16))
                guard !reply.isEmpty, !reply.hasPrefix("E") else { break }
                let fields = VPhoneGuestDebugStub.fields(reply)
                for key in ["name", "alt-name"] {
                    if let name = fields[key], names.contains(name), numbers[name] == nil { numbers[name] = number }
                }
                if numbers.count == names.count { break }
            }
            return numbers
        }

        /// One register of one vCPU, as the target's bytes.
        func register(_ number: Int, cpu: Int) throws -> [UInt8] {
            let reply = try request("p" + String(number, radix: 16) + ";thread:" + String(cpu, radix: 16) + ";")
            let digits = Array(reply.utf8)
            // An error is "Exx": odd, so it fails here.
            guard !digits.isEmpty, digits.count % 2 == 0 else {
                throw Failure.malformed("register \(number) of vCPU \(cpu): \(reply.prefix(16))")
            }
            var bytes: [UInt8] = []
            for index in stride(from: 0, to: digits.count, by: 2) {
                guard let byte = VPhoneGuestDebugStub.hex(String(decoding: digits[index ..< index + 2], as: UTF8.self))
                else {
                    throw Failure.malformed("register \(number) of vCPU \(cpu): \(reply.prefix(16))")
                }
                bytes.append(UInt8(byte))
            }
            return bytes
        }

        /// Ends the session without changing the vCPUs' state.
        func detach() {
            _ = try? request("D")
        }
    }
}
