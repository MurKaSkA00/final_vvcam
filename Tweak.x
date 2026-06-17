// Tweak.x - MediaPlaybackUtils v1.5.1
// FIX 1: застывший кадр при переключении камеры (_lastBufferTime + сброс overlay)
// FIX 2: фото сохраняется со стрима (правильный CGImage рендер с colorspace)
// FIX 3: чёрный экран — CGImage fallback если IOSurface недоступен
// FIX 4: краш при смене картинки — безопасный порядок NULL→Release для CVPixelBuffer
// FIX 5: миниатюра фото берётся с реальной камеры — перехват previewPixelBuffer +
//        fileDataRepresentationWithCustomizer: + отключение embedded thumbnail
// FIX 6: зависание при съёмке — CIContext рендер вынесен ЗА пределы @synchronized

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "_MPUMediaBufferAdapter.h"

#define MPU_PREFS_ID CFSTR("com.proximacore.mediaplaybackutils")

// Не static — экспортируются для WebRTCHooks.x, AntifraudHooks.x, StealthHooks.x
BOOL _enabled = YES;
CVPixelBufferRef _lastBuffer = NULL;
id _v_lock = nil;

static NSString *_url = @"http://192.168.1.44:8888/live/stream/index.m3u8";
static _MPUMediaBufferAdapter *_reader = nil;
static CFTimeInterval _lastBufferTime = 0;
static CIContext *_v_ciContext = nil;
static NSString *_currentStreamURL = nil;
static BOOL _isSwitching = NO;

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

static void _v_restartStreamIfNeeded(void) {
    @synchronized(_v_lock) {
        if (_reader && ![_currentStreamURL isEqualToString:_url]) {
            _isSwitching = YES;
            [_reader stopStreaming];
            _reader = nil;
            _currentStreamURL = nil;
        }
        if (!_reader && _enabled) {
            NSURL *u = [NSURL URLWithString:_url];
            if (!u) return;
            _currentStreamURL = [_url copy];
            _reader = [[_MPUMediaBufferAdapter alloc] initWithURL:u];
            _reader.pixelBufferCallback = ^(CVPixelBufferRef buffer) {
                if (!buffer) return;
                @synchronized(_v_lock) {
                    // FIX 4: сначала Retain новый, потом Release старый
                    CVPixelBufferRef newBuffer = CVPixelBufferRetain(buffer);
                    CVPixelBufferRef oldBuffer = _lastBuffer;
                    _lastBuffer = newBuffer;
                    _lastBufferTime = CACurrentMediaTime();
                    _isSwitching = NO;
                    if (oldBuffer) CVPixelBufferRelease(oldBuffer);
                }
            };
            [_reader startStreaming];
            NSLog(@"[MPU] Stream started: %@", _url);
        }
    }
}

static void _v_init(void) { _v_restartStreamIfNeeded(); }

static void _v_prefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n,
                             const void *obj, CFDictionaryRef i) {
    _v_loadPrefs();
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        _v_restartStreamIfNeeded();
    });
}

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
    return (s == noErr) ? out : NULL;
}

