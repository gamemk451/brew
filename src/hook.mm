// Brew - hook.dylib for Geometry Dash 2.207 (iOS, arm64)
// Adds a draggable Brew button (GD's green thumbs-up circle) that opens a "Brew Menu" with a
// Noclip checkbox. All art comes from the game's own sprite sheets and bitmap font in the app bundle.
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <stdint.h>
#include <string.h>

// ---------------------------------------------------------------------------
// Noclip flag. tools/noclip_patch.py writes a small header into the end of the
// __TEXT segment that tells us where the flag byte lives. No header = no patch.
// ---------------------------------------------------------------------------
static volatile uint8_t *g_noclipFlag = NULL;

static void brew_find_noclip_flag(void) {
    const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(0);
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    if (!mh || mh->magic != MH_MAGIC_64) return;
    uint64_t textEnd = 0, dataStart = 0, dataEnd = 0;
    const uint8_t *p = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)p;
            if (strncmp(seg->segname, "__TEXT", 16) == 0) {
                textEnd = seg->vmaddr + seg->vmsize;
            } else if (strncmp(seg->segname, "__DATA", 16) == 0) {
                dataStart = seg->vmaddr;
                dataEnd = seg->vmaddr + seg->vmsize;
            }
        }
        p += lc->cmdsize;
    }
    if (!textEnd || !dataEnd) return;
    const uint32_t *hdr = (const uint32_t *)(uintptr_t)(textEnd - 0x40 + slide);
    if (hdr[0] != 0x57455242u) return;                 // "BREW" (little-endian)
    uint64_t flagVm;
    memcpy(&flagVm, hdr + 2, sizeof(flagVm));
    if (flagVm < dataStart || flagVm >= dataEnd) return;
    g_noclipFlag = (volatile uint8_t *)(uintptr_t)(flagVm + slide);
}

// ---------------------------------------------------------------------------
// GD art helpers
// ---------------------------------------------------------------------------
static UIImage *BrewLoad(NSString *name) {
    NSString *path = [[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:name];
    return [UIImage imageWithContentsOfFile:path];
}

// Copies a pixel rectangle out of an image (src must have scale 1).
static UIImage *BrewCrop(UIImage *src, CGRect r) {
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 1.0;
    fmt.opaque = NO;
    UIGraphicsImageRenderer *rd = [[UIGraphicsImageRenderer alloc] initWithSize:r.size format:fmt];
    return [rd imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [src drawAtPoint:CGPointMake(-r.origin.x, -r.origin.y)];
    }];
}

static NSDictionary *g_frames;
static UIImage *g_sheet;

// A sprite frame from GJ_GameSheet03-hd (the "-hd" art is 2x, so points = pixels / 2).
static UIImage *BrewFrame(NSString *name) {
    if (!g_frames) {
        NSString *plist = [[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:@"GJ_GameSheet03-hd.plist"];
        g_frames = [NSDictionary dictionaryWithContentsOfFile:plist][@"frames"];
        g_sheet = BrewLoad(@"GJ_GameSheet03-hd.png");
    }
    NSDictionary *f = g_frames[name];
    if (!f || !g_sheet) return nil;
    CGRect r = CGRectFromString(f[@"textureRect"]);
    BOOL rotated = [f[@"textureRotated"] boolValue];
    CGRect srcRect = rotated ? CGRectMake(r.origin.x, r.origin.y, r.size.height, r.size.width) : r;
    UIImage *crop = BrewCrop(g_sheet, srcRect);
    return [UIImage imageWithCGImage:crop.CGImage scale:2.0
                         orientation:(rotated ? UIImageOrientationLeft : UIImageOrientationUp)];
}

// GD's bigFont bitmap font (BMFont text format).
static UIImage *g_fontAtlas;
static NSMutableDictionary<NSNumber *, NSDictionary *> *g_glyphs;
static NSMutableDictionary<NSString *, NSNumber *> *g_kern;
static int g_lineH;

static int BrewField(NSString *line, NSString *key) {
    NSRange r = [line rangeOfString:[key stringByAppendingString:@"="]];
    if (r.location == NSNotFound) return 0;
    NSScanner *sc = [NSScanner scannerWithString:[line substringFromIndex:NSMaxRange(r)]];
    NSInteger v = 0;
    [sc scanInteger:&v];
    return (int)v;
}

static void BrewLoadFont(void) {
    if (g_fontAtlas) return;
    NSString *path = [[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:@"bigFont-hd.fnt"];
    NSString *txt = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    UIImage *atlas = BrewLoad(@"bigFont-hd.png");
    if (!txt || !atlas) return;
    g_glyphs = [NSMutableDictionary dictionary];
    g_kern = [NSMutableDictionary dictionary];
    for (NSString *line in [txt componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"common "]) {
            g_lineH = BrewField(line, @"lineHeight");
        } else if ([line hasPrefix:@"char "]) {
            g_glyphs[@(BrewField(line, @"id"))] = @{
                @"x": @(BrewField(line, @"x")), @"y": @(BrewField(line, @"y")),
                @"w": @(BrewField(line, @"width")), @"h": @(BrewField(line, @"height")),
                @"xo": @(BrewField(line, @"xoffset")), @"yo": @(BrewField(line, @"yoffset")),
                @"xa": @(BrewField(line, @"xadvance")) };
        } else if ([line hasPrefix:@"kerning "]) {
            NSString *k = [NSString stringWithFormat:@"%d,%d", BrewField(line, @"first"), BrewField(line, @"second")];
            g_kern[k] = @(BrewField(line, @"amount"));
        }
    }
    g_fontAtlas = atlas;
}

// Renders text in GD's font. factor 1.0 = the font's native hd size (67px line = 33.5pt).
static UIImage *BrewText(NSString *s, CGFloat factor) {
    BrewLoadFont();
    if (!g_fontAtlas) return nil;
    NSMutableArray *items = [NSMutableArray array];
    int x = 0, prev = -1;
    for (NSUInteger i = 0; i < s.length; i++) {
        int c = (int)[s characterAtIndex:i];
        NSDictionary *g = g_glyphs[@(c)];
        if (!g) continue;
        if (prev >= 0) x += [g_kern[[NSString stringWithFormat:@"%d,%d", prev, c]] intValue];
        [items addObject:@[g, @(x)]];
        x += [g[@"xa"] intValue];
        prev = c;
    }
    CGFloat pad = 6;
    CGSize size = CGSizeMake(x + pad * 2, g_lineH + pad * 2);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 1.0;
    fmt.opaque = NO;
    UIGraphicsImageRenderer *rd = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
    UIImage *img = [rd imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        for (NSArray *it in items) {
            NSDictionary *g = it[0];
            CGRect r = CGRectMake([g[@"x"] intValue], [g[@"y"] intValue], [g[@"w"] intValue], [g[@"h"] intValue]);
            if (r.size.width <= 0 || r.size.height <= 0) continue;
            [BrewCrop(g_fontAtlas, r) drawAtPoint:CGPointMake(pad + [it[1] intValue] + [g[@"xo"] intValue],
                                                              pad + [g[@"yo"] intValue])];
        }
    }];
    return [UIImage imageWithCGImage:img.CGImage scale:(2.0 / factor) orientation:UIImageOrientationUp];
}

