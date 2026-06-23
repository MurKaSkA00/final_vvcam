// PhotoCaptureHooks.x - MediaPlaybackUtils v1.7.8
// =============================================================================
// ПОДМЕНА ПРИ ФОТОГРАФИРОВАНИИ (still capture).
//
// Проблема: Tweak.x/WebRTCHooks.x/BrowserHooks.x подменяют только ВИДЕО-путь
// (AVCaptureVideoDataOutput / превью / AVSampleBufferDisplayLayer). Когда
// пользователь жмёт затвор, приложения берут кадр напрямую с сенсора через
// AVCapturePhotoOutput → AVCapturePhoto (iOS 11+) или AVCaptureStillImageOutput
// (legacy). Этот путь не перехватывался → СОХРАНЁННОЕ фото шло с реальной линзы.
//
// Решение: перехватываем сами объекты результата съёмки и их аксессоры данных
// (fileDataRepresentation / CGImageRepresentation / pixelBuffer / preview...),
// возвращая текущий кадр потока _lastBuffer — тот же, что виден в превью.
// Метаданные EXIF/GPS/дата берём из реального снимка (для антифрод/KYC),
// но ориентацию нормализуем в 1 (кадр уже ориентирован как в превью).
// =============================================================================

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "SharedState.h"

// AVCaptureStillImageOutput помечен deprecated с iOS 10, а проект собирается с
// -Werror. Глушим только это предупреждение для всего файла (legacy-путь нужен
// для старых приложений, которые всё ещё им пользуются).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#define MPU_PHOTO_LOG(fmt, ...) NSLog(@"[MPU/Photo] " fmt, ##__VA_ARGS__)

static CIContext *_mpu_photoCtx = nil;

// ── helpers ──────────────────────────────────────────────────────────────────

static inline BOOL _mpu_photo_active(void) {
    if (!_enabled) return NO;
    BOOL has = NO;
    @synchronized(_v_lock) { has = (_lastBuffer != NULL); }
    return has;
}

// retained копия текущего кадра потока (caller должен CVPixelBufferRelease)
static CVPixelBufferRef _mpu_copyReplacement(void) CF_RETURNS_RETAINED {
    CVPixelBufferRef src = NULL;
    @synchronized(_v_lock) {
        if (_lastBuffer) src = CVPixelBufferRetain(_lastBuffer);
    }
    return src;
}

// CGImage из pixel buffer (caller владеет — CGImageRelease)
static CGImageRef _mpu_createCGImage(CVPixelBufferRef pb) CF_RETURNS_RETAINED {
    if (!pb || !_mpu_photoCtx) return NULL;
    CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
    if (!ci) return NULL;
    return [_mpu_photoCtx createCGImage:ci fromRect:ci.extent];
}

// метаданные из реального JPEG (для сохранения EXIF/GPS/device)
static NSDictionary *_mpu_metadataFromData(NSData *data) {
    if (!data) return nil;
    CGImageSourceRef s = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!s) return nil;
    CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(s, 0, NULL);
    CFRelease(s);
    if (!props) return nil;
    return (__bridge_transfer NSDictionary *)props;
}

// кодируем наш кадр в JPEG; metadata — реальные свойства снимка (опц.)
static NSData *_mpu_encodeJPEG(CVPixelBufferRef pb, NSDictionary *metadata) {
    CGImageRef cg = _mpu_createCGImage(pb);
    if (!cg) return nil;

    NSMutableData *out = [NSMutableData data];
    CGImageDestinationRef dest =
        CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out,
                                         (__bridge CFStringRef)@"public.jpeg", 1, NULL);
    if (!dest) { CGImageRelease(cg); return nil; }

    NSMutableDictionary *opts = metadata ? [metadata mutableCopy]
                                         : [NSMutableDictionary dictionary];
    opts[(id)kCGImageDestinationLossyCompressionQuality] = @0.92;
    // Кадр уже ориентирован как в превью → нормализуем ориентацию,
    // иначе EXIF-Orientation из реального снимка повернёт картинку.
    opts[(id)kCGImagePropertyOrientation] = @1;
    NSMutableDictionary *tiff =
        [(opts[(id)kCGImagePropertyTIFFDictionary] ?: @{}) mutableCopy];
    tiff[(id)kCGImagePropertyTIFFOrientation] = @1;
    opts[(id)kCGImagePropertyTIFFDictionary] = tiff;

    CGImageDestinationAddImage(dest, cg, (__bridge CFDictionaryRef)opts);
    BOOL ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    CGImageRelease(cg);
    return ok ? out : nil;
}

