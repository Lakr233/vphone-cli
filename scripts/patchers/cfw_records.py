"""Reference-snapshot capture for the Swift patcher migration (plan P1.0).

Why this exists
---------------
The CFW patches rewrite executable pages that TXM hashes. A wrong byte is not a
failing test, it is a boot panic — so before any of `scripts/patchers/` is
reimplemented in Swift, every patch site has to be captured off a *real* install
as `file offset + original bytes + patched bytes`. The Swift port is then diffed
against that instead of eyeballed. `README_reference_capture.md` has the capture
procedure.

Contract: recording is a pure observer, or it stops
---------------------------------------------------
Every entry point below returns immediately when capture is off, and on the
happy path nothing here mutates a buffer, a file, or a patcher's control flow.
A patch run with capture on therefore produces a byte-identical output file to
one with it off; the README documents how that is proven.

The one way capture changes a run is by *refusing* it: when the input it is
asked to describe cannot yield an honest record, it raises `CaptureError`
instead of storing a false one. That aborts the patcher before its write, which
is the point — a reference nobody can trust is worse than no reference, because
the Swift port is graded against it and a boot panic is the failing grade. The
two refusals are documented at `_assert_not_degenerate` and
`_assert_pristine_input`; both are unreachable on a clean capture over pristine
inputs, which is the only capture the README asks for.

One capture root per (variant x iOS build)
------------------------------------------
A root holds exactly one copy of each input under `raw_payloads/`, and
`PatchComparisonTests.swift` replays the Swift port against that one copy and
asserts the record count matches. So a root describes one build, and capturing a
second build into it would silently mix two references. `_assert_pristine_input`
catches the common way that happens — re-running an install over a tree the last
capture already patched — and `flush()` warns when a site's bytes disagree with
what the root already holds.

Output layout — the existing `ipsws/patch_refactor_input/` convention
---------------------------------------------------------------------
    <root>/reference_patches/<group>.json   one JSON array per patcher
    <root>/raw_payloads/<name>              the pre-patch input, for replaying
    <root>/reference_patches/_capture_log.jsonl
    <root>/reference_patches/_capture_warnings.jsonl

Each JSON object carries two key sets naming the same values:

  * `patchID` / `component` / `fileOffset` / `virtualAddress` / `originalBytes` /
    `patchedBytes` / `beforeDisasm` / `afterDisasm` / `patchDescription` —
    `FirmwarePatcher.PatchRecord`'s own `Codable` keys, `Data` as base64, so
    `JSONDecoder().decode([PatchRecord].self, from:)` works directly.
  * `file_offset` / `patch_bytes` / `patch_size` / `description` / `component` —
    the `ReferencePatch` struct `tests/FirmwarePatcherTests/PatchComparisonTests.swift`
    already decodes, bytes as lowercase hex.

Neither decoder minds the other's keys, so the capture needs no translation
layer on either side.
"""

import atexit
import base64
import hashlib
import json
import os
import struct
import sys
import time


class CaptureError(Exception):
    """The capture cannot describe this write honestly, so it stops the run.

    Raised only from the two guards named in the module docstring. It is not a
    patcher failure: it means the *input* was wrong for a capture (already
    patched, or a site that did not change), and continuing would write a
    reference that lies about the pristine bytes.
    """

# Environment override, so a whole `cfw_install*.sh` run captures without any
# shell edit: `VPHONE_PATCH_RECORDS=<root> make cfw_install_exp`.
ENV_VAR = "VPHONE_PATCH_RECORDS"

# DSC code-signature page granularity on these caches. Used only to decide how
# much context to stash alongside a DSC patch, never to locate one.
DSC_PAGE_SIZE = 0x4000

# A raw payload above this is not worth copying — the DSC chunks are ~8 GiB and
# are captured page-wise instead.
MAX_PAYLOAD_BYTES = 512 * 1024 * 1024

# Whole-file before/after is inlined into the JSON below this; past it only the
# SHA-256 goes in, and the two payload copies carry the bytes. Each record
# spells its bytes twice (base64 for PatchRecord, hex for ReferencePatch), so a
# generous limit here costs four times the file size in JSON.
MAX_INLINE_REWRITE_BYTES = 256 * 1024

# A patched region that spans more than this many disjoint runs is a structural
# rewrite wearing a diff's clothes; record it as one span instead.
MAX_DIFF_RUNS = 512


# MARK: - Capture state


class _Capture:
    def __init__(self, root):
        self.root = root
        self.reference_dir, self.payload_dir = _resolve_dirs(root)
        # Directories are created on first write, not here. Creating them in the
        # constructor is how a mis-parsed `--emit-records <subcommand>` used to
        # leave a junk `./<subcommand>/reference_patches/` tree in the cwd of a
        # run that then exited 1 without capturing anything.
        self.dirs_ready = False
        self.group = "unclassified"
        self.records = []
        self.pending = None
        self.dsc_pages = {}   # (chunk_path, page_index) -> bytes before the write
        self.payloads = {}    # raw_payloads name -> sha256 of what is stored there
        self.group_index = {}  # group -> {"inputs": {...}, "outputs": {...}}
        self.warnings = []
        self.started = time.time()


def _ensure_dirs():
    if not _capture.dirs_ready:
        os.makedirs(_capture.reference_dir, exist_ok=True)
        os.makedirs(_capture.payload_dir, exist_ok=True)
        _capture.dirs_ready = True


