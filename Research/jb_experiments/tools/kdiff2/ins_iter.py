"""per-word disassembly that survives instructions capstone cannot decode (md.disasm stops at the first one)."""
import struct
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM

_MD = Cs(CS_ARCH_ARM64, CS_MODE_ARM)


def iter_ins(blob, addr):
    """yield (address, mnemonic, op_str) for each 4-byte word; undecodable -> ('.word', '0x...')."""
    for i in range(0, len(blob) - len(blob) % 4, 4):
        w = struct.unpack_from('<I', blob, i)[0]
        ins = next(_MD.disasm(blob[i:i + 4], addr + i, 1), None)
        if ins is None:
            yield addr + i, '.word', hex(w)
        else:
            yield addr + i, ins.mnemonic, ins.op_str
