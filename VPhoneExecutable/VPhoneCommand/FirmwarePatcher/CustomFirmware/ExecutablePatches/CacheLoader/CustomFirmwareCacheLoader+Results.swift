public extension CustomFirmwareCacheLoaderPatcher {
    // MARK: - Results

    /// The boot-arg string the gate is built around, and the code that loads it.
    struct Anchor: Sendable, Equatable {
        /// Which of ``anchorTokens`` matched.
        public let token: String
        /// The whole null-terminated string the token sits inside.
        public let text: String
        /// `"__TEXT,__cstring"` and the like — where the string was found.
        public let sectionName: String
        /// File offset of the string's FIRST byte, which is what code addresses.
        public let stringFileOffset: Int
        public let stringVMA: UInt64
        /// Address of the matched substring, which differs from ``stringVMA``
        /// whenever the token is not itself the start of the string.
        public let matchVMA: UInt64
        /// File offset of the ADRP that forms the string's address.
        public let referenceFileOffset: Int
        public let referenceVMA: UInt64
    }

    /// The conditional branch that skips the unsecure-cache path — or the NOP a
    /// previous run already left in its place.
    struct Gate: Sendable, Equatable {
        public let fileOffset: Int
        public let vma: UInt64
        /// Capstone's mnemonic: `cbz`/`cbnz`/`tbz`/`tbnz`/`b.<cond>`, or `nop`
        /// when this binary has already been patched.
        public let mnemonic: String
        public let operandString: String
        /// The call whose return value the gate tests, when one was found. The
        /// fallback path leaves this `nil`.
        public let callFileOffset: Int?
        public let callVMA: UInt64?
        /// Where the branch jumps when it is taken, i.e. past the unsecure path.
        /// `nil` once the gate is a NOP and there is no target left to read.
        public let targetVMA: UInt64?

        /// True when the site already holds this patch's own output.
        public var wasAlreadyNOP: Bool {
            mnemonic == "nop"
        }

        /// How the gate reads in disassembly.
        public var text: String {
            operandString.isEmpty ? mnemonic : "\(mnemonic) \(operandString)"
        }
    }

    /// What a run did.
    enum Outcome: String, Sendable, Equatable {
        /// The gate already held a NOP. Nothing was written.
        case alreadyPatched
        /// `dryRun` was set, so the site was located and reported only.
        case wouldPatch
        /// The branch was replaced with a NOP.
        case patched
    }

    /// The outcome of one run, and the site it acted on.
    struct Report: Sendable {
        public let outcome: Outcome
        public let anchor: Anchor
        public let gate: Gate
        /// The write, in the shape the Python's reference capture records it.
        /// `nil` unless bytes actually changed.
        public let record: PatchRecord?
        /// Slot hashes recomputed, empty unless `reattestsCodeSignature` was set.
        public let reattestedSlots: [CustomFirmwareSlotRehash]

        /// Sites whose bytes this run changed. The parity number: the Python
        /// writes exactly one, and so must this.
        public var sitesWritten: Int {
            record == nil ? 0 : 1
        }
    }
}