def _warn(kind, **fields):
    """Note something the capture could still store but nobody should trust.

    Louder than a comment, quieter than `CaptureError`: it goes to stderr now
    and to `_capture_warnings.jsonl` at flush, so a capture that needs a second
    look says so without aborting an install that is otherwise fine.
    """
    entry = dict(kind=kind, group=_capture.group if _capture else None, **fields)
    if _capture is not None:
        _capture.warnings.append(entry)
    sys.stderr.write(f"[capture] WARNING {kind}: "
                     + ", ".join(f"{k}={v}" for k, v in fields.items() if v is not None)
                     + "\n")


_capture = None
_env_checked = False


def _resolve_dirs(root):
    """`<root>` is `ipsws/patch_refactor_input/` (or its `reference_patches/`
    subdirectory — both spellings land in the same place)."""
    root = os.path.abspath(os.path.expanduser(root))
    base = os.path.dirname(root) if os.path.basename(root) == "reference_patches" else root
    return os.path.join(base, "reference_patches"), os.path.join(base, "raw_payloads")


def resolve_dirs(root):
    """Where a given capture root puts its two directories."""
    return _resolve_dirs(root)


def enable(root, *, group=None):
    """Turn capture on, writing under `root`. Idempotent per process."""
    global _capture
    if _capture is None:
        _capture = _Capture(root)
        atexit.register(flush)
    if group:
        set_group(group)
    return _capture.reference_dir


def enabled():
    """True when capture is on. Picks up `VPHONE_PATCH_RECORDS` on first ask, so
    a patcher imported and called directly records without any argv plumbing."""
    global _env_checked
    if _capture is None and not _env_checked:
        _env_checked = True
        root = os.environ.get(ENV_VAR)
        if root:
            enable(root)
    return _capture is not None


def set_group(name):
    """Name the output file. Records already held under a different group are
    flushed first so one process can drive several patchers."""
    if not enabled():
        return
    if name == _capture.group:
        return
    if _capture.records:
        flush()
    _capture.group = name


def next_site(patch_id, description, *, component=None, virtual_address=None):
    """Label the next recorded write. One-shot: consumed by whichever write
    lands next, so a loop over N symbols labels each of the N records."""
    if not enabled():
        return
    _capture.pending = {
        "patch_id": patch_id,
        "description": description,
        "component": component,
        "virtual_address": virtual_address,
    }


def default_root():
    """`<repo>/ipsws/patch_refactor_input` — the convention the Swift
    comparison harness already reads from."""
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.dirname(os.path.dirname(here))
    return os.path.join(repo, "ipsws", "patch_refactor_input")


def _looks_like_root(token, reserved):
    """Is `token` the `<root>` of a bare `--emit-records <root>`, or the next
    real argument?

    `--emit-records` takes an optional value, so the separated spelling is
    ambiguous by construction. Consuming any non-dash token, which is what this
    used to do, ate the subcommand out of
    `cfw.py --emit-records patch-seputil <bin>`: the run then died with
    "Unknown command: <bin>" and left a `./patch-seputil/` capture tree behind.

    A root is a filesystem path, so that is what is required of it: a separator,
    a `~`, `.`/`..`, or a directory that already exists. A caller that knows its
    own verbs (`cfw.py` passes its dispatch table) also gets them excluded by
    name. Anything else means the flag was written bare — use the default root.
    A root with no separator that does not exist yet has to be spelled
    `--emit-records=<root>`.
    """
    if not token or token.startswith("-") or token in reserved:
        return False
    if token.startswith("~") or os.sep in token or token in (".", ".."):
        return True
    if os.altsep and os.altsep in token:
        return True
    return os.path.isdir(token)


def take_cli_flag(argv, *, reserved=()):
    """Strip `--emit-records [<root>]` / `--emit-records=<root>` out of `argv`
    and turn capture on. Returns `(argv_without_flag, root_or_None)`.

    Stripping rather than parsing in place is deliberate: every `cfw.py`
    subcommand indexes `sys.argv` positionally, so the flag has to be gone
    before dispatch for all of them to accept it without touching their
    argument handling.

    `reserved` is the caller's own argument vocabulary — subcommand names it
    must never lose to the flag's optional value.
    """
    reserved = frozenset(reserved)
    out = []
    root = None
    found = False
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--emit-records":
            found = True
            if i + 1 < len(argv) and _looks_like_root(argv[i + 1], reserved):
                root = argv[i + 1]
                i += 2
            else:
                i += 1
            continue
        if arg.startswith("--emit-records="):
            found = True
            root = arg.split("=", 1)[1]
            i += 1
            continue
        out.append(arg)
        i += 1
    if found:
        enable(root or os.environ.get(ENV_VAR) or default_root())
    return out, root


def site(file_offset, length, patch_id, description, *, virtual_address=None):
    """Declare a patch span for `record_file_write`. Plain data, no side effect —
    safe to build even when capture is off (the caller's list is just ignored)."""
    return {
        "file_offset": file_offset,
        "length": length,
        "patch_id": patch_id,
        "description": description,
        "virtual_address": virtual_address,
    }


# MARK: - What this root already holds


def _group_index(group):
    """What files this group has already described, read once per process.

    Two views, both keyed off the whole-file hashes every file-level record
    carries:

      * `inputs` — source path -> {sha256 of the file this group has already
        called the *original* at that path};
      * `outputs` — basename -> {sha256 of the file *after* a recorded patch},
        so the capture recognises its own output handed back to it even when
        the install ran under a different temporary path.

    `flush()` does its own dedupe straight off the file, so nothing about record
    identity is cached here — only what the guard needs.
    """
    cached = _capture.group_index.get(group)
    if cached is not None:
        return cached
    index = {"inputs": {}, "outputs": {}}
    path = os.path.join(_capture.reference_dir, f"{group}.json")
    try:
        with open(path, "r") as f:
            existing = json.load(f)
    except (OSError, ValueError):
        existing = []
    if isinstance(existing, list):
        for rec in existing:
            if not isinstance(rec, dict) or "patchID" not in rec:
                continue
            source = rec.get("file") or ""
            if rec.get("file_sha256_before"):
                index["inputs"].setdefault(source, set()).add(
                    rec["file_sha256_before"])
            if rec.get("file_sha256_after"):
                index["outputs"].setdefault(os.path.basename(source), set()).add(
                    rec["file_sha256_after"])
    _capture.group_index[group] = index
    return index


