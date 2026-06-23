// =============================================================================
//  MediaPlaybackUtils — Tweak.x
//  Reference complete build with FIX 1…FIX 6 applied.
//  Target: palera1n rootless (Theos rootless scheme).
// =============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurface.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>

#define MPU_BUNDLE_ID    @"com.mpu.mediaplaybackutils"
#define MPU_NOTIF_NAME   CFSTR("com.mpu.mediaplaybackutils/prefs-changed")
#define MPU_LOG(fmt, ...) NSLog(@"[MPU] " fmt, ##__VA_ARGS__)

static BOOL              _enabled        = NO;
static NSString         *_url            = nil;
static CVPixelBufferRef  _lastBuffer     = NULL;
static CFTimeInterval    _lastBufferTime = 0;
static BOOL              _isSwitching    = NO;

static NSObject         *_v_lock          = nil;
static CIContext        *_v_ciContext     = nil;
static dispatch_queue_t  _v_streamQueue   = NULL;
static BOOL              _v_streamRunning = NO;
static NSURLSessionDataTask *_v_task      = nil;
static NSMutableData    *_v_recvBuffer    = nil;

static void _v_init(void);
static void _v_loadPrefs(void);
static void _v_startStreamIfNeeded(void);
static void _v_stopStream(void);
static void _v_restartStreamIfNeeded(void);
static CMSampleBufferRef _v_makeReplacementSampleBuffer(CMSampleBufferRef original);
static CVPixelBufferRef  _v_pixelBufferFromJPEG(NSData *jpeg);


// ── prefs ────────────────────────────────────────────────────────────────────
static void _v_loadPrefs(void) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:MPU_BUNDLE_ID];
    _enabled = [d boolForKey:@"enabled"];
    NSString *raw = [d stringForKey:@"rtspURL"];
    NSString *trimmed = [raw stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    _url = (trimmed.length > 0) ? [trimmed copy] : @"";
    MPU_LOG(@"prefs loaded: enabled=%d url='%@'", _enabled, _url);

    if (_enabled && _url.length > 0) _v_startStreamIfNeeded();
    else                              _v_stopStream();
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
        _v_lock        = [NSObject new];
        _v_ciContext   = [CIContext contextWithOptions:nil];
        _v_streamQueue = dispatch_queue_create("com.mpu.stream", DISPATCH_QUEUE_SERIAL);
        _v_recvBuffer  = [NSMutableData new];

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, _v_prefsChangedCallback, MPU_NOTIF_NAME, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        _v_loadPrefs();
        MPU_LOG(@"initialized");
    });
}


// ── MJPEG stream over HTTP ───────────────────────────────────────────────────
@interface _MPUStreamDelegate : NSObject <NSURLSessionDataDelegate>
@end
@implementation _MPUStreamDelegate
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    @synchronized(_v_recvBuffer) {
        [_v_recvBuffer appendData:data];
        const uint8_t *bytes = _v_recvBuffer.bytes;
        NSUInteger len = _v_recvBuffer.length;
        NSUInteger lastEnd = 0;

        for (NSUInteger i = 0; i + 1 < len; i++) {
            if (bytes[i] == 0xFF && bytes[i+1] == 0xD8) {
                for (NSUInteger j = i + 2; j + 1 < len; j++) {
                    if (bytes[j] == 0xFF && bytes[j+1] == 0xD9) {
                        NSData *frame = [NSData dataWithBytes:bytes + i length:(j + 2 - i)];
                        CVPixelBufferRef pb = _v_pixelBufferFromJPEG(frame);
                        if (pb) {
                            @synchronized(_v_lock) {
                                if (_lastBuffer) CVPixelBufferRelease(_lastBuffer);
                                _lastBuffer = pb;
                                _lastBufferTime = CACurrentMediaTime();
                                _isSwitching = NO;
                            }
                        }
                        lastEnd = j + 2;
                        i = j + 1;
                        break;
                    }
                }
            }
        }
        if (lastEnd > 0)
            [_v_recvBuffer replaceBytesInRange:NSMakeRange(0, lastEnd) withBytes:NULL length:0];
        if (_v_recvBuffer.length > 8 * 1024 * 1024) [_v_recvBuffer setLength:0];
    }
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    MPU_LOG(@"stream task ended: %@", error);
    _v_streamRunning = NO;
}
@end

static _MPUStreamDelegate *_v_streamDelegate = nil;
static NSURLSession       *_v_session        = nil;

static void _v_startStreamIfNeeded(void) {
    if (_v_streamRunning) return;
    if (_url.length == 0) return;

    dispatch_async(_v_streamQueue, ^{
        if (_v_streamRunning) return;
        _v_streamRunning = YES;

        if (!_v_streamDelegate) _v_streamDelegate = [_MPUStreamDelegate new];
        if (!_v_session) {
            NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
            cfg.timeoutIntervalForRequest  = 15;
            cfg.timeoutIntervalForResource = 0;
            cfg.HTTPMaximumConnectionsPerHost = 4;
            _v_session = [NSURLSession sessionWithConfiguration:cfg
                                                       delegate:_v_streamDelegate
                                                  delegateQueue:nil];
        }

        NSURL *u = [NSURL URLWithString:_url];
        if (!u) { _v_streamRunning = NO; return; }
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
        [req setValue:@"close" forHTTPHeaderField:@"Connection"];

        @synchronized(_v_recvBuffer) { [_v_recvBuffer setLength:0]; }
        _v_task = [_v_session dataTaskWithRequest:req];
        [_v_task resume];
        MPU_LOG(@"stream started: %@", _url);
    });
}

static void _v_stopStream(void) {
    if (_v_task) { [_v_task cancel]; _v_task = nil; }
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


// ── JPEG → CVPixelBuffer (BGRA) ──────────────────────────────────────────────
static CVPixelBufferRef _v_pixelBufferFromJPEG(NSData *jpeg) {
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
    if (!src) return NULL;
    CGImageRef cg = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!cg) return NULL;

    size_t w = CGImageGetWidth(cg);
    size_t h = CGImageGetHeight(cg);
    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
    };
    CVPixelBufferRef pb = NULL;
    CVReturn r = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                     kCVPixelFormatType_32BGRA,
                                     (__bridge CFDictionaryRef)attrs, &pb);
    if (r != kCVReturnSuccess || !pb) { CGImageRelease(cg); return NULL; }

    CVPixelBufferLockBaseAddress(pb, 0);
    void *base = CVPixelBufferGetBaseAddress(pb);
    size_t bpr = CVPixelBufferGetBytesPerRow(pb);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, bpr, cs,
        kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (ctx) {
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
        CGContextRelease(ctx);
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    CGImageRelease(cg);
    return pb;
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
        timing.duration              = CMTimeMake(1, 30);
        timing.decodeTimeStamp       = kCMTimeInvalid;
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


// ── 2. AVCaptureVideoDataOutput delegate swizzle ─────────────────────────────
%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
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
            // FIX 6: без URL потока подмену не делаем — отдаём настоящий буфер.
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


// ── 3. ПРЕДПРОСМОТР — AVCaptureVideoPreviewLayer ─────────────────────────────
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
    CFTimeInterval bufTime   = 0;
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


// ── 4. AVSampleBufferDisplayLayer ────────────────────────────────────────────
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