// ── FIX 6: рендер JPEG вынесен ЗА пределы @synchronized ─────────────────────
// Сначала retain буфер (быстро, внутри лока), потом рендерим снаружи.
// Это устраняет зависание: CIContext и JPEG компрессия больше не держат мьютекс.
static NSData *_v_jpegFromCurrentBuffer(void) {
    // Шаг 1: быстро захватить буфер под локом
    CVPixelBufferRef buf = NULL;
    @synchronized(_v_lock) {
        if (_lastBuffer) buf = CVPixelBufferRetain(_lastBuffer);
    }
    if (!buf) return nil;

    // Шаг 2: тяжёлые операции — ВНЕ лока
    if (!_v_ciContext) {
        CVPixelBufferRelease(buf);
        return nil;
    }

    CIImage *ci = [CIImage imageWithCVPixelBuffer:buf];
    CVPixelBufferRelease(buf); // освобождаем как только CIImage создан

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

// ── 1. ПЕРЕХВАТ ДЕЛЕГАТА ──────────────────────────────────────────────────────

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    if (!_enabled || !delegate) { %orig; return; }
    _v_init();

    static NSMutableSet *swizzled = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ swizzled = [NSMutableSet new]; });

    Class cls = object_getClass(delegate);
    if (!cls) { %orig; return; }

    NSString *clsName = NSStringFromClass(cls);
    if ([clsName hasPrefix:@"RCT"] || [clsName hasPrefix:@"WK"] ||
        [clsName hasPrefix:@"WebKit"] ||
        [clsName hasPrefix:@"_"]) { %orig; return; }

    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);

    @synchronized(swizzled) {
        if (![swizzled containsObject:clsName]) {
            Method m = class_getInstanceMethod(cls, sel);
            if (m) {
                const char *types = method_getTypeEncoding(m);
                IMP origIMP = method_getImplementation(m);
                __block IMP capturedIMP = origIMP;

                IMP newIMP = imp_implementationWithBlock(^(id self_,
                    AVCaptureOutput *output, CMSampleBufferRef sb, AVCaptureConnection *conn) {
                    @try {
                        CMSampleBufferRef rep = (_enabled && sb)
                            ? _v_makeReplacementSampleBuffer(sb) : NULL;
                        CMSampleBufferRef use = rep ? rep : sb;
                        if (use)
                            ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))
                             capturedIMP)(self_, sel, output, use, conn);
                        if (rep) CFRelease(rep);
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
                [swizzled addObject:clsName];
                NSLog(@"[MPU] Hooked: %@", clsName);
            }
        }
    }
    %orig;
}

%end

// ── 2. ПЕРЕХВАТ ФОТО ──────────────────────────────────────────────────────────

%hook AVCapturePhoto

// FIX 6: retain буфера внутри лока, возврат снаружи
- (CVPixelBufferRef)pixelBuffer {
    CVPixelBufferRef buf = NULL;
    @synchronized(_v_lock) {
        if (_enabled && _lastBuffer) buf = CVPixelBufferRetain(_lastBuffer);
    }
    if (buf) return (CVPixelBufferRef)CFAutorelease(buf);
    return %orig;
}

// FIX 5 + FIX 6: миниатюра тоже из стрима, без удержания лока
- (CVPixelBufferRef)previewPixelBuffer {
    CVPixelBufferRef buf = NULL;
    @synchronized(_v_lock) {
        if (_enabled && _lastBuffer) buf = CVPixelBufferRetain(_lastBuffer);
    }
    if (buf) return (CVPixelBufferRef)CFAutorelease(buf);
    return %orig;
}

// FIX 6: рендер полностью вне лока — устраняет зависание при съёмке
- (NSData *)fileDataRepresentation {
    if (!_enabled) return %orig;
    NSData *d = _v_jpegFromCurrentBuffer();
    if (d) { NSLog(@"[MPU] Photo from stream (fileDataRepresentation)"); return d; }
    return %orig;
}

// FIX 5 + FIX 6: iOS 16+
- (NSData *)fileDataRepresentationWithCustomizer:(id)customizer {
    if (!_enabled) return %orig;
    NSData *d = _v_jpegFromCurrentBuffer();
    if (d) { NSLog(@"[MPU] Photo from stream (fileDataRepresentationWithCustomizer)"); return d; }
    return %orig;
}

%end

// ── 2.5. ОТКЛЮЧЕНИЕ EMBEDDED THUMBNAIL ───────────────────────────────────────

%hook AVCapturePhotoSettings

- (void)setEmbeddedThumbnailPhotoFormat:(NSDictionary *)format {
    if (_enabled) {
        %orig(nil);
        return;
    }
    %orig;
}

%end

%hook AVCapturePhotoOutput

- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings
                        delegate:(id)delegate {
    if (_enabled) {
        [settings setEmbeddedThumbnailPhotoFormat:nil];
    }
    %orig;
}

%end

