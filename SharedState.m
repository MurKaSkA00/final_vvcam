// SharedState.m - MediaPlaybackUtils v1.8.3
// Единственное физическое хранилище общих глобалов + общие helper-функции.
// Линкуется ровно один раз. Все остальные .x/.m видят их через extern из SharedState.h.

#import \"SharedState.h\"
#import <UIKit/UIKit.h>
#import <string.h>

BOOL              _enabled        = NO;
CVPixelBufferRef  _lastBuffer     = NULL;
id                _v_lock         = nil;
CFTimeInterval    _lastBufferTime = 0;

NSMutableSet     *_mpu_globalHookedClasses = nil;
id                _mpu_globalHookedLock    = nil;

// =============================================================================
// FIX 9 (v1.8.3): строгий gatekeeper. Вычисляется один раз на процесс.
// =============================================================================
BOOL _mpu_processIsLoadable(void) {
    static BOOL  cached = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSBundle *mb     = [NSBundle mainBundle];
        NSString *bid    = mb.bundleIdentifier;
        NSString *path   = mb.bundlePath ?: @\"\";
        NSString *exe    = mb.executablePath ?: @\"\";
        NSDictionary *info = mb.infoDictionary;

        if (!bid || bid.length == 0) { cached = NO; return; }

        // ---- 1. App-extensions (.appex / NSExtension) ----
        // Widgets, FileProvider'ы, ShareSheet, CallKit-extensions и т.п. У них
        // dyld-initializers порядок другой — FBLPromises и Firebase SDK падают,
        // если в их адресное пространство грузится наш .dylib. См. краш
        // Capital One Widgets: EXC_BREAKPOINT в FBLPromises.
        if ([path containsString:@\".appex/\"] ||
            [path hasSuffix:@\".appex\"]) { cached = NO; return; }
        if (info[@\"NSExtension\"] != nil)  { cached = NO; return; }

        // ---- 2. Системные пути (демоны / сервисы) ----
        // navd, destinationd, mapspushd, locationd, searchd, identityservicesd, ...
        // лежат в /usr/libexec, /System/Library, /usr/sbin и т.п.
        if ([path hasPrefix:@\"/usr/\"])               { cached = NO; return; }
        if ([path hasPrefix:@\"/System/\"])            { cached = NO; return; }
        if ([path hasPrefix:@\"/Library/\"])           { cached = NO; return; }
        if ([path hasPrefix:@\"/sbin/\"])              { cached = NO; return; }
        if ([path hasPrefix:@\"/bin/\"])               { cached = NO; return; }
        if ([path hasPrefix:@\"/var/jb/usr/\"])        { cached = NO; return; }
        if ([path hasPrefix:@\"/var/jb/System/\"])     { cached = NO; return; }
        if ([path hasPrefix:@\"/var/jb/Library/\"])    { cached = NO; return; }

        // ---- 3. Все Apple-системные процессы ----
        // (Camera/Safari/FaceTime тоже отбрасываем — для них есть отдельные
        // прицельные модули, и для нашей подмены они не нужны на уровне ctor'а.)
        if ([bid hasPrefix:@\"com.apple.\"])           { cached = NO; return; }

        // ---- 4. Jailbreak-инфраструктура / отладчики / package managers ----
        static NSArray *jb = nil;
        static dispatch_once_t once2;
        dispatch_once(&once2, ^{
            jb = @[
                @\"org.coolstar.\",
                @\"com.silverhawkx.sileo\",
                @\"xyz.willy.Zebra\",
                @\"com.tigisoftware.\",
                @\"com.sparklabs.\",
                @\"cool.palera1n\",
                @\"com.opa334.\",
                @\"com.palera1n\",
                @\"org.theos.\",
                @\"science.xnu.\",
                @\"com.checkra.\",
                @\"com.unc0ver.\",
            ];
        });
        for (NSString *p in jb) {
            if ([bid hasPrefix:p] || [bid isEqualToString:p]) {
                cached = NO; return;
            }
        }

        // ---- 5. Имя исполняемого файла — известные демоны на случай, если bundleID
        //         совпал по нашим whitelists, а реально это системный демон.
        NSString *exeName = exe.lastPathComponent ?: @\"\";
        static NSArray *daemons = nil;
        static dispatch_once_t once3;
        dispatch_once(&once3, ^{
            daemons = @[
                @\"navd\", @\"destinationd\", @\"mapspushd\", @\"locationd\",
                @\"searchd\", @\"spotlightd\", @\"callservicesd\",
                @\"identityservicesd\", @\"assertiond\", @\"backboardd\",
                @\"mediaserverd\", @\"SpringBoard\", @\"itunesstored\",
                @\"mobileactivationd\", @\"runningboardd\", @\"dasd\",
                @\"powerd\", @\"thermalmonitord\", @\"watchdogd\",
                @\"contextstored\", @\"healthd\", @\"siriknowledged\",
                @\"nsurlsessiond\", @\"cloudd\", @\"bird\", @\"apsd\",
                @\"pasted\", @\"useractivityd\", @\"sharingd\",
                @\"PhotoLibrary\", @\"photoanalysisd\", @\"cameracaptured\",
            ];
        });
        for (NSString *d in daemons) {
            if ([exeName isEqualToString:d]) { cached = NO; return; }
        }

        cached = YES;
    });
    return cached;
}

// =============================================================================
// FIX 8/9: единая проверка \"опасных\" имён классов.
// Раньше дублировалась в Tweak.x / WebRTCHooks.x / BrowserHooks.x.
// =============================================================================
BOOL _mpu_isUnsafeClassName(const char *cn) {
    if (!cn || cn[0] == 0) return YES;
    // Swift mangled: _Tt..., _$s..., _$S...
    if (cn[0] == '_' && (cn[1] == 'T' || cn[1] == '$')) return YES;
    // Swift dotted name \"Module.Class\" / Kotlin-Native \":\" / '$' / non-ASCII
    for (const char *p = cn; *p; p++) {
        unsigned char c = (unsigned char)*p;
        if (c == '.' || c == '$' || c == ':' || c >= 0x80) return YES;
    }
    if (strncmp(cn, \"__NS\", 4) == 0) return YES;
    if (strncmp(cn, \"_NS\",  3) == 0) return YES;
    if (strncmp(cn, \"OS_\",  3) == 0) return YES;
    // Объекты Apple SDK с подчёркивающим префиксом — Vision / Photo / Core* —
    // тоже не наши (там может быть и proxy class под капотом).
    if (strncmp(cn, \"VK\", 2) == 0 && cn[2] >= 'A' && cn[2] <= 'Z') return YES;
    return NO;
}

// =============================================================================
// FIX 9 (v1.8.3): безопасная ленивая инициализация CIContext.
// Если Metal недоступен (системный сервис без GPU, или сбойный init —
// видели в navd/destinationd/mapspushd) — падаем в software renderer.
// Если и он не создаётся — возвращаем nil, вызывающий код это уже умеет.
// =============================================================================
CIContext *_mpu_ciContextShared(void) {
    static CIContext *ctx = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            ctx = [CIContext contextWithOptions:nil];
        } @catch (...) { ctx = nil; }
        if (!ctx) {
            @try {
                ctx = [CIContext contextWithOptions:@{
                    kCIContextUseSoftwareRenderer: @YES
                }];
            } @catch (...) { ctx = nil; }
        }
    });
    return ctx;
}