// замена CMSampleBuffer (для legacy AVCaptureStillImageOutput)
static CMSampleBufferRef _mpu_makeSampleBuffer(CMSampleBufferRef original) CF_RETURNS_RETAINED {
    CVPixelBufferRef src = _mpu_copyReplacement();
    if (!src) return NULL;

    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, src, &fmt) != noErr || !fmt) {
        CVPixelBufferRelease(src);
        return NULL;
    }

    CMSampleTimingInfo timing;
    if (!original || CMSampleBufferGetSampleTimingInfo(original, 0, &timing) != noErr) {
        timing.duration = CMTimeMake(1, 30);
        timing.presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000);
        timing.decodeTimeStamp = kCMTimeInvalid;
    }

    CMSampleBufferRef out = NULL;
    OSStatus s = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, src,
                                                          fmt, &timing, &out);
    if (s == noErr && out && original) {
        CFDictionaryRef att = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, original,
                                                            kCMAttachmentMode_ShouldPropagate);
        if (att) { CMSetAttachments(out, att, kCMAttachmentMode_ShouldPropagate); CFRelease(att); }
    }
    CFRelease(fmt);
    CVPixelBufferRelease(src);
    return (s == noErr) ? out : NULL;
}

// =============================================================================
// AVCapturePhoto (iOS 11+) — основной современный путь
// =============================================================================
%hook AVCapturePhoto

- (NSData *)fileDataRepresentation {
    if (!_mpu_photo_active()) return %orig;
    CVPixelBufferRef pb = _mpu_copyReplacement();
    if (!pb) return %orig;
    NSData *orig = %orig;                          // реальный снимок → метаданные
    NSDictionary *meta = _mpu_metadataFromData(orig);
    NSData *out = _mpu_encodeJPEG(pb, meta);
    CVPixelBufferRelease(pb);
    if (out) { MPU_PHOTO_LOG(@"fileDataRepresentation replaced (%lu bytes)", (unsigned long)out.length); return out; }
    return orig;
}

- (NSData *)fileDataRepresentationWithCustomizer:(id)customizer {
    if (!_mpu_photo_active()) return %orig;
    CVPixelBufferRef pb = _mpu_copyReplacement();
    if (!pb) return %orig;
    NSData *orig = %orig;
    NSDictionary *meta = _mpu_metadataFromData(orig);
    NSData *out = _mpu_encodeJPEG(pb, meta);
    CVPixelBufferRelease(pb);
    return out ?: orig;
}

- (CGImageRef)CGImageRepresentation {
    if (!_mpu_photo_active()) return %orig;
    CVPixelBufferRef pb = _mpu_copyReplacement();
    if (!pb) return %orig;
    CGImageRef cg = _mpu_createCGImage(pb);
    CVPixelBufferRelease(pb);
    if (!cg) return %orig;
    return (CGImageRef)CFAutorelease(cg);
}

- (CGImageRef)previewCGImageRepresentation {
    if (!_mpu_photo_active()) return %orig;
    CVPixelBufferRef pb = _mpu_copyReplacement();
    if (!pb) return %orig;
    CGImageRef cg = _mpu_createCGImage(pb);
    CVPixelBufferRelease(pb);
    if (!cg) return %orig;
    return (CGImageRef)CFAutorelease(cg);
}

- (CVPixelBufferRef)pixelBuffer {
    if (!_mpu_photo_active()) return %orig;
    CVPixelBufferRef pb = _mpu_copyReplacement();
    if (!pb) return %orig;
    return (CVPixelBufferRef)CFAutorelease(pb);
}

