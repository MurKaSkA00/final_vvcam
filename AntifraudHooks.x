// AntifraudHooks.x - MediaPlaybackUtils v2.0.1
// Полная маскировка подмены камеры
// FIX: убраны хуки AVCaptureSession/isRunning и AVCaptureConnection/isActive —
//      они блокировали capturePhoto: и вызывали зависание при съёмке

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

extern CVPixelBufferRef _lastBuffer;
extern id _v_lock;
extern BOOL _enabled;

// ── NSStringFromClass — скрываем _MPU суффикс ────────────────────────────────

static NSString *(*orig_NSStringFromClass)(Class) = NULL;

static NSString *hook_NSStringFromClass(Class cls) {
    NSString *r = orig_NSStringFromClass(cls);
    if (!r) return r;
    if ([r hasSuffix:@"_MPU"]) return [r substringToIndex:r.length - 4];
    return r;
}

// ── AVCaptureDevice — скрываем метаданные ────────────────────────────────────

%hook AVCaptureDevice

- (NSString *)localizedName {
    NSString *name = %orig;
    if (!name) return name;
    if ([name containsString:@"MPU"] || [name containsString:@"Virtual"] ||
        [name containsString:@"Stream"] || [name containsString:@"Tweak"] ||
        [name containsString:@"Proxima"] || [name containsString:@"Media"]) {
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
    if (p == AVCaptureDevicePositionUnspecified) return AVCaptureDevicePositionBack;
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

- (BOOL)isFocusPointOfInterestSupported { return YES; }
- (BOOL)isExposurePointOfInterestSupported { return YES; }
- (BOOL)isFlashAvailable { return YES; }
- (BOOL)isTorchAvailable { return YES; }

- (BOOL)hasMediaType:(AVMediaType)mediaType {
    if ([mediaType isEqualToString:AVMediaTypeVideo]) return YES;
    return %orig;
}

%end

// ── AVCaptureConnection ───────────────────────────────────────────────────────
// FIX: isEnabled и isActive намеренно НЕ хукаем.
//      capturePhoto: проверяет isActive у connection перед захватом кадра.
//      Принудительный return YES при реально неактивном connection → зависание.

%hook AVCaptureConnection

- (BOOL)isVideoMirroringSupported { return YES; }
- (BOOL)isVideoOrientationSupported { return YES; }

%end

// ── AVCaptureSession ──────────────────────────────────────────────────────────
// FIX: isRunning и isInterrupted намеренно НЕ хукаем.
//      capturePhoto: ждёт реального перехода состояния сессии через KVO/notifications.
//      Подмена значений → бесконечное ожидание → зависание приложения.

// ── AVCaptureDeviceFormat ─────────────────────────────────────────────────────

%hook AVCaptureDeviceFormat

- (CMVideoDimensions)highResolutionStillImageDimensions {
    CMVideoDimensions d = %orig;
    if (d.width == 0 || d.height == 0) {
        d.width = 4032;
        d.height = 3024;
    }
    return d;
}

%end

// ── NSProcessInfo — скрываем среду выполнения ────────────────────────────────

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

// ── UIDevice ──────────────────────────────────────────────────────────────────

%hook UIDevice

- (NSString *)model {
    NSString *m = %orig;
    if ([m containsString:@"Simulator"]) return @"iPhone";
    return m;
}

%end

// ── NSUserDefaults ────────────────────────────────────────────────────────────

%hook NSUserDefaults

- (id)objectForKey:(NSString *)key {
    if (key && ([key containsString:@"MediaPlaybackUtils"] ||
                [key containsString:@"proximacore"] ||
                [key containsString:@"MPU"])) {
        return nil;
    }
    return %orig;
}

%end

// ── NSFileManager ─────────────────────────────────────────────────────────────

%hook NSFileManager

- (BOOL)fileExistsAtPath:(NSString *)path {
    if (path && ([path containsString:@"MediaPlaybackUtils"] ||
                 [path containsString:@"proximacore"])) {
        return NO;
    }
    return %orig;
}

- (NSDictionary *)attributesOfItemAtPath:(NSString *)path error:(NSError **)error {
    if (path && ([path containsString:@"MediaPlaybackUtils"] ||
                 [path containsString:@"proximacore"])) {
        if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                                code:NSFileNoSuchFileError
                                            userInfo:nil];
        return nil;
    }
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
        if ([path hasPrefix:@"/usr/"]) return;
        if ([path hasPrefix:@"/System/"]) return;
        if ([bid hasPrefix:@"org.coolstar."]) return;
        if ([bid hasPrefix:@"com.tigisoftware."]) return;
        if ([bid hasPrefix:@"org.theos."]) return;
        if ([bid hasPrefix:@"science.xnu."]) return;
        if ([bid isEqualToString:@"xyz.willy.Zebra"]) return;
        if ([bid hasPrefix:@"com.opa334."]) return;
        if ([bid hasPrefix:@"com.palera1n"]) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            MSHookFunction((void *)NSStringFromClass,
                           (void *)hook_NSStringFromClass,
                           (void **)&orig_NSStringFromClass);
            %init;
            NSLog(@"[MPU/AntiIntrospect] Installed for %@", bid);
        });
    }
}
