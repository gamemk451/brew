// Brew - hook.dylib (GD 2.207 iOS, arm64)
// Build on a Mac with `make`. Loaded by GeometryJump via an injected LC_LOAD_DYLIB.
//
// Features:
//   * Draggable GD thumbs-up (green circle) button, always on top of the game.
//   * Tapping it opens the "Brew Menu" panel (GD sprites + GD bigFont taken from the app bundle).
//   * Noclip toggle (GD checkbox sprites). State is remembered between launches.
//
// !! ONE THING YOU MUST FILL IN: BREW_ADDR_DESTROY_PLAYER (see below). !!
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <atomic>

// Uncomment once you've added Dobby (https://github.com/jmpews/Dobby) to the project.
// #define BREW_USE_DOBBY
#ifdef BREW_USE_DOBBY
#include "dobby.h"
#endif

// ---- Addresses you must supply ---------------------------------------------
// Address of PlayLayer::destroyPlayer(PlayerObject *, GameObject *) in 2.207 iOS arm64,
// exactly as Ghidra/IDA shows it (e.g. 0x100123456). Leave 0 and noclip does nothing.
#define BREW_ADDR_DESTROY_PLAYER 0x0

// ---- Address helpers ------------------------------------------------------
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

// ---- Noclip ---------------------------------------------------------------
static std::atomic<bool> g_noclip{false};
static NSString *const kNoclipKey = @"brew.noclip";

static void (*orig_destroyPlayer)(void *self, void *player, void *obj) = nullptr;
static void hook_destroyPlayer(void *self, void *player, void *obj) {
    if (g_noclip.load()) return;           // noclip on: the player never dies
    orig_destroyPlayer(self, player, obj);
}

static void brew_install_hooks() {
    if (BREW_ADDR_DESTROY_PLAYER == 0) {
        NSLog(@"[Brew] BREW_ADDR_DESTROY_PLAYER is not set - noclip checkbox will have no effect");
        return;
    }
    if (!brew_hook(BREW_ADDR_DESTROY_PLAYER, hook_destroyPlayer, &orig_destroyPlayer)) {
        NSLog(@"[Brew] failed to hook PlayLayer::destroyPlayer");
    }
}

// ---- GD asset helpers (everything is read from the game's own bundle) ------
// All GD "-hd" assets are 2x the SD size, so they are loaded with scale 2 -> 1 point = 2 px.
static NSString *brew_path(NSString *file) {
    return [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:file];
}

static UIImage *brew_load(NSString *file) {
    return [UIImage imageWithContentsOfFile:brew_path(file)];
}

static UIImage *brew_hd(UIImage *img) {
    if (!img) return nil;
    return [UIImage imageWithCGImage:img.CGImage scale:2 orientation:UIImageOrientationUp];
}

static UIGraphicsImageRendererFormat *brew_pixel_format() {
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.scale = 1;          // draw in raw pixels, we tag the result as @2x afterwards
    fmt.opaque = NO;
    return fmt;
}