- (CVPixelBufferRef)previewPixelBuffer {
    if (!_mpu_photo_active()) return %orig;
    CVPixelBufferRef pb = _mpu_copyReplacement();
    if (!pb) return %orig;
    return (CVPixelBufferRef)CFAutorelease(pb);
}

%end

// =============================================================================
// AVCapturePhotoOutput — class helper для iOS 10 sample-buffer пути
// =============================================================================
%hook AVCapturePhotoOutput

+ (NSData *)JPEGPhotoDataRepresentationForJPEGSampleBuffer:(CMSampleBufferRef)jpegSampleBuffer
                                  previewPhotoSampleBuffer:(CMSampleBufferRef)previewPhotoSampleBuffer {
    if (_mpu_photo_active()) {
        CVPixelBufferRef pb = _mpu_copyReplacement();
        if (pb) {
            NSData *out = _mpu_encodeJPEG(pb, nil);
            CVPixelBufferRelease(pb);
            if (out) return out;
        }
    }
    return %orig;
}

%end

// =============================================================================
// AVCaptureStillImageOutput (legacy, iOS < 11 и старые приложения)
// =============================================================================
%hook AVCaptureStillImageOutput

- (void)captureStillImageAsynchronouslyFromConnection:(AVCaptureConnection *)connection
                                    completionHandler:(void (^)(CMSampleBufferRef, NSError *))handler {
    if (!_mpu_photo_active() || !handler) { %orig; return; }

    void (^wrapped)(CMSampleBufferRef, NSError *) = ^(CMSampleBufferRef sb, NSError *err) {
        CMSampleBufferRef rep = _mpu_makeSampleBuffer(sb);
        if (rep) {
            handler(rep, nil);
            CFRelease(rep);
        } else {
            handler(sb, err);
        }
    };
    %orig(connection, wrapped);
}

+ (NSData *)jpegStillImageNSDataRepresentation:(CMSampleBufferRef)jpegSampleBuffer {
    if (_mpu_photo_active()) {
        CVPixelBufferRef pb = _mpu_copyReplacement();
        if (pb) {
            NSData *out = _mpu_encodeJPEG(pb, nil);
            CVPixelBufferRelease(pb);
            if (out) return out;
        }
    }
    return %orig;
}

%end

// =============================================================================
// ctor
// =============================================================================
%ctor {
    @autoreleasepool {
        NSString *bid  = [[NSBundle mainBundle] bundleIdentifier];
        NSString *path = [[NSBundle mainBundle] bundlePath];
        if (!bid) return;

        // системные / служебные процессы
        if ([bid hasPrefix:@"com.apple.springboard"]) return;
        if ([bid hasPrefix:@"com.apple.mediaserverd"]) return;
        if ([bid hasPrefix:@"com.apple.assetsd"]) return;
        if ([path hasPrefix:@"/usr/"]) return;
        if ([path hasPrefix:@"/System/"]) return;
        // браузеры/WebKit берут кадр через getUserMedia (видео-путь), нативного
        // AVCapturePhoto там нет — пропускаем, чтобы не рисковать стабильностью.
        if ([bid hasPrefix:@"com.apple.WebKit"])       return;
        if ([bid hasPrefix:@"com.apple.mobilesafari"]) return;
        if ([bid hasPrefix:@"com.google.chrome"])      return;
        if ([bid hasPrefix:@"com.brave.ios"])          return;
        if ([bid hasPrefix:@"com.microsoft.msedge"])   return;
        if ([bid hasPrefix:@"org.mozilla.ios"])        return;

        // _v_lock инициализируется в Tweak.x _v_init, но на случай раннего
        // вызова в этом процессе — подстрахуемся (как в BrowserHooks.x).
        if (!_v_lock) _v_lock = [NSObject new];
        if (!_mpu_photoCtx) {
            _mpu_photoCtx = [CIContext contextWithOptions:@{
                kCIContextUseSoftwareRenderer: @NO
            }];
        }

        %init;
        MPU_PHOTO_LOG(@"Loaded for %@", bid);
    }
}

#pragma clang diagnostic pop
