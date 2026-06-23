
📄 1. control
Package: com.proximacore.mediaplaybackutils
Name: Media Playback Utilities
Depends: mobilesubstrate, preferenceloader
Version: 1.7.7
Architecture: iphoneos-arm64
Description: Low-level media playback helper for AVFoundation pipelines
Maintainer: ProximaCore
Author: ProximaCore
Section: System
📄 2. Tweak.x
// Tweak.x - MediaPlaybackUtils v1.7.7
// FIX 5 (v1.7.7):
//   - В свизле делегата AVCaptureVideoDataOutput тот же use-after-free,
//     что FIX 3 закрыл для AVSampleBufferDisplayLayer: Instagram/Snapchat/
//     TikTok/Zoom РЕТЕЙНЯТ sample buffer на фоновую очередь для фильтров.
//     Синхронный CFRelease(rep) после %orig → refcount=0 в момент, когда
//     async-потребитель ещё держит буфер → use-after-free → краш на старте
//     камеры. CFRelease заменён на CFAutorelease.
//   - Убран дублирующий setSampleBufferDelegate в %hook AVCaptureSession
//     startRunning — он переустанавливал делегата под уже свизленным классом
//     и в редких случаях гонялся с активным колбеком, давая EXC_BAD_ACCESS.
//   - _url больше не имеет hard-coded дефолта 192.168.1.44. Без явно
//     выставленного rtspURL стрим не стартует — это убирает retry-loop
//     NSURLSession, который PromonShield / Approov детектят как tampering
//     и тихо вызывают exit(0).
// FIX 3:
//   - PayPal bundle id: com.yourcompany.PPClient (Theos template) -> com.paypal.PPClient
//   - enqueueSampleBuffer: CFRelease(rep) сразу после %orig вызывал
//     use-after-free в AVSampleBufferDisplayLayer (асинхронный декодер).
//     Заменено на CFAutorelease — буфер живёт до конца runloop tick.
//   - _v_makeReplacementSampleBuffer: проверяем CFArrayGetCount(dstArr)>0
//     перед CFArrayGetValueAtIndex(dstArr,0). Иначе segfault на новых
//     sample buffers без samples.
//   - shared _mpu_globalHookedClasses — больше нет двойного swizzle между
//     Tweak.x / WebRTCHooks.x / BrowserHooks.x.

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "_MPUMediaBufferAdapter.h"

#define MPU_PREFS_ID CFSTR("com.proximacore.mediaplaybackutils")

// === ОБЩИЕ ПЕРЕМЕННЫЕ (без static — видны другим .x) ===
BOOL              _enabled        = YES;
CVPixelBufferRef  _lastBuffer     = NULL;
id                _v_lock         = nil;
CFTimeInterval    _lastBufferTime = 0;

// FIX 3: общий набор свизленных классов
NSMutableSet     *_mpu_globalHookedClasses = nil;
id                _mpu_globalHookedLock    = nil;

// ── ЛОКАЛЬНОЕ ───
// FIX 5: убран hard-coded дефолт 192.168.1.44 — без явного rtspURL из prefs
// стрим не стартует.
static NSString             *_url             = nil;
static _MPUMediaBufferAdapter *_reader        = nil;
static CIContext            *_v_ciContext     = nil;
static NSString             *_currentStreamURL = nil;
static BOOL                  _isSwitching     = NO;

// ── prefs ────────────────────────────────────────────────────────────────────
static void _v_loadPrefs(void) {
    CFPreferencesAppSynchronize(MPU_PREFS_ID);
    CFPropertyListRef en = CFPreferencesCopyAppValue(CFSTR("enabled"), MPU_PREFS_ID);
    if (en) {
        if (CFGetTypeID(en) == CFBooleanGetTypeID())
            _enabled = CFBooleanGetValue((CFBooleanRef)en);
        CFRelease(en);
    }
    CFPropertyListRef u = CFPreferencesCopyAppValue(CFSTR("rtspURL"), MPU_PREFS_ID);
    if (u) {
        if (CFGetTypeID(u) == CFStringGetTypeID()) {
            NSString *s = (__bridge NSString *)u;
            if (s.length > 0) _url = [s copy];
        }
        CFRelease(u);
    }
}

