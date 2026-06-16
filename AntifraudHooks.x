// AntifraudHooks.x - MediaPlaybackUtils v1.5.2

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

static NSString *(*orig_NSStringFromClass)(Class) = NULL;
static NSString *hook_NSStringFromClass(Class cls) {
    NSString *r = orig_NSStringFromClass(cls);
    if (!r) return r;
    if ([r hasSuffix:@"_MPU"]) {
        return [r substringToIndex:r.length - 4];
    }
    return r;
}

// ── OVERLAY: УБРАЛИ хук sublayers — он удалял стрим слой и вызывал моргание ──

// ── СКРЫТИЕ МЕТАДАННЫХ УСТРОЙСТВА ────────────────────────────────────────────

%hook AVCaptureDevice

- (NSString *)localizedName {
    NSString *name = %orig;
    if (!name) return name;
    if ([name containsString:@"MPU"]     || [name containsString:@"Virtual"] ||
        [name containsString:@"Stream"]  || [name containsString:@"Tweak"]   ||
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
    if (p == AVCaptureDevicePositionUnspecified) {
        return AVCaptureDevicePositionBack;
    }
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

%end

// ── СОЕДИНЕНИЕ ────────────────────────────────────────────────────────────────

%hook AVCaptureConnection

- (BOOL)isEnabled {
    return YES;
}

- (BOOL)isActive {
    return YES;
}

%end

%ctor {
    @autoreleasepool {
        NSString *bid  = [[NSBundle mainBundle] bundleIdentifier];
        NSString *path = [[NSBundle mainBundle] bundlePath];
        if (!bid) return;

        if ([bid hasPrefix:@"com.apple."])          return;
        if ([path hasPrefix:@"/usr/"])              return;
        if ([path hasPrefix:@"/System/"])           return;
        if ([bid hasPrefix:@"org.coolstar."])       return;
        if ([bid hasPrefix:@"com.tigisoftware."])   return;
        if ([bid hasPrefix:@"org.theos."])          return;
        if ([bid hasPrefix:@"science.xnu."])        return;
        if ([bid isEqualToString:@"xyz.willy.Zebra"])          return;
        if ([bid hasPrefix:@"com.opa334."])         return;
        if ([bid hasPrefix:@"com.palera1n"])        return;

        dispatch_async(dispatch_get_main_queue(), ^{
            MSHookFunction((void *)NSStringFromClass,
                           (void *)hook_NSStringFromClass,
                           (void **)&orig_NSStringFromClass);
            %init;
            NSLog(@"[MPU/AntiIntrospect] Installed for %@", bid);
        });
    }
}
