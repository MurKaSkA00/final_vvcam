Перед билдом подними версию в control: Version: 1.7.9.

1) Tweak.x — фикс рекурсии в свизле делегата
// =============================================================================
// MediaPlaybackUtils — Tweak.x  (v1.7.9)
// FIX 6 (v1.7.9):
//   - setSampleBufferDelegate: больше не делает method_setImplementation на
//     Method, который может быть унаследован от суперкласса (раньше это
//     ломало все классы-наследники и приводило к stack overflow при втором
//     открытии камеры в Instagram/Snapchat/TikTok/Tinder/KYC-сканерах).
//     Вместо этого используется class_addMethod / class_replaceMethod
//     ПО КЛАССУ делегата с трекингом через _mpu_globalHookedClasses.
// =============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <notify.h>
#import "SharedState.h"
#import "_MPUMediaBufferAdapter.h"

#define MPU_BUNDLE_ID  @"com.proximacore.mediaplaybackutils"
#define MPU_NOTIF_NAME CFSTR("com.proximacore.mpu/cfg")
#define MPU_LOG(fmt, ...) NSLog(@"[MPU] " fmt, ##__VA_ARGS__)

static NSString *_url = nil;
static BOOL _isSwitching = NO;

static CIContext *_v_ciContext = nil;
static dispatch_queue_t _v_streamQueue = NULL;
static BOOL _v_streamRunning = NO;
static _MPUMediaBufferAdapter *_v_adapter = nil;

static void _v_init(void);
static void _v_loadPrefs(void);
static void _v_startStreamIfNeeded(void);
static void _v_stopStream(void);
static void _v_restartStreamIfNeeded(void);
static CMSampleBufferRef _v_makeReplacementSampleBuffer(CMSampleBufferRef original);

static NSDictionary *_v_readPrefsDict(void) {
    NSArray *paths = @[
        @"/var/mobile/Library/Preferences/com.proximacore.mediaplaybackutils.plist",
        @"/var/jb/var/mobile/Library/Preferences/com.proximacore.mediaplaybackutils.plist",
        @"/private/var/mobile/Library/Preferences/com.proximacore.mediaplaybackutils.plist",
    ];
    for (NSString *p in paths) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (d.count > 0) return d;
    }
    NSMutableDictionary *m = [NSMutableDictionary new];
    CFPropertyListRef enRef  = CFPreferencesCopyAppValue(CFSTR("enabled"),
                                  (__bridge CFStringRef)MPU_BUNDLE_ID);
    CFPropertyListRef urlRef = CFPreferencesCopyAppValue(CFSTR("rtspURL"),
                                  (__bridge CFStringRef)MPU_BUNDLE_ID);
    if (enRef)  { m[@"enabled"] = (__bridge id)enRef;  CFRelease(enRef); }
    if (urlRef) { m[@"rtspURL"] = (__bridge id)urlRef; CFRelease(urlRef); }
    return m.count ? m : nil;
}

static void _v_loadPrefs(void) {
    NSDictionary *d = _v_readPrefsDict();
    _enabled = [d[@"enabled"] boolValue];
    NSString *raw = nil;
    id rawObj = d[@"rtspURL"];
    if ([rawObj isKindOfClass:[NSString class]]) raw = (NSString *)rawObj;
    NSString *trimmed = [raw stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *newURL = (trimmed.length > 0) ? [trimmed copy] : @"";

    BOOL urlChanged = ![newURL isEqualToString:_url ?: @""];
    _url = newURL;
    MPU_LOG(@"prefs loaded: enabled=%d url='%@'", _enabled, _url);

    if (_enabled && _url.length > 0) {
        if (urlChanged) _v_restartStreamIfNeeded();
        else _v_startStreamIfNeeded();
    } else {
        _v_stopStream();
    }
}

static void _v_prefsChangedCallback(CFNotificationCenterRef center, void *observer,
                                    CFNotificationName name, const void *object,
                                    CFDictionaryRef userInfo) {
    _v_loadPrefs();
}

static void _v_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!_v_lock) _v_lock = [NSObject new];
        if (!_mpu_globalHookedClasses) {
            _mpu_globalHookedClasses = [NSMutableSet new];
            _mpu_globalHookedLock    = [NSObject new];
        }
        _v_ciContext = [CIContext contextWithOptions:nil];
        _v_streamQueue = dispatch_queue_create("com.mpu.stream", DISPATCH_QUEUE_SERIAL);

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, _v_prefsChangedCallback, MPU_NOTIF_NAME, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        _v_loadPrefs();
        MPU_LOG(@"initialized");
    });
}

static void _v_startStreamIfNeeded(void) {
    if (_v_streamRunning) return;
    if (_url.length == 0) return;

    dispatch_async(_v_streamQueue, ^{
        if (_v_streamRunning) return;
        NSURL *u = [NSURL URLWithString:_url];
        if (!u) return;

        _v_streamRunning = YES;

        if (_v_adapter) { [_v_adapter stopStreaming]; _v_adapter = nil; }
        _v_adapter = [[_MPUMediaBufferAdapter alloc] initWithURL:u];
        _v_adapter.pixelBufferCallback = ^(CVPixelBufferRef pb) {
            if (!pb) return;
            @synchronized(_v_lock) {
                if (_lastBuffer) CVPixelBufferRelease(_lastBuffer);
                _lastBuffer = (CVPixelBufferRef)CFRetain(pb);
                _lastBufferTime = CACurrentMediaTime();
                _isSwitching = NO;
            }
        };
        _v_adapter.errorCallback = ^(NSError *err) {
            MPU_LOG(@"adapter error: %@", err.localizedDescription);
        };
        [_v_adapter startStreaming];
        MPU_LOG(@"stream started via adapter: %@", _url);
    });
}

static void _v_stopStream(void) {
    if (_v_adapter) { [_v_adapter stopStreaming]; _v_adapter = nil; }
    _v_streamRunning = NO;
    @synchronized(_v_lock) {
        if (_lastBuffer) { CVPixelBufferRelease(_lastBuffer); _lastBuffer = NULL; }
        _lastBufferTime = 0;
    }
}

static void _v_restartStreamIfNeeded(void) {
    _v_stopStream();
    _v_startStreamIfNeeded();
}