// ── рестарт потока ───────────────────────────────────────────────────────────
static void _v_restartStreamIfNeeded(void) {
    static dispatch_queue_t restartQ;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        restartQ = dispatch_queue_create("com.proximacore.mpu.restart", DISPATCH_QUEUE_SERIAL);
    });

    dispatch_async(restartQ, ^{
        BOOL needRestart = NO;
        if (_reader && ![_currentStreamURL isEqualToString:_url]) needRestart = YES;

        if (needRestart) {
            _isSwitching = YES;
            [_reader stopStreaming];
            _reader = nil;
            _currentStreamURL = nil;
        }
        // FIX 5: без явно сконфигурированного URL стрим НЕ стартуем.
        if (!_reader && _enabled && _url.length > 0) {
            NSURL *u = [NSURL URLWithString:_url];
            if (!u) return;
            _currentStreamURL = [_url copy];
            _reader = [[_MPUMediaBufferAdapter alloc] initWithURL:u];
            _reader.pixelBufferCallback = ^(CVPixelBufferRef buffer) {
                if (!buffer) return;
                CVPixelBufferRef newBuf = CVPixelBufferRetain(buffer);
                CVPixelBufferRef oldBuf = NULL;
                @synchronized(_v_lock) {
                    oldBuf = _lastBuffer;
                    _lastBuffer = newBuf;
                    _lastBufferTime = CACurrentMediaTime();
                    _isSwitching = NO;
                }
                if (oldBuf) CVPixelBufferRelease(oldBuf);
            };
            [_reader startStreaming];
            NSLog(@"[MPU] Stream started: %@", _url);
        }
    });
}

static void _v_init(void) { _v_restartStreamIfNeeded(); }

static void _v_prefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n,
                             const void *obj, CFDictionaryRef i) {
    _v_loadPrefs();
    _v_restartStreamIfNeeded();
}

// ── создание замещающего sample-buffer С КОПИРОВАНИЕМ ATTACHMENTS ───────────
static CMSampleBufferRef _v_makeReplacementSampleBuffer(CMSampleBufferRef original) {
    CVPixelBufferRef src = NULL;
    @synchronized(_v_lock) {
        if (_lastBuffer) src = CVPixelBufferRetain(_lastBuffer);
    }
    if (!src) return NULL;

    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, src, &fmt) != noErr || !fmt) {
        CVPixelBufferRelease(src); return NULL;
    }

    CMSampleTimingInfo timing;
    if (!original || CMSampleBufferGetSampleTimingInfo(original, 0, &timing) != noErr) {
        timing.duration = CMTimeMake(1, 30);
        timing.presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000);
        timing.decodeTimeStamp = kCMTimeInvalid;
    }

    CMSampleBufferRef out = NULL;
    OSStatus s = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, src, fmt, &timing, &out);
    CFRelease(fmt);
    CVPixelBufferRelease(src);

    if (s != noErr || !out) return NULL;

    if (original) {
        CFArrayRef srcArr = CMSampleBufferGetSampleAttachmentsArray(original, false);
        if (srcArr && CFArrayGetCount(srcArr) > 0) {
            CFArrayRef dstArr = CMSampleBufferGetSampleAttachmentsArray(out, true);
            // FIX 3: dstArr может быть пустым для нового sample buffer — проверяем count
            if (dstArr && CFArrayGetCount(dstArr) > 0) {
                CFDictionaryRef srcDict = CFArrayGetValueAtIndex(srcArr, 0);
                CFMutableDictionaryRef dstDict =
                    (CFMutableDictionaryRef)CFArrayGetValueAtIndex(dstArr, 0);
                if (srcDict && dstDict &&
                    CFGetTypeID(srcDict) == CFDictionaryGetTypeID() &&
                    CFGetTypeID(dstDict) == CFDictionaryGetTypeID()) {
                    CFIndex n = CFDictionaryGetCount(srcDict);
                    if (n > 0) {
                        const void **keys = malloc(sizeof(void *) * n);
                        const void **vals = malloc(sizeof(void *) * n);
                        if (keys && vals) {
                            CFDictionaryGetKeysAndValues(srcDict, keys, vals);
                            for (CFIndex i = 0; i < n; i++)
                                CFDictionarySetValue(dstDict, keys[i], vals[i]);
                        }
                        if (keys) free(keys);
                        if (vals) free(vals);
                    }
                }
            }
        }
        CFDictionaryRef bufAtt = CMCopyDictionaryOfAttachments(kCFAllocatorDefault,
                                                                original,
                                                                kCMAttachmentMode_ShouldPropagate);
        if (bufAtt) {
            CMSetAttachments(out, bufAtt, kCMAttachmentMode_ShouldPropagate);
            CFRelease(bufAtt);
        }
        CFDictionaryRef bufAtt2 = CMCopyDictionaryOfAttachments(kCFAllocatorDefault,
                                                                 original,
                                                                 kCMAttachmentMode_ShouldNotPropagate);
        if (bufAtt2) {
            CMSetAttachments(out, bufAtt2, kCMAttachmentMode_ShouldNotPropagate);
            CFRelease(bufAtt2);
        }
    }

    return out;
}

