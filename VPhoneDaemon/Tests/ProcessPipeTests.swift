import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private func isClosed(_ descriptor: Int32) -> Bool {
    errno = 0
    return fcntl(descriptor, F_GETFD) == -1 && errno == EBADF
}

@main
private enum ProcessPipeTests {
    static func main() throws {
        try reusedWriteDescriptorSurvivesCleanup()
        try failedSecondPipeReleasesFirst()
        try unwindingReleasesBothEnds()
        print("process pipe ownership: descriptor reuse, allocation failure and unwinding passed")
    }

    private static func reusedWriteDescriptorSurvivesCleanup() throws {
        var captured: GuestProcessPipe? = try GuestProcessPipe()
        let readEnd = captured!.readEnd
        let released = captured!.writeEnd
        captured!.closeWriteEnd()
        precondition(isClosed(released))

        let replacement = open("/dev/null", O_RDONLY)
        precondition(replacement == released, "fixture did not reuse the released descriptor")
        defer { close(replacement) }
        captured!.closeWriteEnd()
        precondition(!isClosed(replacement), "repeated close closed a reused descriptor")
        captured = nil
        precondition(!isClosed(replacement), "pipe destruction closed a reused descriptor")
        precondition(isClosed(readEnd), "pipe destruction leaked its read end")
    }

    private static func failedSecondPipeReleasesFirst() throws {
        var first: [Int32] = []
        var attempts = 0
        let create: (UnsafeMutablePointer<Int32>) -> Int32 = { descriptors in
            attempts += 1
            if attempts == 2 {
                errno = EMFILE
                return -1
            }
            let result = pipe(descriptors)
            if result == 0 { first = [descriptors[0], descriptors[1]] }
            return result
        }
        func capture() throws {
            let stdout = try GuestProcessPipe(create: create)
            let stderr = try GuestProcessPipe(create: create)
            withExtendedLifetime((stdout, stderr)) {}
        }
        do {
            try capture()
            preconditionFailure("second pipe unexpectedly succeeded")
        } catch let error as POSIXError {
            precondition(error.code == .EMFILE, "pipe failure lost its errno")
        }
        precondition(attempts == 2 && first.count == 2)
        precondition(first.allSatisfy(isClosed), "failed second pipe leaked the first pipe")
    }

    private static func unwindingReleasesBothEnds() throws {
        enum SpawnFailure: Error { case fixture }
        var descriptors: [Int32] = []
        func capture() throws {
            let output = try GuestProcessPipe()
            descriptors = [output.readEnd, output.writeEnd]
            defer { withExtendedLifetime(output) {} }
            throw SpawnFailure.fixture
        }
        do {
            try capture()
            preconditionFailure("fixture did not throw")
        } catch SpawnFailure.fixture {}
        precondition(descriptors.count == 2 && descriptors.allSatisfy(isClosed), "unwinding leaked a pipe end")
    }
}