static CMSampleBufferRef _v_makeReplacementSampleBuffer(CMSampleBufferRef original) {
    if (!original) return NULL;
    CVPixelBufferRef src = NULL;
    @synchronized(_v_lock) {
        if (_lastBuffer) src = CVPixelBufferRetain(_lastBuffer);
    }
    if (!src) return NULL;

    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, src, &fmt) != noErr || !fmt) {
        CVPixelBufferRelease(src);
        return NULL;
    }
    CMSampleTimingInfo timing = kCMTimingInfoInvalid;
    CMSampleBufferGetSampleTimingInfo(original, 0, &timing);
    if (CMTIME_IS_INVALID(timing.presentationTimeStamp)) {
        timing.presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000);
        timing.duration = CMTimeMake(1, 30);
        timing.decodeTimeStamp = kCMTimeInvalid;
    }
    CMSampleBufferRef out = NULL;
    OSStatus s = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, src, true, NULL, NULL,
                                                    fmt, &timing, &out);
    CFRelease(fmt);
    CVPixelBufferRelease(src);
    if (s != noErr || !out) return NULL;
    return out;
}

static BOOL _v_shouldRunInThisProcess(void) {
    NSString *bid  = [[NSBundle mainBundle] bundleIdentifier];
    NSString *path = [[NSBundle mainBundle] bundlePath];
    if (!bid) return NO;
    if ([bid hasPrefix:@"com.apple.springboard"]) return NO;
    if ([bid hasPrefix:@"com.apple.mediaserverd"]) return NO;
    if ([bid hasPrefix:@"com.apple.assetsd"])      return NO;
    if ([bid hasPrefix:@"com.apple.cameracaptured"]) return NO;
    if ([bid hasPrefix:@"com.apple.WebKit"])       return NO;
    if ([path hasPrefix:@"/usr/"])                 return NO;
    return YES;
}

// ── FIX 6: безопасный хук делегата AVCaptureVideoDataOutput по классу ────────
static void _v_hookDelegateClass(Class cls) {
    if (!cls) return;
    NSString *cn = NSStringFromClass(cls);
    if (!cn) return;

    @synchronized(_mpu_globalHookedLock) {
        if ([_mpu_globalHookedClasses containsObject:cn]) return;
    }

    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    const char *types = method_getTypeEncoding(m);
    // capturedIMP — это либо собственная IMP класса, либо унаследованная
    // от суперкласса (legit case). Захватываем ДО class_addMethod.
    __block IMP capturedIMP = method_getImplementation(m);

    IMP newIMP = imp_implementationWithBlock(
        ^(id self_, AVCaptureOutput *output, CMSampleBufferRef sb, AVCaptureConnection *conn) {
            CMSampleBufferRef rep = (_enabled && sb && _url.length > 0)
                ? _v_makeReplacementSampleBuffer(sb) : NULL;
            CMSampleBufferRef use = rep ?: sb;
            ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))
                capturedIMP)(self_, sel, output, use, conn);
            if (rep) CFRelease(rep);
        });

    // 1) если у класса НЕТ собственной реализации (унаследована) — add
    //    добавляет наш IMP, capturedIMP уже корректно указывает на super.
    // 2) если есть собственная — replace вернёт её, и мы её сохраним.
    BOOL added = class_addMethod(cls, sel, newIMP, types);
    if (!added) {
        IMP prev = class_replaceMethod(cls, sel, newIMP, types);
        if (prev) capturedIMP = prev;
    }

    @synchronized(_mpu_globalHookedLock) {
        [_mpu_globalHookedClasses addObject:cn];
    }
    MPU_LOG(@"hooked delegate class: %@", cn);
}

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id)delegate
                          queue:(dispatch_queue_t)queue {
    if (!delegate) { %orig; return; }
    _v_init();
    _v_hookDelegateClass(object_getClass(delegate));
    %orig;
}

%end

%hook AVCaptureVideoPreviewLayer

- (void)layoutSublayers {
    %orig;
    if (!_enabled) return;
    if (_url.length == 0) return;
    _v_init();

    CALayer *overlay = objc_getAssociatedObject(self, "_v_overlay");
    if (!overlay) {
        overlay = [CALayer layer];
        overlay.contentsGravity = kCAGravityResizeAspectFill;
        overlay.zPosition = 999999;
        overlay.backgroundColor = [UIColor clearColor].CGColor;
        overlay.opaque = NO;
        overlay.hidden = YES;
        [self addSublayer:overlay];
        objc_setAssociatedObject(self, "_v_overlay", overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        CADisplayLink *dl = [CADisplayLink displayLinkWithTarget:self
                                                        selector:@selector(_mpu_updateOverlay:)];
        dl.preferredFramesPerSecond = 30;
        [dl addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        objc_setAssociatedObject(self, "_v_displayLink", dl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    overlay.frame = self.bounds;
    [CATransaction commit];
}

%new
- (void)_mpu_updateOverlay:(CADisplayLink *)sender {
    if (!_enabled) return;
    CALayer *overlay = objc_getAssociatedObject(self, "_v_overlay");
    if (!overlay) return;

    CVPixelBufferRef bufCopy = NULL;
    CFTimeInterval bufTime = 0;
    BOOL switching;
    @synchronized(_v_lock) {
        if (_lastBuffer) bufCopy = CVPixelBufferRetain(_lastBuffer);
        bufTime = _lastBufferTime;
        switching = _isSwitching;
    }

    if (!bufCopy) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        overlay.contents = nil;
        overlay.hidden = YES;
        overlay.opacity = 0.0;
        [CATransaction commit];
        return;
    }

    CFTimeInterval age = CACurrentMediaTime() - bufTime;
    if (!switching && bufTime > 0 && age > 10.0) {
        _isSwitching = YES;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            _v_restartStreamIfNeeded();
        });
    }

    IOSurfaceRef surf = CVPixelBufferGetIOSurface(bufCopy);
    if (surf) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        overlay.contents = (__bridge id)surf;
        overlay.frame = self.bounds;
        overlay.hidden = NO;
        overlay.opacity = 1.0;
        overlay.opaque = YES;
        [CATransaction commit];
        CVPixelBufferRelease(bufCopy);
        return;
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        CIImage *ci = [CIImage imageWithCVPixelBuffer:bufCopy];
        if (ci && _v_ciContext) {
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            CGImageRef cg = [_v_ciContext createCGImage:ci fromRect:ci.extent
                                                  format:kCIFormatBGRA8 colorSpace:cs];
            CGColorSpaceRelease(cs);
            if (cg) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [CATransaction begin];
                    [CATransaction setDisableActions:YES];
                    overlay.contents = (__bridge id)cg;
                    overlay.frame = self.bounds;
                    overlay.hidden = NO;
                    overlay.opacity = 1.0;
                    overlay.opaque = YES;
                    [CATransaction commit];
                    CGImageRelease(cg);
                });
            }
        }
        CVPixelBufferRelease(bufCopy);
    });
}

