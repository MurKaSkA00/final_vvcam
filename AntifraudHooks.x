// AntifraudHooks.x - MediaPlaybackUtils v2.0.3 (logos-safe)
// FIX 6 (v1.7.9):
//   - УБРАН MSHookFunction(NSStringFromClass). Эта функция вызывается
//     миллионы раз на старте, а dispatch_async-установка trampoline'а
//     создавала окно SIGSEGV на NULL (orig_NSStringFromClass еще не
//     инициализирован, а calls уже идут через jmp). Классы и так
//     с префиксом _MPU и не светятся в NSBundle.allBundles (см. Stealth).
//   - Сужена маска NSUserDefaults: только префиксы "MediaPlaybackUtils",
//     "proximacore", "MPUStream" (раньше containsString:@"MPU" ловил
//     системные ключи вроде "_UIKitMPU*", из-за чего часть фреймворков
//     SDK не получали свои настройки и тихо exit'или).
//   - %hook NSProcessInfo - environment вызывает %orig ровно один раз.
// FIX (v1.8.0):
//   - УДАЛЁН %hook AVCaptureConnection с однострочными методами
//     isVideoMirroringSupported / isVideoOrientationSupported — свежий
//     logos из master-theos не парсит однострочные { return %orig; },
//     ломая раскрытие. Эти геттеры всё равно ничего не подменяли —
//     просто проксировали %orig без логики. Удаление безопасно: реальные
//     значения от системы и так корректны для антифрод-проверок.
// FIX (v2.0.3):
//   - %ctor переведён на единый gatekeeper _mpu_processIsLoadable() из
//     SharedState.m. Прежний inline-чек блокировал только
//     com.apple.springboard, поэтому dylib грузился в com.apple.Preferences
//     и его же NSFileManager-хук скрывал MediaPlaybackUtils.plist от
//     PreferenceLoader — в результате твик не появлялся в Настройках.

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

%hook AVCaptureDevice

- (NSString *)localizedName {
    NSString *name = %orig;
    if (!name) return name;
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
    return %orig;
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
    return %orig;
}

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
    NSDictionary *orig = %orig;       // FIX 6: один вызов
    if (!orig) return nil;
    NSMutableDictionary *env = [orig mutableCopy];
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
    // FIX 6: только префиксы, не containsString — иначе ловили системные ключи
    if (key && ([key hasPrefix:@"MediaPlaybackUtils"] ||
                [key hasPrefix:@"proximacore"] ||
                [key hasPrefix:@"MPUStream"] ||
                [key hasPrefix:@"com.proximacore"])) return nil;
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
        // v2.0.3: используем единый gatekeeper из SharedState.m, чтобы
        // надёжно НЕ грузиться в com.apple.Preferences / com.apple.* /
        // системные демоны. Прежний inline-чек блокировал только
        // springboard, из-за чего NSFileManager-хук скрывал prefs-бандл
        // от самой Settings.app, и твик не появлялся в Настройках.
        if (!_mpu_processIsLoadable()) return;

        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];

        // Дополнительно: браузеры (WebKit/Safari/Chrome/Brave/Edge/Firefox/etc.)
        // не нуждаются в антифрод-косметике AVCaptureDevice и иногда падают на
        // NSProcessInfo-хуке из-за своей собственной песочницы окружения.
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

        %init;
        NSLog(@"[MPU/AntiIntrospect] Installed for %@", bid);
    }
}