// ── JPEG из буфера (для photo) ───────────────────────────────────────────────
static NSData *_v_jpegFromBuffer(CVPixelBufferRef buffer) {
    if (!buffer || !_v_ciContext) return nil;
    CIImage *ci = [CIImage imageWithCVPixelBuffer:buffer];
    if (!ci) return nil;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGImageRef cg = [_v_ciContext createCGImage:ci
                                       fromRect:ci.extent
                                         format:kCIFormatBGRA8
                                     colorSpace:cs];
    CGColorSpaceRelease(cs);
    if (!cg) return nil;
    NSData *d = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.92);
    CGImageRelease(cg);
    return d;
}

static BOOL _v_shouldSkipClass(NSString *clsName) {
    if (!clsName) return YES;
    static NSArray *blacklist;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        blacklist = @[
            @"_AVAssetWriterInputCaptureSampleBufferDelegate",
            @"AVCaptureMovieFileOutputInternal",
            @"AVCaptureSessionPresetResolver",
        ];
    });
    for (NSString *b in blacklist) if ([clsName isEqualToString:b]) return YES;
    return NO;
}

// ── 1. ПЕРЕХВАТ DELEGATE У AVCaptureVideoDataOutput ─────────────────────────
%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    if (!_enabled || !delegate) { %orig; return; }
    _v_init();

    Class cls = object_getClass(delegate);
    if (!cls) { %orig; return; }

    NSString *clsName = NSStringFromClass(cls);
    if (_v_shouldSkipClass(clsName)) { %orig; return; }

    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);

    // FIX 3: общий lock + общий set с другими .x — никаких двойных swizzle
    @synchronized(_mpu_globalHookedLock) {
        if (![_mpu_globalHookedClasses containsObject:clsName]) {
            Method m = class_getInstanceMethod(cls, sel);
            if (m) {
                const char *types = method_getTypeEncoding(m);
                __block IMP capturedIMP = method_getImplementation(m);

                IMP newIMP = imp_implementationWithBlock(^(id self_,
                    AVCaptureOutput *output, CMSampleBufferRef sb, AVCaptureConnection *conn) {
                    @try {
                        CMSampleBufferRef rep = (_enabled && sb)
                            ? _v_makeReplacementSampleBuffer(sb) : NULL;
                        CMSampleBufferRef use = rep ? rep : sb;
                        if (use)
                            ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))
                             capturedIMP)(self_, sel, output, use, conn);
                        // FIX 5: CFAutorelease вместо CFRelease — Instagram/Snapchat/
                        // TikTok/Zoom ретейнят sample buffer на фоновую очередь, и
                        // синхронный CFRelease ронял буфер → use-after-free → краш
                        // на старте камеры.
                        if (rep) CFAutorelease(rep);
                    } @catch (NSException *ex) {
                        NSLog(@"[MPU] hook exception %@: %@", clsName, ex.reason);
                        @try {
                            if (sb)
                                ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))
                                 capturedIMP)(self_, sel, output, sb, conn);
                        } @catch (...) {}
                    }
                });

                BOOL added = class_addMethod(cls, sel, newIMP, types);
                if (!added) {
                    IMP prev = class_replaceMethod(cls, sel, newIMP, types);
                    if (prev) capturedIMP = prev;
                }
                [_mpu_globalHookedClasses addObject:clsName];
                NSLog(@"[MPU] Hooked delegate: %@", clsName);
            }
        }
    }
    %orig;
}

