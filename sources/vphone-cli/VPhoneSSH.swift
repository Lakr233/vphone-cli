import Foundation
import NIOCore
import NIOPosix
import NIOSSH

struct VPhoneSSHCommandResult {
    let exitStatus: Int32
    let standardOutput: Data
    let standardError: Data

    var standardOutputString: String {
        String(decoding: standardOutput, as: UTF8.self)
    }

    var standardErrorString: String {
        String(decoding: standardError, as: UTF8.self)
    }
}

enum VPhoneSSHError: Error, CustomStringConvertible {
    case notConnected
    case invalidChannelType
    case commandFailed(String)

    var description: String {
        switch self {
        case .notConnected:
            return "SSH client is not connected"
        case .invalidChannelType:
            return "Invalid SSH channel type"
        case let .commandFailed(message):
            return message
        }
    }
}

final class VPhoneSSHClient: @unchecked Sendable {
    let host: String
    let port: Int
    let username: String
    let password: String

    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?
    private var sshHandler: NIOSSHHandler?

    init(host: String, port: Int, username: String, password: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    deinit {
        try? shutdown()
    }

    func connect() throws {
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { [username, password] channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(
                        role: .client(
                            .init(
                                userAuthDelegate: SimplePasswordDelegate(username: username, password: password),
                                serverAuthDelegate: AcceptAllHostKeysDelegate()
                            )
                        ),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try channel.pipeline.syncOperations.addHandler(ssh)
                    try channel.pipeline.syncOperations.addHandler(VPhoneSSHErrorHandler())
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

        let connectedChannel = try bootstrap.connect(host: host, port: port).wait()
        channel = connectedChannel
        sshHandler = try connectedChannel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
    }

    func shutdown() throws {
        if let channel {
            try? channel.close().wait()
            self.channel = nil
        }
        try group.syncShutdownGracefully()
    }

    func execute(_ command: String, stdin: Data? = nil, requireSuccess: Bool = true) throws -> VPhoneSSHCommandResult {
        guard let channel, let sshHandler else {
            throw VPhoneSSHError.notConnected
        }

        let resultPromise = channel.eventLoop.makePromise(of: VPhoneSSHCommandResult.self)
        let childPromise = channel.eventLoop.makePromise(of: Channel.self)
        sshHandler.createChannel(childPromise) { childChannel, channelType in
            guard channelType == .session else {
                return channel.eventLoop.makeFailedFuture(VPhoneSSHError.invalidChannelType)
            }

            return childChannel.eventLoop.makeCompletedFuture {
                try childChannel.pipeline.syncOperations.addHandler(
                    VPhoneSSHExecHandler(command: command, stdinData: stdin, resultPromise: resultPromise)
                )
            }
        }

        let childChannel = try childPromise.futureResult.wait()
        try childChannel.closeFuture.wait()
        let result = try resultPromise.futureResult.wait()
        if requireSuccess, result.exitStatus != 0 {
            let stderr = result.standardErrorString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw VPhoneSSHError.commandFailed(
                stderr.isEmpty
                    ? "SSH command failed with status \(result.exitStatus): \(command)"
                    : "SSH command failed with status \(result.exitStatus): \(command)\n\(stderr)"
            )
        }
        return result
    }

    func uploadFile(localURL: URL, remotePath: String) throws {
        _ = try execute("/bin/cat > \(shellQuote(remotePath))", stdin: try Data(contentsOf: localURL))
    }

    func uploadData(_ data: Data, remotePath: String) throws {
        _ = try execute("/bin/cat > \(shellQuote(remotePath))", stdin: data)
    }

    func downloadFile(remotePath: String, localURL: URL) throws {
        let result = try execute("/bin/cat \(shellQuote(remotePath))")
        try result.standardOutput.write(to: localURL)
    }

    func uploadDirectory(localURL: URL, remotePath: String) throws {
        let archiveData = try VPhoneArchive.createTarArchive(from: localURL)
        let temporaryRemotePath = "/tmp/vphone-upload-\(UUID().uuidString).tar"
        try uploadData(archiveData, remotePath: temporaryRemotePath)
        _ = try execute(
            "/bin/mkdir -p \(shellQuote(remotePath)) && /usr/bin/tar --preserve-permissions --no-overwrite-dir -xf \(shellQuote(temporaryRemotePath)) -C \(shellQuote(remotePath)) && /bin/rm -f \(shellQuote(temporaryRemotePath))"
        )
    }

    static func probe(host: String, port: Int, username: String, password: String) -> Bool {
        do {
            let client = VPhoneSSHClient(host: host, port: port, username: username, password: password)
            defer { try? client.shutdown() }
            try client.connect()
            let result = try client.execute("echo ready", requireSuccess: false)
            return result.exitStatus == 0
        } catch {
            return false
        }
    }

    private func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private final class VPhoneSSHExecHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    let command: String
    let stdinData: Data?
    let resultPromise: EventLoopPromise<VPhoneSSHCommandResult>

    var standardOutput = Data()
    var standardError = Data()
    var exitStatus: Int32 = 0
    var completed = false

    init(command: String, stdinData: Data?, resultPromise: EventLoopPromise<VPhoneSSHCommandResult>) {
        self.command = command
        self.stdinData = stdinData
        self.resultPromise = resultPromise
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            self.fail(error, context: loopBoundContext.value)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        let request = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(request).whenComplete { result in
            switch result {
            case .success:
                self.sendStandardInput(context: loopBoundContext.value)
            case .failure(let error):
                self.fail(error, context: loopBoundContext.value)
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(var bytes) = message.data,
              let chunk = bytes.readData(length: bytes.readableBytes)
        else {
            return
        }

        switch message.type {
        case .channel:
            standardOutput.append(chunk)
        case .stdErr:
            standardError.append(chunk)
        default:
            break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let exit = event as? SSHChannelRequestEvent.ExitStatus {
            exitStatus = Int32(exit.exitStatus)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        succeedIfNeeded()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error, context: context)
    }

    private func sendStandardInput(context: ChannelHandlerContext) {
        guard let stdinData, !stdinData.isEmpty else {
            context.close(mode: .output, promise: nil)
            return
        }

        var buffer = context.channel.allocator.buffer(capacity: stdinData.count)
        buffer.writeBytes(stdinData)
        let payload = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.writeAndFlush(wrapOutboundOut(payload)).whenComplete { _ in
            loopBoundContext.value.close(mode: .output, promise: nil)
        }
    }

    private func succeedIfNeeded() {
        guard !completed else { return }
        completed = true
        resultPromise.succeed(
            VPhoneSSHCommandResult(
                exitStatus: exitStatus,
                standardOutput: standardOutput,
                standardError: standardError
            )
        )
    }

    private func fail(_ error: Error, context: ChannelHandlerContext) {
        guard !completed else { return }
        completed = true
        resultPromise.fail(error)
        context.close(promise: nil)
    }
}

private final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

private final class VPhoneSSHErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
