// SharedState.h - MediaPlaybackUtils v1.8.4
#ifndef SHARED_STATE_H
#define SHARED_STATE_H

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>

extern BOOL              _enabled;
extern CVPixelBufferRef  _lastBuffer;
extern id                _v_lock;
extern CFTimeInterval    _lastBufferTime;

extern NSMutableSet     *_mpu_globalHookedClasses;
extern id                _mpu_globalHookedLock;

// Единый gatekeeper — вызывать из %ctor каждого модуля.
BOOL       _mpu_processIsLoadable(void);

// Проверка опасных (Swift/Kotlin/служебных) имён классов.
BOOL       _mpu_isUnsafeClassName(const char *cn);

// Ленивая безопасная инициализация CIContext (Metal → software fallback).
// НЕ вызывать из %ctor — только из горячего пути!
CIContext *_mpu_ciContextShared(void);

#endif
📄 SharedState.m (полная замена)
// SharedState.m - MediaPlaybackUtils v1.8.4
// Единственное физическое хранилище общих глобалов + общие helper-функции.

#import "SharedState.h"
#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>

BOOL              _enabled         = NO;
CVPixelBufferRef  _lastBuffer      = NULL;
id                _v_lock          = nil;
CFTimeInterval    _lastBufferTime  = 0;

NSMutableSet     *_mpu_globalHookedClasses = nil;
id                _mpu_globalHookedLock    = nil;

// =============================================================================
// Строгий gatekeeper. Вычисляется один раз на процесс.
// =============================================================================
BOOL _mpu_processIsLoadable(void) {
    static BOOL cached = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSBundle      *mb   = [NSBundle mainBundle];
        NSString      *bid  = mb.bundleIdentifier;
        NSString      *path = mb.bundlePath      ?: @"";
        NSString      *exe  = mb.executablePath  ?: @"";
        NSDictionary  *info = mb.infoDictionary;

        if (!bid || bid.length == 0) { cached = NO; return; }

        // 1) App-extensions (.appex / NSExtension)
        if ([path containsString:@".appex/"] ||
            [path hasSuffix:@".appex"])               { cached = NO; return; }
        if (info[@"NSExtension"] != nil)              { cached = NO; return; }

        // 2) Системные пути (демоны / сервисы)
        if ([path hasPrefix:@"/usr/"])                { cached = NO; return; }
        if ([path hasPrefix:@"/System/"])             { cached = NO; return; }
        if ([path hasPrefix:@"/Library/"])            { cached = NO; return; }
        if ([path hasPrefix:@"/sbin/"])               { cached = NO; return; }
        if ([path hasPrefix:@"/bin/"])                { cached = NO; return; }
        if ([path hasPrefix:@"/var/jb/usr/"])         { cached = NO; return; }
        if ([path hasPrefix:@"/var/jb/System/"])      { cached = NO; return; }
        if ([path hasPrefix:@"/var/jb/Library/"])     { cached = NO; return; }

        // 3) Все Apple-системные процессы
        if ([bid hasPrefix:@"com.apple."])            { cached = NO; return; }

        // 4) Jailbreak / package managers / debuggers
        NSArray *jb = @[
            @"org.coolstar.",
            @"com.silverhawkx.sileo",
            @"xyz.willy.Zebra",
            @"com.tigisoftware.",
            @"com.sparklabs.",
            @"cool.palera1n",
            @"com.opa334.",
            @"com.palera1n",
            @"org.theos.",
            @"science.xnu.",
            @"com.checkra.",
            @"com.unc0ver.",
        ];
        for (NSString *p in jb) {
            if ([bid hasPrefix:p] || [bid isEqualToString:p]) {
                cached = NO; return;
            }
        }

        // 5) Имя исполняемого файла — известные демоны
        NSString *exeName = exe.lastPathComponent ?: @"";
        NSArray  *daemons = @[
            @"navd", @"destinationd", @"mapspushd", @"locationd",
            @"searchd", @"spotlightd", @"callservicesd",
            @"identityservicesd", @"assertiond", @"backboardd",
            @"mediaserverd", @"SpringBoard", @"itunesstored",
            @"mobileactivationd", @"runningboardd", @"dasd",
            @"powerd", @"thermalmonitord", @"watchdogd",
            @"contextstored", @"healthd", @"siriknowledged",
            @"nsurlsessiond", @"cloudd", @"bird", @"apsd",
            @"pasted", @"useractivityd", @"sharingd",
            @"PhotoLibrary", @"photoanalysisd", @"cameracaptured",
        ];
        for (NSString *d in daemons) {
            if ([exeName isEqualToString:d]) { cached = NO; return; }
        }

        cached = YES;
    });
    return cached;
}

// =============================================================================
// Единая проверка "опасных" имён классов (Swift/Kotlin/служебные).
// =============================================================================
BOOL _mpu_isUnsafeClassName(const char *cn) {
    if (!cn || cn[0] == 0) return YES;
    // Swift mangled: _Tt..., _$s..., _$S...
    if (cn[0] == '_' && (cn[1] == 'T' || cn[1] == '$')) return YES;
    // Swift dotted "Module.Class" / Kotlin-Native ":" / '$' / non-ASCII
    for (const char *p = cn; *p; p++) {
        unsigned char c = (unsigned char)*p;
        if (c == '.' || c == '$' || c == ':' || c >= 0x80) return YES;
    }
    if (strncmp(cn, "__NS", 4) == 0) return YES;
    if (strncmp(cn, "_NS",  3) == 0) return YES;
    if (strncmp(cn, "OS_",  3) == 0) return YES;
    // Vision-/VisionKit-классы — там бывают proxy под капотом
    if (strncmp(cn, "VK", 2) == 0 && cn[2] >= 'A' && cn[2] <= 'Z') return YES;
    return NO;
}

// =============================================================================
// Безопасная ленивая инициализация CIContext.
// Metal → software fallback. Не вызывать из %ctor!
// =============================================================================
CIContext *_mpu_ciContextShared(void) {
    static CIContext *ctx = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            ctx = [CIContext contextWithOptions:nil];
        } @catch (__unused NSException *e) { ctx = nil; }
        if (!ctx) {
            @try {
                ctx = [CIContext contextWithOptions:@{
                    kCIContextUseSoftwareRenderer: @YES
                }];
            } @catch (__unused NSException *e) { ctx = nil; }
        }
    });
    return ctx;
}
