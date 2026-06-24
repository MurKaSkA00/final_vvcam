// WebRTCHooks.x - MediaPlaybackUtils v1.8.0
// FIX 7 (v1.8.0): устранён крах Amazon/PayPal/банков/Instagram и т.п.
// Симптом: EXC_BAD_ACCESS at 0x0 в swift_getSingletonMetadata →
//          realizeAllClasses → objc_copyClassList → _CFInitialize.
// Причина:
//   1) В %ctor стоял dispatch_after(1.0s) на QOS_CLASS_USER_INITIATED, который
//      вызывал _webrtc_scanAllClasses() → objc_copyClassList() из фонового
//      потока ПОКА главный ещё инициализирует Swift/Kotlin singletons.
//      У Amazon (Kotlin/Native KMM) и PayPal (Swift+CoreML) это гонка
//      Swift runtime ↔ Obj-C runtime: realizeAllClasses пытается достать
//      singleton metadata, которой ещё нет → NULL → SIGSEGV.
//   2) class_addMethod на Swift-классах с типовой строкой Obj-C ломает
//      Swift class layout — пропускаем Swift/Kotlin-классы.
//   3) Hooked даже в банках/шопинге, где WebRTC физически отсутствует —
//      бесполезный риск. Убираем эти процессы.
//
// Что изменилось:
//   - НЕТ dispatch_after-сканера в %ctor (главная причина крашей).
//   - Скан запускается ТОЛЬКО при AVCaptureSession.startRunning, всегда
//     с главного потока, через dispatch_async(main_queue), один раз
//     на сессию (через флаг _webrtc_scanDone).
//   - Пропускаем Swift/Kotlin-классы: _Tt*, _$s*, имена с '.' / '$' /
//     не-ASCII символами, а также служебные __NS*/_NS*.
//   - Список ранних %ctor early-return расширен: не загружаемся в
//     процессы, заведомо не использующие AVCaptureVideoDataOutput
//     (банки, маркетплейсы, KYC, почта, такси и т.п. — они либо
//     используют AVCapturePhoto, либо VNDocumentCameraView, либо
//     встроенные ML-SDK без classic capture-pipeline).

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#include <stdatomic.h>
#import "SharedState.h"

static atomic_bool _webrtc_scanDone = ATOMIC_VAR_INIT(false);

// FIX 7: явно отбраковываем Swift/Kotlin/служебные классы — на них
// class_addMethod может развалить Swift-layout и вызвать swift_getSingletonMetadata.
static BOOL _webrtc_isUnsafeClassName(const char *cn) {
    if (!cn || cn[0] == 0) return YES;
    // Swift mangled: _Tt..., _$s..., _$S...
    if (cn[0] == '_' && (cn[1] == 'T' || cn[1] == '$')) return YES;
    // KMM/Kotlin-Native:  имя содержит '.' или ':'
    // Swift dotted name: "Module.Class"
    for (const char *p = cn; *p; p++) {
        unsigned char c = (unsigned char)*p;
        if (c == '.' || c == '$' || c == ':' || c >= 0x80) return YES;
    }
    // системные служебные
    if (strncmp(cn, "__NS", 4) == 0) return YES;
    if (strncmp(cn, "_NS",  3) == 0) return YES;
    if (strncmp(cn, "OS_",  3) == 0) return YES;
    return NO;
}

static BOOL _webrtc_isInterestingClass(const char *cn) {
    if (!cn) return NO;
    // Жёстко: только классы с явно WebRTC-ишными именами.
    // Убраны слишком общие маски hasSuffix:VideoOutput / CaptureDelegate /
    // SampleBufferDelegate — они ловили пользовательские классы приложений
    // (Amazon/PayPal/Instagram) и провоцировали свизл там, где не нужно.
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

static void _webrtc_hookClass(Class cls) {
    if (!cls) return;
    const char *cn = class_getName(cls);
    if (_webrtc_isUnsafeClassName(cn)) return;
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

// FIX 7: ВСЕГДА на главном потоке. Один раз на процесс.
static void _webrtc_scanAllClasses_mainThread(void) {
    bool expected = false;
    if (!atomic_compare_exchange_strong(&_webrtc_scanDone, &expected, true)) return;

    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return;

    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        const char *cn = class_getName(cls);
        if (_webrtc_isUnsafeClassName(cn)) continue;
        if (!_webrtc_isInterestingClass(cn))  continue;
        if (!class_getInstanceMethod(cls, sel)) continue;
        _webrtc_hookClass(cls);
    }
    free(classes);
    NSLog(@"[MPU/WebRTC] Scan done (main, %u classes)", count);
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
    // FIX 7: только main queue, не QOS_CLASS_USER_INTERACTIVE из фона.
    dispatch_async(dispatch_get_main_queue(), ^{
        _webrtc_scanAllClasses_mainThread();
    });
}
%end

// FIX 7: процессы, в которых WebRTC точно отсутствует → не загружаемся
static BOOL _webrtc_isBlockedProcess(NSString *bid) {
    if (!bid) return YES;
    static NSArray *blocked = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        blocked = @[
            // Apple system / browsers
            @"com.apple.springboard", @"com.apple.mediaserverd",
            @"com.apple.assetsd",      @"com.apple.cameracaptured",
            @"com.apple.WebKit",       @"com.apple.mobilesafari",
            @"com.google.chrome",      @"com.brave.ios",
            @"com.opera",              @"com.microsoft.msedge",
            @"com.firefox.ios",        @"org.mozilla.ios",
            @"com.ddg.ios",            @"com.kagi",
            // Shopping / banks / payments — нет WebRTC, ловили краши
            @"com.amazon.Amazon",      @"com.ebay",
            @"com.paypal.PPClient",    @"com.venmo.Venmo",
            @"com.cashapp.squarecash", @"com.konylabs.westernunion",
            @"com.chase.sig.ios",      @"com.bankofamerica.BofAMobileBanking",
            @"com.wellsfargo.wellsfargomobile", @"com.key.KeyBank",
            @"com.citigroup.citimobile",
            // Mail / docs / scanners — то же
            @"com.google.Gmail",       @"com.microsoft.Office.Outlook",
            @"com.apple.mobilemail",   @"com.adobe.scan.ios",
            @"com.microsoft.Office.Lens", @"com.apple.Notes",
            @"com.readdle.scanner",    @"net.doo.DMobile",
            // Taxi / learning
            @"com.ubercab.UberClient", @"com.lyft.ios",
            @"com.duolingo.duolingo",
        ];
    });
    for (NSString *b in blocked) {
        if ([bid hasPrefix:b] || [bid isEqualToString:b]) return YES;
    }
    return NO;
}

%ctor {
    @autoreleasepool {
        NSString *bid  = [[NSBundle mainBundle] bundleIdentifier];
        NSString *path = [[NSBundle mainBundle] bundlePath];
        if (!bid) return;
        if (_webrtc_isBlockedProcess(bid)) return;
        if ([path hasPrefix:@"/usr/"]) return;

        if (!_v_lock) _v_lock = [NSObject new];
        if (!_mpu_globalHookedClasses) {
            _mpu_globalHookedClasses = [NSMutableSet new];
            _mpu_globalHookedLock    = [NSObject new];
        }

        %init;
        NSLog(@"[MPU/WebRTC] Loaded for %@", bid);

        // FIX 7: НЕТ dispatch_after-скана. Скан произойдёт только когда
        // приложение реально откроет камеру → AVCaptureSession.startRunning.
    }
}

