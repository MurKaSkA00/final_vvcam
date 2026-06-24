// JailbreakBypass.x - MediaPlaybackUtils v1.7.9
// FIX 6 (v1.7.9):
//   - Добавлен fast-path: пути внутри своего app bundle (а в Cocoa-приложении
//     это >99% всех open()/stat() на старте — ресурсы, .lproj, шрифты,
//     asset catalogs) сразу возвращают NO из _path_is_blacklisted БЕЗ
//     прохода по 50+ строкам. Это снимает основной watchdog-риск твика.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#import <dlfcn.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <sys/mount.h>
#import <unistd.h>
#import <fcntl.h>
#import <dirent.h>
#import <stdio.h>
#import <string.h>
#import <errno.h>
#import <stdlib.h>

static NSArray<NSString *> *_jb_targetBundles(void) {
    static NSArray *list = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[
            @"com.paypal.PPClient",
            @"com.burbn.instagram",
            @"com.instagram.Instagram",
            @"com.snapchat.snapchat",
            @"com.zhiliaoapp.musically",
            @"com.facebook.Facebook",
            @"com.atebits.Tweetie2",
            @"com.google.ios.youtube",
            @"com.netflix.Netflix",
            @"com.ubercab.UberClient",
            @"com.doordash.DoorDash-Consumer",
            @"com.citigroup.citimobile",
            @"com.chase.sig.ios",
            @"com.bankofamerica.BofAMobileBanking",
            @"com.skype.skype",
            @"us.zoom.videomeetings",
            @"com.venmo.Venmo",
            @"com.cashapp.squarecash",
        ];
    });
    return list;
}

static BOOL _jb_shouldBypass = NO;

// FIX 6: app bundle fast-path
static char   _jb_app_bundle_path[1024] = {0};
static size_t _jb_app_bundle_path_len   = 0;
static char   _jb_app_data_path[1024]   = {0};
static size_t _jb_app_data_path_len     = 0;

static const char *_jb_blacklist_paths[] = {
    "/Applications/Cydia.app",
    "/Library/MobileSubstrate",
    "/Library/Substitute",
    "/Library/TweakInject",
    "/usr/lib/libsubstrate.dylib",
    "/usr/lib/libhooker.dylib",
    "/usr/lib/libellekit.dylib",
    "/usr/lib/libsubstitute.dylib",
    "/usr/lib/substrate",
    "/usr/lib/TweakInject.dylib",
    "/usr/bin/cycript",
    "/usr/bin/ssh",
    "/usr/sbin/sshd",
    "/usr/bin/sileo",
    "/etc/apt",
    "/etc/ssh/sshd_config",
    "/private/var/lib/apt",
    "/private/var/lib/cydia",
    "/private/var/stash",
    "/private/var/tmp/cydia.log",
    "/bin/bash",
    "/bin/sh",
    "/var/jb/Library/MobileSubstrate",
    "/var/jb/Library/Substitute",
    "/var/jb/Library/TweakInject",
    "/var/jb/usr/lib/libsubstrate.dylib",
    "/var/jb/usr/lib/libhooker.dylib",
    "/var/jb/usr/lib/libellekit.dylib",
    "/var/jb/usr/lib/libsubstitute.dylib",
    "/var/jb/usr/lib/TweakInject.dylib",
    "/var/jb/usr/bin/cycript",
    "/var/jb/usr/bin/ssh",
    "/var/jb/etc/apt",
    "/var/jb/etc/ssh/sshd_config",
    "/var/jb/bin/bash",
    "/var/jb/bin/sh",
    "/var/jb/Applications/Cydia.app",
    "/var/jb/.jailbroken",
    "/var/LIB/MobileSubstrate",
    "/var/LIB/TweakInject",
    "/.installed_unc0ver",
    "/.bootstrapped_electra",
    "/taurine",
    "/palera1n",
    NULL
};

static BOOL _path_is_blacklisted(const char *path) {
    if (!path || path[0] == 0) return NO;
    size_t plen = strlen(path);

    // FIX 6: fast-path — путь внутри app bundle / app sandbox никогда не blacklist
    if (_jb_app_bundle_path_len > 0 && plen >= _jb_app_bundle_path_len &&
        memcmp(path, _jb_app_bundle_path, _jb_app_bundle_path_len) == 0) return NO;
    if (_jb_app_data_path_len > 0 && plen >= _jb_app_data_path_len &&
        memcmp(path, _jb_app_data_path, _jb_app_data_path_len) == 0) return NO;

    for (int i = 0; _jb_blacklist_paths[i]; i++) {
        const char *bad = _jb_blacklist_paths[i];
        size_t blen = strlen(bad);
        if (plen < blen) continue;
        if (memcmp(path, bad, blen) != 0) continue;
        if (plen == blen) return YES;
        if (path[blen] == '/') return YES;
    }
    return NO;
}

