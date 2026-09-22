// vphone-archive — unpacking and packing, without four external programs.
//
// Replaces gtar, bsdtar, unzip and zstd. The last of those is the reason this
// exists at all: neither the system tar nor GNU tar can read a .zst without a
// zstd(1) on PATH, because both shell out for that filter, and libzstd is not
// in /usr/lib or in the SDK. The libarchive this links has it compiled in, so
// a machine with no Homebrew can still install CFW.
//
// The shell scripts call this while they are still shell; vphone-cli calls the
// same library in-process. One implementation either way.

import ArgumentParser
import Foundation
import VPhoneArchive
import VPhoneCore

struct VPhoneArchiveCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vphone-archive",
        abstract: "Unpack and pack archives",
        discussion: """
        The compressor is detected when reading, so there is no --zstd to pass
        and no way to pass the wrong one.
        """,
        subcommands: [
            Extract.self, Create.self, Decompress.self,
            List.self, Cat.self, Fingerprint.self,
        ],
        defaultSubcommand: Extract.self
    )
}

// MARK: - extract

struct Extract: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "extract",
        abstract: "Unpack an archive into a directory"
    )

    @Option(name: [.customShort("f"), .long], help: "Archive to read",
            transform: URL.init(fileURLWithPath:))
    var file: URL

    @Option(name: [.customShort("C"), .customLong("directory")],
            help: "Where to unpack it", transform: URL.init(fileURLWithPath:))
    var destination: URL = URL(fileURLWithPath: ".")

    @Flag(name: [.customShort("p"), .customLong("preserve-permissions")],
          help: "Restore modes, and — as root — the archive's numeric uid/gid")
    var preservePermissions = false

    @Flag(name: .customLong("no-overwrite-dir"),
          help: "Leave an existing directory's mode, owner and mtime alone")
    var noOverwriteDir = false

    @Flag(name: .customLong("numeric-owner"),
          help: "Accepted for compatibility; ownership is always restored by number")
    var numericOwner = false

    @Flag(name: [.customShort("v"), .long], help: "Print each member as it is written")
    var verbose = false

    func run() throws {
        // --preserve-permissions is what the install scripts pass GNU tar, and
        // they pass it precisely where they are running as root and unpacking
        // onto a mounted guest volume. Ownership by number is not a separate
        // choice: resolving the archive's `mobile` against the host's passwd
        // database is how files end up owned by an unrelated macOS account.
        var options = preservePermissions
            ? VPhoneArchiveExtractOptions.ontoGuestVolume
            : VPhoneArchiveExtractOptions.intoHostDirectory
        options.noOverwriteDir = noOverwriteDir

        let written = try VPhoneArchiveExtractor.extract(
            file, into: destination, options: options,
            progress: verbose ? { print($0.currentPath) } : nil
        )
        if !verbose { print("extracted \(written) entries to \(destination.path)") }
    }
}

// MARK: - create

struct Create: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Pack a directory into an archive"
    )

    @Option(name: [.customShort("f"), .long], help: "Archive to write",
            transform: URL.init(fileURLWithPath:))
    var file: URL

    @Option(name: [.customShort("C"), .customLong("directory")],
            help: "Directory to pack", transform: URL.init(fileURLWithPath:))
    var source: URL = URL(fileURLWithPath: ".")

    @Option(help: "tar dialect: gnutar, pax or ustar")
    var format: String = "gnutar"

    @Flag(name: .customLong("zstd"), help: "Compress with zstd")
    var zstd = false

    @Flag(name: .customLong("xz"), help: "Compress with xz")
    var xz = false

    @Option(help: "Compression level")
    var level: Int?

    @Option(help: "fnmatch pattern to leave out; repeatable")
    var exclude: [String] = []

    @Flag(name: [.customShort("v"), .long], help: "Print each member as it is added")
    var verbose = false

    func validate() throws {
        if zstd, xz { throw ValidationError("choose one of --zstd or --xz") }
        guard VPhoneArchiveFormat(rawValue: format) != nil else {
            throw ValidationError(
                "unknown format '\(format)' (gnutar, pax, ustar)"
            )
        }
    }

    func run() throws {
        // gnutar by default, and it matters: `vm export` feeds a consumer that
        // reads pax extended headers as an mtree listing and dies with "Line
        // too long", and ustar cannot hold a member over 8 GB.
        let tarFormat = VPhoneArchiveFormat(rawValue: format) ?? .gnutar
        let compression: VPhoneArchiveCompression = if zstd {
            .zstd(level: level ?? 3)
        } else if xz {
            .xz(level: level ?? 9)
        } else {
            .none
        }

        let written = try VPhoneArchiveWriter.create(
            archive: file, from: source,
            format: tarFormat, compression: compression, excluding: exclude,
            progress: verbose ? { print($0.currentPath) } : nil
        )
        if !verbose { print("packed \(written) entries into \(file.path)") }
    }
}