// Cuts one frame out of a cocos2d spritesheet (handles "textureRotated" frames).
static UIImage *brew_sprite(NSString *sheet, NSString *frame) {
    static NSMutableDictionary<NSString *, UIImage *> *atlases;
    static NSMutableDictionary<NSString *, NSDictionary *> *plists;
    if (!atlases) { atlases = [NSMutableDictionary dictionary]; plists = [NSMutableDictionary dictionary]; }

    UIImage *atlas = atlases[sheet];
    if (!atlas) {
        atlas = brew_load([sheet stringByAppendingString:@"-hd.png"]);
        if (atlas) atlases[sheet] = atlas;
    }
    NSDictionary *plist = plists[sheet];
    if (!plist) {
        plist = [NSDictionary dictionaryWithContentsOfFile:brew_path([sheet stringByAppendingString:@"-hd.plist"])];
        if (plist) plists[sheet] = plist;
    }
    NSDictionary *f = plist[@"frames"][frame];
    if (!atlas || !f) { NSLog(@"[Brew] missing sprite %@ in %@", frame, sheet); return nil; }

    CGRect r = CGRectFromString(f[@"textureRect"]);        // size = un-rotated sprite size
    BOOL rotated = [f[@"textureRotated"] boolValue];
    CGRect src = rotated ? CGRectMake(r.origin.x, r.origin.y, r.size.height, r.size.width) : r;

    CGImageRef cg = CGImageCreateWithImageInRect(atlas.CGImage, src);
    if (!cg) return nil;
    UIImage *piece = [UIImage imageWithCGImage:cg scale:1 orientation:UIImageOrientationUp];
    CGImageRelease(cg);
    if (!rotated) return brew_hd(piece);

    // Frames are stored rotated 90 degrees clockwise on the sheet: rotate back counter-clockwise.
    UIGraphicsImageRenderer *rd = [[UIGraphicsImageRenderer alloc] initWithSize:r.size format:brew_pixel_format()];
    UIImage *upright = [rd imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef g = ctx.CGContext;
        CGContextTranslateCTM(g, 0, src.size.width);
        CGContextRotateCTM(g, -M_PI_2);
        [piece drawAtPoint:CGPointZero];
    }];
    return brew_hd(upright);
}

// Renders a string with GD's bigFont (bitmap font from the bundle) into one image.
static UIImage *brew_text(NSString *text) {
    static NSDictionary<NSNumber *, NSDictionary *> *glyphs;
    static UIImage *atlas;
    static int lineHeight = 67;
    if (!glyphs) {
        NSString *fnt = [NSString stringWithContentsOfFile:brew_path(@"bigFont-hd.fnt")
                                                  encoding:NSUTF8StringEncoding error:nil];
        atlas = brew_load(@"bigFont-hd.png");
        if (!fnt || !atlas) { NSLog(@"[Brew] bigFont not found"); return nil; }
        NSMutableDictionary *g = [NSMutableDictionary dictionary];
        for (NSString *line in [fnt componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
            BOOL isChar = [line hasPrefix:@"char "], isCommon = [line hasPrefix:@"common "];
            if (!isChar && !isCommon) continue;
            NSMutableDictionary *kv = [NSMutableDictionary dictionary];
            for (NSString *tok in [line componentsSeparatedByString:@" "]) {
                NSRange eq = [tok rangeOfString:@"="];
                if (eq.location == NSNotFound) continue;
                kv[[tok substringToIndex:eq.location]] = @([[tok substringFromIndex:eq.location + 1] intValue]);
            }
            if (isCommon) lineHeight = [kv[@"lineHeight"] intValue];
            else if (kv[@"id"]) g[kv[@"id"]] = kv;
        }
        glyphs = g;
    }

    CGFloat total = 0;
    for (NSUInteger i = 0; i < text.length; i++)
        total += [glyphs[@([text characterAtIndex:i])][@"xadvance"] intValue];

    UIGraphicsImageRenderer *rd = [[UIGraphicsImageRenderer alloc]
        initWithSize:CGSizeMake(MAX(total, 1), lineHeight) format:brew_pixel_format()];
    UIImage *img = [rd imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGFloat cx = 0;
        for (NSUInteger i = 0; i < text.length; i++) {
            NSDictionary *c = glyphs[@([text characterAtIndex:i])];
            if (!c) continue;
            int w = [c[@"width"] intValue], h = [c[@"height"] intValue];
            if (w > 0 && h > 0) {
                CGImageRef cg = CGImageCreateWithImageInRect(atlas.CGImage,
                    CGRectMake([c[@"x"] intValue], [c[@"y"] intValue], w, h));
                if (cg) {
                    UIImage *gi = [UIImage imageWithCGImage:cg scale:1 orientation:UIImageOrientationUp];
                    CGImageRelease(cg);
                    [gi drawAtPoint:CGPointMake(cx + [c[@"xoffset"] intValue], [c[@"yoffset"] intValue])];
                }
            }
            cx += [c[@"xadvance"] intValue];
        }
    }];
    return brew_hd(img);
}

