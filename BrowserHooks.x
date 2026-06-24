// BrowserHooks.x - MediaPlaybackUtils v1.8.0
// FIX 7 (v1.8.0):
//   - Убран dispatch_source timer, который каждые 2с гонял objc_copyClassList()
//     из QOS_CLASS_UTILITY. У браузеров (особенно Chrome/Brave) это плодило
//     гонки со Swift/Kotlin metadata init (та же причина крашей, что
//     в Amazon/PayPal: swift_getSingletonMetadata at 0x0).
//   - Скан теперь идёт ТОЛЬКО при AVCaptureSession.startRunning, всегда
//     с main queue и один раз на сессию.
//   - Пропускаем Swift/Kotlin/служебные классы (см. _brw_isUnsafeClassName).
//
// FIX 5 (наследовано):
//   - _v_lock = [NSObject new] в %ctor (защита от nil-lock в WebKit процессах).

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <stdatomic.h>
#import "SharedState.h"

static atomic_bool _brw_scanDone = ATOMIC_VAR_INIT(false);

static BOOL _brw_isUnsafeClassName(const char *cn) {
    if (!cn || cn[0] == 0) return YES;
    if (cn[0] == '_' && (cn[1] == 'T' || cn[1] == '$')) return YES;
    for (const char *p = cn; *p; p++) {
        unsigned char c = (unsigned char)*p;
        if (c == '.' || c == '$' || c == ':' || c >= 0x80) return YES;
    }
    if (strncmp(cn, "__NS", 4) == 0) return YES;
    if (strncmp(cn, "_NS",  3) == 0) return YES;
    if (strncmp(cn, "OS_",  3) == 0) return YES;
    return NO;
}

static BOOL _brw_isInterestingClass(const char *cn) {
    if (!cn) return NO;
    return (strstr(cn, "WebCore")           ||
            strstr(cn, "WebRTC")            ||
            strstr(cn, "WKVideoCapture")    ||
            strstr(cn, "WKCapture")         ||
            strstr(cn, "WKWebRTC")          ||
            strstr(cn, "RTCCamera")         ||
            strstr(cn, "RTCVideoCapture")   ||
            strstr(cn, "RealtimeIncoming")  ||
            strstr(cn, "RealtimeOutgoing")  ||
            strstr(cn, "AVVideoCaptureSource"));
}

static void _brw_hookClass(Class cls) {
    if (!cls) return;
    const char *cn = class_getName(cls);
    if (_brw_isUnsafeClassName(cn)) return;
    NSString *name = [NSString stringWithUTF8String:cn];
    if (!name) return;

    @synchronized(_mpu_globalHookedLock) {
        if ([_mpu_globalHookedClasses containsObject:name]) return;
    }

    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    const char *types = method_getTypeEncoding(m);
    if (!types) return;
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

    @synchronized(_mpu_globalHookedLock) {
        [_mpu_globalHookedClasses addObject:name];
    }
    NSLog(@"[MPU/Browser] Hooked: %@", name);
}

static void _brw_scan_mainThread(void) {
    bool expected = false;
    if (!atomic_compare_exchange_strong(&_brw_scanDone, &expected, true)) return;

    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return;

    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        const char *cn = class_getName(cls);
        if (_brw_isUnsafeClassName(cn)) continue;
        if (!_brw_isInterestingClass(cn)) continue;
        SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
        if (!class_getInstanceMethod(cls, sel)) continue;
        _brw_hookClass(cls);
    }
    free(classes);
    NSLog(@"[MPU/Browser] Scan done (main, %u classes)", count);
}

%hook AVCaptureSession
- (void)startRunning {
    %orig;
    if (!_enabled) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        _brw_scan_mainThread();
    });
}
%end

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
        if ([path hasPrefix:@"/usr/"]) return;

        if (!_mpu_globalHookedClasses) {
            _mpu_globalHookedClasses = [NSMutableSet new];
            _mpu_globalHookedLock    = [NSObject new];
        }
        if (!_v_lock) _v_lock = [NSObject new];

        %init;
        NSLog(@"[MPU/Browser] Loaded for %@", bid);

        // FIX 7: НЕТ периодического таймера и НЕТ dispatch_after-скана.
    }
}