// ── 3. ПРЕДПРОСМОТР ───────────────────────────────────────────────────────────

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

    // FIX мигание: только обновляем frame, НЕ сбрасываем contents
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

    @synchronized(_v_lock) {
        if (!_lastBuffer) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            overlay.contents = nil;
            overlay.backgroundColor = [UIColor blackColor].CGColor;
            [CATransaction commit];
            return;
        }

        CFTimeInterval age = CACurrentMediaTime() - _lastBufferTime;
        if (!_isSwitching && _lastBufferTime > 0 && age > 2.0) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            overlay.contents = nil;
            overlay.backgroundColor = [UIColor blackColor].CGColor;
            [CATransaction commit];

            if (!_isSwitching) {
                _isSwitching = YES;
                CVPixelBufferRef toRelease = _lastBuffer;
                _lastBuffer = NULL;
                _lastBufferTime = 0;
                if (toRelease) CVPixelBufferRelease(toRelease);
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    @synchronized(_v_lock) {
                        if (_reader) {
                            [_reader stopStreaming];
                            _reader = nil;
                            _currentStreamURL = nil;
                        }
                    }
                    _v_restartStreamIfNeeded();
                });
            }
            return;
        }

        // Быстрый путь — IOSurface
        IOSurfaceRef surf = CVPixelBufferGetIOSurface(_lastBuffer);
        if (surf) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            overlay.contents = (__bridge id)surf;
            overlay.frame = self.bounds;
            [CATransaction commit];
            return;
        }

        // Fallback — CGImage (для форматов без IOSurface)
        // FIX 6: retain буфер перед выходом из лока, рендерим снаружи
        CVPixelBufferRef buf = CVPixelBufferRetain(_lastBuffer);

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!_v_ciContext) { CVPixelBufferRelease(buf); return; }
            CIImage *ci = [CIImage imageWithCVPixelBuffer:buf];
            CVPixelBufferRelease(buf);
            if (!ci) return;
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            CGImageRef cg = [_v_ciContext createCGImage:ci
                                               fromRect:ci.extent
                                                 format:kCIFormatBGRA8
                                             colorSpace:cs];
            CGColorSpaceRelease(cs);
            if (cg) {
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                overlay.contents = (__bridge id)cg;
                overlay.frame = self.bounds;
                [CATransaction commit];
                CGImageRelease(cg);
            }
        });
    }
}

%end

// ── 3.5. ПЕРЕХВАТ СЕССИИ ─────────────────────────────────────────────────────

%hook AVCaptureSession

- (void)startRunning {
    if (_enabled) {
        _v_init();
        NSArray *outputs = [self outputs];
        for (AVCaptureOutput *output in outputs) {
            if ([output isKindOfClass:[AVCaptureVideoDataOutput class]]) {
                AVCaptureVideoDataOutput *vdo = (AVCaptureVideoDataOutput *)output;
                id delegate = vdo.sampleBufferDelegate;
                dispatch_queue_t queue = vdo.sampleBufferCallbackQueue;
                if (delegate && queue) {
                    [vdo setSampleBufferDelegate:delegate queue:queue];
                }
            }
        }
    }
    %orig;
}

%end

// ── 4. УСТРОЙСТВО ─────────────────────────────────────────────────────────────

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

// ── ИНИЦИАЛИЗАЦИЯ ─────────────────────────────────────────────────────────────

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        NSString *path = [[NSBundle mainBundle] bundlePath];
        if (!bid) return;
        if ([bid hasPrefix:@"com.apple.springboard"]) return;
        if ([bid hasPrefix:@"com.apple.WebKit"]) return;
        if ([bid hasPrefix:@"com.apple.mediaserverd"]) return;
        if ([bid hasPrefix:@"com.apple.assetsd"]) return;
        if ([bid hasPrefix:@"com.apple.coremedia"]) return;
        if ([bid hasPrefix:@"com.apple.avconferenced"]) return;
        if ([bid hasPrefix:@"com.apple.cameracaptured"]) return;
        if ([path hasPrefix:@"/usr/"]) return;
        if ([path hasPrefix:@"/System/Library/"]) return;

        _v_lock = [NSObject new];
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