static UIImageView *brew_label(NSString *s, CGFloat k) {
    UIImage *img = brew_text(s);
    UIImageView *iv = [[UIImageView alloc] initWithImage:img];
    iv.frame = CGRectMake(0, 0, img.size.width * k, img.size.height * k);
    return iv;
}

// ---- UI -------------------------------------------------------------------
// Transparent full-window view that only reacts where our own controls are,
// so every other touch still reaches the game underneath.
@interface BrewOverlay : UIView
@end
@implementation BrewOverlay
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    return v == self ? nil : v;
}
@end

@interface BrewUI : NSObject
@property (nonatomic, strong) BrewOverlay *overlay;
@property (nonatomic, strong) UIImageView *button;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIImageView *check;
@property (nonatomic, strong) UIImage *checkOn, *checkOff;
@property (nonatomic, assign) BOOL open;
- (void)installInWindow:(UIWindow *)win;
- (void)bringToFront;
@end

@implementation BrewUI

- (void)installInWindow:(UIWindow *)win {
    self.overlay = [[BrewOverlay alloc] initWithFrame:win.bounds];
    self.overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.overlay.backgroundColor = UIColor.clearColor;
    [win addSubview:self.overlay];

    // --- Brew Menu panel (GJ_square01 is GD's brown popup background) ---
    UIImage *sq = [brew_hd(brew_load(@"GJ_square01-hd.png"))
        resizableImageWithCapInsets:UIEdgeInsetsMake(20, 20, 20, 20) resizingMode:UIImageResizingModeStretch];
    CGSize ps = CGSizeMake(250, 130);
    self.panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, ps.width, ps.height)];
    self.panel.center = CGPointMake(CGRectGetMidX(self.overlay.bounds), CGRectGetMidY(self.overlay.bounds));
    self.panel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                                  UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    self.panel.hidden = YES;
    [self.overlay addSubview:self.panel];

    UIImageView *bg = [[UIImageView alloc] initWithImage:sq];
    bg.frame = self.panel.bounds;
    [self.panel addSubview:bg];

    UIImageView *title = brew_label(@"Brew Menu", 0.85);
    title.center = CGPointMake(ps.width / 2, 32);
    [self.panel addSubview:title];

    // --- Noclip row: checkbox + label ---
    self.checkOn  = brew_sprite(@"GJ_GameSheet03", @"GJ_checkOn_001.png");
    self.checkOff = brew_sprite(@"GJ_GameSheet03", @"GJ_checkOff_001.png");

    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(20, 62, 210, 56)];
    [row addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleNoclip)]];
    [self.panel addSubview:row];

    self.check = [[UIImageView alloc] initWithFrame:CGRectMake(6, 6, 44, 44)];
    self.check.contentMode = UIViewContentModeCenter;     // natural GD size, no stretching
    [row addSubview:self.check];

    UIImageView *label = brew_label(@"Noclip", 0.7);
    CGRect lf = label.frame; lf.origin = CGPointMake(62, (56 - lf.size.height) / 2); label.frame = lf;
    [row addSubview:label];
    [self refreshCheck];

    // --- Draggable button: GD's green circle button with the thumbs-up ---
    UIImage *like = brew_sprite(@"GJ_GameSheet03", @"GJ_likeBtn_001.png");
    self.button = [[UIImageView alloc] initWithImage:like];
    self.button.frame = CGRectMake(0, 0, 58, 58);
    self.button.center = CGPointMake(win.safeAreaInsets.left + 44, 110);
    self.button.userInteractionEnabled = YES;
    [self.button addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)]];
    [self.button addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapButton)]];
    [self.overlay addSubview:self.button];        // added last = drawn above the panel
}