%end

%hook AVSampleBufferDisplayLayer

- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!_enabled || !sampleBuffer) { %orig; return; }
    if (_url.length == 0) { %orig; return; }
    _v_init();
    CMSampleBufferRef rep = _v_makeReplacementSampleBuffer(sampleBuffer);
    if (rep) {
        %orig(rep);
        CFRelease(rep);
        return;
    }
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        if (!_v_shouldRunInThisProcess()) return;
        _v_init();
        %init;
    }
}
2) StealthHooks.x — кеш фильтра + notifications вместо ребилда на каждом вызове
// StealthHooks.x - MediaPlaybackUtils v1.7.9
// FIX 6 (v1.7.9):
//   - _stealth_rebuild_filter() больше НЕ зовётся на каждый dyld-вызов.
//     Раньше O(images × calls × substrings) вешало watchdog на старте
//     Instagram/банков/Snapchat. Теперь фильтр инвалидируется только
//     через _dyld_register_func_for_add_image / _remove_image и
//     перестраивается лениво при первом обращении (атомарный флаг).
//   - Снят os_unfair_lock из горячего пути — заменён на atomic load.

#import <Foundation/Foundation.h>
#import <substrate.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <string.h>
#import <mach/mach.h>
#import <stdatomic.h>
#import <os/lock.h>

static BOOL _stealth_is_trusted(void) {
    static BOOL trusted = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (!bid) return;
        NSArray *whitelist = @[
            @"org.coolstar.SileoStore",
            @"com.silverhawkx.sileo",
            @"xyz.willy.Zebra",
            @"com.tigisoftware.Filza",
            @"com.sparklabs.Installer",
            @"cool.palera1n",
            @"com.opa334.TrollStore",
            @"com.opa334.TrollStorePersistenceHelper",
        ];
        for (NSString *w in whitelist) {
            if ([bid hasPrefix:w] || [bid isEqualToString:w]) {
                trusted = YES; return;
            }
        }
        NSString *path = [[NSBundle mainBundle] bundlePath];
        if ([path hasPrefix:@"/var/jb/"]) trusted = YES;
    });
    return trusted;
}

static BOOL _stealth_should_hide_image(const char *name) {
    if (!name) return NO;
    if (strstr(name, "MediaPlaybackUtils")) return YES;
    if (strstr(name, "MobileSubstrate"))    return YES;
    if (strstr(name, "libsubstrate"))       return YES;
    if (strstr(name, "libhooker"))          return YES;
    if (strstr(name, "libellekit"))         return YES;
    if (strstr(name, "Substitute"))         return YES;
    if (strstr(name, "TweakInject"))        return YES;
    if (strstr(name, "ChOma"))              return YES;
    if (strstr(name, "WebRTCHooks"))        return YES;
    if (strstr(name, "PhotoCaptureHooks"))  return YES;
    if (strstr(name, "AntifraudHooks"))     return YES;
    if (strstr(name, "StealthHooks"))       return YES;
    if (strstr(name, "JailbreakBypass"))    return YES;
    return NO;
}

static uint32_t (*orig_dyld_image_count)(void);
static const char *(*orig_dyld_get_image_name)(uint32_t);
static const struct mach_header *(*orig_dyld_get_image_header)(uint32_t);
static intptr_t (*orig_dyld_get_image_vmaddr_slide)(uint32_t);

#define MPU_MAX_IMAGES 4096
static uint32_t _filtered_to_real[MPU_MAX_IMAGES];
static uint32_t _filtered_count = 0;

static atomic_bool _filter_dirty = ATOMIC_VAR_INIT(true);
static os_unfair_lock _filter_rebuild_lock = OS_UNFAIR_LOCK_INIT;

static void _stealth_rebuild_locked(void) {
    uint32_t real = orig_dyld_image_count();
    uint32_t fc = 0;
    for (uint32_t i = 0; i < real && fc < MPU_MAX_IMAGES; i++) {
        const char *n = orig_dyld_get_image_name(i);
        if (!_stealth_should_hide_image(n))
            _filtered_to_real[fc++] = i;
    }
    _filtered_count = fc;
}

static inline void _stealth_ensure_filter(void) {
    if (!atomic_load_explicit(&_filter_dirty, memory_order_acquire)) return;
    os_unfair_lock_lock(&_filter_rebuild_lock);
    if (atomic_load_explicit(&_filter_dirty, memory_order_acquire)) {
        _stealth_rebuild_locked();
        atomic_store_explicit(&_filter_dirty, false, memory_order_release);
    }
    os_unfair_lock_unlock(&_filter_rebuild_lock);
}

// dyld callbacks — инвалидируют кеш при загрузке/выгрузке образа
static void _stealth_image_added(const struct mach_header *mh, intptr_t slide) {
    (void)mh; (void)slide;
    atomic_store_explicit(&_filter_dirty, true, memory_order_release);
}
static void _stealth_image_removed(const struct mach_header *mh, intptr_t slide) {
    (void)mh; (void)slide;
    atomic_store_explicit(&_filter_dirty, true, memory_order_release);
}

static uint32_t hook_dyld_image_count(void) {
    if (_stealth_is_trusted()) return orig_dyld_image_count();
    _stealth_ensure_filter();
    return _filtered_count;
}

static const char *hook_dyld_get_image_name(uint32_t idx) {
    if (_stealth_is_trusted()) return orig_dyld_get_image_name(idx);
    _stealth_ensure_filter();
    if (idx >= _filtered_count) return NULL;
    return orig_dyld_get_image_name(_filtered_to_real[idx]);
}

static const struct mach_header *hook_dyld_get_image_header(uint32_t idx) {
    if (_stealth_is_trusted()) return orig_dyld_get_image_header(idx);
    _stealth_ensure_filter();
    if (idx >= _filtered_count) return NULL;
    return orig_dyld_get_image_header(_filtered_to_real[idx]);
}

