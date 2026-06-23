
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
📄 4. AntifraudHooks.x
// AntifraudHooks.x - MediaPlaybackUtils v1.7.7
// FIX 5 (v1.7.7):
//   - MSHookFunction на NSStringFromClass теперь НЕ ставится в браузерных
//     и WebKit-процессах. Эта функция дёргается миллионы раз на старте
//     любого Cocoa-приложения; в WebKit + WebContent + GPU процессах
//     trampoline иногда не успевал инициализироваться до первого вызова
//     → SIGSEGV в Foundation до AppDelegate.
// FIX 4 (v1.7.7) — остаточные launch-crash'и в Instagram / Snapchat / TikTok /
// банковских приложениях, не исправленные FIX 3:
//   - hasMediaType: больше не возвращает безусловно YES для AVMediaTypeVideo.
//     Раньше это превращало микрофон и любые audio/external-устройства в
//     "видео-устройства". При итерации AVCaptureDevice.devices приложение
//     создавало AVCaptureDeviceInput с audio-устройством как video-source ->
//     nil + NSException -> краш при запуске камеры.
//   - position: больше не подменяет Unspecified на Back для ВСЕХ устройств.
//     Микрофоны/внешние устройства легитимно Unspecified — насильственный
//     Back ломал FSM AVCaptureSession в Instagram/Snapchat (краш на
//     -[AVCaptureSession addInput:]).
//   - localizedName: убрана подстрока "Media" из чёрного списка — она
//     совпадала со штатными системными именами и подменяла их на
//     "Back Camera", путая Instagram и сканеры.

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

static NSString *(*orig_NSStringFromClass)(Class) = NULL;

static NSString *hook_NSStringFromClass(Class cls) {
    NSString *r = orig_NSStringFromClass(cls);
    if (!r) return r;
    // FIX 5: классы названы с ПРЕФИКСОМ _MPU (например _MPUMediaBufferAdapter,
    // _MPUFrameProcessor). Старый код проверял hasSuffix:@"_MPU" — он никогда
    // не срабатывал, и PromonShield (PayPal/банки) ловил наши классы по имени
    // через objc_copyClassList -> приложение тихо закрывалось.
    if ([r hasPrefix:@"_MPU"]) {
        return [@"NS" stringByAppendingString:[r substringFromIndex:4]];
    }
    return r;
}


%hook AVCaptureDevice

- (NSString *)localizedName {
    NSString *name = %orig;
    if (!name) return name;
    // FIX 4: убрана подстрока "Media" — слишком широкая, ломала
    // легитимные имена системных устройств.
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
    AVCaptureDevicePosition p = %orig;
    // FIX 4: НЕ подменяем Unspecified на Back для всех устройств подряд.
    return p;
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
    // FIX 4: больше не врём про hasMediaType:.
    return %orig;
}

%end

%hook AVCaptureConnection
// FIX 3: вернули %orig — иначе AVCaptureSession бросал на commitConfiguration.
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
    NSMutableDictionary *env = [%orig mutableCopy];
    if (!env) return %orig;
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
    if (key && ([key containsString:@"MediaPlaybackUtils"] ||
                [key containsString:@"proximacore"] ||
                [key containsString:@"MPU"])) return nil;
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
        // FIX 5: пропускаем браузеры и WebKit-XPC процессы — MSHookFunction
        // на NSStringFromClass в них ронял Safari/Chrome до AppDelegate.
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

        dispatch_async(dispatch_get_main_queue(), ^{
            MSHookFunction((void *)NSStringFromClass,
                           (void *)hook_NSStringFromClass,
                           (void **)&orig_NSStringFromClass);
            %init;
            NSLog(@"[MPU/AntiIntrospect] Installed for %@", bid);
        });
    }
}
📄 5. JailbreakBypass.x
// JailbreakBypass.x - MediaPlaybackUtils v1.7.7
// FIX 5 (v1.7.7):
//   - Bank of America bundle: com.bankofamerica.BofAMobileBank ->
//     com.bankofamerica.BofAMobileBanking (соответствует Plist-фильтру
//     и App Store). Без этого bypass-хуки не активировались, и приложение
//     детектило твик через дефолтный stat("/Library/MobileSubstrate")
//     → тихий exit() на старте.
// FIX 3:
//   - PayPal bundle id (com.yourcompany.PPClient -> com.paypal.PPClient).
//   - _path_is_blacklisted переписан на чистые C-строки (strcmp/strlen) БЕЗ NSString.
//     Раньше из хуков open()/stat()/fopen() вызывался [NSString stringWithUTF8String:]
//     + [NSString hasPrefix:], а NSString сам дёргает open() для локалей -> рекурсия
//     -> stack overflow -> краш на запуске.

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
    for (int i = 0; _jb_blacklist_paths[i]; i++) {
        const char *bad = _jb_blacklist_paths[i];
        size_t blen = strlen(bad);
        if (plen < blen) continue;
        if (strncmp(path, bad, blen) != 0) continue;
        if (plen == blen) return YES;
        if (path[blen] == '/') return YES;
    }
    return NO;
}

// ========================================
// SYSCALL HOOKS
// ========================================

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

// ========================================
// ObjC HOOKS
// ========================================

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
