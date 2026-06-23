// =============================================================================
// MediaPlaybackUtils — Tweak.x
// FIX: bundle id + notif name aligned with prefs
// FIX: stream via _MPUMediaBufferAdapter (HLS + MJPEG)
// Target: palera1n rootless (Theos rootless scheme).
// =============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurface.h>
#import <objc/runtime.h>
#import "SharedState.h"
#import "_MPUMediaBufferAdapter.h"

#define MPU_BUNDLE_ID  @"com.proximacore.mediaplaybackutils"
#define MPU_NOTIF_NAME CFSTR("com.proximacore.mpu/cfg")
#define MPU_LOG(fmt, ...) NSLog(@"[MPU] " fmt, ##__VA_ARGS__)

// _enabled, _lastBuffer, _lastBufferTime, _v_lock — живут в SharedState.m (extern)
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

// ── prefs ────────────────────────────────────────────────────────────────────
static void _v_loadPrefs(void) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:MPU_BUNDLE_ID];
    _enabled = [d boolForKey:@"enabled"];
    NSString *raw = [d stringForKey:@"rtspURL"];
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

// ── init ─────────────────────────────────────────────────────────────────────
static void _v_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        _v_lock = [NSObject new];
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

// ── stream via _MPUMediaBufferAdapter (HLS + MJPEG) ──────────────────────────
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

// ── CMSampleBuffer reconstruction ────────────────────────────────────────────
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

// ── ctor ─────────────────────────────────────────────────────────────────────
%ctor {
    @autoreleasepool { _v_init(); }
}

// ── AVCaptureVideoDataOutput delegate swizzle ────────────────────────────────
%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id)delegate
                          queue:(dispatch_queue_t)queue {
    if (!delegate) { %orig; return; }
    _v_init();

    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    Method m = class_getInstanceMethod([delegate class], sel);
    if (!m) { %orig; return; }

    static const void *kMPUSwizzledKey = &kMPUSwizzledKey;
    if (objc_getAssociatedObject(delegate, kMPUSwizzledKey)) { %orig; return; }
    objc_setAssociatedObject(delegate, kMPUSwizzledKey, @YES, OBJC_ASSOCIATION_RETAIN);

    IMP origIMP = method_getImplementation(m);
    typedef void (*OrigFn)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *);
    OrigFn origFn = (OrigFn)origIMP;

    IMP newIMP = imp_implementationWithBlock(
        ^(id self_, AVCaptureOutput *output, CMSampleBufferRef sb, AVCaptureConnection *conn) {
            CMSampleBufferRef rep = (_enabled && sb && _url.length > 0)
                ? _v_makeReplacementSampleBuffer(sb) : NULL;
            if (rep) {
                origFn(self_, sel, output, rep, conn);
                CFRelease(rep);
            } else {
                origFn(self_, sel, output, sb, conn);
            }
        });
    method_setImplementation(m, newIMP);
    %orig;
}

%end

// ── ПРЕДПРОСМОТР — AVCaptureVideoPreviewLayer ────────────────────────────────
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

// ── AVSampleBufferDisplayLayer ───────────────────────────────────────────────
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