def _note_input(group, path, file_before_sha):
    """Remember what this process just called an original, so a second run
    inside one process is caught without waiting for a flush."""
    if file_before_sha:
        _group_index(group)["inputs"].setdefault(path, set()).add(file_before_sha)


def _note_output(group, path, file_after_sha):
    """Remember a file hash this process just produced, same reason."""
    if file_after_sha:
        _group_index(group)["outputs"].setdefault(
            os.path.basename(path), set()).add(file_after_sha)


def _assert_pristine_input(path, before):
    """Refuse to describe an input this root has already recorded patching.

    The capture reads `originalBytes` off the file on disk. Run it twice over
    the same tree and the second run reads run 1's *output* and calls it the
    original — every record it writes then misdescribes the pristine image.
    Dedupe cannot save that: the bytes differ from run 1's, so a bytes-keyed key
    could never collide, and a patcher that is not idempotent (launchd's cache
    loader and jetsam guard each find a *second* site on an already-patched
    binary) lands a genuinely new, genuinely wrong record at an offset run 1
    never touched. So the guard is at the front door instead.

    Two nets, because a capture can arrive here two ways:

      * the same source path, different bytes — this group already recorded an
        original at this path and it is not this one. That covers the chained
        case the "is it my own output?" test misses: `cfw_install_exp.sh` runs
        `inject-dylib` and then `patch-launchd-jetsam` over one `launchd`, so on
        a re-capture jetsam's input is neither pristine nor jetsam's own output.
      * these exact bytes, recorded as an *output* — the tree is this root's own
        result, reached under some other temporary path.

    Anything else that merely looks unfamiliar is warned about, not refused: a
    patcher legitimately runs over several files that share a basename (SystemOS
    and AppOS cryptexes), and those are different sites, not a re-capture.

    Returns the input's sha256, which the caller threads into its records.
    """
    sha = hashlib.sha256(before).hexdigest()
    index = _group_index(_capture.group)

    known_here = index["inputs"].get(path)
    if known_here and sha not in known_here:
        raise CaptureError(
            f"re-capture refused: {_capture.root} already holds records taken "
            f"from {path} with a different original (sha256 "
            f"{sorted(known_here)[0][:16]}..., now {sha[:16]}...), group "
            f"'{_capture.group}'. The file has been patched since — recording "
            f"it as an original would describe the wrong bytes. Restore the "
            f"pristine input, or capture into a fresh root: one root per "
            f"(variant x iOS build)."
        )

    produced = index["outputs"].get(os.path.basename(path))
    if produced and sha in produced:
        raise CaptureError(
            f"re-capture refused: {path} is already the *patched* output of an "
            f"earlier capture into {_capture.root} (sha256 {sha[:16]}..., "
            f"group '{_capture.group}'). Restore the pristine input, or capture "
            f"into a fresh root — one root per (variant x iOS build)."
        )

    if not known_here and index["inputs"]:
        stem = os.path.basename(path)
        siblings = {os.path.basename(p) for p in index["inputs"]}
        if stem in siblings:
            _warn("unfamiliar input for a known basename", file=path,
                  sha256=sha[:16],
                  note="this group already recorded a different file called "
                       f"'{stem}'; fine for SystemOS vs AppOS, a re-capture "
                       "under a new temp path otherwise")

    _note_input(_capture.group, path, sha)
    return sha


# MARK: - Record construction


def _cs_engine():
    try:
        try:
            from .cfw_asm import _cs
        except ImportError:
            from cfw_asm import _cs
        return _cs
    except Exception:
        return None


def _disasm(blob, address):
    """Best-effort ARM64 text for `blob`. Returns "" unless the whole span
    decodes cleanly — a half-decoded string would be worse than none.

    A record without a virtual address is not mapped code (a header field, a
    code-signature slot, a plist), so it is never disassembled: "udf #0" as the
    reading of a zeroed `maxSlide` would be actively misleading.
    """
    if address is None or not blob or len(blob) % 4 or len(blob) > 64:
        return ""
    cs = _cs_engine()
    if cs is None:
        return ""
    parts, covered = [], 0
    try:
        for insn in cs.disasm(bytes(blob), address or 0):
            parts.append(f"{insn.mnemonic} {insn.op_str}".strip())
            covered += insn.size
    except Exception:
        return ""
    if covered != len(blob) or not parts:
        return ""
    return "; ".join(parts)


def _assert_not_degenerate(patch_id, component, file_offset, original, patched,
                           source_file):
    """A record whose `originalBytes` equal its `patchedBytes` is not a patch.

    Stored, it asserts a false thing about the pristine image: "at this offset
    the untouched file held exactly what the patched file holds". Every way of
    producing one is a bug worth stopping for —

      * re-capturing over a tree a previous capture already patched, so the
        patcher reads its own output back as the original (this is how
        diskimagesiod and mobileactivationd grew a second, degenerate record);
      * a `site()` declaring a span the patcher did not actually change.

    Both mean the capture is describing something other than the patch, so it
    refuses rather than writing a record the Swift comparison would happily and
    wrongly satisfy with a port that writes nothing.
    """
    raise CaptureError(
        f"degenerate record refused: {patch_id} @ 0x{file_offset:X} in "
        f"{component} claims a patch but original == patched "
        f"({original.hex()[:32] or '<empty>'}). "
        f"Source: {source_file or '<none>'}. "
        f"The usual cause is a re-capture over an already-patched input — "
        f"restore the pristine file, or capture into a fresh root."
    )