- (void)bringToFront {
    [self.overlay.superview bringSubviewToFront:self.overlay];
}

- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view, *host = v.superview;
    CGPoint t = [g translationInView:host];
    CGFloat hw = v.bounds.size.width / 2, hh = v.bounds.size.height / 2;
    CGPoint c = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    c.x = MAX(hw, MIN(host.bounds.size.width - hw, c.x));
    c.y = MAX(hh, MIN(host.bounds.size.height - hh, c.y));
    v.center = c;
    [g setTranslation:CGPointZero inView:host];
}

- (void)tapButton {
    [UIView animateWithDuration:0.06 animations:^{
        self.button.transform = CGAffineTransformMakeScale(1.2, 1.2);
    } completion:^(BOOL f) {
        [UIView animateWithDuration:0.08 animations:^{ self.button.transform = CGAffineTransformIdentity; }];
    }];
    [self toggleMenu];
}

- (void)toggleMenu {
    self.open = !self.open;
    if (self.open) {
        self.panel.hidden = NO;
        self.panel.alpha = 0;
        self.panel.transform = CGAffineTransformMakeScale(0.6, 0.6);
        [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.6 initialSpringVelocity:0
                            options:0 animations:^{
            self.panel.alpha = 1;
            self.panel.transform = CGAffineTransformIdentity;
        } completion:nil];
    } else {
        [UIView animateWithDuration:0.12 animations:^{
            self.panel.alpha = 0;
            self.panel.transform = CGAffineTransformMakeScale(0.8, 0.8);
        } completion:^(BOOL f) {
            if (!self.open) { self.panel.hidden = YES; self.panel.transform = CGAffineTransformIdentity; }
        }];
    }
}

- (void)toggleNoclip {
    bool v = !g_noclip.load();
    g_noclip.store(v);
    [[NSUserDefaults standardUserDefaults] setBool:v forKey:kNoclipKey];
    [self refreshCheck];
    NSLog(@"[Brew] noclip %@", v ? @"ON" : @"OFF");
}

- (void)refreshCheck {
    self.check.image = g_noclip.load() ? self.checkOn : self.checkOff;
}

@end

// ---- UI installation ------------------------------------------------------
static BrewUI *g_ui = nil;

static UIWindow *brew_key_window() {
    UIApplication *app = UIApplication.sharedApplication;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *w in app.windows) if (w.isKeyWindow) return w;
#pragma clang diagnostic pop
    for (UIScene *s in app.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) return w;
    }
    return nil;
}

// GD builds its window/view a moment after launch, so retry until it's ready.
static void brew_try_install(int attempt) {
    if (g_ui) return;
    UIWindow *win = brew_key_window();
    if (!win || !win.rootViewController) {
        if (attempt < 60) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ brew_try_install(attempt + 1); });
        } else {
            NSLog(@"[Brew] gave up waiting for the game window");
        }
        return;
    }
    g_ui = [[BrewUI alloc] init];
    [g_ui installInWindow:win];
    NSLog(@"[Brew] UI installed");

    // If the game adds views later, make sure our overlay stays on top.
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil queue:NSOperationQueue.mainQueue
                                                  usingBlock:^(NSNotification *n) { [g_ui bringToFront]; }];
}

// ---- Entry point ----------------------------------------------------------
__attribute__((constructor))
static void brew_init() {
    g_slide = _dyld_get_image_vmaddr_slide(0);   // image 0 is the main executable (GeometryJump)
    NSLog(@"[Brew] loaded. slide = 0x%lx", (unsigned long)g_slide);
    g_noclip.store([[NSUserDefaults standardUserDefaults] boolForKey:kNoclipKey]);
    brew_install_hooks();
    dispatch_async(dispatch_get_main_queue(), ^{ brew_try_install(0); });
}