// MARK: - decompress

struct Decompress: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "decompress",
        abstract: "Unwrap a single compressed file, leaving what is inside packed",
        discussion: """
        What `zstd -d -f x.tar.zst -o x.tar` does. The result is still a tar;
        use `extract` to unpack it.
        """
    )

    @Option(name: [.customShort("f"), .long], help: "File to decompress",
            transform: URL.init(fileURLWithPath:))
    var file: URL

    @Option(name: [.customShort("o"), .long], help: "Where to write the result",
            transform: URL.init(fileURLWithPath:))
    var output: URL

    func run() throws {
        try VPhoneArchiveWriter.decompress(file, to: output)
        print("decompressed \(file.lastPathComponent) → \(output.path)")
    }
}

// MARK: - list

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List an archive's members"
    )

    @Option(name: [.customShort("f"), .long], help: "Archive to read",
            transform: URL.init(fileURLWithPath:))
    var file: URL

    @Flag(name: [.customShort("v"), .long], help: "Include mode, owner and size")
    var verbose = false

    func run() throws {
        let entries = try VPhoneArchiveReader.entries(of: file)
        for entry in entries {
            if verbose {
                let mode = String(entry.mode, radix: 8)
                print("\(mode)\t\(entry.uid):\(entry.gid)\t\(entry.size)\t\(entry.path)")
            } else {
                print(entry.path)
            }
        }
    }
}

// MARK: - cat

struct Cat: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cat",
        abstract: "Write one member to stdout without unpacking the archive"
    )

    @Option(name: [.customShort("f"), .long], help: "Archive to read",
            transform: URL.init(fileURLWithPath:))
    var file: URL

    @Argument(help: "Member path inside the archive")
    var member: String

    func run() throws {
        let data = try VPhoneArchiveReader.readMember(member, from: file)
        FileHandle.standardOutput.write(data)
    }
}

// MARK: - fingerprint

struct Fingerprint: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fingerprint",
        abstract: "Describe a directory tree completely, or compare two of them",
        discussion: """
        For deciding whether GNU tar and vphone-archive produced the same
        result. `diff -r` and `stat` cannot answer that: they miss ACLs,
        extended attributes, which files are hardlinked to which, and
        sparse-file occupancy — the four things most likely to differ, and
        all four of which change how a guest behaves.

        With one path, writes JSON. With two, prints the differences and exits
        non-zero if there are any.
        """
    )

    @Argument(help: "Tree to describe", transform: URL.init(fileURLWithPath:))
    var tree: URL

    @Argument(help: "Second tree; given, the two are compared",
              transform: URL.init(fileURLWithPath:))
    var other: URL?

    @Flag(name: .customLong("no-content-hashes"),
          help: "Skip file digests — much faster, and enough to compare metadata")
    var noContentHashes = false

    func run() throws {
        let first = try VPhoneTreeFingerprint.capture(tree, includeContentHashes: !noContentHashes)

        guard let other else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(first), as: UTF8.self))
            return
        }

        let second = try VPhoneTreeFingerprint.capture(
            other, includeContentHashes: !noContentHashes
        )
        let differences = first.differences(from: second)
        guard differences.isEmpty else {
            for line in differences { print(line) }
            print("\n\(differences.count) difference(s)")
            throw ExitCode(1)
        }
        print("identical (\(first.entries.count) entries)")
    }
}

VPhoneArchiveCLI.main()
