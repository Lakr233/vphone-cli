import Foundation

/// The relay only names the channel's `Ending`, `send` and `close`; the real
/// channel needs the whole VM stack, so this stands in for it.
final class VPhoneGuestShellChannel: @unchecked Sendable {
    enum Ending: Sendable {
        case exited(Int)
        case signalled(Int)
        case failed(String)
    }

    func send(_: Data) {}
    func close() {}
}

/// Runs one relay session against a socketpair and returns every byte the
/// client side reads until the relay closes its end.
private func session(_ run: (VPhoneHostShellRelay) -> Void) -> String {
    var pair: [Int32] = [0, 0]
    precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    let relay = VPhoneHostShellRelay(descriptor: pair[0])
    run(relay)
    var received = Data()
    var bytes = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = read(pair[1], &bytes, bytes.count)
        if count <= 0 { break }
        received.append(contentsOf: bytes[0 ..< count])
    }
    close(pair[1])
    return String(decoding: received, as: UTF8.self)
}

@main
enum HostShellRelayTests {
    static func main() {
        var checks = 0
        func expect(_ actual: String, _ expected: String, _ name: String) {
            checks += 1
            guard actual == expected else {
                print("FAIL \(name): expected \(expected.debugDescription) got \(actual.debugDescription)")
                exit(1)
            }
        }
        let prompt = Data("probe> ".utf8)
        let line = Data("42\n".utf8)

        expect(session { $0.deliver(prompt); $0.end(.exited(0)) },
               "probe> \n{\"exit\":0,\"ok\":true}\n", "unterminated prompt gets its own status line")
        expect(session { $0.deliver(line); $0.end(.exited(0)) },
               "42\n{\"exit\":0,\"ok\":true}\n", "terminated output is unchanged")
        expect(session { $0.end(.signalled(2)) },
               "{\"ok\":true,\"signal\":2}\n", "silent session adds no byte")
        expect(session { $0.deliver(prompt); $0.deliver(Data("x\n".utf8)); $0.end(.exited(3)) },
               "probe> x\n{\"exit\":3,\"ok\":true}\n", "only the last byte counts")
        expect(session { $0.deliver(prompt); $0.end(.failed("gone")) },
               "probe> \n{\"error\":\"gone\",\"ok\":false}\n", "failure after a prompt")
        expect(session { $0.refuse("no guest") },
               "{\"error\":\"no guest\",\"ok\":false}\n", "refused session adds no byte")

        print("Host shell relay tests passed: \(checks) checks (status line starts on its own line only when needed)")
    }
}
