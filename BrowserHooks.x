// BrowserHooks.x - MediaPlaybackUtils v1.7.3
// Перехват камеры в браузерных процессах (Safari/Chrome/Brave/Edge/Firefox)
//
// На iOS все браузеры используют WebKit → камера реально живёт в
// com.apple.WebKit.GPU. Классы вида WebCoreAVVideoCaptureSourceObserver,
// RealtimeIncoming…, _WKVideoCapture… ЛЕНИВО подгружаются при первом
// getUserMedia(), поэтому требуется периодический rescan.

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "SharedState.h"

static NSMutableSet *_brw_hooked = nil;
static dispatch_source_t _brw_timer = nil;

// ── проверка: интересный ли это класс для браузера ──────────────────────────
static BOOL _brw_isInterestingClass(NSString *n) {
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
            [n containsString:@"AVVideoCaptureSource"]);
}

// ── ставим хук на captureOutput:didOutputSampleBuffer:fromConnection: ───────
static void _brw_hookClass(Class cls) {
    if (!cls) return;
    NSString *name = NSStringFromClass(cls);
    if (!name) return;

    @synchronized(_brw_hooked) {
        if ([_brw_hooked containsObject:name]) return;
    }

    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    const char *types = method_getTypeEncoding(m);
    __block IMP capturedIMP = method_getImplementation(m);

    IMP newIMP = imp_implementationWithBlock(^(id self_,
        AVCaptureOutput *output, CMSampleBufferRef sb, AVCaptureConnection *conn) {

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
        CMSampleBufferRef rep = NULL;
        if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, src, &fmt) == noErr && fmt) {
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
            } else if (sb) {
                ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))
                    capturedIMP)(self_, sel, output, sb, conn);
            }
            CFRelease(fmt);
        } else if (sb) {
            ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))
                capturedIMP)(self_, sel, output, sb, conn);
        }
        CVPixelBufferRelease(src);
    });

    BOOL added = class_addMethod(cls, sel, newIMP, types);
    if (!added) {
        IMP prev = class_replaceMethod(cls, sel, newIMP, types);
        if (prev) capturedIMP = prev;
    }

    @synchronized(_brw_hooked) { [_brw_hooked addObject:name]; }
    NSLog(@"[MPU/Browser] Hooked: %@", name);
}

// ── скан памяти на интересные классы (быстрый, фильтр по имени) ─────────────
static void _brw_scan(void) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return;

    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        const char *cn = class_getName(cls);
        if (!cn) continue;
        NSString *name = [NSString stringWithUTF8String:cn];
        if (!_brw_isInterestingClass(name)) continue;
        SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
        if (!class_getInstanceMethod(cls, sel)) continue;
        _brw_hookClass(cls);
    }
    free(classes);
}

// ── periodic rescan: WebKit классы появляются ПОЗЖЕ старта процесса ─────────
static void _brw_startPeriodicScan(void) {
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    _brw_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    __block int ticks = 0;
    dispatch_source_set_timer(_brw_timer, DISPATCH_TIME_NOW,
                              2 * NSEC_PER_SEC, 500 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_brw_timer, ^{
        _brw_scan();
        ticks++;
        if (ticks == 30) {
            dispatch_source_set_timer(_brw_timer, DISPATCH_TIME_NOW,
                                      10 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
        }
    });
    dispatch_resume(_brw_timer);
}

// ── ХУК AVCaptureSession.startRunning ────────────────────────────────────────
%hook AVCaptureSession
- (void)startRunning {
    %orig;
    if (_enabled) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            _brw_scan();
        });
    }
}
%end

// ── ИНИЦИАЛИЗАЦИЯ ───────────────────────────────────────────────────────────
static BOOL _brw_isBrowserProcess(NSString *bid) {
    if (!bid) return NO;
    return ([bid hasPrefix:@"com.apple.WebKit"] ||
            [bid hasPrefix:@"com.apple.mobilesafari"] ||
            [bid hasPrefix:@"com.google.chrome"] ||
            [bid hasPrefix:@"com.brave.ios"] ||
            [bid hasPrefix:@"com.opera"] ||
            [bid hasPrefix:@"com.microsoft.msedge"] ||
            [bid hasPrefix:@"com.firefox.ios"] ||
            [bid hasPrefix:@"org.mozilla.ios"] ||
            [bid hasPrefix:@"com.ddg.ios"] ||
            [bid hasPrefix:@"com.kagi"]);
}

%ctor {
    @autoreleasepool {
        NSString *bid  = [[NSBundle mainBundle] bundleIdentifier];
        NSString *path = [[NSBundle mainBundle] bundlePath];
        if (!bid) return;

        if (!_brw_isBrowserProcess(bid)) return;

        // FIX: com.apple.WebKit.GPU / WebContent / Networking физически живут в
        // /System/Library/Frameworks/WebKit.framework/XPCServices/ — НЕ скипаем их.
        if ([path hasPrefix:@"/usr/"]) return;

        _brw_hooked = [NSMutableSet new];
        %init;
        NSLog(@"[MPU/Browser] Loaded for %@", bid);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            _brw_scan();
            _brw_startPeriodicScan();
        });
    }
}
