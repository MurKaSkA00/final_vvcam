// WebRTCHooks.x - MediaPlaybackUtils v1.0.0
// Перехват WebRTC камеры в Safari и Chrome через RTCVideoSource

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <substrate.h>

// Эти переменные общие с Tweak.x
extern CVPixelBufferRef  _lastBuffer;
extern id                _v_lock;
extern BOOL              _enabled;

// ── SAFARI (WebKit внутри процесса приложения) ───────────────────────────────
// Safari использует RTCVideoSource через приватный WebKit фреймворк.
// Перехватываем на уровне AVCaptureVideoDataOutput делегата в WebKit процессе.

static void _webrtc_hookClass(Class cls) {
    if (!cls) return;
    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    const char *types = method_getTypeEncoding(m);
    IMP origIMP = method_getImplementation(m);
    __block IMP capturedIMP = origIMP;

    IMP newIMP = imp_implementationWithBlock(^(id self_,
        AVCaptureOutput *output,
        CMSampleBufferRef sb,
        AVCaptureConnection *conn) {

        if (!_enabled || !_lastBuffer) {
            ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))
                capturedIMP)(self_, sel, output, sb, conn);
            return;
        }

        // Создаём замену sampleBuffer из нашего _lastBuffer
        CMVideoFormatDescriptionRef fmt = NULL;
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
        if (CMSampleBufferGetSampleTimingInfo(sb, 0, &timing) != noErr) {
            timing.duration = CMTimeMake(1, 30);
            timing.presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000);
            timing.decodeTimeStamp = kCMTimeInvalid;
        }

        if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, src, &fmt) == noErr && fmt) {
            CMSampleBufferRef rep = NULL;
            if (CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, src, fmt, &timing, &rep) == noErr && rep) {
                ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))
                    capturedIMP)(self_, sel, output, rep, conn);
                CFRelease(rep);
            } else {
                ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))
                    capturedIMP)(self_, sel, output, sb, conn);
            }
            CFRelease(fmt);
        } else {
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
    NSLog(@"[MPU/WebRTC] Hooked: %@", NSStringFromClass(cls));
}

// Перебираем все классы в памяти и ищем те что реализуют
// captureOutput:didOutputSampleBuffer:fromConnection:
static void _webrtc_hookAllVideoCaptureDelegates(void) {
    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return;

    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        // Ищем только классы с нужным методом
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) continue;

        NSString *name = NSStringFromClass(cls);
        // Пропускаем системные и уже хукнутые
        if ([name hasPrefix:@"NS"] || [name hasPrefix:@"UI"] ||
            [name hasPrefix:@"CA"] || [name hasPrefix:@"_"]) continue;

        _webrtc_hookClass(cls);
    }
    free(classes);
}

// ── HOOK AVCaptureVideoDataOutput setSampleBufferDelegate ────────────────────
// Дополнительно перехватываем через setSampleBufferDelegate
// чтобы поймать WebKit классы которые регистрируются динамически

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    %orig;
    if (!_enabled || !delegate) return;

    Class cls = object_getClass(delegate);
    if (!cls) return;

    NSString *name = NSStringFromClass(cls);
    // Хукаем WebKit и WK классы — они нужны для Safari/Chrome WebRTC
    if ([name hasPrefix:@"WK"] || [name hasPrefix:@"WebKit"] ||
        [name containsString:@"Video"] || [name containsString:@"Camera"] ||
        [name containsString:@"Capture"] || [name containsString:@"RTC"]) {
        _webrtc_hookClass(cls);
    }
}

%end

%ctor {
    @autoreleasepool {
        NSString *bid  = [[NSBundle mainBundle] bundleIdentifier];
        NSString *path = [[NSBundle mainBundle] bundlePath];
        if (!bid) return;

        // Грузим только в Safari, Chrome и WebKit процессы
        BOOL isSafari = [bid isEqualToString:@"com.apple.mobilesafari"];
        BOOL isChrome = [bid isEqualToString:@"com.google.chrome.ios"];
        BOOL isWebKit = [bid hasPrefix:@"com.apple.WebKit"] ||
                        [bid hasPrefix:@"com.apple.webkit"];

        if (!isSafari && !isChrome && !isWebKit) return;
        if ([path hasPrefix:@"/usr/"] || [path hasPrefix:@"/System/"]) return;

        NSLog(@"[MPU/WebRTC] Loading for %@", bid);

        %init;

        // Хукаем все существующие классы с небольшой задержкой
        // чтобы WebKit успел загрузить свои классы
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (_enabled) {
                _webrtc_hookAllVideoCaptureDelegates();
            }
        });
    }
}
