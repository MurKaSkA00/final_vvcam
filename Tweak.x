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
                        CMSampleBufferRef rep = (_enabled && sb && _url.length > 0)
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

Нужно сделать две вещи:

1. Выставить URL потока в настройках твика (обязательно!)
Откройте на устройстве: Настройки → Media Playback Utilities → RTSP URL и введите рабочий адрес вашего MJPEG/HLS-потока, например:

http://192.168.1.44:8888/live/stream/index.m3u8
(тот же, что был хардкодом в v1.7.6, или ваш собственный)

Если оставить пустым — overlay будет чёрным и все приложения с камерой будут краш-лупить. Это by-design твика: он подменяет камеру на ваш стрим, без стрима смысла в нём нет.

2. Поправить Tweak.x — не вешать overlay, когда стрима нет
Замените блок %hook AVCaptureVideoPreviewLayer целиком на это (в Tweak.x, начиная со строки // ── 3. ПРЕДПРОСМОТР):

// ── 3. ПРЕДПРОСМОТР — AVCaptureVideoPreviewLayer ────────────────────────────
%hook AVCaptureVideoPreviewLayer

- (void)layoutSublayers {
    %orig;
    if (!_enabled) return;
    // FIX 6: если URL не задан в prefs — overlay НЕ вешаем. Иначе превью
    // остаётся сплошным чёрным, антифрод видит "мёртвую камеру" → exit().
    if (_url.length == 0) return;
    _v_init();

    CALayer *overlay = objc_getAssociatedObject(self, "_v_overlay");
    if (!overlay) {
        overlay = [CALayer layer];
        overlay.contentsGravity = kCAGravityResizeAspectFill;
        overlay.zPosition = 999999;
        // FIX 6: НЕ ставим чёрный background и opaque=YES до первого буфера.
        // Иначе пока стрим коннектится, экран чёрный → антифрод-детект.
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

    // FIX 6: нет буфера → overlay прозрачный и скрыт, показываем
    // настоящую камеру вместо чёрного экрана.
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

// ── 3a. ПРЕДПРОСМОТР — AVSampleBufferDisplayLayer (фильтры, WebRTC) ──────────
%hook AVSampleBufferDisplayLayer

- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!_enabled || !sampleBuffer) { %orig; return; }
    // FIX 6: без URL потока не подменяем — пропускаем настоящий буфер.
    if (_url.length == 0) { %orig; return; }
    _v_init();
    CMSampleBufferRef rep = _v_makeReplacementSampleBuffer(sampleBuffer);
    if (rep) {
        %orig(rep);
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