%end

// ── 2. ПЕРЕХВАТ ФОТО ─────────────────────────────────────────────────────────
%hook AVCapturePhoto

- (CVPixelBufferRef)pixelBuffer {
    CVPixelBufferRef buf = NULL;
    @synchronized(_v_lock) { if (_enabled && _lastBuffer) buf = CVPixelBufferRetain(_lastBuffer); }
    if (buf) return (CVPixelBufferRef)CFAutorelease(buf);
    return %orig;
}

- (CVPixelBufferRef)previewPixelBuffer {
    CVPixelBufferRef buf = NULL;
    @synchronized(_v_lock) { if (_enabled && _lastBuffer) buf = CVPixelBufferRetain(_lastBuffer); }
    if (buf) return (CVPixelBufferRef)CFAutorelease(buf);
    return %orig;
}

- (NSData *)fileDataRepresentation {
    CVPixelBufferRef buf = NULL;
    @synchronized(_v_lock) { if (_enabled && _lastBuffer) buf = CVPixelBufferRetain(_lastBuffer); }
    if (buf) {
        NSData *d = _v_jpegFromBuffer(buf);
        CVPixelBufferRelease(buf);
        if (d) return d;
    }
    return %orig;
}

- (NSData *)fileDataRepresentationWithCustomizer:(id)customizer {
    CVPixelBufferRef buf = NULL;
    @synchronized(_v_lock) { if (_enabled && _lastBuffer) buf = CVPixelBufferRetain(_lastBuffer); }
    if (buf) {
        NSData *d = _v_jpegFromBuffer(buf);
        CVPixelBufferRelease(buf);
        if (d) return d;
    }
    return %orig;
}

%end

%hook AVCapturePhotoSettings
- (void)setEmbeddedThumbnailPhotoFormat:(NSDictionary *)format {
    if (_enabled) { %orig(nil); return; }
    %orig;
}
%end

%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id)delegate {
    if (_enabled) [settings setEmbeddedThumbnailPhotoFormat:nil];
    %orig;
}
%end

// ── 3. ПРЕДПРОСМОТР — AVCaptureVideoPreviewLayer ────────────────────────────
%hook AVCaptureVideoPreviewLayer

- (void)layoutSublayers {
    %orig;
    if (!_enabled) return;
    _v_init();

    CALayer *overlay = objc_getAssociatedObject(self, "_v_overlay");
    if (!overlay) {
        overlay = [CALayer layer];
        overlay.contentsGravity = kCAGravityResizeAspectFill;
        overlay.zPosition = 999999;
        overlay.backgroundColor = [UIColor blackColor].CGColor;
        overlay.opaque = YES;
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
    overlay.hidden = NO;
    overlay.opacity = 1.0;
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
        overlay.backgroundColor = [UIColor blackColor].CGColor;
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
                    [CATransaction commit];
                    CGImageRelease(cg);
                });
            }
        }
        CVPixelBufferRelease(bufCopy);
    });
}

%end

// ── 3a. ПРЕДПРОСМОТР — AVSampleBufferDisplayLayer (фильтры, WebRTC) ──────────
%hook AVSampleBufferDisplayLayer

- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!_enabled || !sampleBuffer) { %orig; return; }
    _v_init();
    CMSampleBufferRef rep = _v_makeReplacementSampleBuffer(sampleBuffer);
    if (rep) {
        %orig(rep);
        // FIX 3: AVSampleBufferDisplayLayer декодирует асинхронно через
        // VideoToolbox/GPU. Немедленный CFRelease(rep) приводил к
        // use-after-free и крашу в mediaserverd / прямо в процессе.
        // CFAutorelease даёт layer'у дочитать буфер до конца текущего tick.
        CFAutorelease(rep);
        return;
    }
    %orig;
}