// ---------------------------------------------------------------------------
// Brew UI
// ---------------------------------------------------------------------------
static NSString *const kNoclipKey = @"brew.noclip";

@interface BrewUI : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)install;
@end

@implementation BrewUI {
    UIWindow *_window;
    UIButton *_fab;
    UIView *_overlay;
    UIView *_wrap;
    UIButton *_check;
    UIImage *_checkOn, *_checkOff;
    BOOL _noclip;
    int _tries;
}

+ (instancetype)shared {
    static BrewUI *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [BrewUI new]; });
    return s;
}

- (UIWindow *)findWindow {
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if ([sc isKindOfClass:[UIWindowScene class]]) {
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (w.isKeyWindow) return w;
            }
        }
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

- (void)install {
    if (_fab) return;
    _window = [self findWindow];
    UIImage *like = BrewFrame(@"GJ_likeBtn_001.png");
    if (!_window || !like) {
        if (++_tries < 20) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self install]; });
        }
        return;
    }
    _noclip = [[NSUserDefaults standardUserDefaults] boolForKey:kNoclipKey];
    if (g_noclipFlag) *g_noclipFlag = _noclip ? 1 : 0;

    _fab = [UIButton buttonWithType:UIButtonTypeCustom];
    [_fab setImage:like forState:UIControlStateNormal];
    UIEdgeInsets sa = _window.safeAreaInsets;
    _fab.frame = CGRectMake(sa.left + 16, sa.top + 56, like.size.width, like.size.height);
    _fab.accessibilityLabel = @"Brew menu";
    [_fab addTarget:self action:@selector(fabTapped) forControlEvents:UIControlEventTouchUpInside];
    [_fab addTarget:self action:@selector(fabDown) forControlEvents:UIControlEventTouchDown];
    [_fab addTarget:self action:@selector(fabUp) forControlEvents:(UIControlEventTouchUpOutside | UIControlEventTouchCancel)];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
    [_fab addGestureRecognizer:pan];
    [_window addSubview:_fab];
}

- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    UIView *sv = v.superview;
    CGPoint t = [g translationInView:sv];
    UIEdgeInsets sa = sv.safeAreaInsets;
    CGFloat hw = v.bounds.size.width / 2, hh = v.bounds.size.height / 2;
    CGPoint c = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    c.x = MIN(MAX(c.x, sa.left + hw), sv.bounds.size.width - sa.right - hw);
    c.y = MIN(MAX(c.y, sa.top + hh), sv.bounds.size.height - sa.bottom - hh);
    v.center = c;
    [g setTranslation:CGPointZero inView:sv];
}

