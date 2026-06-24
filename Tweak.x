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

// ── FIX 8 (v1.8.2): отбраковываем Swift/Kotlin/служебные классы — на них
//    class_addMethod ломает Swift-layout и валит процессы (Citi, Capital One,
//    PayPal, банки на Swift/Kotlin-Native). Логика дублирует BrowserHooks/WebRTCHooks.
static BOOL _v_isUnsafeClassName(const char *cn) {
    if (!cn || cn[0] == 0) return YES;
    // Swift mangled: _Tt..., _$s..., _$S...
    if (cn[0] == '_' && (cn[1] == 'T' || cn[1] == '$')) return YES;
    // Swift dotted name "Module.Class" / Kotlin-Native ":" / '$' / non-ASCII
    for (const char *p = cn; *p; p++) {
        unsigned char c = (unsigned char)*p;
        if (c == '.' || c == '$' || c == ':' || c >= 0x80) return YES;
    }
    if (strncmp(cn, "__NS", 4) == 0) return YES;
    if (strncmp(cn, "_NS",  3) == 0) return YES;
    if (strncmp(cn, "OS_",  3) == 0) return YES;
    return NO;
}

// ── FIX 6 + FIX 8: безопасный хук делегата AVCaptureVideoDataOutput по классу
static void _v_hookDelegateClass(Class cls) {
    if (!cls) return;
    // FIX 8: НЕ трогаем Swift/Kotlin/служебные классы — class_addMethod на
    // них валит swift_getSingletonMetadata в Citi/PayPal/Capital One/банках.
    const char *cnRaw = class_getName(cls);
    if (_v_isUnsafeClassName(cnRaw)) {
        MPU_LOG(@"skip unsafe delegate class: %s", cnRaw ?: "(null)");
        return;
    }
    NSString *cn = NSStringFromClass(cls);
    if (!cn) return;

    @synchronized(_mpu_globalHookedLock) {
        if ([_mpu_globalHookedClasses containsObject:cn]) return;
    }

    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    const char *types = method_getTypeEncoding(m);
    if (!types) return;
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
