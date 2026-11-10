#!/usr/bin/env python3
"""Add an LC_LOAD_DYLIB command to a thin arm64 Mach-O (pure Python, works on Windows).
CLI: inject.py GeometryJump @executable_path/Frameworks/hook.dylib
"""
import struct, sys

LC_LOAD_DYLIB = 0xC
MH_MAGIC_64 = 0xFEEDFACF

def inject(data: bytes, dylib: str) -> bytes:
    data = bytearray(data)
    magic, _, _, _, ncmds, sizeofcmds, _, _ = struct.unpack_from("<8I", data, 0)
    if magic != MH_MAGIC_64:
        raise ValueError("not a thin 64-bit little-endian Mach-O")

    off, first_sect = 32, None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == LC_LOAD_DYLIB:
            nameoff = struct.unpack_from("<I", data, off + 8)[0]
            if data[off + nameoff: off + size].split(b"\0")[0].decode() == dylib:
                raise ValueError("already injected")
        if cmd == 0x19:  # LC_SEGMENT_64: track lowest section file offset
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            for s in range(nsects):
                sect_off = struct.unpack_from("<I", data, off + 72 + s * 80 + 48)[0]
                if sect_off and (first_sect is None or sect_off < first_sect):
                    first_sect = sect_off
        off += size

    name = dylib.encode() + b"\0"
    cmdsize = (24 + len(name) + 7) & ~7
    cmd = struct.pack("<IIIIII", LC_LOAD_DYLIB, cmdsize, 24, 2, 0x00010000, 0x00010000)
    cmd += name + b"\0" * (cmdsize - 24 - len(name))

    end = 32 + sizeofcmds
    if end + cmdsize > first_sect:
        raise ValueError("not enough header padding for a new load command")
    if any(data[end:end + cmdsize]):
        raise ValueError("header padding is not empty")

    data[end:end + cmdsize] = cmd
    struct.pack_into("<II", data, 16, ncmds + 1, sizeofcmds + cmdsize)
    return bytes(data)

if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    path, lib = sys.argv[1:]
    out = inject(open(path, "rb").read(), lib)
    open(path, "wb").write(out)
    print("injected", lib)
