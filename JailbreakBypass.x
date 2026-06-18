// JailbreakBypass.x - MediaPlaybackUtils v1.7.3
// Скрывает джейлбрейк ТОЛЬКО от конкретных целевых приложений.
// НЕ убивает Sileo, Filza, palera1n, Chrome.

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

// ========================================
// СПИСОК ПРИЛОЖЕНИЙ, от которых скрываем джейл.
// ========================================
static NSArray<NSString *> *_jb_targetBundles(void) {
    static NSArray *list = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[
            @"com.paypal.PPClient",
            @"com.burbn.instagram",
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
            @"com.bankofamerica.BofAMobileBank",
            @"com.skype.skype",
            @"us.zoom.videomeetings",
        ];
    });
    return list;
}

static BOOL _jb_shouldBypass = NO;

static NSArray<NSString *> *_jb_blacklist(void) {
    static NSArray *list = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[
            @"/Applications/Cydia.app",
            @"/Library/MobileSubstrate",
            @"/Library/Substitute",
            @"/Library/TweakInject",
            @"/usr/lib/libsubstrate.dylib",
            @"/usr/lib/libhooker.dylib",
            @"/usr/lib/libellekit.dylib",
            @"/usr/lib/libsubstitute.dylib",
            @"/usr/lib/substrate",
            @"/usr/lib/TweakInject.dylib",
            @"/usr/bin/cycript",
            @"/usr/bin/ssh",
            @"/usr/sbin/sshd",
            @"/usr/bin/sileo",
            @"/etc/apt",
            @"/etc/ssh/sshd_config",
            @"/private/var/lib/apt",
            @"/private/var/lib/cydia",
            @"/private/var/stash",
            @"/private/var/tmp/cydia.log",
            @"/bin/bash",
            @"/bin/sh",
            // FIX 2: rootless варианты (/var/jb/) — PayPal делает прямые stat() на них.
            @"/var/jb/Library/MobileSubstrate",
            @"/var/jb/Library/Substitute",
            @"/var/jb/Library/TweakInject",
            @"/var/jb/usr/lib/libsubstrate.dylib",
            @"/var/jb/usr/lib/libhooker.dylib",
            @"/var/jb/usr/lib/libellekit.dylib",
            @"/var/jb/usr/lib/libsubstitute.dylib",
            @"/var/jb/usr/lib/TweakInject.dylib",
            @"/var/jb/usr/bin/cycript",
            @"/var/jb/usr/bin/ssh",
            @"/var/jb/etc/apt",
            @"/var/jb/etc/ssh/sshd_config",
            @"/var/jb/bin/bash",
            @"/var/jb/bin/sh",
            @"/var/jb/Applications/Cydia.app",
            // /var/jb НЕ добавляем полностью — там Sileo/Filza.
            @"/var/jb/.jailbroken",
            @"/.installed_unc0ver",
            @"/.bootstrapped_electra",
            @"/taurine",
            @"/palera1n",
        ];
    });
    return list;
}

static BOOL _path_is_blacklisted(const char *path) {
    if (!path || strlen(path) == 0) return NO;
    NSString *s = [NSString stringWithUTF8String:path];
    if (!s) return NO;
    for (NSString *bad in _jb_blacklist()) {
        if ([s isEqualToString:bad]) return YES;
        if ([s hasPrefix:[bad stringByAppendingString:@"/"]]) return YES;
    }
    return NO;
}

// ========================================
// SYSCALL HOOKS
// ========================================

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

// FIX 2: dlsym — PayPal SDK дёргает dlsym(RTLD_DEFAULT, "MSHookFunction") и аналоги.
static void *(*orig_dlsym)(void *, const char *);
static void *hook_dlsym(void *handle, const char *symbol) {
    if (_jb_shouldBypass && symbol) {
        if (strstr(symbol, "MSHookFunction"))     return NULL;
        if (strstr(symbol, "MSHookMessageEx"))    return NULL;
        if (strstr(symbol, "MSGetImageByName"))   return NULL;
        if (strstr(symbol, "MSFindSymbol"))       return NULL;
        if (strstr(symbol, "LHHookFunctions"))    return NULL;
        if (strstr(symbol, "SubHookFunction"))    return NULL;
        if (strstr(symbol, "EKHook"))             return NULL;
        if (strstr(symbol, "_logos_"))            return NULL;
    }
    return orig_dlsym(handle, symbol);
}

