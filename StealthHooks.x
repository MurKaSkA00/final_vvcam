// StealthHooks.x - MediaPlaybackUtils v2.0.0
// Полное скрытие твика из памяти процесса

#import <Foundation/Foundation.h>
#import <substrate.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <string.h>
#import <mach/mach.h>

static BOOL _stealth_is_trusted(void) {
    static BOOL trusted = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (!bid) return;
        NSArray *whitelist = @[
            @"org.coolstar.SileoStore",
            @"com.silverhawkx.sileo",
            @"xyz.willy.Zebra",
            @"com.tigisoftware.Filza",
            @"com.sparklabs.Installer",
            @"cool.palera1n",
            @"com.opa334.TrollStore",
            @"com.opa334.TrollStorePersistenceHelper",
        ];
        for (NSString *w in whitelist) {
            if ([bid hasPrefix:w] || [bid isEqualToString:w]) {
                trusted = YES; return;
            }
        }
        NSString *path = [[NSBundle mainBundle] bundlePath];
        if ([path hasPrefix:@"/var/jb/"]) trusted = YES;
    });
    return trusted;
}

static BOOL _stealth_should_hide_image(const char *name) {
    if (!name) return NO;
    if (strstr(name, "MediaPlaybackUtils")) return YES;
    if (strstr(name, "MobileSubstrate"))    return YES;
    if (strstr(name, "libsubstrate"))       return YES;
    if (strstr(name, "libhooker"))          return YES;
    if (strstr(name, "libellekit"))         return YES;
    if (strstr(name, "Substitute"))         return YES;
    if (strstr(name, "TweakInject"))        return YES;
    if (strstr(name, "ChOma"))              return YES;
    if (strstr(name, "WebRTCHooks"))        return YES;
    if (strstr(name, "AntifraudHooks"))     return YES;
    if (strstr(name, "StealthHooks"))       return YES;
    if (strstr(name, "JailbreakBypass"))    return YES;
    return NO;
}

// ── dyld image список ─────────────────────────────────────────────────────────

static uint32_t (*orig_dyld_image_count)(void);
static const char *(*orig_dyld_get_image_name)(uint32_t);
static const struct mach_header *(*orig_dyld_get_image_header)(uint32_t);
static intptr_t (*orig_dyld_get_image_vmaddr_slide)(uint32_t);

static uint32_t  _filtered_to_real[2048];
static uint32_t  _filtered_count = 0;

static void _stealth_rebuild_filter(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        uint32_t real = orig_dyld_image_count();
        _filtered_count = 0;
        for (uint32_t i = 0; i < real && _filtered_count < 2048; i++) {
            if (!_stealth_should_hide_image(orig_dyld_get_image_name(i)))
                _filtered_to_real[_filtered_count++] = i;
        }
    });
}

static uint32_t hook_dyld_image_count(void) {
    if (_stealth_is_trusted()) return orig_dyld_image_count();
    _stealth_rebuild_filter();
    return _filtered_count;
}

static const char *hook_dyld_get_image_name(uint32_t idx) {
    if (_stealth_is_trusted()) return orig_dyld_get_image_name(idx);
    _stealth_rebuild_filter();
    if (idx >= _filtered_count) return NULL;
    return orig_dyld_get_image_name(_filtered_to_real[idx]);
}

static const struct mach_header *hook_dyld_get_image_header(uint32_t idx) {
    if (_stealth_is_trusted()) return orig_dyld_get_image_header(idx);
    _stealth_rebuild_filter();
    if (idx >= _filtered_count) return NULL;
    return orig_dyld_get_image_header(_filtered_to_real[idx]);
}

static intptr_t hook_dyld_get_image_vmaddr_slide(uint32_t idx) {
    if (_stealth_is_trusted()) return orig_dyld_get_image_vmaddr_slide(idx);
    _stealth_rebuild_filter();
    if (idx >= _filtered_count) return 0;
    return orig_dyld_get_image_vmaddr_slide(_filtered_to_real[idx]);
}

// ── dladdr — скрываем адреса наших функций ───────────────────────────────────

static int (*orig_dladdr)(const void *, Dl_info *);
static int hook_dladdr(const void *addr, Dl_info *info) {
    int r = orig_dladdr(addr, info);
    if (_stealth_is_trusted()) return r;
    if (r && info && info->dli_fname && _stealth_should_hide_image(info->dli_fname)) {
        info->dli_fname = "/System/Library/Frameworks/AVFoundation.framework/AVFoundation";
        info->dli_sname = NULL;
        info->dli_saddr = NULL;
    }
    return r;
}

// ── NSString чтение файлов — скрываем пути твика ─────────────────────────────

%hook NSString

