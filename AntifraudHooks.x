// AntifraudHooks.x - MediaPlaybackUtils v1.7.9
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

%hook AVCaptureConnection
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

        // FIX 6: убран MSHookFunction(NSStringFromClass) — только %init
        %init;
        NSLog(@"[MPU/AntiIntrospect] Installed for %@", bid);
    }
}
