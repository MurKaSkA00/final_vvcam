// Tweak.x - MediaPlaybackUtils v2.1.0 "All Apps"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurfaceRef.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import "SharedState.h"
#import "_MPUMediaBufferAdapter.h"

#define MPU_BUNDLE_ID  @"com.proximacore.mediaplaybackutils"
#define MPU_NOTIF_NAME CFSTR("com.proximacore.mpu/cfg")
#define MPU_LOG(fmt, ...) NSLog(@"[MPU] " fmt, ##__VA_ARGS__)

static NSString *_url = nil;
static dispatch_queue_t _v_streamQueue = NULL;
static BOOL _v_streamRunning = NO;
static _MPUMediaBufferAdapter *_v_adapter = nil;
static NSString *_v_currentURL = nil;

static void _v_init(void);
static void _v_loadPrefs(void);
static void _v_startStreamIfNeeded(void);
static void _v_stopStream(void);
static void _v_restartStreamIfNeeded(void);

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
    CFPreferencesAppSynchronize((__bridge CFStringRef)MPU_BUNDLE_ID);
    CFPropertyListRef enRef  = CFPreferencesCopyAppValue(CFSTR("enabled"),  (__bridge CFStringRef)MPU_BUNDLE_ID);
    CFPropertyListRef urlRef = CFPreferencesCopyAppValue(CFSTR("rtspURL"), (__bridge CFStringRef)MPU_BUNDLE_ID);
    if (enRef)  { m[@"enabled"] = (__bridge id)enRef;  CFRelease(enRef); }
    if (urlRef) { m[@"rtspURL"] = (__bridge id)urlRef; CFRelease(urlRef); }
    return m.count ? m : nil;
}

static void _v_loadPrefs(void) {
    NSDictionary *d = _v_readPrefsDict();
    _enabled = d ? [d[@"enabled"] boolValue] : YES;
    NSString *raw = [d[@"rtspURL"] isKindOfClass:[NSString class]] ? d[@"rtspURL"] : nil;
    NSString *trimmed = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *newURL = (trimmed.length > 0) ? [trimmed copy] : @"";
    BOOL urlChanged = ![newURL isEqualToString:_url ?: @""];
    _url = newURL;
    MPU_LOG(@"prefs: enabled=%d url='%@'", _enabled, _url);
    if (_enabled && _url.length > 0) {
        if (urlChanged) _v_restartStreamIfNeeded();
        else            _v_startStreamIfNeeded();
    } else {
        _v_stopStream();
    }
}

static void _v_prefsChangedCallback(CFNotificationCenterRef c, void *o, CFNotificationName n,
                                    const void *obj, CFDictionaryRef ui) { _v_loadPrefs(); }

static void _v_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!_v_lock) _v_lock = [NSObject new];
        if (!_mpu_globalHookedClasses) {
            _mpu_globalHookedClasses = [NSMutableSet new];
            _mpu_globalHookedLock    = [NSObject new];
        }
        _v_streamQueue = dispatch_queue_create("com.mpu.stream", DISPATCH_QUEUE_SERIAL);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, _v_prefsChangedCallback, MPU_NOTIF_NAME, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        _v_loadPrefs();
        MPU_LOG(@"initialized in %@", [[NSBundle mainBundle] bundleIdentifier]);
    });
}

static void _v_startStreamIfNeeded(void) {
    if (_v_streamRunning || _url.length == 0) return;
    dispatch_async(_v_streamQueue, ^{
        if (_v_streamRunning) return;
        NSURL *u = [NSURL URLWithString:_url];
        if (!u) return;
        _v_streamRunning = YES;
        _v_currentURL = [_url copy];
        if (_v_adapter) { [_v_adapter stopStreaming]; _v_adapter = nil; }
        _v_adapter = [[_MPUMediaBufferAdapter alloc] initWithURL:u];
        _v_adapter.pixelBufferCallback = ^(CVPixelBufferRef pb) {
            if (!pb) return;
            @synchronized(_v_lock) {
                CVPixelBufferRef newBuf = CVPixelBufferRetain(pb);
                CVPixelBufferRef oldBuf = _lastBuffer;
                _lastBuffer     = newBuf;
                _lastBufferTime = CACurrentMediaTime();
                if (oldBuf) CVPixelBufferRelease(oldBuf);
            }
        };
        _v_adapter.errorCallback = ^(NSError *err) {
            MPU_LOG(@"adapter error: %@", err.localizedDescription);
        };
        [_v_adapter startStreaming];
        MPU_LOG(@"stream started: %@", _url);
    });
}