static intptr_t hook_dyld_get_image_vmaddr_slide(uint32_t idx) {
    if (_stealth_is_trusted()) return orig_dyld_get_image_vmaddr_slide(idx);
    _stealth_ensure_filter();
    if (idx >= _filtered_count) return 0;
    return orig_dyld_get_image_vmaddr_slide(_filtered_to_real[idx]);
}

static int (*orig_dladdr)(const void *, Dl_info *);
static int hook_dladdr(const void *addr, Dl_info *info) {
    int r = orig_dladdr(addr, info);
    if (_stealth_is_trusted()) return r;
    if (r && info && info->dli_fname && _stealth_should_hide_image(info->dli_fname)) {
        info->dli_fname = "/System/Library/Frameworks/AVFoundation.framework/AVFoundation";
        info->dli_sname = NULL;
        info->dli_saddr = NULL;
    }
    return r;
}

%hook NSString
+ (instancetype)stringWithContentsOfFile:(NSString *)path
                                encoding:(NSStringEncoding)enc
                                   error:(NSError **)err {
    if (!_stealth_is_trusted() && path) {
        if ([path containsString:@"MediaPlaybackUtils"] ||
            [path containsString:@"proximacore"] ||
            ([path containsString:@"MobileSubstrate"] &&
             ![path containsString:@"dpkg"])) {
            if (err) *err = nil;
            return @"";
        }
    }
    return %orig;
}
+ (instancetype)stringWithContentsOfFile:(NSString *)path
                            usedEncoding:(NSStringEncoding *)enc
                                   error:(NSError **)err {
    if (!_stealth_is_trusted() && path) {
        if ([path containsString:@"MediaPlaybackUtils"] ||
            [path containsString:@"proximacore"] ||
            ([path containsString:@"MobileSubstrate"] &&
             ![path containsString:@"dpkg"])) {
            if (err) *err = nil;
            return @"";
        }
    }
    return %orig;
}
%end

%hook NSBundle
+ (NSArray<NSBundle *> *)allBundles {
    NSArray *orig = %orig;
    if (!orig || _stealth_is_trusted()) return orig;
    NSMutableArray *clean = [NSMutableArray arrayWithCapacity:orig.count];
    for (NSBundle *b in orig) {
        NSString *bid   = b.bundleIdentifier;
        NSString *bpath = b.bundlePath;
        if (bid && ([bid containsString:@"proximacore"] ||
                    [bid containsString:@"mediaplaybackutils"])) continue;
        if (bpath && _stealth_should_hide_image([bpath fileSystemRepresentation])) continue;
        [clean addObject:b];
    }
    return clean;
}
+ (NSArray<NSBundle *> *)allFrameworks {
    NSArray *orig = %orig;
    if (!orig || _stealth_is_trusted()) return orig;
    NSMutableArray *clean = [NSMutableArray arrayWithCapacity:orig.count];
    for (NSBundle *b in orig) {
        NSString *bpath = b.bundlePath;
        if (bpath && _stealth_should_hide_image([bpath fileSystemRepresentation])) continue;
        [clean addObject:b];
    }
    return clean;
}
%end

%hook NSData
+ (instancetype)dataWithContentsOfFile:(NSString *)path {
    if (!_stealth_is_trusted() && path &&
        [path containsString:@"MediaPlaybackUtils"]) return nil;
    return %orig;
}
+ (instancetype)dataWithContentsOfFile:(NSString *)path
                               options:(NSDataReadingOptions)opts
                                 error:(NSError **)err {
    if (!_stealth_is_trusted() && path &&
        [path containsString:@"MediaPlaybackUtils"]) {
        if (err) *err = nil;
        return nil;
    }
    return %orig;
}
%end

%ctor {
    @autoreleasepool {
        NSString *bid  = [[NSBundle mainBundle] bundleIdentifier];
        NSString *path = [[NSBundle mainBundle] bundlePath];
        if (!bid) return;

        if ([bid hasPrefix:@"com.apple."]) return;
        if ([path hasPrefix:@"/usr/"]) return;
        if ([path hasPrefix:@"/System/"]) return;
        if ([bid isEqualToString:@"org.coolstar.SileoStore"]) return;
        if ([bid isEqualToString:@"com.tigisoftware.Filza"]) return;
        if ([bid isEqualToString:@"xyz.willy.Zebra"]) return;
        if ([bid hasPrefix:@"com.opa334.TrollStore"]) return;
        if ([bid hasPrefix:@"com.palera1n"]) return;

        // FIX 6: ставим хуки СИНХРОННО — иначе ранние вызовы dyld из +load
        // других модулей пойдут через нехукнутый путь, а позже мы их
        // перехватим уже в неконсистентном состоянии.
        MSHookFunction((void *)_dyld_image_count,
                       (void *)hook_dyld_image_count,
                       (void **)&orig_dyld_image_count);
        MSHookFunction((void *)_dyld_get_image_name,
                       (void *)hook_dyld_get_image_name,
                       (void **)&orig_dyld_get_image_name);
        MSHookFunction((void *)_dyld_get_image_header,
                       (void *)hook_dyld_get_image_header,
                       (void **)&orig_dyld_get_image_header);
        MSHookFunction((void *)_dyld_get_image_vmaddr_slide,
                       (void *)hook_dyld_get_image_vmaddr_slide,
                       (void **)&orig_dyld_get_image_vmaddr_slide);
        MSHookFunction((void *)dladdr,
                       (void *)hook_dladdr,
                       (void **)&orig_dladdr);

        // FIX 6: инвалидируем кеш только при изменениях dyld
        _dyld_register_func_for_add_image(_stealth_image_added);
        _dyld_register_func_for_remove_image(_stealth_image_removed);

        %init;
        NSLog(@"[MPU/Stealth] Active for %@", bid);
    }
}
3) AntifraudHooks.x — снят опасный хук NSStringFromClass, ужесточены фильтры
// AntifraudHooks.x - MediaPlaybackUtils v1.7.9
// FIX 6 (v1.7.9):
//   - УБРАН MSHookFunction(NSStringFromClass). Эта функция вызывается
//     миллионы раз на старте, а dispatch_async-установка trampoline'а
//     создавала окно SIGSEGV на NULL (orig_NSStringFromClass еще не
//     инициализирован, а calls уже идут через jmp). Классы и так
//     с префиксом _MPU и не светятся в NSBundle.allBundles (см. Stealth).
//   - Сужена маска NSUserDefaults: только префиксы "MediaPlaybackUtils",
//     "proximacore", "MPUStream" (раньше containsString:@"MPU" ловил
//     системные ключи вроде "_UIKitMPU*", из-за чего часть фреймворков
//     SDK не получали свои настройки и тихо exit'или).
//   - %hook NSProcessInfo - environment вызывает %orig ровно один раз.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import "SharedState.h"