%end

// ── 4. СЕССИЯ ───
%hook AVCaptureSession

- (void)startRunning {
    // FIX 5: убрана переустановка делегата под уже свизленным классом —
    // она гонялась с активным колбеком и давала EXC_BAD_ACCESS на старте.
    // Делегат уже захвачен в %hook AVCaptureVideoDataOutput setSampleBufferDelegate.
    if (_enabled) _v_init();
    %orig;
}

%end

// ── 5. УСТРОЙСТВО ────────────────────────────────────────────────────────────
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

// ── ИНИЦИАЛИЗАЦИЯ ────────────────────────────────────────────────────────────
%ctor {
    @autoreleasepool {
        NSString *bid  = [[NSBundle mainBundle] bundleIdentifier];
        NSString *path = [[NSBundle mainBundle] bundlePath];
        if (!bid) return;

        if ([bid hasPrefix:@"com.apple.springboard"])     return;
        if ([bid hasPrefix:@"com.apple.mediaserverd"])    return;
        if ([bid hasPrefix:@"com.apple.assetsd"])         return;
        if ([bid hasPrefix:@"com.apple.cameracaptured"])  return;
        if ([bid hasPrefix:@"com.apple.coremedia"])       return;
        if ([bid hasPrefix:@"com.apple.avconferenced"])   return;

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
        if ([path hasPrefix:@"/System/Library/"]) return;

        _v_lock = [NSObject new];
        // FIX 3: shared hooked set
        _mpu_globalHookedClasses = [NSMutableSet new];
        _mpu_globalHookedLock    = [NSObject new];

        _v_ciContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
        _v_loadPrefs();

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL, _v_prefsChanged,
            CFSTR("com.proximacore.mediaplaybackutils/prefsChanged"),
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        if (_enabled) {
            NSLog(@"[MPU] Loaded: %@ url=%@", bid, _url);
            %init;
        }
    }
}
📄 3. BrowserHooks.x
// BrowserHooks.x - MediaPlaybackUtils v1.7.7
// FIX 5 (v1.7.7):
//   - В браузерных процессах Tweak.x %ctor возвращается рано и оставляет
//     _v_lock = nil. BrowserHooks.x использовал @synchronized(_v_lock) —
//     это no-op (без локов), и параллельные читатели _lastBuffer
//     гонялись за CVPixelBufferRetain/Release → double-release → краш
//     в WebKit GPU/Content процессах. Добавлена инициализация _v_lock.
// FIX 3:
//   - Используем общий _mpu_globalHookedClasses из SharedState.h — никаких
//     двойных swizzle с Tweak.x/WebRTCHooks.x.
//   - Periodic rescan останавливается через ~60 сек (раньше крутился
//     бесконечно, что детектировалось как tampering антифрод-движками).

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "SharedState.h"

static dispatch_source_t _brw_timer = nil;

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

static void _brw_hookClass(Class cls) {
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

static void _brw_startPeriodicScan(void) {
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    _brw_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    __block int ticks = 0;
    dispatch_source_set_timer(_brw_timer, DISPATCH_TIME_NOW,
                              2 * NSEC_PER_SEC, 500 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_brw_timer, ^{
        _brw_scan();
        ticks++;
        if (ticks >= 30) {
            dispatch_source_cancel(_brw_timer);
        }
    });
    dispatch_resume(_brw_timer);
}

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
        // FIX 5: Tweak.x %ctor возвращается рано для браузерных bid и
        // оставляет _v_lock = nil → @synchronized(_v_lock) превращался в
        // no-op без локов → гонки на _lastBuffer → крах WebContent/GPU.
        if (!_v_lock) _v_lock = [NSObject new];

        %init;
        NSLog(@"[MPU/Browser] Loaded for %@", bid);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            _brw_scan();
            _brw_startPeriodicScan();
        });
    }
}
