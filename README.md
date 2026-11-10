# Brew (GD 2.207 iOS) - hook.dylib starter

## Windows workflow
1. Push this folder to a (private) GitHub repo. The `build-hook` Action builds `hook.dylib` on a
   macOS runner; download it from the run's Artifacts. (Alternatives: WSL2 + Theos, or a cloud Mac.)
2. Build the IPA (needs only Python 3):
       python tools/build_ipa.py Geometry-Dash.ipa hook.dylib out/Brew.ipa
3. Sign + install out/Brew.ipa with Sideloadly (Windows) or AltStore.
4. Check the device log for `[Brew] loaded. slide = ...` to confirm injection.

On a Mac you can just run `make` instead of step 1.

Hooking needs a backend (Dobby is the usual pick): add it, define BREW_USE_DOBBY in src/hook.mm.
Runtime code patching on a non-jailbroken device generally needs JIT access; otherwise use static
byte patches in the binary.
