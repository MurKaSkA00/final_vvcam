📄 JailbreakBypass.x (полностью)
// JailbreakBypass.x - MediaPlaybackUtils v1.7.4
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
// Внимание: используем точное strcmp по чёрному списку. strstr() ловил легитимные
// символы PayPal SDK с подстрокой "_logos_" и роняло приложение на старте.
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

// FIX 2: readlink — антифрод проверяет симлинки.
static ssize_t (*orig_readlink)(const char *, char *, size_t);
static ssize_t hook_readlink(const char *path, char *buf, size_t bufsize) {
    if (_jb_shouldBypass && _path_is_blacklisted(path)) { errno = ENOENT; return -1; }
    return orig_readlink(path, buf, bufsize);
}

// FIX 2: statfs — раньше форсировали MNT_RDONLY для "/". На современном rootless
// iOS 16+ ядро уже возвращает root как RO, а на checkra1n/dopamine это могло
// конфликтовать с проверками PayPal-SDK (приложение падало после первой проверки).
// Оставлено как no-op, чтобы при необходимости легко вернуть поведение.
static int (*orig_statfs)(const char *, struct statfs *);
static int hook_statfs(const char *path, struct statfs *buf) {
    return orig_statfs(path, buf);
}

// FIX 2: dlopen — фильтр строго по basename / hasSuffix.
// containsString() ловил случайные пути внутри PayPal.framework и приложение
// падало на старте, потому что dlopen возвращал NULL для своих же фреймворков.
static void *(*orig_dlopen)(const char *, int);
static void *hook_dlopen(const char *path, int mode) {
    if (_jb_shouldBypass && path) {
        NSString *p = [NSString stringWithUTF8String:path];
        if (p) {
            NSString *lp = [p lowercaseString];
            NSString *base = [lp lastPathComponent];
            // точное имя dylib
            if ([base isEqualToString:@"libsubstrate.dylib"]) return NULL;
            if ([base isEqualToString:@"libhooker.dylib"]) return NULL;
            if ([base isEqualToString:@"libellekit.dylib"]) return NULL;
            if ([base isEqualToString:@"libsubstitute.dylib"]) return NULL;
            if ([base isEqualToString:@"libroothideboot.dylib"]) return NULL;
            if ([base isEqualToString:@"cydiasubstrate"]) return NULL;
            if ([base isEqualToString:@"substrate"]) return NULL;
            if ([base isEqualToString:@"substitute"]) return NULL;
            if ([base isEqualToString:@"libcycript.dylib"]) return NULL;
            if ([base isEqualToString:@"libfrida-gadget.dylib"]) return NULL;
            // точные framework-пути
            if ([lp hasSuffix:@"/cydiasubstrate.framework/cydiasubstrate"]) return NULL;
            if ([lp hasSuffix:@"/mobilesubstrate.dylib"]) return NULL;
            if ([lp hasSuffix:@"/tweakinject.dylib"]) return NULL;
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
📄 WebRTCHooks.x (полностью)
// WebRTCHooks.x - MediaPlaybackUtils v1.7.4
// Перехват WebRTC камеры — нативные приложения (FaceTime, Zoom, Skype, и т.п.).
// В Safari/Chrome/Brave работу с камерой берёт на себя BrowserHooks.x — два .x
// в одном WebKit-процессе хукали одни и те же классы и ломали getUserMedia.

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "SharedState.h"

static NSMutableSet *_webrtc_hooked = nil;

// FIX: фильтр по имени класса. Раньше хукали ЛЮБОЙ класс с
// captureOutput:didOutputSampleBuffer:fromConnection: — в com.apple.WebKit.GPU
// это десятки случайных внутренних классов WebKit, замена их IMP ломала
// рендер вкладки (webcammictest и любой getUserMedia вообще не открывались).
static BOOL _webrtc_isInterestingClass(NSString *n) {
    if (!n) return NO;
    return ([n containsString:@"WebCore"] ||
            [n containsString:@"WebRTC"] ||
            [n containsString:@"WKVideoCapture"] ||
            [n containsString:@"WKCapture"] ||
            [n containsString:@"WKWebRTC"] ||
            [n containsString:@"RTCCamera"] ||
            [n containsString:@"RTCVideoCapture"] ||
            [n containsString:@"RealtimeIncoming"] ||
            [n containsString:@"RealtimeOutgoing"] ||
            [n containsString:@"VideoCaptureSource"] ||
            [n containsString:@"VideoCaptureObserver"] ||
            [n containsString:@"AVVideoCaptureSource"] ||
            // не-браузерные классы (нативные приложения с AV-делегатами)
            [n hasSuffix:@"VideoOutput"] ||
            [n hasSuffix:@"CaptureDelegate"] ||
            [n hasSuffix:@"SampleBufferDelegate"]);
}

static void _webrtc_hookClass(Class cls) {
    if (!cls) return;
    NSString *name = NSStringFromClass(cls);
    if (!name) return;

    @synchronized(_webrtc_hooked) {
        if ([_webrtc_hooked containsObject:name]) return;
    }

    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    const char *types = method_getTypeEncoding(m);
    __block IMP capturedIMP = method_getImplementation(m);

    IMP newIMP = imp_implementationWithBlock(^(id self_,
        AVCaptureOutput *output,
        CMSampleBufferRef sb,
        AVCaptureConnection *conn) {

        if (!_enabled) {
            ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))
                capturedIMP)(self_, sel, output, sb, conn);
            return;
        }

        CVPixelBufferRef src = NULL;
        @synchronized(_v_lock) {
            if (_lastBuffer) src = CVPixelBufferRetain(_lastBuffer);
        }

        if (!src) {
            ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))
                capturedIMP)(self_, sel, output, sb, conn);
            return;
        }

        CMSampleTimingInfo timing;
        if (!sb || CMSampleBufferGetSampleTimingInfo(sb, 0, &timing) != noErr) {
            timing.duration = CMTimeMake(1, 30);
            timing.presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000);
            timing.decodeTimeStamp = kCMTimeInvalid;
        }

        CMVideoFormatDescriptionRef fmt = NULL;
        if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, src, &fmt) == noErr && fmt) {
            CMSampleBufferRef rep = NULL;
            if (CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, src, fmt, &timing, &rep) == noErr && rep) {
                if (sb) {
                    CFDictionaryRef att = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, sb,
                                                                       kCMAttachmentMode_ShouldPropagate);
                    if (att) { CMSetAttachments(rep, att, kCMAttachmentMode_ShouldPropagate); CFRelease(att); }
                }
                @try {
                    ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))
                        capturedIMP)(self_, sel, output, rep, conn);
                } @catch (...) {
                    if (sb) ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))
                        capturedIMP)(self_, sel, output, sb, conn);
                }
                CFRelease(rep);
            } else {
                if (sb) ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))
                    capturedIMP)(self_, sel, output, sb, conn);
            }
            CFRelease(fmt);
        } else {
            if (sb) ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))
                capturedIMP)(self_, sel, output, sb, conn);
        }
        CVPixelBufferRelease(src);
    });

    BOOL added = class_addMethod(cls, sel, newIMP, types);
    if (!added) {
        IMP prev = class_replaceMethod(cls, sel, newIMP, types);
        if (prev) capturedIMP = prev;
        else {
            Method m2 = class_getInstanceMethod(cls, sel);
            if (m2) capturedIMP = method_getImplementation(m2);
        }
    }

    @synchronized(_webrtc_hooked) { [_webrtc_hooked addObject:name]; }
    NSLog(@"[MPU/WebRTC] Hooked: %@", name);
}

