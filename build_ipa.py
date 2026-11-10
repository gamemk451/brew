#!/usr/bin/env python3
"""Build Brew.ipa: add hook.dylib to the GD IPA and inject it. Works on Windows/macOS/Linux.
usage: python tools/build_ipa.py Geometry-Dash.ipa hook.dylib out/Brew.ipa
"""
import os, sys, zipfile, copy
sys.path.insert(0, os.path.dirname(__file__))
from inject import inject

DYLIB_PATH_IN_APP = "@executable_path/Frameworks/hook.dylib"

def main(ipa, dylib, out):
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    with zipfile.ZipFile(ipa) as zin, zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zout:
        app = next(n.split("/")[1] for n in zin.namelist()
                   if n.startswith("Payload/") and n.split("/")[1].endswith(".app"))
        prefix = f"Payload/{app}/"
        exe = prefix + "GeometryJump"
        for info in zin.infolist():
            if info.filename.startswith(prefix + "_CodeSignature/"):
                continue                      # invalid after patching; re-signed on install
            data = zin.read(info.filename)
            if info.filename == exe:
                data = inject(data, DYLIB_PATH_IN_APP)
            zout.writestr(copy.copy(info), data)   # copy keeps permissions (executable bit)
        lib = zipfile.ZipInfo(prefix + "Frameworks/hook.dylib")
        lib.external_attr = 0o755 << 16
        lib.compress_type = zipfile.ZIP_DEFLATED
        zout.writestr(lib, open(dylib, "rb").read())
    print("wrote", out, "(unsigned: sign with Sideloadly / AltStore)")

if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
