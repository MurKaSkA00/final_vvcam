// StealthHooks.x - MediaPlaybackUtils v1.7.9
// FIX 6 (v1.7.9):
//   - _stealth_rebuild_filter() больше НЕ зовётся на каждый dyld-вызов.
//     Раньше O(images × calls × substrings) вешало watchdog на старте
//     Instagram/банков/Snapchat. Теперь фильтр инвалидируется только
//     через _dyld_register_func_for_add_image / _remove_image и
//     перестраивается лениво при первом обращении (атомарный флаг).
//   - Снят os_unfair_lock из горячего пути — заменён на atomic load.

#import <Foundation/Foundation.h>
#import <substrate.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <string.h>
#import <mach/mach.h>
#import <stdatomic.h>
#import <os/lock.h>

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
    if (strstr(name, "PhotoCaptureHooks"))  return YES;
    if (strstr(name, "AntifraudHooks"))     return YES;
    if (strstr(name, "StealthHooks"))       return YES;
    if (strstr(name, "JailbreakBypass"))    return YES;
    return NO;
}

static uint32_t (*orig_dyld_image_count)(void);
static const char *(*orig_dyld_get_image_name)(uint32_t);
static const struct mach_header *(*orig_dyld_get_image_header)(uint32_t);
static intptr_t (*orig_dyld_get_image_vmaddr_slide)(uint32_t);

#define MPU_MAX_IMAGES 4096
static uint32_t _filtered_to_real[MPU_MAX_IMAGES];
static uint32_t _filtered_count = 0;

static atomic_bool _filter_dirty = ATOMIC_VAR_INIT(true);
static os_unfair_lock _filter_rebuild_lock = OS_UNFAIR_LOCK_INIT;

static void _stealth_rebuild_locked(void) {
    uint32_t real = orig_dyld_image_count();
    uint32_t fc = 0;
    for (uint32_t i = 0; i < real && fc < MPU_MAX_IMAGES; i++) {
        const char *n = orig_dyld_get_image_name(i);
        if (!_stealth_should_hide_image(n))
            _filtered_to_real[fc++] = i;
    }
    _filtered_count = fc;
}

static inline void _stealth_ensure_filter(void) {
    if (!atomic_load_explicit(&_filter_dirty, memory_order_acquire)) return;
    os_unfair_lock_lock(&_filter_rebuild_lock);
    if (atomic_load_explicit(&_filter_dirty, memory_order_acquire)) {
        _stealth_rebuild_locked();
        atomic_store_explicit(&_filter_dirty, false, memory_order_release);
    }
    os_unfair_lock_unlock(&_filter_rebuild_lock);
}

// dyld callbacks — инвалидируют кеш при загрузке/выгрузке образа
static void _stealth_image_added(const struct mach_header *mh, intptr_t slide) {
    (void)mh; (void)slide;
    atomic_store_explicit(&_filter_dirty, true, memory_order_release);
}
static void _stealth_image_removed(const struct mach_header *mh, intptr_t slide) {
    (void)mh; (void)slide;
    atomic_store_explicit(&_filter_dirty, true, memory_order_release);
}

static uint32_t hook_dyld_image_count(void) {
    if (_stealth_is_trusted()) return orig_dyld_image_count();
    _stealth_ensure_filter();
    return _filtered_count;
}

static const char *hook_dyld_get_image_name(uint32_t idx) {
    if (_stealth_is_trusted()) return orig_dyld_get_image_name(idx);
    _stealth_ensure_filter();
    if (idx >= _filtered_count) return NULL;
    return orig_dyld_get_image_name(_filtered_to_real[idx]);
}

static const struct mach_header *hook_dyld_get_image_header(uint32_t idx) {
    if (_stealth_is_trusted()) return orig_dyld_get_image_header(idx);
    _stealth_ensure_filter();
    if (idx >= _filtered_count) return NULL;
    return orig_dyld_get_image_header(_filtered_to_real[idx]);
}

static intptr_t hook_dyld_get_image_vmaddr_slide(uint32_t idx) {
    if (_stealth_is_trusted()) return orig_dyld_get_image_vmaddr_slide(idx);
    _stealth_ensure_filter();
    if (idx >= _filtered_count) return 0;
    return orig_dyld_get_image_vmaddr_slide(_filtered_to_real[idx]);
}

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

%hook NSData
+ (instancetype)dataWithContentsOfFile:(NSString *)path {
    if (!_stealth_is_trusted() && path &&
        [path containsString:@"MediaPlaybackUtils"]) return nil;
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

%ctor {
    @autoreleasepool {
        NSString *bid  = [[NSBundle mainBundle] bundleIdentifier];
        NSString *path = [[NSBundle mainBundle] bundlePath];
        if (!bid) return;

        if ([bid hasPrefix:@"com.apple."]) return;
        if ([path hasPrefix:@"/usr/"]) return;
        if ([path hasPrefix:@"/System/"]) return;
        if ([bid isEqualToString:@"org.coolstar.SileoStore"]) return;
        if ([bid isEqualToString:@"com.tigisoftware.Filza"]) return;
        if ([bid isEqualToString:@"xyz.willy.Zebra"]) return;
        if ([bid hasPrefix:@"com.opa334.TrollStore"]) return;
        if ([bid hasPrefix:@"com.palera1n"]) return;

        // FIX 6: ставим хуки СИНХРОННО — иначе ранние вызовы dyld из +load
        // других модулей пойдут через нехукнутый путь, а позже мы их
        // перехватим уже в неконсистентном состоянии.
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

        // FIX 6: инвалидируем кеш только при изменениях dyld
        _dyld_register_func_for_add_image(_stealth_image_added);
        _dyld_register_func_for_remove_image(_stealth_image_removed);

        %init;
        NSLog(@"[MPU/Stealth] Active for %@", bid);
    }
}