def _make_record(patch_id, component, file_offset, original, patched,
                 *, virtual_address, description, source_file, inline,
                 file_before_sha=None, file_after_sha=None,
                 payload_before=None, payload_after=None):
    original = bytes(original or b"")
    patched = bytes(patched or b"")
    if inline and original == patched:
        _assert_not_degenerate(patch_id, component, file_offset,
                               original, patched, source_file)
    if not inline:
        # The bytes did not fit, so `patch_bytes` is empty and the Swift
        # comparison cannot check this record — it can only be a pointer at the
        # payload pair. Name it so nobody mistakes it for a check, and warn.
        patch_id = f"{patch_id}.opaque"
        _warn("opaque record", patch_id=patch_id, component=component,
              file=source_file, orig_size=len(original),
              patched_size=len(patched),
              note="too large to inline; not comparable — needs a structural "
                   "recorder before this group can grade a Swift port")
    before = _disasm(original, virtual_address) if inline else ""
    after = _disasm(patched, virtual_address) if inline else ""
    rec = {
        # FirmwarePatcher.PatchRecord — decodes straight into [PatchRecord].
        "patchID": patch_id,
        "component": component,
        "fileOffset": file_offset,
        "virtualAddress": virtual_address,
        "originalBytes": base64.b64encode(original).decode() if inline else "",
        "patchedBytes": base64.b64encode(patched).decode() if inline else "",
        "beforeDisasm": before,
        "afterDisasm": after,
        "patchDescription": description,
        # PatchComparisonTests.ReferencePatch — same values, its spelling.
        # `patch_size` describes `patch_bytes`, so it is 0 when the bytes were
        # too big to inline; the true lengths are in the provenance fields and
        # the bytes themselves are the `raw_payloads/` pair.
        "file_offset": file_offset,
        "patch_bytes": patched.hex() if inline else "",
        "patch_size": len(patched) if inline else 0,
        "description": description,
        # Capture provenance. Both decoders ignore these.
        "orig_bytes": original.hex() if inline else "",
        "orig_size": len(original),
        "patched_size": len(patched),
        "va": f"0x{virtual_address:X}" if virtual_address is not None else None,
        "file": source_file,
        "orig_sha256": hashlib.sha256(original).hexdigest(),
        "patch_sha256": hashlib.sha256(patched).hexdigest(),
        "inline_bytes": bool(inline),
        "comparable": bool(inline),
        # Whole-file hashes, when the recorder read whole files. These are what
        # `_assert_pristine_input` matches a later run's input against, and what
        # tells a replay harness which `raw_payloads/` entry a record belongs to.
        "file_sha256_before": file_before_sha,
        "file_sha256_after": file_after_sha,
        "payload_before": payload_before,
        "payload_after": payload_after,
    }
    return rec


def record(patch_id, component, file_offset, original_bytes, patched_bytes,
           *, virtual_address=None, description="", source_file=None, inline=True,
           file_before_sha=None, file_after_sha=None,
           payload_before=None, payload_after=None):
    """Append one patch record. The lowest level; everything else funnels here."""
    if not enabled():
        return
    _capture.records.append(_make_record(
        patch_id, component, file_offset, original_bytes, patched_bytes,
        virtual_address=virtual_address, description=description,
        source_file=source_file, inline=inline,
        file_before_sha=file_before_sha, file_after_sha=file_after_sha,
        payload_before=payload_before, payload_after=payload_after,
    ))


def record_span(component, file_offset, original_bytes, patched_bytes,
                *, virtual_address=None, source_file=None):
    """Record a write whose label came from `next_site`."""
    if not enabled():
        return
    pending = _capture.pending
    _capture.pending = None
    if pending:
        patch_id = pending["patch_id"]
        description = pending["description"]
        component = pending["component"] or component
        if virtual_address is None:
            virtual_address = pending["virtual_address"]
    else:
        patch_id = f"{_capture.group}.site{len(_capture.records)}"
        description = f"undeclared write in {_capture.group}"
    record(patch_id, component, file_offset, original_bytes, patched_bytes,
           virtual_address=virtual_address, description=description,
           source_file=source_file)


# MARK: - File-level capture


def _diff_runs(before, after):
    """Contiguous byte runs where `before` and `after` differ. Equal lengths
    only — a length change is a rewrite, not a patch."""
    runs = []
    n = len(before)
    i = 0
    while i < n:
        if before[i] == after[i]:
            i += 1
            continue
        start = i
        while i < n and before[i] != after[i]:
            i += 1
        runs.append((start, i))
        if len(runs) > MAX_DIFF_RUNS:
            return None
    return runs


def _stored_payload_sha(name):
    """sha256 of what `raw_payloads/<name>` already holds, or None."""
    known = _capture.payloads.get(name)
    if known is not None:
        return known
    dest = os.path.join(_capture.payload_dir, name)
    try:
        if os.path.getsize(dest) > MAX_PAYLOAD_BYTES:
            return None
        with open(dest, "rb") as f:
            sha = hashlib.sha256(f.read()).hexdigest()
    except OSError:
        return None
    _capture.payloads[name] = sha
    return sha


