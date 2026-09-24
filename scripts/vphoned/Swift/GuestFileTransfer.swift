import Darwin
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

enum GuestFileTransfer {
    static func path(from uri: String) throws -> String {
        let components = URLComponents(string: "http://vphoned\(uri)")
        guard let path = components?.queryItems?.first(where: { $0.name == "path" })?.value,
              path.hasPrefix("/"), !path.contains("\0")
        else { throw GuestAPIError.invalidRequest("An absolute path query parameter is required") }
        return path
    }

    static func download(path: String, fileIO: NonBlockingFileIO, channel: Channel) {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            GuestHTTPHandler.send(APIWire.error("File could not be opened", status: 404), on: channel)
            return
        }
        let handle = NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: fd)
        do {
            var statBuffer = stat()
            guard fstat(fd, &statBuffer) == 0, (statBuffer.st_mode & S_IFMT) == S_IFREG else {
                throw GuestAPIError.invalidRequest("Path is not a regular file")
            }
            let region = try FileRegion(fileHandle: handle)
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/octet-stream")
            headers.add(name: "Content-Length", value: String(region.readableBytes))
            headers.add(name: "Connection", value: "close")
            channel.write(HTTPServerResponsePart.head(.init(version: .http1_1, status: .ok, headers: headers)), promise: nil)
            fileIO.readChunked(fileRegion: region, chunkSize: 64 * 1024,
                               allocator: channel.allocator, eventLoop: channel.eventLoop) { bytes in
                channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(bytes)))
            }.whenComplete { result in
                try? handle.close()
                switch result {
                case .success:
                    channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
                        channel.close(promise: nil)
                    }
                case .failure:
                    channel.close(promise: nil)
                }
            }
        } catch {
            try? handle.close()
            GuestHTTPHandler.send(APIWire.error(String(describing: error), status: 400), on: channel)
        }
    }
}

final class GuestFileUpload: @unchecked Sendable {
    private let destination: String
    private let temporary: String
    private let handle: NIOFileHandle
    private let fileIO: NonBlockingFileIO
    private var offset: Int64 = 0
    private var writes: EventLoopFuture<Void>
    private let onCommit: ((String) throws -> Void)?

    init(destination: String, fileIO: NonBlockingFileIO, channel: Channel,
         onCommit: ((String) throws -> Void)? = nil) throws {
        let temporary = destination + ".vphoned-" + UUID().uuidString + ".tmp"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw GuestAPIError.operationFailed("Could not create upload file") }
        self.destination = destination
        self.temporary = temporary
        self.handle = NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: fd)
        self.fileIO = fileIO
        self.writes = channel.eventLoop.makeSucceededFuture(())
        self.onCommit = onCommit
    }

    func append(_ buffer: ByteBuffer, channel: Channel) {
        let start = offset
        offset += Int64(buffer.readableBytes)
        _ = channel.setOption(ChannelOptions.autoRead, value: false)
        writes = writes.flatMap { [fileIO, handle] in
            fileIO.write(fileHandle: handle, toOffset: start, buffer: buffer, eventLoop: channel.eventLoop)
        }
        writes.whenComplete { [self] _ in
            _ = self
            _ = channel.setOption(ChannelOptions.autoRead, value: true)
        }
    }

    func finish(channel: Channel) {
        writes.whenComplete { [self] result in
            do {
                try handle.close()
                switch result {
                case .failure(let error): throw error
                case .success: break
                }
                guard rename(temporary, destination) == 0 else {
                    throw GuestAPIError.operationFailed("Could not replace destination file")
                }
                chmod(destination, 0o644)
                try onCommit?(destination)
                GuestHTTPHandler.send(.json(["result": ["path": destination, "size": offset]]), on: channel)
            } catch {
                unlink(temporary)
                GuestHTTPHandler.send(APIWire.error(String(describing: error), status: 500), on: channel)
            }
        }
    }

    deinit {
        if handle.isOpen { try? handle.close() }
        unlink(temporary)
    }
}