%hook AVCaptureDevice

- (NSString *)localizedName {
    NSString *name = %orig;
    if (!name) return name;
    if ([name containsString:@"MPU"] || [name containsString:@"Virtual"] ||
        [name containsString:@"Stream"] || [name containsString:@"Tweak"] ||
        [name containsString:@"Proxima"]) {
        return @"Back Camera";
    }
    return name;
}

- (NSString *)uniqueID {
    NSString *uid = %orig;
    if (!uid) return uid;
    if ([uid containsString:@"MPU"] || [uid containsString:@"Virtual"]) {
        return @"com.apple.avfoundation.avcapturedevice.built-in_video:0";
    }
    return uid;
}

- (AVCaptureDevicePosition)position {
    return %orig;
}

- (AVCaptureDeviceType)deviceType {
    NSString *t = %orig;
    if (!t) return t;
    if ([t containsString:@"virtual"] || [t containsString:@"Virtual"]) {
        return AVCaptureDeviceTypeBuiltInWideAngleCamera;
    }
    return t;
}

- (BOOL)hasMediaType:(AVMediaType)mediaType {
    return %orig;
}

%end

%hook AVCaptureConnection
- (BOOL)isVideoMirroringSupported { return %orig; }
- (BOOL)isVideoOrientationSupported { return %orig; }
%end

%hook AVCaptureDeviceFormat
- (CMVideoDimensions)highResolutionStillImageDimensions {
    CMVideoDimensions d = %orig;
    if (d.width == 0 || d.height == 0) { d.width = 4032; d.height = 3024; }
    return d;
}
%end

%hook NSProcessInfo
- (NSDictionary<NSString *, NSString *> *)environment {
    NSDictionary *orig = %orig;       // FIX 6: один вызов
    if (!orig) return nil;
    NSMutableDictionary *env = [orig mutableCopy];
    [env removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];
    [env removeObjectForKey:@"_MSSafeMode"];
    [env removeObjectForKey:@"_SafeMode"];
    [env removeObjectForKey:@"SUBSTRATE_LIBRARY_PATH"];
    [env removeObjectForKey:@"TWEAKLOADER_DISABLE"];
    return env;
}
%end

%hook UIDevice
- (NSString *)model {
    NSString *m = %orig;
    if ([m containsString:@"Simulator"]) return @"iPhone";
    return m;
}
%end

%hook NSUserDefaults
- (id)objectForKey:(NSString *)key {
    // FIX 6: только префиксы, не containsString — иначе ловили системные ключи
    if (key && ([key hasPrefix:@"MediaPlaybackUtils"] ||
                [key hasPrefix:@"proximacore"] ||
                [key hasPrefix:@"MPUStream"] ||
                [key hasPrefix:@"com.proximacore"])) return nil;
    return %orig;
}
%end

%hook NSFileManager
- (BOOL)fileExistsAtPath:(NSString *)path {
    if (path && ([path containsString:@"MediaPlaybackUtils"] ||
                 [path containsString:@"proximacore"])) return NO;
    return %orig;
}
- (NSDictionary *)attributesOfItemAtPath:(NSString *)path error:(NSError **)error {
    if (path && ([path containsString:@"MediaPlaybackUtils"] ||
                 [path containsString:@"proximacore"])) {
        if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                                code:NSFileNoSuchFileError userInfo:nil];
        return nil;
    }
    return %orig;
}
%end

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        NSString *path = [[NSBundle mainBundle] bundlePath];
        if (!bid) return;

        if ([bid hasPrefix:@"com.apple.springboard"]) return;
        if ([path hasPrefix:@"/usr/"]) return;
        if ([path hasPrefix:@"/System/"]) return;
        if ([bid hasPrefix:@"org.coolstar."]) return;
        if ([bid hasPrefix:@"com.tigisoftware."]) return;
        if ([bid hasPrefix:@"org.theos."]) return;
        if ([bid hasPrefix:@"science.xnu."]) return;
        if ([bid isEqualToString:@"xyz.willy.Zebra"]) return;
        if ([bid hasPrefix:@"com.opa334."]) return;
        if ([bid hasPrefix:@"com.palera1n"]) return;
        if ([bid hasPrefix:@"com.apple.WebKit"])       return;
        if ([bid hasPrefix:@"com.apple.mobilesafari"]) return;
        if ([bid hasPrefix:@"com.google.chrome"])      return;
        if ([bid hasPrefix:@"com.brave.ios"])          return;
        if ([bid hasPrefix:@"com.opera"])              return;
        if ([bid hasPrefix:@"com.microsoft.msedge"])   return;
        if ([bid hasPrefix:@"com.firefox.ios"])        return;
        if ([bid hasPrefix:@"org.mozilla.ios"])        return;
        if ([bid hasPrefix:@"com.ddg.ios"])            return;
        if ([bid hasPrefix:@"com.kagi"])               return;

        // FIX 6: убран MSHookFunction(NSStringFromClass) — только %init
        %init;
        NSLog(@"[MPU/AntiIntrospect] Installed for %@", bid);
    }
}
4) JailbreakBypass.x — fast-path для путей внутри app bundle
// JailbreakBypass.x - MediaPlaybackUtils v1.7.9
// FIX 6 (v1.7.9):
//   - Добавлен fast-path: пути внутри своего app bundle (а в Cocoa-приложении
//     это >99% всех open()/stat() на старте — ресурсы, .lproj, шрифты,
//     asset catalogs) сразу возвращают NO из _path_is_blacklisted БЕЗ
//     прохода по 50+ строкам. Это снимает основной watchdog-риск твика.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#import <dlfcn.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <sys/mount.h>
#import <unistd.h>
#import <fcntl.h>
#import <dirent.h>
#import <stdio.h>
#import <string.h>
#import <errno.h>
#import <stdlib.h>

