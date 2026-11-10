// Brew - hook.dylib entry point (GD 2.207 iOS, arm64)
// Build on a Mac with `make`. Loaded by GeometryJump via an injected LC_LOAD_DYLIB.
#import <Foundation/Foundation.h>
#include <mach-o/dyld.h>
#include <stdint.h>

// Uncomment once you've added Dobby (https://github.com/jmpews/Dobby) to the project.
// #define BREW_USE_DOBBY
#ifdef BREW_USE_DOBBY
#include "dobby.h"
#endif

// ---- Address helpers ------------------------------------------------------
// Offsets you find in Ghidra/IDA are relative to the image base (0x100000000
// in the file). Runtime address = ASLR slide + file address.
static intptr_t g_slide = 0;

static inline uintptr_t brew_addr(uintptr_t ghidra_addr) {
    return ghidra_addr + g_slide;          // pass the address exactly as Ghidra/IDA shows it
}

// ---- Hook helper ----------------------------------------------------------
template <typename Fn>
static bool brew_hook(uintptr_t ghidra_addr, Fn replacement, Fn *original) {
#ifdef BREW_USE_DOBBY
    return DobbyHook((void *)brew_addr(ghidra_addr), (void *)replacement, (void **)original) == 0;
#else
    NSLog(@"[Brew] hook requested at 0x%lx but no hooking backend is compiled in", (unsigned long)ghidra_addr);
    return false;
#endif
}

// ---- Example hook (TEMPLATE: the address below is a placeholder) ----------
// Say you find that PlayLayer::init is at 0x100123456 and returns bool:
//
//   class PlayLayer;                                   // opaque, we only pass pointers around
//   static bool (*orig_PlayLayer_init)(PlayLayer *, void *, bool, bool);
//   static bool hook_PlayLayer_init(PlayLayer *self, void *level, bool a, bool b) {
//       NSLog(@"[Brew] PlayLayer::init");
//       return orig_PlayLayer_init(self, level, a, b);
//   }
//   ... then in brew_install_hooks():
//   brew_hook(0x100123456, hook_PlayLayer_init, &orig_PlayLayer_init);

static void brew_install_hooks() {
    // brew_hook(...) calls go here
}

// ---- Entry point ----------------------------------------------------------
__attribute__((constructor))
static void brew_init() {
    g_slide = _dyld_get_image_vmaddr_slide(0);   // image 0 is the main executable (GeometryJump)
    NSLog(@"[Brew] loaded. slide = 0x%lx", (unsigned long)g_slide);
    brew_install_hooks();
}