def write_payload(name, blob, sha=None):
    """Store `blob` in `raw_payloads/` and return the name it landed under.

    Writes the buffer the caller already has rather than re-reading the file,
    which is the only correct thing to do on the `record_file_write` path: there
    the file on disk is still the *original* when the record is made, so
    re-reading it to save "<name>.patched" would have saved the original bytes
    under the patched name.

    First distinct content wins the plain name, so `raw_payloads/<binary>` stays
    the pristine input the Swift harness loads. A later, different input for the
    same basename — a second patcher in a chain, which sees its predecessor's
    output — gets a hash-qualified name instead of silently sharing or
    overwriting the first one.
    """
    if not enabled():
        return None
    blob = bytes(blob)
    if len(blob) > MAX_PAYLOAD_BYTES:
        return None
    sha = sha or hashlib.sha256(blob).hexdigest()
    stored = _stored_payload_sha(name)
    if stored == sha:
        return name
    if stored is not None:
        name = f"{name}.{sha[:12]}"
        if _stored_payload_sha(name) == sha:
            return name
    try:
        _ensure_dirs()
        with open(os.path.join(_capture.payload_dir, name), "wb") as out:
            out.write(blob)
    except OSError:
        return None
    _capture.payloads[name] = sha
    return name


def capture_payload(path, *, name=None):
    """Copy the file as it stands right now into `raw_payloads/`, so a harness
    has the pre-patch input to replay. Returns the stored name."""
    if not enabled():
        return None
    try:
        if os.path.getsize(path) > MAX_PAYLOAD_BYTES:
            return None
        with open(path, "rb") as f:
            blob = f.read()
    except OSError:
        return None
    return write_payload(name or os.path.basename(path), blob)


def record_file_write(path, new_data, *, component=None, sites=None,
                      patch_id=None, description="", capture_input=True):
    """Record what writing `new_data` over `path` changes.

    Called immediately *before* the write, while the file on disk is still the
    original — so the diff is ground truth, not a transcription of what the
    patcher believes it did.

    `sites` (from `site()`) names the spans the patcher meant to change; each
    becomes its own record. Anything else that differs is still recorded, under
    an `.undeclared` id, which is the point: a declaration that drifts from the
    bytes shows up in the capture instead of hiding in it.
    """
    if not enabled():
        return
    component = component or _capture.group
    try:
        with open(path, "rb") as f:
            before = f.read()
    except OSError:
        return
    after = bytes(new_data)
    before_sha = _assert_pristine_input(path, before)
    after_sha = hashlib.sha256(after).hexdigest()
    payload_before = capture_payload(path) if capture_input else None

    if len(before) != len(after):
        _record_rewrite(path, before, after, component,
                        patch_id or f"{component}.rewrite", description,
                        before_sha=before_sha, after_sha=after_sha,
                        payload_before=payload_before)
        _note_output(_capture.group, path, after_sha)
        return

    claimed = []
    for s in (sites or []):
        off, ln = s["file_offset"], s["length"]
        if off < 0 or ln <= 0 or off + ln > len(after):
            continue
        claimed.append((off, off + ln))
        record(s["patch_id"], component, off,
               before[off:off + ln], after[off:off + ln],
               virtual_address=s["virtual_address"],
               description=s["description"], source_file=path,
               file_before_sha=before_sha, file_after_sha=after_sha,
               payload_before=payload_before)

    runs = _diff_runs(before, after)
    if runs is None:
        _record_rewrite(path, before, after, component,
                        patch_id or f"{component}.rewrite", description,
                        before_sha=before_sha, after_sha=after_sha,
                        payload_before=payload_before)
        _note_output(_capture.group, path, after_sha)
        return
    for start, end in runs:
        if any(c_start <= start and end <= c_end for c_start, c_end in claimed):
            continue
        record(f"{patch_id or component}.undeclared.0x{start:X}", component, start,
               before[start:end], after[start:end],
               description=description or f"undeclared change in {component}",
               source_file=path,
               file_before_sha=before_sha, file_after_sha=after_sha,
               payload_before=payload_before)
    _note_output(_capture.group, path, after_sha)


def _record_rewrite(path, before, after, component, patch_id, description,
                    *, before_sha=None, after_sha=None, payload_before=None):
    """Last resort: one record for the whole file, before and after.

    Only reached when nothing structural is known about the format, so prefer a
    structural recorder (`record_macho_lc_edit`) wherever one exists — past
    `MAX_INLINE_REWRITE_BYTES` this emits an `.opaque` record that the Swift
    comparison cannot check at all.
    """
    before_sha = before_sha or hashlib.sha256(before).hexdigest()
    after_sha = after_sha or hashlib.sha256(after).hexdigest()
    inline = max(len(before), len(after)) <= MAX_INLINE_REWRITE_BYTES
    payload_before = payload_before or write_payload(
        os.path.basename(path), before, before_sha)
    payload_after = None
    if not inline:
        # From the `after` buffer, never by re-reading `path`: on the
        # `record_file_write` path the write has not happened yet.
        payload_after = write_payload(
            f"{payload_before or os.path.basename(path)}.patched", after, after_sha)
    record(patch_id, component, 0, before, after,
           description=description or f"whole-file rewrite of {component}",
           source_file=path, inline=inline,
           file_before_sha=before_sha, file_after_sha=after_sha,
           payload_before=payload_before, payload_after=payload_after)


def record_file_rewrite(path, new_data, *, component, patch_id, description=""):
    """Whole-file structural rewrite (plists, device trees) where a byte diff
    would be noise. One record, before and after, from the file on disk."""
    if not enabled():
        return
    try:
        with open(path, "rb") as f:
            before = f.read()
    except OSError:
        return
    after = bytes(new_data)
    before_sha = _assert_pristine_input(path, before)
    after_sha = hashlib.sha256(after).hexdigest()
    _record_rewrite(path, before, after, component, patch_id, description,
                    before_sha=before_sha, after_sha=after_sha)
    _note_output(_capture.group, path, after_sha)