static void _v_stopStream(void) {
    if (_v_adapter) { [_v_adapter stopStreaming]; _v_adapter = nil; }
    _v_streamRunning = NO;
    _v_currentURL = nil;
    @synchronized(_v_lock) {
        if (_lastBuffer) { CVPixelBufferRelease(_lastBuffer); _lastBuffer = NULL; }
        _lastBufferTime = 0;
    }
}
static void _v_restartStreamIfNeeded(void) { _v_stopStream(); _v_startStreamIfNeeded(); }

static CMSampleBufferRef _v_makeReplacementForOutput(CMSampleBufferRef original,
                                                     OSType targetFmt) {
    CVPixelBufferRef raw = NULL;
    @synchronized(_v_lock) { if (_lastBuffer) raw = CVPixelBufferRetain(_lastBuffer); }
    if (!raw) return NULL;

    OSType fmt = targetFmt;
    if (fmt == 0 && original) {
        CVImageBufferRef ib = CMSampleBufferGetImageBuffer(original);
        if (ib) fmt = CVPixelBufferGetPixelFormatType(ib);
    }
    CVPixelBufferRef src = _mpu_convertPixelBuffer(raw, fmt);
    CVPixelBufferRelease(raw);
    if (!src) return NULL;

    CMVideoFormatDescriptionRef fmtDesc = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, src, &fmtDesc) != noErr || !fmtDesc) {
        CVPixelBufferRelease(src); return NULL;
    }
    CMSampleTimingInfo timing;
    if (!original || CMSampleBufferGetSampleTimingInfo(original, 0, &timing) != noErr) {
        timing.duration              = CMTimeMake(1, 30);
        timing.presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000);
        timing.decodeTimeStamp       = kCMTimeInvalid;
    }
    CMSampleBufferRef out = NULL;
    OSStatus s = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, src, fmtDesc, &timing, &out);
    if (s == noErr && out && original) {
        CFDictionaryRef att = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, original,
                                                            kCMAttachmentMode_ShouldPropagate);
        if (att) { CMSetAttachments(out, att, kCMAttachmentMode_ShouldPropagate); CFRelease(att); }
    }
    CFRelease(fmtDesc); CVPixelBufferRelease(src);
    return (s == noErr) ? out : NULL;
}

static void _v_hookDelegateClass(Class cls) {
    if (!cls) return;
    const char *cnRaw = class_getName(cls);
    if (_mpu_isUnsafeClassName(cnRaw)) return;
    NSString *cn = NSStringFromClass(cls);
    if (!cn) return;
    if (!_mpu_globalHookedClasses) {
        _mpu_globalHookedClasses = [NSMutableSet new];
        _mpu_globalHookedLock    = [NSObject new];
    }
    @synchronized(_mpu_globalHookedLock) {
        if ([_mpu_globalHookedClasses containsObject:cn]) return;
    }
    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    // Если метод унаследован — копируем в наш класс перед свизлом
    Method mSuper = class_getInstanceMethod(class_getSuperclass(cls), sel);
    if (m == mSuper) {
        const char *types = method_getTypeEncoding(m);
        if (!types) return;
        if (!class_addMethod(cls, sel, method_getImplementation(m), types)) return;
        m = class_getInstanceMethod(cls, sel);
        if (!m) return;
    }
    __block IMP capturedIMP = method_getImplementation(m);
    IMP newIMP = imp_implementationWithBlock(
        ^(id self_, AVCaptureOutput *output, CMSampleBufferRef sb, AVCaptureConnection *conn) {
            @try {
                OSType want = _mpu_outputPixelFormat(output);
                CMSampleBufferRef rep = (_enabled && sb) ? _v_makeReplacementForOutput(sb, want) : NULL;
                CMSampleBufferRef use = rep ?: sb;
                if (use && capturedIMP) {
                    ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))
                        capturedIMP)(self_, sel, output, use, conn);
                }
                if (rep) CFRelease(rep);
            } @catch (NSException *ex) {
                MPU_LOG(@"hook exception %@: %@", cn, ex.reason);
                @try {
                    if (sb && capturedIMP)
                        ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))
                            capturedIMP)(self_, sel, output, sb, conn);
                } @catch (...) {}
            }
        });
    method_setImplementation(m, newIMP);
    @synchronized(_mpu_globalHookedLock) { [_mpu_globalHookedClasses addObject:cn]; }
    MPU_LOG(@"hooked delegate: %@", cn);
}

static void _v_reattachAllOutputs(AVCaptureSession *session) {
    @try {
        for (AVCaptureOutput *output in [session outputs]) {
            if (![output isKindOfClass:[AVCaptureVideoDataOutput class]]) continue;
            AVCaptureVideoDataOutput *vdo = (AVCaptureVideoDataOutput *)output;
            id del = vdo.sampleBufferDelegate;
            dispatch_queue_t q = vdo.sampleBufferCallbackQueue;
            if (del) _v_hookDelegateClass(object_getClass(del));
            if (del && q) [vdo setSampleBufferDelegate:del queue:q];
        }
    } @catch (__unused NSException *e) {}
}

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    if (delegate) { _v_init(); _v_hookDelegateClass(object_getClass(delegate)); }
    %orig;
}
%end