+ (instancetype)stringWithContentsOfFile:(NSString *)path
                                 encoding:(NSStringEncoding)enc
                                    error:(NSError **)err {
    if (!_stealth_is_trusted() && path) {
        if ([path containsString:@"MediaPlaybackUtils"] ||
            [path containsString:@"proximacore"] ||
            ([path containsString:@"MobileSubstrate"] &&
             ![path containsString:@"dpkg"])) {
            if (err) *err = nil;
            return @"";
        }
    }
    return %orig;
}

+ (instancetype)stringWithContentsOfFile:(NSString *)path
                            usedEncoding:(NSStringEncoding *)enc
                                   error:(NSError **)err {
    if (!_stealth_is_trusted() && path) {
        if ([path containsString:@"MediaPlaybackUtils"] ||
            [path containsString:@"proximacore"] ||
            ([path containsString:@"MobileSubstrate"] &&
             ![path containsString:@"dpkg"])) {
            if (err) *err = nil;
            return @"";
        }
    }
    return %orig;
}

%end

// ── NSBundle — скрываем наши бандлы ──────────────────────────────────────────

%hook NSBundle

+ (NSArray<NSBundle *> *)allBundles {
    NSArray *orig = %orig;
    if (!orig || _stealth_is_trusted()) return orig;
    NSMutableArray *clean = [NSMutableArray arrayWithCapacity:orig.count];
    for (NSBundle *b in orig) {
        NSString *bid   = b.bundleIdentifier;
        NSString *bpath = b.bundlePath;
        if (bid && ([bid containsString:@"proximacore"] ||
                    [bid containsString:@"mediaplaybackutils"])) continue;
        if (bpath && _stealth_should_hide_image([bpath fileSystemRepresentation])) continue;
        [clean addObject:b];
    }
    return clean;
}

+ (NSArray<NSBundle *> *)allFrameworks {
    NSArray *orig = %orig;
    if (!orig || _stealth_is_trusted()) return orig;
    NSMutableArray *clean = [NSMutableArray arrayWithCapacity:orig.count];
    for (NSBundle *b in orig) {
        NSString *bpath = b.bundlePath;
        if (bpath && _stealth_should_hide_image([bpath fileSystemRepresentation])) continue;
        [clean addObject:b];
    }
    return clean;
}

%end

// ── NSData — блокируем чтение бинарников твика ───────────────────────────────

%hook NSData

+ (instancetype)dataWithContentsOfFile:(NSString *)path {
    if (!_stealth_is_trusted() && path &&
        [path containsString:@"MediaPlaybackUtils"]) {
        return nil;
    }
    return %orig;
}

+ (instancetype)dataWithContentsOfFile:(NSString *)path
                               options:(NSDataReadingOptions)opts
                                 error:(NSError **)err {
    if (!_stealth_is_trusted() && path &&
        [path containsString:@"MediaPlaybackUtils"]) {
        if (err) *err = nil;
        return nil;
    }
    return %orig;
}

%end

// ── ИНИЦИАЛИЗАЦИЯ ─────────────────────────────────────────────────────────────

%ctor {
    @autoreleasepool {
        NSString *bid  = [[NSBundle mainBundle] bundleIdentifier];
        NSString *path = [[NSBundle mainBundle] bundlePath];
        if (!bid) return;

        if ([bid hasPrefix:@"com.apple."]) return;
        if ([path hasPrefix:@"/usr/"])     return;
        if ([path hasPrefix:@"/System/"])  return;
        if ([bid isEqualToString:@"org.coolstar.SileoStore"]) return;
        if ([bid isEqualToString:@"com.tigisoftware.Filza"])   return;
        if ([bid isEqualToString:@"xyz.willy.Zebra"])          return;
        if ([bid hasPrefix:@"com.opa334.TrollStore"])          return;
        if ([bid hasPrefix:@"com.palera1n"])                   return;

        dispatch_async(dispatch_get_main_queue(), ^{
            MSHookFunction((void *)_dyld_image_count,
                           (void *)hook_dyld_image_count,
                           (void **)&orig_dyld_image_count);
            MSHookFunction((void *)_dyld_get_image_name,
                           (void *)hook_dyld_get_image_name,
                           (void **)&orig_dyld_get_image_name);
            MSHookFunction((void *)_dyld_get_image_header,
                           (void *)hook_dyld_get_image_header,
                           (void **)&orig_dyld_get_image_header);
            MSHookFunction((void *)_dyld_get_image_vmaddr_slide,
                           (void *)hook_dyld_get_image_vmaddr_slide,
                           (void **)&orig_dyld_get_image_vmaddr_slide);
            MSHookFunction((void *)dladdr,
                           (void *)hook_dladdr,
                           (void **)&orig_dladdr);
            %init;
            NSLog(@"[MPU/Stealth] Active for %@", bid);
        });
    }
}