// FIX 2: readlink — антифрод проверяет симлинки.
static ssize_t (*orig_readlink)(const char *, char *, size_t);
static ssize_t hook_readlink(const char *path, char *buf, size_t bufsize) {
    if (_jb_shouldBypass && _path_is_blacklisted(path)) { errno = ENOENT; return -1; }
    return orig_readlink(path, buf, bufsize);
}

// FIX 2: statfs — PayPal проверяет writable root через MNT_RDONLY.
static int (*orig_statfs)(const char *, struct statfs *);
static int hook_statfs(const char *path, struct statfs *buf) {
    int r = orig_statfs(path, buf);
    if (_jb_shouldBypass && r == 0 && buf && path) {
        if (strcmp(path, "/") == 0) {
            buf->f_flags |= MNT_RDONLY;
        }
    }
    return r;
}

// FIX 2: dlopen — расширенный фильтр (containsString вместо hasSuffix).
static void *(*orig_dlopen)(const char *, int);
static void *hook_dlopen(const char *path, int mode) {
    if (_jb_shouldBypass && path) {
        NSString *p = [NSString stringWithUTF8String:path];
        if (p) {
            NSString *lp = [p lowercaseString];
            if ([lp hasSuffix:@"libsubstrate.dylib"]) return NULL;
            if ([lp hasSuffix:@"libhooker.dylib"]) return NULL;
            if ([lp hasSuffix:@"libellekit.dylib"]) return NULL;
            if ([lp hasSuffix:@"libsubstitute.dylib"]) return NULL;
            if ([lp hasSuffix:@"libroothideboot.dylib"]) return NULL;
            if ([lp containsString:@"mobilesubstrate"]) return NULL;
            if ([lp containsString:@"substrate"]) return NULL;
            if ([lp containsString:@"substitute"]) return NULL;
            if ([lp containsString:@"libhooker"]) return NULL;
            if ([lp containsString:@"libellekit"]) return NULL;
            if ([lp containsString:@"tweakinject"]) return NULL;
            if ([lp containsString:@"choma"]) return NULL;
            if ([lp containsString:@"cycript"]) return NULL;
            if ([lp containsString:@"frida"]) return NULL;
            if ([lp containsString:@"libcolorpicker"]) return NULL;
        }
    }
    return orig_dlopen(path, mode);
}

// ========================================
// ObjC HOOKS
// ========================================

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

// ========================================
// ИНИЦИАЛИЗАЦИЯ
// ========================================

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

        MSHookFunction((void *)stat,     (void *)hook_stat,     (void **)&orig_stat);
        MSHookFunction((void *)lstat,    (void *)hook_lstat,    (void **)&orig_lstat);
        MSHookFunction((void *)access,   (void *)hook_access,   (void **)&orig_access);
        MSHookFunction((void *)open,     (void *)hook_open,     (void **)&orig_open);
        MSHookFunction((void *)fopen,    (void *)hook_fopen,    (void **)&orig_fopen);
        MSHookFunction((void *)opendir,  (void *)hook_opendir,  (void **)&orig_opendir);
        MSHookFunction((void *)getenv,   (void *)hook_getenv,   (void **)&orig_getenv);
        MSHookFunction((void *)dlopen,   (void *)hook_dlopen,   (void **)&orig_dlopen);
        // FIX 2: дополнительные хуки для PayPal и др.
        MSHookFunction((void *)dlsym,    (void *)hook_dlsym,    (void **)&orig_dlsym);
        MSHookFunction((void *)readlink, (void *)hook_readlink, (void **)&orig_readlink);
        MSHookFunction((void *)statfs,   (void *)hook_statfs,   (void **)&orig_statfs);

        %init;
        NSLog(@"[MPU/JBBypass] Active for: %@", bid);
    }
}