def record_blob_diff(component, before, after, *, patch_id_prefix,
                     description="", source_file=None, base_offset=0):
    """Record a diff of a decoded payload rather than a file — the device-tree
    blob inside an IM4P, say, where the file offsets mean nothing until the
    container is unwrapped. Offsets are payload-relative; `component` says so."""
    if not enabled():
        return
    before, after = bytes(before), bytes(after)
    if len(before) != len(after):
        record(f"{patch_id_prefix}.payload", component, base_offset, before, after,
               description=description or f"{component} payload replaced",
               source_file=source_file,
               inline=max(len(before), len(after)) <= MAX_INLINE_REWRITE_BYTES)
        return
    runs = _diff_runs(before, after)
    if runs is None:
        record(f"{patch_id_prefix}.payload", component, base_offset, before, after,
               description=description or f"{component} payload replaced",
               source_file=source_file,
               inline=len(before) <= MAX_INLINE_REWRITE_BYTES)
        return
    for start, end in runs:
        record(f"{patch_id_prefix}.0x{start:X}", component, base_offset + start,
               before[start:end], after[start:end],
               description=description, source_file=source_file)


def snapshot_file(path):
    """Read `path` as it stands, for patchers that write through a serializer
    (`plistlib.dump`) or an external program and so have no buffer to diff.
    Returns None when capture is off, which `record_after_write` treats as
    "nothing to do" — so the pair costs one branch in the normal path."""
    if not enabled():
        return None
    try:
        with open(path, "rb") as f:
            before = f.read()
    except OSError:
        return None
    _assert_pristine_input(path, before)
    capture_payload(path)
    return before


def record_after_write(path, before, *, component, patch_id, description="",
                       structure=None):
    """Close the pair opened by `snapshot_file`, reading the file back."""
    if before is None or not enabled():
        return
    try:
        with open(path, "rb") as f:
            after = f.read()
    except OSError:
        return
    record_external_edit(path, before, after, component=component,
                         patch_id=patch_id, description=description,
                         structure=structure)


def record_external_edit(path, before, after, *, component, patch_id,
                         description="", structure=None):
    """An edit made by a program we shell out to (`insert_dylib`). Caller reads
    the file either side of the call; we only classify the difference.

    `structure="macho"` says the file is a Mach-O whose *load commands* are the
    edit, so a length change is described by `record_macho_lc_edit` — the
    header and the inserted command — rather than collapsing into one opaque
    whole-file record.
    """
    if not enabled():
        return
    before, after = bytes(before), bytes(after)
    before_sha = hashlib.sha256(before).hexdigest()
    after_sha = hashlib.sha256(after).hexdigest()
    if before == after:
        return
    if len(before) == len(after):
        runs = _diff_runs(before, after)
        if runs is not None:
            for start, end in runs:
                record(f"{patch_id}.0x{start:X}", component, start,
                       before[start:end], after[start:end],
                       description=description, source_file=path,
                       file_before_sha=before_sha, file_after_sha=after_sha)
            _note_output(_capture.group, path, after_sha)
            return
    if structure == "macho" and record_macho_lc_edit(
            path, before, after, component=component, patch_id=patch_id,
            description=description,
            before_sha=before_sha, after_sha=after_sha):
        _note_output(_capture.group, path, after_sha)
        return
    _record_rewrite(path, before, after, component, patch_id, description,
                    before_sha=before_sha, after_sha=after_sha)
    _note_output(_capture.group, path, after_sha)


# MARK: - Mach-O load-command edits


LC_REQ_DYLD = 0x80000000
MH_MAGIC_64 = 0xFEEDFACF          # 64-bit Mach-O, little-endian on disk here
FAT_CIGAM = 0xBEBAFECA            # FAT_MAGIC (0xCAFEBABE) read little-endian
FAT_CIGAM_64 = 0xBFBAFECA
_DYLIB_LOAD_COMMANDS = (
    0x0C,                      # LC_LOAD_DYLIB
    0x0D,                      # LC_ID_DYLIB
    0x20,                      # LC_LAZY_LOAD_DYLIB
    0x18 | LC_REQ_DYLD,        # LC_LOAD_WEAK_DYLIB — what `insert_dylib --weak`
    0x1F | LC_REQ_DYLD,        # LC_REEXPORT_DYLIB     writes
)
_MACH_HEADER_64_SIZE = 32


def _macho_slices(buf):
    """File offsets of the 64-bit Mach-O images in `buf`, in file order.

    One entry for a thin binary, one per arch for a universal one. Returns []
    for anything this does not recognise, which sends the caller back to the
    whole-file path rather than guessing.
    """
    if len(buf) < 8:
        return []
    magic = struct.unpack_from("<I", buf, 0)[0]
    if magic == MH_MAGIC_64:
        return [0]
    if magic not in (FAT_CIGAM, FAT_CIGAM_64):
        return []
    is64 = magic == FAT_CIGAM_64
    nfat = struct.unpack_from(">I", buf, 4)[0]
    entry = 32 if is64 else 20
    offs = []
    for i in range(nfat):
        base = 8 + i * entry
        if base + entry > len(buf):
            return []
        if is64:
            off = struct.unpack_from(">Q", buf, base + 8)[0]
        else:
            off = struct.unpack_from(">I", buf, base + 8)[0]
        if off + _MACH_HEADER_64_SIZE > len(buf):
            return []
        if struct.unpack_from("<I", buf, off)[0] != MH_MAGIC_64:
            return []
        offs.append(off)
    return offs