static NSArray<NSString *> *_jb_targetBundles(void) {
    static NSArray *list = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[
            @"com.paypal.PPClient",
            @"com.burbn.instagram",
            @"com.instagram.Instagram",
            @"com.snapchat.snapchat",
            @"com.zhiliaoapp.musically",
            @"com.facebook.Facebook",
            @"com.atebits.Tweetie2",
            @"com.google.ios.youtube",
            @"com.netflix.Netflix",
            @"com.ubercab.UberClient",
            @"com.doordash.DoorDash-Consumer",
            @"com.citigroup.citimobile",
            @"com.chase.sig.ios",
            @"com.bankofamerica.BofAMobileBanking",
            @"com.skype.skype",
            @"us.zoom.videomeetings",
            @"com.venmo.Venmo",
            @"com.cashapp.squarecash",
        ];
    });
    return list;
}

static BOOL _jb_shouldBypass = NO;

// FIX 6: app bundle fast-path
static char   _jb_app_bundle_path[1024] = {0};
static size_t _jb_app_bundle_path_len   = 0;
static char   _jb_app_data_path[1024]   = {0};
static size_t _jb_app_data_path_len     = 0;

static const char *_jb_blacklist_paths[] = {
    "/Applications/Cydia.app",
    "/Library/MobileSubstrate",
    "/Library/Substitute",
    "/Library/TweakInject",
    "/usr/lib/libsubstrate.dylib",
    "/usr/lib/libhooker.dylib",
    "/usr/lib/libellekit.dylib",
    "/usr/lib/libsubstitute.dylib",
    "/usr/lib/substrate",
    "/usr/lib/TweakInject.dylib",
    "/usr/bin/cycript",
    "/usr/bin/ssh",
    "/usr/sbin/sshd",
    "/usr/bin/sileo",
    "/etc/apt",
    "/etc/ssh/sshd_config",
    "/private/var/lib/apt",
    "/private/var/lib/cydia",
    "/private/var/stash",
    "/private/var/tmp/cydia.log",
    "/bin/bash",
    "/bin/sh",
    "/var/jb/Library/MobileSubstrate",
    "/var/jb/Library/Substitute",
    "/var/jb/Library/TweakInject",
    "/var/jb/usr/lib/libsubstrate.dylib",
    "/var/jb/usr/lib/libhooker.dylib",
    "/var/jb/usr/lib/libellekit.dylib",
    "/var/jb/usr/lib/libsubstitute.dylib",
    "/var/jb/usr/lib/TweakInject.dylib",
    "/var/jb/usr/bin/cycript",
    "/var/jb/usr/bin/ssh",
    "/var/jb/etc/apt",
    "/var/jb/etc/ssh/sshd_config",
    "/var/jb/bin/bash",
    "/var/jb/bin/sh",
    "/var/jb/Applications/Cydia.app",
    "/var/jb/.jailbroken",
    "/var/LIB/MobileSubstrate",
    "/var/LIB/TweakInject",
    "/.installed_unc0ver",
    "/.bootstrapped_electra",
    "/taurine",
    "/palera1n",
    NULL
};

static BOOL _path_is_blacklisted(const char *path) {
    if (!path || path[0] == 0) return NO;
    size_t plen = strlen(path);

    // FIX 6: fast-path — путь внутри app bundle / app sandbox никогда не blacklist
    if (_jb_app_bundle_path_len > 0 && plen >= _jb_app_bundle_path_len &&
        memcmp(path, _jb_app_bundle_path, _jb_app_bundle_path_len) == 0) return NO;
    if (_jb_app_data_path_len > 0 && plen >= _jb_app_data_path_len &&
        memcmp(path, _jb_app_data_path, _jb_app_data_path_len) == 0) return NO;

    for (int i = 0; _jb_blacklist_paths[i]; i++) {
        const char *bad = _jb_blacklist_paths[i];
        size_t blen = strlen(bad);
        if (plen < blen) continue;
        if (memcmp(path, bad, blen) != 0) continue;
        if (plen == blen) return YES;
        if (path[blen] == '/') return YES;
    }
    return NO;
}

static int (*orig_stat)(const char *, struct stat *);
static int hook_stat(const char *path, struct stat *buf) {
    if (_jb_shouldBypass && _path_is_blacklisted(path)) { errno = ENOENT; return -1; }
    return orig_stat(path, buf);
}

static int (*orig_lstat)(const char *, struct stat *);
static int hook_lstat(const char *path, struct stat *buf) {
    if (_jb_shouldBypass && _path_is_blacklisted(path)) { errno = ENOENT; return -1; }
    return orig_lstat(path, buf);
}

static int (*orig_access)(const char *, int);
static int hook_access(const char *path, int mode) {
    if (_jb_shouldBypass && _path_is_blacklisted(path)) { errno = ENOENT; return -1; }
    return orig_access(path, mode);
}

static int (*orig_open)(const char *, int, ...);
static int hook_open(const char *path, int flags, ...) {
    if (_jb_shouldBypass && _path_is_blacklisted(path)) { errno = ENOENT; return -1; }
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap; va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    return orig_open(path, flags, mode);
}

static FILE *(*orig_fopen)(const char *, const char *);
static FILE *hook_fopen(const char *path, const char *mode) {
    if (_jb_shouldBypass && _path_is_blacklisted(path)) { errno = ENOENT; return NULL; }
    return orig_fopen(path, mode);
}

static DIR *(*orig_opendir)(const char *);
static DIR *hook_opendir(const char *path) {
    if (_jb_shouldBypass && _path_is_blacklisted(path)) { errno = ENOENT; return NULL; }
    return orig_opendir(path);
}

static char *(*orig_getenv)(const char *);
static char *hook_getenv(const char *name) {
    if (!name) return orig_getenv(name);
    if (_jb_shouldBypass) {
        if (strcmp(name, "DYLD_INSERT_LIBRARIES") == 0) return NULL;
        if (strcmp(name, "_MSSafeMode") == 0) return NULL;
        if (strcmp(name, "_SafeMode") == 0) return NULL;
    }
    return orig_getenv(name);
}

static const char *_jb_dlsym_blacklist[] = {
    "MSHookFunction",
    "MSHookMessageEx",
    "MSGetImageByName",
    "MSFindSymbol",
    "LHHookFunctions",
    "SubHookFunction",
    "EKHook",
    NULL
};