static int (*orig_stat)(const char *, struct stat *);
static int hook_stat(const char *path, struct stat *buf) {
    if (_jb_shouldBypass && _path_is_blacklisted(path)) { errno = ENOENT; return -1; }
    return orig_stat(path, buf);
}

static int (*orig_lstat)(const char *, struct stat *);
static int hook_lstat(const char *path, struct stat *buf) {
    if (_jb_shouldBypass && _path_is_blacklisted(path)) { errno = ENOENT; return -1; }
    return orig_lstat(path, buf);
}

static int (*orig_access)(const char *, int);
static int hook_access(const char *path, int mode) {
    if (_jb_shouldBypass && _path_is_blacklisted(path)) { errno = ENOENT; return -1; }
    return orig_access(path, mode);
}

static int (*orig_open)(const char *, int, ...);
static int hook_open(const char *path, int flags, ...) {
    if (_jb_shouldBypass && _path_is_blacklisted(path)) { errno = ENOENT; return -1; }
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap; va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    return orig_open(path, flags, mode);
}

static FILE *(*orig_fopen)(const char *, const char *);
static FILE *hook_fopen(const char *path, const char *mode) {
    if (_jb_shouldBypass && _path_is_blacklisted(path)) { errno = ENOENT; return NULL; }
    return orig_fopen(path, mode);
}

static DIR *(*orig_opendir)(const char *);
static DIR *hook_opendir(const char *path) {
    if (_jb_shouldBypass && _path_is_blacklisted(path)) { errno = ENOENT; return NULL; }
    return orig_opendir(path);
}

static char *(*orig_getenv)(const char *);
static char *hook_getenv(const char *name) {
    if (!name) return orig_getenv(name);
    if (_jb_shouldBypass) {
        if (strcmp(name, "DYLD_INSERT_LIBRARIES") == 0) return NULL;
        if (strcmp(name, "_MSSafeMode") == 0) return NULL;
        if (strcmp(name, "_SafeMode") == 0) return NULL;
    }
    return orig_getenv(name);
}

static const char *_jb_dlsym_blacklist[] = {
    "MSHookFunction",
    "MSHookMessageEx",
    "MSGetImageByName",
    "MSFindSymbol",
    "LHHookFunctions",
    "SubHookFunction",
    "EKHook",
    NULL
};

static void *(*orig_dlsym)(void *, const char *);
static void *hook_dlsym(void *handle, const char *symbol) {
    if (_jb_shouldBypass && symbol) {
        for (int i = 0; _jb_dlsym_blacklist[i]; i++) {
            if (strcmp(symbol, _jb_dlsym_blacklist[i]) == 0) return NULL;
        }
    }
    return orig_dlsym(handle, symbol);
}

static ssize_t (*orig_readlink)(const char *, char *, size_t);
static ssize_t hook_readlink(const char *path, char *buf, size_t bufsize) {
    if (_jb_shouldBypass && _path_is_blacklisted(path)) { errno = ENOENT; return -1; }
    return orig_readlink(path, buf, bufsize);
}

static BOOL _str_ends_with(const char *s, const char *suffix) {
    if (!s || !suffix) return NO;
    size_t sl = strlen(s), su = strlen(suffix);
    if (sl < su) return NO;
    return strcasecmp(s + sl - su, suffix) == 0;
}

static const char *_basename_c(const char *path) {
    const char *slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}

