// AntifraudHooks.x - MediaPlaybackUtils v1.7.7
// FIX 3:
//   - PayPal bundle id (com.yourcompany.PPClient -> com.paypal.PPClient).
//   - isFocusPointOfInterestSupported / isExposurePointOfInterestSupported /
//     isFlashAvailable / isTorchAvailable БОЛЬШЕ НЕ возвращают безусловно YES.
//     Раньше это ломало Instagram/Snapchat: они пытались реально включить
//     torch на устройствах без него -> NSInvalidArgumentException -> крах.
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
    if ([r hasSuffix:@"_MPU"]) return [r substringToIndex:r.length - 4];
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
    // Audio-устройства (микрофоны) и external accessories легитимно
    // возвращают Unspecified. Принудительный Back ломал AVCaptureSession
    // в Instagram/Snapchat -> краш на старте захвата.
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

// FIX 3: возвращаем реальные возможности устройства.
// Раньше безусловный YES ломал Instagram/Snapchat: они дёргали setTorchMode:/
// setFocusPointOfInterest: и получали NSInvalidArgumentException на устройствах,
// где это реально не поддерживалось -> необработанное исключение -> краш.

- (BOOL)hasMediaType:(AVMediaType)mediaType {
    // FIX 4: больше не врём про hasMediaType:. Раньше безусловный YES для
    // AVMediaTypeVideo превращал микрофон в "видео-устройство". Приложение
    // пыталось сделать AVCaptureDeviceInput.deviceInputWithDevice: с
    // audio-устройством как видео-источником -> nil + NSException на
    // -[AVCaptureSession addInput:] -> краш при запуске камеры.
    // Настоящие камеры и так корректно возвращают YES для AVMediaTypeVideo,
    // поэтому подмена не нужна и только ломает приложения.
    return %orig;
}

%end

%hook AVCaptureConnection
// FIX 3: вернули %orig — иначе AVCaptureSession бросал на commitConfiguration,
// если устройство реально не поддерживало mirroring/orientation.
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

        dispatch_async(dispatch_get_main_queue(), ^{
            MSHookFunction((void *)NSStringFromClass,
                           (void *)hook_NSStringFromClass,
                           (void **)&orig_NSStringFromClass);
            %init;
            NSLog(@"[MPU/AntiIntrospect] Installed for %@", bid);
        });
    }
}