%hook AVCaptureSession
- (void)startRunning {
    if (_enabled) { _v_init(); _v_reattachAllOutputs(self); }
    %orig;
}
- (void)addOutput:(AVCaptureOutput *)output {
    %orig;
    if (_enabled && [output isKindOfClass:[AVCaptureVideoDataOutput class]]) {
        _v_init();
        AVCaptureVideoDataOutput *vdo = (AVCaptureVideoDataOutput *)output;
        id del = vdo.sampleBufferDelegate;
        if (del) _v_hookDelegateClass(object_getClass(del));
    }
}
%end

%hook AVCaptureDevice
+ (AVCaptureDevice *)defaultDeviceWithMediaType:(AVMediaType)mediaType {
    if (_enabled && [mediaType isEqualToString:AVMediaTypeVideo]) _v_init();
    return %orig;
}
+ (AVCaptureDevice *)defaultDeviceWithDeviceType:(AVCaptureDeviceType)deviceType
                                       mediaType:(AVMediaType)mediaType
                                        position:(AVCaptureDevicePosition)position {
    if (_enabled && [mediaType isEqualToString:AVMediaTypeVideo]) _v_init();
    return %orig;
}
%end

%hook AVCaptureVideoPreviewLayer

- (void)layoutSublayers {
    %orig;
    if (!_enabled || _url.length == 0) return;
    _v_init();
    CADisplayLink *dl = objc_getAssociatedObject(self, "_v_dl");
    if (!dl) {
        dl = [CADisplayLink displayLinkWithTarget:self selector:@selector(_mpu_tickOverlay:)];
        dl.preferredFramesPerSecond = 30;
        [dl addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        objc_setAssociatedObject(self, "_v_dl", dl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CALayer *overlay = objc_getAssociatedObject(self, "_v_overlay");
    if (overlay) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        overlay.frame = self.bounds;
        [CATransaction commit];
    }
}

- (void)removeFromSuperlayer {
    CADisplayLink *dl = objc_getAssociatedObject(self, "_v_dl");
    if (dl) {
        [dl invalidate];
        objc_setAssociatedObject(self, "_v_dl", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    %orig;
}

%new
- (void)_mpu_tickOverlay:(CADisplayLink *)sender {
    if (!_enabled) return;
    CVPixelBufferRef bufCopy = NULL;
    @synchronized(_v_lock) { if (_lastBuffer) bufCopy = CVPixelBufferRetain(_lastBuffer); }
    CALayer *overlay = objc_getAssociatedObject(self, "_v_overlay");
    if (!bufCopy) {
        if (overlay) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            overlay.hidden = YES;
            overlay.contents = nil;
            [CATransaction commit];
        }
        return;
    }
    if (!overlay) {
        overlay = [CALayer layer];
        overlay.contentsGravity = kCAGravityResizeAspectFill;
        overlay.zPosition       = 999999;
        overlay.backgroundColor = [UIColor blackColor].CGColor;
        overlay.opaque          = YES;
        overlay.frame           = self.bounds;
        [self addSublayer:overlay];
        objc_setAssociatedObject(self, "_v_overlay", overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    IOSurfaceRef surf = CVPixelBufferGetIOSurface(bufCopy);
    if (surf) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        overlay.contents = (__bridge id)surf;
        overlay.frame    = self.bounds;
        overlay.hidden   = NO;
        overlay.opacity  = 1.0;
        [CATransaction commit];
        CVPixelBufferRelease(bufCopy);
        return;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        CIImage *ci  = [CIImage imageWithCVPixelBuffer:bufCopy];
        CIContext *ctx = _mpu_ciContextShared();
        if (ci && ctx) {
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            CGImageRef cg = [ctx createCGImage:ci fromRect:ci.extent
                                         format:kCIFormatBGRA8 colorSpace:cs];
            CGColorSpaceRelease(cs);
            if (cg) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [CATransaction begin];
                    [CATransaction setDisableActions:YES];
                    overlay.contents = (__bridge id)cg;
                    overlay.frame    = self.bounds;
                    overlay.hidden   = NO;
                    overlay.opacity  = 1.0;
                    [CATransaction commit];
                    CGImageRelease(cg);
                });
            }
        }
        CVPixelBufferRelease(bufCopy);
    });
}
%end

%ctor {
    @autoreleasepool {
        if (!_mpu_processIsLoadable()) return;
        _v_init();
        %init;
    }
}