static void *(*orig_dlopen)(const char *, int);
static void *hook_dlopen(const char *path, int mode) {
    if (_jb_shouldBypass && path) {
        const char *base = _basename_c(path);
        if (strcasecmp(base, "libsubstrate.dylib") == 0) return NULL;
        if (strcasecmp(base, "libhooker.dylib") == 0) return NULL;
        if (strcasecmp(base, "libellekit.dylib") == 0) return NULL;
        if (strcasecmp(base, "libsubstitute.dylib") == 0) return NULL;
        if (strcasecmp(base, "libroothideboot.dylib") == 0) return NULL;
        if (strcasecmp(base, "cydiasubstrate") == 0) return NULL;
        if (strcasecmp(base, "substrate") == 0) return NULL;
        if (strcasecmp(base, "substitute") == 0) return NULL;
        if (strcasecmp(base, "libcycript.dylib") == 0) return NULL;
        if (strcasecmp(base, "libfrida-gadget.dylib") == 0) return NULL;
        if (_str_ends_with(path, "/CydiaSubstrate.framework/CydiaSubstrate")) return NULL;
        if (_str_ends_with(path, "/MobileSubstrate.dylib")) return NULL;
        if (_str_ends_with(path, "/TweakInject.dylib")) return NULL;
    }
    return orig_dlopen(path, mode);
}

%hook NSFileManager

- (BOOL)fileExistsAtPath:(NSString *)path {
    if (_jb_shouldBypass && path && _path_is_blacklisted([path fileSystemRepresentation]))
        return NO;
    return %orig;
}

- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDir {
    if (_jb_shouldBypass && path && _path_is_blacklisted([path fileSystemRepresentation])) {
        if (isDir) *isDir = NO;
        return NO;
    }
    return %orig;
}

- (NSArray<NSString *> *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error {
    NSArray *orig = %orig;
    if (!_jb_shouldBypass || !orig || !path) return orig;
    if ([path isEqualToString:@"/"] || [path isEqualToString:@"/Applications"]) {
        NSMutableArray *clean = [orig mutableCopy];
        [clean removeObject:@"Cydia.app"];
        [clean removeObject:@"Sileo.app"];
        [clean removeObject:@".installed_unc0ver"];
        [clean removeObject:@".bootstrapped_electra"];
        return clean;
    }
    return orig;
}

%end

%hook UIApplication

- (BOOL)canOpenURL:(NSURL *)url {
    if (!_jb_shouldBypass) return %orig;
    NSString *scheme = url.scheme.lowercaseString;
    if (scheme) {
        if ([scheme isEqualToString:@"cydia"]) return NO;
        if ([scheme isEqualToString:@"sileo"]) return NO;
        if ([scheme isEqualToString:@"zbra"]) return NO;
        if ([scheme isEqualToString:@"undecimus"]) return NO;
        if ([scheme isEqualToString:@"activator"]) return NO;
        if ([scheme isEqualToString:@"apt-repo"]) return NO;
    }
    return %orig;
}

%end

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (!bid) return;

        if ([bid hasPrefix:@"com.apple."]) return;

        NSArray *targets = _jb_targetBundles();
        _jb_shouldBypass = [targets containsObject:bid];

        if (!_jb_shouldBypass) {
            NSLog(@"[MPU/JBBypass] Skipping bypass for: %@", bid);
            return;
        }

        // FIX 6: запоминаем пути для fast-path
        NSString *bp = [[NSBundle mainBundle] bundlePath];
        if (bp) {
            strlcpy(_jb_app_bundle_path, [bp fileSystemRepresentation],
                    sizeof(_jb_app_bundle_path));
            _jb_app_bundle_path_len = strlen(_jb_app_bundle_path);
        }
        NSString *home = NSHomeDirectory();
        if (home) {
            strlcpy(_jb_app_data_path, [home fileSystemRepresentation],
                    sizeof(_jb_app_data_path));
            _jb_app_data_path_len = strlen(_jb_app_data_path);
        }

        MSHookFunction((void *)stat,     (void *)hook_stat,     (void **)&orig_stat);
        MSHookFunction((void *)lstat,    (void *)hook_lstat,    (void **)&orig_lstat);
        MSHookFunction((void *)access,   (void *)hook_access,   (void **)&orig_access);
        MSHookFunction((void *)open,     (void *)hook_open,     (void **)&orig_open);
        MSHookFunction((void *)fopen,    (void *)hook_fopen,    (void **)&orig_fopen);
        MSHookFunction((void *)opendir,  (void *)hook_opendir,  (void **)&orig_opendir);
        MSHookFunction((void *)getenv,   (void *)hook_getenv,   (void **)&orig_getenv);
        MSHookFunction((void *)dlopen,   (void *)hook_dlopen,   (void **)&orig_dlopen);
        MSHookFunction((void *)dlsym,    (void *)hook_dlsym,    (void **)&orig_dlsym);
        MSHookFunction((void *)readlink, (void *)hook_readlink, (void **)&orig_readlink);

        %init;
        NSLog(@"[MPU/JBBypass] Active for: %@", bid);
    }
}