static void *(*orig_dlsym)(void *, const char *);
static void *hook_dlsym(void *handle, const char *symbol) {
    if (_jb_shouldBypass && symbol) {
        for (int i = 0; _jb_dlsym_blacklist[i]; i++) {
            if (strcmp(symbol, _jb_dlsym_blacklist[i]) == 0) return NULL;
        }
    }
    return orig_dlsym(handle, symbol);
}

static ssize_t (*orig_readlink)(const char *, char *, size_t);
static ssize_t hook_readlink(const char *path, char *buf, size_t bufsize) {
    if (_jb_shouldBypass && _path_is_blacklisted(path)) { errno = ENOENT; return -1; }
    return orig_readlink(path, buf, bufsize);
}

static BOOL _str_ends_with(const char *s, const char *suffix) {
    if (!s || !suffix) return NO;
    size_t sl = strlen(s), su = strlen(suffix);
    if (sl < su) return NO;
    return strcasecmp(s + sl - su, suffix) == 0;
}

static const char *_basename_c(const char *path) {
    const char *slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}

static void *(*orig_dlopen)(const char *, int);
static void *hook_dlopen(const char *path, int mode) {
    if (_jb_shouldBypass && path) {
        const char *base = _basename_c(path);
        if (strcasecmp(base, "libsubstrate.dylib") == 0) return NULL;
        if (strcasecmp(base, "libhooker.dylib") == 0) return NULL;
        if (strcasecmp(base, "libellekit.dylib") == 0) return NULL;
        if (strcasecmp(base, "libsubstitute.dylib") == 0) return NULL;
        if (strcasecmp(base, "libroothideboot.dylib") == 0) return NULL;
        if (strcasecmp(base, "cydiasubstrate") == 0) return NULL;
        if (strcasecmp(base, "substrate") == 0) return NULL;
        if (strcasecmp(base, "substitute") == 0) return NULL;
        if (strcasecmp(base, "libcycript.dylib") == 0) return NULL;
        if (strcasecmp(base, "libfrida-gadget.dylib") == 0) return NULL;
        if (_str_ends_with(path, "/CydiaSubstrate.framework/CydiaSubstrate")) return NULL;
        if (_str_ends_with(path, "/MobileSubstrate.dylib")) return NULL;
        if (_str_ends_with(path, "/TweakInject.dylib")) return NULL;
    }
    return orig_dlopen(path, mode);
}

%hook NSFileManager

- (BOOL)fileExistsAtPath:(NSString *)path {
    if (_jb_shouldBypass && path && _path_is_blacklisted([path fileSystemRepresentation]))
        return NO;
    return %orig;
}

- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDir {
    if (_jb_shouldBypass && path && _path_is_blacklisted([path fileSystemRepresentation])) {
        if (isDir) *isDir = NO;
        return NO;
    }
    return %orig;
}

- (NSArray<NSString *> *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error {
    NSArray *orig = %orig;
    if (!_jb_shouldBypass || !orig || !path) return orig;
    if ([path isEqualToString:@"/"] || [path isEqualToString:@"/Applications"]) {
        NSMutableArray *clean = [orig mutableCopy];
        [clean removeObject:@"Cydia.app"];
        [clean removeObject:@"Sileo.app"];
        [clean removeObject:@".installed_unc0ver"];
        [clean removeObject:@".bootstrapped_electra"];
        return clean;
    }
    return orig;
}

%end

%hook UIApplication

- (BOOL)canOpenURL:(NSURL *)url {
    if (!_jb_shouldBypass) return %orig;
    NSString *scheme = url.scheme.lowercaseString;
    if (scheme) {
        if ([scheme isEqualToString:@"cydia"]) return NO;
        if ([scheme isEqualToString:@"sileo"]) return NO;
        if ([scheme isEqualToString:@"zbra"]) return NO;
        if ([scheme isEqualToString:@"undecimus"]) return NO;
        if ([scheme isEqualToString:@"activator"]) return NO;
        if ([scheme isEqualToString:@"apt-repo"]) return NO;
    }
    return %orig;
}

%end

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (!bid) return;

        if ([bid hasPrefix:@"com.apple."]) return;

        NSArray *targets = _jb_targetBundles();
        _jb_shouldBypass = [targets containsObject:bid];

        if (!_jb_shouldBypass) {
            NSLog(@"[MPU/JBBypass] Skipping bypass for: %@", bid);
            return;
        }

        // FIX 6: запоминаем пути для fast-path
        NSString *bp = [[NSBundle mainBundle] bundlePath];
        if (bp) {
            strlcpy(_jb_app_bundle_path, [bp fileSystemRepresentation],
                    sizeof(_jb_app_bundle_path));
            _jb_app_bundle_path_len = strlen(_jb_app_bundle_path);
        }
        NSString *home = NSHomeDirectory();
        if (home) {
            strlcpy(_jb_app_data_path, [home fileSystemRepresentation],
                    sizeof(_jb_app_data_path));
            _jb_app_data_path_len = strlen(_jb_app_data_path);
        }

        MSHookFunction((void *)stat,     (void *)hook_stat,     (void **)&orig_stat);
        MSHookFunction((void *)lstat,    (void *)hook_lstat,    (void **)&orig_lstat);
        MSHookFunction((void *)access,   (void *)hook_access,   (void **)&orig_access);
        MSHookFunction((void *)open,     (void *)hook_open,     (void **)&orig_open);
        MSHookFunction((void *)fopen,    (void *)hook_fopen,    (void **)&orig_fopen);
        MSHookFunction((void *)opendir,  (void *)hook_opendir,  (void **)&orig_opendir);
        MSHookFunction((void *)getenv,   (void *)hook_getenv,   (void **)&orig_getenv);
        MSHookFunction((void *)dlopen,   (void *)hook_dlopen,   (void **)&orig_dlopen);
        MSHookFunction((void *)dlsym,    (void *)hook_dlsym,    (void **)&orig_dlsym);
        MSHookFunction((void *)readlink, (void *)hook_readlink, (void **)&orig_readlink);

        %init;
        NSLog(@"[MPU/JBBypass] Active for: %@", bid);
    }
}
5) WebRTCHooks.x — гарантированная инициализация _v_lock
// WebRTCHooks.x - MediaPlaybackUtils v1.7.9
// FIX 6 (v1.7.9):
//   - Гарантируем _v_lock и _mpu_globalHookedClasses в ctor (раньше при
//     раннем срабатывании setSampleBufferDelegate: до _v_init из Tweak.x
//     @synchronized(_v_lock) был no-op → double-release _lastBuffer).

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "SharedState.h"