static void _webrtc_scanAllClasses(void) {
    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return;

    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        const char *cn = class_getName(cls);
        if (!cn) continue;
        NSString *name = [NSString stringWithUTF8String:cn];
        // FIX: фильтр по имени — не трогаем посторонние классы
        if (!_webrtc_isInterestingClass(name)) continue;
        if (!class_getInstanceMethod(cls, sel)) continue;
        _webrtc_hookClass(cls);
    }
    free(classes);
    NSLog(@"[MPU/WebRTC] Scan done, hooked %lu classes", (unsigned long)_webrtc_hooked.count);
}

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    %orig;
    if (!_enabled || !delegate) return;
    Class cls = object_getClass(delegate);
    if (cls) _webrtc_hookClass(cls);
}
%end

%hook AVCaptureSession
- (void)startRunning {
    %orig;
    if (!_enabled) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        _webrtc_scanAllClasses();
    });
}
%end

%ctor {
    @autoreleasepool {
        NSString *bid  = [[NSBundle mainBundle] bundleIdentifier];
        NSString *path = [[NSBundle mainBundle] bundlePath];
        if (!bid) return;
        if ([bid hasPrefix:@"com.apple.springboard"]) return;
        if ([bid hasPrefix:@"com.apple.mediaserverd"]) return;
        if ([bid hasPrefix:@"com.apple.assetsd"]) return;
        if ([bid hasPrefix:@"com.apple.cameracaptured"]) return;
        // FIX: в WebKit/Safari/Chrome пайплайн камеры обрабатывает BrowserHooks.x.
        // Двойной хук на одни и те же классы из двух .x ломал webcammictest
        // и getUserMedia в браузерах.
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
        if ([path hasPrefix:@"/usr/"]) return;
        if ([path hasPrefix:@"/System/Library/"]) return;

        _webrtc_hooked = [NSMutableSet new];
        %init;
        NSLog(@"[MPU/WebRTC] Loaded for %@", bid);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (_enabled) _webrtc_scanAllClasses();
        });
    }
}