- (void)fabDown {
    [UIView animateWithDuration:0.08 animations:^{ self->_fab.transform = CGAffineTransformMakeScale(0.9, 0.9); }];
}

- (void)fabUp {
    [UIView animateWithDuration:0.12 animations:^{ self->_fab.transform = CGAffineTransformIdentity; }];
}

- (void)fabTapped {
    [self fabUp];
    [self openMenu];
}

- (void)openMenu {
    if (_overlay || !_window) return;
    _checkOn = BrewFrame(@"GJ_checkOn_001.png");
    _checkOff = BrewFrame(@"GJ_checkOff_001.png");
    UIImage *closeImg = BrewFrame(@"GJ_closeBtn_001.png");
    UIImage *panelRaw = BrewLoad(@"GJ_square01-hd.png");
    UIImage *panel = nil;
    if (panelRaw) {
        panel = [UIImage imageWithCGImage:panelRaw.CGImage scale:2.0 orientation:UIImageOrientationUp];
        panel = [panel resizableImageWithCapInsets:UIEdgeInsetsMake(22, 22, 22, 22) resizingMode:UIImageResizingModeStretch];
    }

    _overlay = [[UIView alloc] initWithFrame:_window.bounds];
    _overlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(closeMenu)];
    tap.delegate = self;
    [_overlay addGestureRecognizer:tap];

    CGFloat bw = 300, bh = 180, m = 20;
    _wrap = [[UIView alloc] initWithFrame:CGRectMake(0, 0, bw + m * 2, bh + m * 2)];
    _wrap.center = CGPointMake(_overlay.bounds.size.width / 2, _overlay.bounds.size.height / 2);
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(m, m, bw, bh)];
    UIImageView *bg = [[UIImageView alloc] initWithImage:panel];
    bg.frame = box.bounds;
    [box addSubview:bg];

    UIImage *titleImg = BrewText(@"Brew Menu", 0.9);
    if (titleImg) {
        UIImageView *t = [[UIImageView alloc] initWithImage:titleImg];
        t.center = CGPointMake(bw / 2, 14 + titleImg.size.height / 2);
        [box addSubview:t];
    }
    UIImage *labelImg = BrewText(@"Noclip", 0.7);
    if (labelImg) {
        UIImageView *l = [[UIImageView alloc] initWithImage:labelImg];
        l.center = CGPointMake(28 + labelImg.size.width / 2, 104);
        [box addSubview:l];
    }
    _check = [UIButton buttonWithType:UIButtonTypeCustom];
    _check.frame = CGRectMake(0, 0, 44, 44);
    _check.center = CGPointMake(bw - 28 - 22, 104);
    _check.accessibilityLabel = @"Noclip";
    [_check addTarget:self action:@selector(toggleNoclip) forControlEvents:UIControlEventTouchUpInside];
    [self refreshCheck];
    [box addSubview:_check];
    [_wrap addSubview:box];

    if (closeImg) {
        UIButton *x = [UIButton buttonWithType:UIButtonTypeCustom];
        [x setImage:closeImg forState:UIControlStateNormal];
        x.frame = CGRectMake(0, 0, closeImg.size.width, closeImg.size.height);
        x.accessibilityLabel = @"Close";
        [x addTarget:self action:@selector(closeMenu) forControlEvents:UIControlEventTouchUpInside];
        [_wrap addSubview:x];
    }
    [_overlay addSubview:_wrap];
    [_window addSubview:_overlay];

    _overlay.alpha = 0;
    _wrap.transform = CGAffineTransformMakeScale(0.7, 0.7);
    [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0
                        options:0 animations:^{
        self->_overlay.alpha = 1;
        self->_wrap.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t {
    return t.view == _overlay;      // taps on the dim area close the menu, taps on the panel don't
}

- (void)closeMenu {
    UIView *o = _overlay;
    if (!o) return;
    _overlay = nil;
    _wrap = nil;
    _check = nil;
    [UIView animateWithDuration:0.15 animations:^{ o.alpha = 0; } completion:^(BOOL done) { [o removeFromSuperview]; }];
}

- (void)refreshCheck {
    [_check setImage:(_noclip ? _checkOn : _checkOff) forState:UIControlStateNormal];
}

- (void)toggleNoclip {
    if (!g_noclipFlag) {
        [self showNotPatched];
        return;
    }
    _noclip = !_noclip;
    *g_noclipFlag = _noclip ? 1 : 0;
    [[NSUserDefaults standardUserDefaults] setBool:_noclip forKey:kNoclipKey];
    [self refreshCheck];
}

- (void)showNotPatched {
    UIViewController *vc = _window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if (!vc) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Noclip isn’t set up"
        message:@"This build wasn’t patched with a Noclip address yet. See the README."
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [vc presentViewController:a animated:YES completion:nil];
}

@end

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------
__attribute__((constructor))
static void brew_init(void) {
    brew_find_noclip_flag();
    NSLog(@"[Brew] loaded. noclip patch: %@", g_noclipFlag ? @"present" : @"absent");
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [[BrewUI shared] install]; });
    }];
}