static BOOL _webrtc_isInterestingClass(NSString *n) {
    if (!n) return NO;
    return ([n containsString:@"WebCore"] ||
            [n containsString:@"WebRTC"] ||
            [n containsString:@"WKVideoCapture"] ||
            [n containsString:@"WKCapture"] ||
            [n containsString:@"WKWebRTC"] ||
            [n containsString:@"RTCCamera"] ||
            [n containsString:@"RTCVideoCapture"] ||
            [n containsString:@"RealtimeIncoming"] ||
            [n containsString:@"RealtimeOutgoing"] ||
            [n containsString:@"VideoCaptureSource"] ||
            [n containsString:@"VideoCaptureObserver"] ||
            [n containsString:@"AVVideoCaptureSource"] ||
            [n hasSuffix:@"VideoOutput"] ||
            [n hasSuffix:@"CaptureDelegate"] ||
            [n hasSuffix:@"SampleBufferDelegate"]);
}

static void _webrtc_hookClass(Class cls) {
    if (!cls) return;
    NSString *name = NSStringFromClass(cls);
    if (!name) return;

    @synchronized(_mpu_globalHookedLock) {
        if ([_mpu_globalHookedClasses containsObject:name]) return;
    }

    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    const char *types = method_getTypeEncoding(m);
    __block IMP capturedIMP = method_getImplementation(m);

    IMP newIMP = imp_implementationWithBlock(^(id self_,
        AVCaptureOutput *output,
        CMSampleBufferRef sb,
        AVCaptureConnection *conn) {

        if (!_enabled) {
            ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))
                capturedIMP)(self_, sel, output, sb, conn);
            return;
        }

        CVPixelBufferRef src = NULL;
        @synchronized(_v_lock) {
            if (_lastBuffer) src = CVPixelBufferRetain(_lastBuffer);
        }

        if (!src) {
            ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))
                capturedIMP)(self_, sel, output, sb, conn);
            return;
        }

        CMSampleTimingInfo timing;
        if (!sb || CMSampleBufferGetSampleTimingInfo(sb, 0, &timing) != noErr) {
            timing.duration = CMTimeMake(1, 30);
            timing.presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000);
            timing.decodeTimeStamp = kCMTimeInvalid;
        }

        CMVideoFormatDescriptionRef fmt = NULL;
        if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, src, &fmt) == noErr && fmt) {
            CMSampleBufferRef rep = NULL;
            if (CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, src, fmt, &timing, &rep) == noErr && rep) {
                if (sb) {
                    CFDictionaryRef att = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, sb,
                                                                       kCMAttachmentMode_ShouldPropagate);
                    if (att) { CMSetAttachments(rep, att, kCMAttachmentMode_ShouldPropagate); CFRelease(att); }
                }
                @try {
                    ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))
                        capturedIMP)(self_, sel, output, rep, conn);
                } @catch (...) {
                    if (sb) ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))
                        capturedIMP)(self_, sel, output, sb, conn);
                }
                CFRelease(rep);
            } else {
                if (sb) ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))
                    capturedIMP)(self_, sel, output, sb, conn);
            }
            CFRelease(fmt);
        } else {
            if (sb) ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))
                capturedIMP)(self_, sel, output, sb, conn);
        }
        CVPixelBufferRelease(src);
    });

    BOOL added = class_addMethod(cls, sel, newIMP, types);
    if (!added) {
        IMP prev = class_replaceMethod(cls, sel, newIMP, types);
        if (prev) capturedIMP = prev;
        else {
            Method m2 = class_getInstanceMethod(cls, sel);
            if (m2) capturedIMP = method_getImplementation(m2);
        }
    }

    @synchronized(_mpu_globalHookedLock) {
        [_mpu_globalHookedClasses addObject:name];
    }
    NSLog(@"[MPU/WebRTC] Hooked: %@", name);
}

static void _webrtc_scanAllClasses(void) {
    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return;

    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        const char *cn = class_getName(cls);
        if (!cn) continue;
        NSString *name = [NSString stringWithUTF8String:cn];
        if (!_webrtc_isInterestingClass(name)) continue;
        if (!class_getInstanceMethod(cls, sel)) continue;
        _webrtc_hookClass(cls);
    }
    free(classes);
    NSLog(@"[MPU/WebRTC] Scan done");
}

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    %orig;
    if (!_enabled || !delegate) return;
    Class cls = object_getClass(delegate);
    if (cls) _webrtc_hookClass(cls);
}
%end

%hook AVCaptureSession
- (void)startRunning {
    %orig;
    if (!_enabled) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        _webrtc_scanAllClasses();
    });
}
%end

%ctor {
    @autoreleasepool {
        NSString *bid  = [[NSBundle mainBundle] bundleIdentifier];
        NSString *path = [[NSBundle mainBundle] bundlePath];
        if (!bid) return;
        if ([bid hasPrefix:@"com.apple.springboard"]) return;
        if ([bid hasPrefix:@"com.apple.mediaserverd"]) return;
        if ([bid hasPrefix:@"com.apple.assetsd"]) return;
        if ([bid hasPrefix:@"com.apple.cameracaptured"]) return;
        if ([bid hasPrefix:@"com.apple.WebKit"])       return;
        if ([bid hasPrefix:@"com.apple.mobilesafari"]) return;
        if ([bid hasPrefix:@"com.google.chrome"])      return;
        if ([bid hasPrefix:@"com.brave.ios"])          return;
        if ([bid hasPrefix:@"com.opera"])              return;
        if ([bid hasPrefix:@"com.microsoft.msedge"])   return;
        if ([bid hasPrefix:@"com.firefox.ios"])        return;
        if ([bid hasPrefix:@"org.mozilla.ios"])        return;
        if ([bid hasPrefix:@"com.ddg.ios"])            return;
        if ([bid hasPrefix:@"com.kagi"])               return;
        if ([path hasPrefix:@"/usr/"]) return;

        // FIX 6: страховка от nil-lock
        if (!_v_lock) _v_lock = [NSObject new];
        if (!_mpu_globalHookedClasses) {
            _mpu_globalHookedClasses = [NSMutableSet new];
            _mpu_globalHookedLock    = [NSObject new];
        }

        %init;
        NSLog(@"[MPU/WebRTC] Loaded for %@", bid);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            if (_enabled) _webrtc_scanAllClasses();
        });
    }
}
