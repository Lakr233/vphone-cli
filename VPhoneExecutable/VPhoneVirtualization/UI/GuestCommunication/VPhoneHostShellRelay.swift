import Foundation

/// One `{"t":"shell"}` connection on `vphone.sock`: the local socket on one
/// side, the guest's terminal on the other.
///
/// The client's input ending is not the client leaving. `nc` and most pipes
/// shut their sending half as soon as their input runs out and still want
/// everything the session prints, so the end of input reaches the terminal
/// as a ^D, the way a keyboard ends it, and the session runs on. Only a
/// client that is gone altogether hangs it up. A socket shows that on its
/// sending side alone, so that is what the relay watches once input has ended.
///
/// The descriptor is closed exactly once, after both the input pump has
/// stopped and the session has ended, by whichever comes second: the pump is
/// the only thread that can still be inside `read` or waiting on `watch`.
final class VPhoneHostShellRelay: @unchecked Sendable {
    private let descriptor: Int32
    /// A kqueue that wakes the pump when the client goes, or when `end`
    /// triggers its user event because the session went first.
    private let watch: Int32
    /// Serializes writing with closing, so a write can never reach a
    /// descriptor the system has already handed to something else.
    private let lock = NSLock()
    private var closed = false
    private var pumping = false
    private var ended = false
    /// Whether the last byte relayed to the client was a newline (or nothing
    /// has been relayed yet): the status line starts on a line of its own.
    private var atLineStart = true

    init(descriptor: Int32) {
        self.descriptor = descriptor
        watch = kqueue()
        var events = [
            kevent(ident: UInt(descriptor), filter: Int16(EVFILT_WRITE), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0, udata: nil),
            kevent(ident: 0, filter: Int16(EVFILT_USER), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0, udata: nil),
        ]
        if watch >= 0 { _ = kevent(watch, &events, Int32(events.count), nil, 0, nil) }
    }

    // MARK: - Starting

    func attach(_ channel: VPhoneGuestShellChannel, typedAhead: Data) {
        lock.lock()
        let gone = closed
        pumping = !gone
        lock.unlock()
        guard !gone else {
            channel.close()
            return
        }
        if !typedAhead.isEmpty { channel.send(typedAhead) }
        let pump = Thread { [self] in input(to: channel) }
        pump.name = "vphone.hostctl.shell"
        pump.stackSize = 512 * 1024
        pump.start()
    }

    /// Whatever the client types; once its input ends, a ^D for the terminal
    /// and a wait for the client to go, which hangs the session up.
    private func input(to channel: VPhoneGuestShellChannel) {
        var bytes = [UInt8](repeating: 0, count: 8192)
        var failed = false
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                channel.send(Data(bytes[0 ..< count]))
                continue
            }
            if count < 0, errno == EINTR { continue }
            failed = count < 0
            break
        }

        lock.lock()
        let over = ended
        lock.unlock()
        if !over, !failed {
            // VEOF: a shell or the REPL reads end of input and finishes by
            // itself, and what it prints on the way out still arrives.
            channel.send(Data([0x04]))
            awaitDeparture()
        }

        lock.lock()
        pumping = false
        let finished = ended
        lock.unlock()
        if finished {
            closeDescriptor()
        } else {
            channel.close()
        }
    }

    /// Returns once the client can no longer be written to, or the session
    /// has ended. A half-closed client only ever shows up as writable.
    private func awaitDeparture() {
        var event = kevent()
        while true {
            let count = kevent(watch, nil, 0, &event, 1, nil)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            if event.filter == Int16(EVFILT_USER) { return }
            if event.flags & UInt16(EV_EOF) != 0 { return }
        }
    }

    // MARK: - From the Guest

    func deliver(_ data: Data) {
        write(data)
    }

    /// The last thing a client reads: how the session finished, on one line,
    /// the way every other command on this socket answers. A prompt the
    /// session left unfinished gets a newline first, so the line is never
    /// appended to it.
    func end(_ ending: VPhoneGuestShellChannel.Ending) {
        switch ending {
        case let .exited(status): writeLine(["ok": true, "exit": status])
        case let .signalled(number): writeLine(["ok": true, "signal": number])
        case let .failed(message): writeLine(["ok": false, "error": message])
        }
        lock.lock()
        ended = true
        let waiting = pumping
        if waiting {
            // Unblocks the pump wherever it is, and it then does the closing.
            shutdown(descriptor, SHUT_RDWR)
            var trigger = kevent(ident: 0, filter: Int16(EVFILT_USER), flags: 0, fflags: UInt32(NOTE_TRIGGER), data: 0, udata: nil)
            _ = kevent(watch, &trigger, 1, nil, 0, nil)
        }
        lock.unlock()
        if !waiting { closeDescriptor() }
    }

    /// A session that could not be opened at all: the reason, and no terminal.
    func refuse(_ message: String) {
        writeLine(["ok": false, "error": message])
        closeDescriptor()
    }

    // MARK: - Socket

    private func writeLine(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        write(data, startingLine: true)
    }

    private func write(_ output: Data, startingLine: Bool = false) {
        guard !output.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        var data = output
        if startingLine, !atLineStart { data.insert(0x0A, at: 0) }
        atLineStart = data.last == 0x0A
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var sent = 0
            while sent < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: sent), buffer.count - sent)
                if count > 0 {
                    sent += count
                    continue
                }
                if count < 0, errno == EINTR { continue }
                break
            }
        }
    }

    private func closeDescriptor() {
        lock.lock()
        let already = closed
        closed = true
        lock.unlock()
        guard !already else { return }
        close(descriptor)
        if watch >= 0 { close(watch) }
    }
}