def _macho_load_commands(buf, slice_off):
    """`(ncmds, sizeofcmds, [(offset, cmd, size)])` for one 64-bit image."""
    if slice_off + _MACH_HEADER_64_SIZE > len(buf):
        return None
    _, _, _, _, ncmds, sizeofcmds, _, _ = struct.unpack_from("<8I", buf, slice_off)
    pos = slice_off + _MACH_HEADER_64_SIZE
    end = pos + sizeofcmds
    if end > len(buf) or ncmds > 4096:
        return None
    cmds = []
    for _ in range(ncmds):
        if pos + 8 > end:
            return None
        cmd, size = struct.unpack_from("<2I", buf, pos)
        if size < 8 or pos + size > end:
            return None
        cmds.append((pos, cmd, size))
        pos += size
    return ncmds, sizeofcmds, cmds


def record_macho_lc_edit(path, before, after, *, component, patch_id,
                         description="", before_sha=None, after_sha=None):
    """Describe a Mach-O load-command edit by what a port must reproduce.

    `insert_dylib` rewrites a file end to end — it strips the code signature and
    reflows `__LINKEDIT`, so `launchd` came out 27 KiB *shorter* than it went
    in. Recorded as a whole-file rewrite that was one `.opaque` record: empty
    `patchedBytes`, `patch_size` 0, offset 0. A Swift port that emitted one
    record with empty bytes at offset 0 and the same description matched it
    exactly while writing nothing at all — for the LC_LOAD_WEAK_DYLIB that pid 1
    boots through.

    The edit itself is small and bounded however big the file is, and it lands
    in a region whose offsets are the same either side of the edit: the
    `mach_header` counters and the load commands. So that is what gets recorded,
    run by run:

      * `<patch_id>.mach_header`   — the 32 bytes carrying `ncmds`/`sizeofcmds`
      * `<patch_id>`               — the inserted dylib load command, at its
                                     offset, against whatever stood there before
      * `<patch_id>.lc.0x<off>`    — every other byte the command region moved
                                     (`__LINKEDIT` extent, `LC_SYMTAB` sizes)

    Each carries real bytes at a real offset, so a port that skips any of them
    fails on count or on bytes. What is deliberately *not* graded here is the
    `__LINKEDIT` reflow past the command region: that is the signature strip,
    not the load-command write, and the payload pair is there to replay it.

    Returns True when it recorded, False when the file is not a shape it can
    describe — the caller then falls back to the whole-file record.
    """
    if not enabled():
        return False
    before, after = bytes(before), bytes(after)
    before_sha = before_sha or hashlib.sha256(before).hexdigest()
    after_sha = after_sha or hashlib.sha256(after).hexdigest()

    slices_before = _macho_slices(before)
    slices_after = _macho_slices(after)
    if not slices_after or slices_before != slices_after:
        # A moved slice means offsets are not comparable image to image; a
        # missing header means this is not a Mach-O at all.
        return False

    payload_before = write_payload(os.path.basename(path), before, before_sha)
    payload_after = write_payload(
        f"{payload_before or os.path.basename(path)}.patched", after, after_sha)
    common = dict(source_file=path, file_before_sha=before_sha,
                  file_after_sha=after_sha, payload_before=payload_before,
                  payload_after=payload_after)

    staged = []
    for slice_off in slices_after:
        parsed_before = _macho_load_commands(before, slice_off)
        parsed_after = _macho_load_commands(after, slice_off)
        if parsed_before is None or parsed_after is None:
            return False
        _, size_before, cmds_before = parsed_before
        _, size_after, cmds_after = parsed_after

        suffix = f".slice0x{slice_off:X}" if len(slices_after) > 1 else ""
        hdr_end = slice_off + _MACH_HEADER_64_SIZE
        if before[slice_off:hdr_end] != after[slice_off:hdr_end]:
            staged.append((f"{patch_id}.mach_header{suffix}", slice_off,
                           before[slice_off:hdr_end], after[slice_off:hdr_end],
                           f"mach_header ncmds/sizeofcmds updated for "
                           f"{description or 'the inserted load command'}"))

        # The command region is comparable only where both images have bytes.
        region_end = min(len(before), len(after),
                         hdr_end + max(size_before, size_after))
        if region_end <= hdr_end:
            continue

        # The inserted dylib command: present in `after`, absent from `before`.
        old_blobs = {before[p:p + s] for p, _, s in cmds_before}
        claimed = []
        for pos, cmd, size in cmds_after:
            blob = after[pos:pos + size]
            if cmd not in _DYLIB_LOAD_COMMANDS or blob in old_blobs:
                continue
            if pos + size > region_end:
                continue
            if before[pos:pos + size] == blob:
                # Already there, byte for byte, at the same offset — nothing was
                # inserted here. Leave it to the region diff, which will agree.
                continue
            staged.append((f"{patch_id}{suffix}", pos,
                           before[pos:pos + size], blob,
                           description or "dylib load command inserted"))
            claimed.append((pos, pos + size))

        runs = _diff_runs(before[hdr_end:region_end], after[hdr_end:region_end])
        if runs is None:
            return False
        for start, end in runs:
            off = hdr_end + start
            stop = hdr_end + end
            if any(lo <= off and stop <= hi for lo, hi in claimed):
                continue
            staged.append((f"{patch_id}.lc.0x{off:X}{suffix}", off,
                           before[off:stop], after[off:stop],
                           f"load-command region follow-on for "
                           f"{description or 'the inserted load command'}"))

    if not staged:
        # Nothing inside the header or the command region changed, so this
        # recorder has nothing true to say about the edit.
        return False
    for rec_id, off, orig, patched, desc in staged:
        record(rec_id, component, off, orig, patched, description=desc, **common)
    return True


# MARK: - DSC page context


