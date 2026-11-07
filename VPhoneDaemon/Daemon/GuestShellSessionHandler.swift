import Darwin
import Foundation
import IcliKit
import NIOCore
import NIOWebSocket
import VphonedNative

/// How many sessions a guest runs at once. Each one is a process, and an
/// interactive one is also a thread waiting on its terminal, so a client that
/// opened them without limit would spend the guest's memory and fill the
/// concurrent queue the rest of the API shares — a script may hold its place
/// in that queue for as long as its timeout allows. Refusing the next one
/// says so plainly, where answering everything slowly would not.
final class GuestSessionLimit: @unchecked Sendable {
    static let interactive = GuestSessionLimit(limit: 8, what: "interactive sessions")
    static let evaluations = GuestSessionLimit(limit: 16, what: "scripts")

    private let lock = NSLock()
    private let limit: Int
    private let what: String
    private var count = 0

    init(limit: Int, what: String) {
        self.limit = limit
        self.what = what
    }

    var refusal: String {
        "This guest is already running \(limit) \(what); end one and try again"
    }

    func acquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard count < limit else { return false }
        count += 1
        return true
    }

    func release() {
        lock.lock()
        if count > 0 { count -= 1 }
        lock.unlock()
    }
}

/// One scripting session, over a WebSocket. A binary frame is a chunk of the
/// terminal's byte stream in either direction, and a text frame carries a
/// control message. The session itself runs in a process of its own, so a
/// script that crashes or never returns ends only its own session.
///
/// `GET /v1/shell?program=repl&cols=100&rows=40`
///   - `program` is `repl` (the default, vphoned's JavaScript session), the
///     name of a program in the bootstrap, or an absolute path.
///   - client to server: `{"resize": [columns, rows]}`, `{"signal": "INT"}`.
///   - server to client: `{"exit": status}` or `{"signal": number}` last.
final class GuestShellSessionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    struct Request {
        var program: String
        var columns: Int32
        var rows: Int32
    }

    /// Whether the reader thread saw a failed write and should stop. A class
    /// so the event loop can report it without the reader sharing a variable.
    private final class Delivery: @unchecked Sendable {
        var active = true
    }

    private let request: Request
    private let terminalWrites = DispatchQueue(label: "vphoned.session.terminal", qos: .userInitiated)
    /// Guards the terminal and the session's pid for as long as either is
    /// used: a descriptor and a pid are both reused once released, and a
    /// write or a signal that arrived late must not reach whatever took them.
    private let lock = NSLock()
    private var master: Int32 = -1
    private var session: pid_t = -1
    private var ended = false
    private var closing = false

    init(request: Request) {
        self.request = request
    }

    // MARK: - Requests

    static func request(from uri: String) -> Request? {
        let path = uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
        guard path == "/v1/shell" else { return nil }
        let components = URLComponents(string: "http://vphoned\(uri)")
        var request = Request(program: "repl", columns: 80, rows: 24)
        for item in components?.queryItems ?? [] {
            guard let value = item.value, !value.isEmpty else { continue }
            switch item.name {
            case "program": request.program = value
            case "cols", "columns": request.columns = size(value) ?? request.columns
            case "rows": request.rows = size(value) ?? request.rows
            default: break
            }
        }
        return request
    }

    /// A terminal dimension. The driver's own field is 16 bits, and a client
    /// is free to send anything at all.
    private static func size(_ value: String) -> Int32? {
        guard let number = Int(value), number > 0 else { return nil }
        return clamped(number)
    }

    private static func clamped(_ size: Int) -> Int32 {
        Int32(min(max(size, 0), 9999))
    }

    /// The program a session runs: nothing for vphoned's own session, or the
    /// path of a program to run on the terminal instead. A bare name comes
    /// from the bootstrap, which a fresh guest does not have.
    static func resolveProgram(_ name: String) throws -> String? {
        if name.isEmpty || name == "repl" || name == "js" { return nil }
        if name.hasPrefix("/") {
            guard access(name, X_OK) == 0 else {
                throw GuestAPIError.invalidRequest("\(name) is not an executable file in this guest")
            }
            return name
        }
        guard !name.contains("/") else {
            throw GuestAPIError.invalidRequest("program must be a name or an absolute path")
        }
        guard let root = GuestAPI.jailbreakInfo()["jbroot"] as? String else {
            throw GuestAPIError.invalidRequest(
                "This guest has no bootstrap, so there is no \(name) to run. "
                    + "Leave program unset for vphoned's own session.",
            )
        }
        let prefix = root == "/" ? "" : root
        for candidate in ["\(prefix)/bin/\(name)", "\(prefix)/usr/bin/\(name)", "\(prefix)/usr/local/bin/\(name)"]
            where access(candidate, X_OK) == 0
        {
            return candidate
        }
        throw GuestAPIError.invalidRequest("The bootstrap at \(root) has no \(name)")
    }

    // MARK: - Opening

    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        guard GuestSessionLimit.interactive.acquire() else {
            refuse(GuestSessionLimit.interactive.refusal, on: channel)
            return
        }
        // From here the session's place is held, and every way out but a
        // started session gives it back. A started one is given back by
        // finish(), which runs once for each.
        let program: String?
        do {
            program = try Self.resolveProgram(request.program)
        } catch {
            GuestSessionLimit.interactive.release()
            refuse(String(describing: error), on: channel)
            return
        }
        if program == nil, !probeAvailable() {
            GuestSessionLimit.interactive.release()
            refuse("This guest has no JavaScriptCore, so there is no session to open.", on: channel)
            return
        }

        var started: pid_t = -1
        let descriptor: Int32 = if let program {
            program.withCString { vp_session_open($0, request.columns, request.rows, &started) }
        } else {
            vp_session_open(nil, request.columns, request.rows, &started)
        }
        guard descriptor >= 0 else {
            GuestSessionLimit.interactive.release()
            refuse("Could not open a session: \(String(cString: strerror(errno)))", on: channel)
            return
        }
        lock.lock()
        master = descriptor
        session = started
        lock.unlock()

        let reader = Thread { [self] in pump(on: channel, terminal: descriptor) }
        reader.name = "vphoned.session.reader"
        reader.stackSize = 512 * 1024
        reader.start()
    }

    // MARK: - The Terminal

    /// Reads the terminal until the session closes it. Each frame is awaited
    /// before the next read, so a client that cannot keep up slows the
    /// session down instead of filling the worker's memory with its output.
    /// This thread owns the descriptor: nothing else closes it.
    private func pump(on channel: Channel, terminal: Int32) {
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(terminal, $0.baseAddress, $0.count) }
            if count > 0 {
                guard forward(Array(bytes[0 ..< count]), to: channel) else { break }
                continue
            }
            // A pseudo-terminal reports EIO once the last program holding the
            // other end has gone, where a pipe would report end of file.
            if count < 0, errno == EINTR { continue }
            break
        }
        finish(on: channel)
    }

    private func forward(_ bytes: [UInt8], to channel: Channel) -> Bool {
        let delivered = DispatchSemaphore(value: 0)
        let delivery = Delivery()
        channel.eventLoop.execute {
            guard channel.isActive else {
                delivery.active = false
                delivered.signal()
                return
            }
            var payload = channel.allocator.buffer(capacity: bytes.count)
            payload.writeBytes(bytes)
            channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .binary, data: payload))
                .whenComplete { result in
                    if case .failure = result { delivery.active = false }
                    delivered.signal()
                }
        }
        // The wait is what applies the backpressure; the timeout only keeps a
        // wedged event loop from holding this thread for good.
        _ = delivered.wait(timeout: .now() + 30)
        return delivery.active
    }

    private func sendToTerminal(_ buffer: ByteBuffer) {
        var buffer = buffer
        guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else { return }
        terminalWrites.async { [self] in
            lock.lock()
            defer { lock.unlock() }
            guard !ended, master >= 0 else { return }
            var offset = 0
            while offset < bytes.count {
                let sent = bytes.withUnsafeBytes {
                    Darwin.write(master, $0.baseAddress?.advanced(by: offset), bytes.count - offset)
                }
                if sent > 0 {
                    offset += sent
                    continue
                }
                if sent < 0, errno == EINTR { continue }
                break
            }
        }
    }

    // MARK: - Control Messages

    private func handle(control text: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        if let size = object["resize"] as? [Any], size.count == 2,
           let columns = (size[0] as? NSNumber)?.intValue, let rows = (size[1] as? NSNumber)?.intValue
        {
            lock.lock()
            if !ended, master >= 0 {
                vp_session_resize(master, Self.clamped(columns), Self.clamped(rows))
            }
            lock.unlock()
        }
        if let name = object["signal"] as? String, let number = Self.signals[name.uppercased()] {
            lock.lock()
            // The group, so a program the session started receives it too.
            if !ended, session > 0 { kill(-session, number) }
            lock.unlock()
        }
    }

    private static let signals: [String: Int32] = [
        "HUP": SIGHUP, "SIGHUP": SIGHUP,
        "INT": SIGINT, "SIGINT": SIGINT,
        "QUIT": SIGQUIT, "SIGQUIT": SIGQUIT,
        "TERM": SIGTERM, "SIGTERM": SIGTERM,
        "KILL": SIGKILL, "SIGKILL": SIGKILL,
    ]

    // MARK: - Channel

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard !closing else { return }
        switch frame.opcode {
        case .binary:
            sendToTerminal(frame.unmaskedData)
        case .text:
            var payload = frame.unmaskedData
            if let text = payload.readString(length: payload.readableBytes) {
                handle(control: text)
            }
        case .ping:
            context.writeAndFlush(
                wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)),
                promise: nil,
            )
        case .connectionClose:
            closing = true
            let channel = context.channel
            context.writeAndFlush(
                wrapOutboundOut(WebSocketFrame(fin: true, opcode: .connectionClose, data: frame.unmaskedData)),
            ).whenComplete { _ in channel.closeAfterPeer() }
        default:
            close(1003, on: context.channel)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        closing = true
        // The terminal is not closed here: the reader thread may be inside
        // read() on it. Hanging the session up makes it close its own end,
        // which ends that read, and the reader then reaps and closes.
        requestEnd()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error _: Error) {
        context.close(promise: nil)
    }

    // MARK: - Ending

    private func requestEnd() {
        lock.lock()
        let ending = ended ? -1 : session
        // Signalled while the session is still this handler's, as the control
        // path does it: a pid released between the check and the signal
        // belongs to whatever the guest starts next.
        if ending > 0 {
            kill(ending, SIGHUP)
            kill(-ending, SIGHUP)
        }
        lock.unlock()
        guard ending > 0 else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            lock.lock()
            defer { lock.unlock() }
            // Only while this session still owns the pid: once it is reaped
            // the number belongs to whatever the guest starts next.
            guard !ended, session == ending else { return }
            kill(ending, SIGKILL)
            kill(-ending, SIGKILL)
        }
    }

    /// Reap the session and tell the client how it ended. Runs once, on the
    /// reader thread, after the terminal has stopped producing bytes.
    private func finish(on channel: Channel) {
        lock.lock()
        if ended {
            lock.unlock()
            return
        }
        // Taking them out under the lock is what makes closing them safe: a
        // writer holding the lock finishes first, and every writer after this
        // sees `ended` and leaves the descriptor alone. Reaping itself waits
        // for the session, so it must not be done holding a lock the event
        // loop takes to resize the terminal.
        ended = true
        let terminal = master
        let ending = session
        master = -1
        session = -1
        lock.unlock()

        let status = vp_session_close(terminal, ending, 2)
        // Once the process is gone, so the count is of sessions a guest is
        // actually running rather than of handlers that have not tidied up.
        GuestSessionLimit.interactive.release()

        var ended: [String: Any] = ["exit": NSNull()]
        if status >= 0 {
            let signalled = status & 0x7F
            ended = signalled != 0 ? ["signal": signalled] : ["exit": (status >> 8) & 0xFF]
        }
        let data = (try? JSONSerialization.data(withJSONObject: ended, options: [.sortedKeys])) ?? Data()
        send(text: data, on: channel, thenClose: 1000)
    }

    /// A session that could not be opened: the reason reaches the client as a
    /// text frame, because a WebSocket that has been accepted has no status
    /// code left to carry it.
    private func refuse(_ message: String, on channel: Channel) {
        let data = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
        send(text: data, on: channel, thenClose: 1011)
    }

    private func send(text data: Data, on channel: Channel, thenClose code: UInt16) {
        let write: @Sendable () -> Void = { [self] in
            guard channel.isActive else { return }
            var payload = channel.allocator.buffer(capacity: data.count)
            payload.writeBytes(data)
            channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, data: payload)).whenComplete { _ in
                self.close(code, on: channel)
            }
        }
        if channel.eventLoop.inEventLoop { write() } else { channel.eventLoop.execute(write) }
    }

    private func close(_ code: UInt16, on channel: Channel) {
        guard channel.isActive else { return }
        closing = true
        var data = channel.allocator.buffer(capacity: 2)
        data.writeInteger(code, endianness: .big)
        channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .connectionClose, data: data)).whenComplete { _ in
            channel.closeAfterPeer()
        }
    }
}