def note_dsc_page(chunk_path, file_offset):
    """Stash the 16 KiB code-signature page around a DSC write, before it lands.
    Copying the whole cache is out of the question, and the page is what P1.1's
    slot-hash cross-check needs anyway."""
    if not enabled():
        return
    page_index = file_offset // DSC_PAGE_SIZE
    key = (chunk_path, page_index)
    if key in _capture.dsc_pages:
        return
    try:
        with open(chunk_path, "rb") as f:
            f.seek(page_index * DSC_PAGE_SIZE)
            _capture.dsc_pages[key] = f.read(DSC_PAGE_SIZE)
    except OSError:
        pass


def _flush_dsc_pages():
    """Write each stashed page's before/after pair. "After" is read at flush,
    not at write time, so it includes the code-signature re-attestation."""
    pages_dir = os.path.join(_capture.payload_dir, "dsc_pages")
    for (chunk_path, page_index), before in _capture.dsc_pages.items():
        stem = f"{os.path.basename(chunk_path)}.page{page_index:06d}"
        try:
            os.makedirs(pages_dir, exist_ok=True)
            with open(os.path.join(pages_dir, stem + ".before.bin"), "wb") as f:
                f.write(before)
            with open(chunk_path, "rb") as src:
                src.seek(page_index * DSC_PAGE_SIZE)
                after = src.read(DSC_PAGE_SIZE)
            with open(os.path.join(pages_dir, stem + ".after.bin"), "wb") as f:
                f.write(after)
        except OSError:
            continue
    _capture.dsc_pages = {}


# MARK: - Flush


def _flush_warnings():
    """Persist anything `_warn` collected, so a capture that needs a second look
    still says so in the root itself after the terminal has scrolled away."""
    if not _capture.warnings:
        return
    try:
        _ensure_dirs()
        with open(os.path.join(_capture.reference_dir,
                               "_capture_warnings.jsonl"), "a") as f:
            for entry in _capture.warnings:
                entry.setdefault("utc", time.strftime("%Y-%m-%dT%H:%M:%SZ",
                                                      time.gmtime()))
                f.write(json.dumps(entry) + "\n")
    except OSError:
        return
    _capture.warnings = []


def _dedupe_key(rec):
    """What makes two records the same record: the *site*, not the bytes.

    This used to include `orig_sha256` and `patch_sha256`, which made the key
    unable to do its job. The capture reads `originalBytes` off disk, so a
    second capture over an already-patched tree reads different original bytes
    and produced a key that could never collide with run 1's — the very case
    dedupe existed for. Keying on the site collapses it instead, and when the
    bytes disagree that is reported as a conflict rather than quietly stored as
    a second truth about one offset.

    The source file's basename is in the key because one install legitimately
    runs a patcher over several files (SystemOS and AppOS cryptexes), and those
    are different sites that can share an offset and a patch id.
    """
    return (rec["patchID"], rec["component"], rec["fileOffset"],
            os.path.basename(rec.get("file") or ""))


def flush():
    """Merge this run's records into `<group>.json` and clear them.

    Merging rather than overwriting: one install runs a patcher several times
    (SystemOS and AppOS cryptexes, repeated variants), and the capture wants all
    of it. A site already in the file keeps the record it has; if this run's
    bytes for that site disagree, the disagreement is warned about, because it
    means two different inputs are being captured into one root and the root can
    only describe one.
    """
    if _capture is None:
        return
    if not _capture.records:
        _flush_warnings()
        return
    _ensure_dirs()
    path = os.path.join(_capture.reference_dir, f"{_capture.group}.json")
    merged = []
    seen = {}
    try:
        with open(path, "r") as f:
            existing = json.load(f)
        if isinstance(existing, list):
            for rec in existing:
                if isinstance(rec, dict) and "patchID" in rec:
                    merged.append(rec)
                    seen[_dedupe_key(rec)] = rec
    except (OSError, ValueError, KeyError):
        merged, seen = [], {}

    added = 0
    for rec in _capture.records:
        key = _dedupe_key(rec)
        prior = seen.get(key)
        if prior is not None:
            if (prior.get("orig_sha256") != rec["orig_sha256"]
                    or prior.get("patch_sha256") != rec["patch_sha256"]):
                _warn("conflicting record for one site",
                      patch_id=rec["patchID"], component=rec["component"],
                      file_offset=f"0x{rec['fileOffset']:X}",
                      kept=prior.get("patch_sha256", "")[:16],
                      discarded=rec["patch_sha256"][:16],
                      note="one capture root describes one (variant x iOS "
                           "build); capture the other build into its own root")
            continue
        seen[key] = rec
        merged.append(rec)
        added += 1

    merged.sort(key=lambda r: (r["component"], r["fileOffset"], r["patchID"]))
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(merged, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)
    # The on-disk view just changed, so the cached index for this group is stale.
    _capture.group_index.pop(_capture.group, None)

    with open(os.path.join(_capture.reference_dir, "_capture_log.jsonl"), "a") as f:
        f.write(json.dumps({
            "group": _capture.group,
            "recorded": len(_capture.records),
            "added": added,
            "total": len(merged),
            # `capture_root` rather than trusting `argv` to show how capture was
            # turned on: `cfw.py` strips `--emit-records` out of `sys.argv[:]`
            # before dispatch, so its subcommands log an argv with no flag in it,
            # while `cfw_patch_build_version.py`, `cfw_patch_post_restore_dt.py`
            # and `campo_mach_lookup_exceptions.py` strip a *local* argv and log
            # the flag. The env var shows in neither. This field always answers it.
            "capture_root": _capture.root,
            "env_var_set": bool(os.environ.get(ENV_VAR)),
            "argv": sys.argv,
            "cwd": os.getcwd(),
            "utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }) + "\n")

    _flush_warnings()

    _capture.records = []
    _flush_dsc_pages()
