// SharedState.m - MediaPlaybackUtils v2.1.0 "All Apps"
// Единственное физическое хранилище общих глобалов + общие helper-функции.

#import "SharedState.h"
#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>

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

        if ([path containsString:@".appex/"] ||
            [path hasSuffix:@".appex"])               { cached = NO; return; }
        if (info[@"NSExtension"] != nil)              { cached = NO; return; }

        if ([path hasPrefix:@"/usr/"])                { cached = NO; return; }
        if ([path hasPrefix:@"/System/"])             { cached = NO; return; }
        if ([path hasPrefix:@"/Library/"])            { cached = NO; return; }
        if ([path hasPrefix:@"/sbin/"])               { cached = NO; return; }
        if ([path hasPrefix:@"/bin/"])                { cached = NO; return; }
        if ([path hasPrefix:@"/var/jb/usr/"])         { cached = NO; return; }
        if ([path hasPrefix:@"/var/jb/System/"])      { cached = NO; return; }
        if ([path hasPrefix:@"/var/jb/Library/"])     { cached = NO; return; }

        if ([bid hasPrefix:@"com.apple."])            { cached = NO; return; }

        NSArray *jb = @[
            @"org.coolstar.", @"com.silverhawkx.sileo", @"xyz.willy.Zebra",
            @"com.tigisoftware.", @"com.sparklabs.", @"cool.palera1n",
            @"com.opa334.", @"com.palera1n", @"org.theos.",
            @"science.xnu.", @"com.checkra.", @"com.unc0ver.",
        ];
        for (NSString *p in jb) {
            if ([bid hasPrefix:p] || [bid isEqualToString:p]) {
                cached = NO; return;
            }
        }

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
// v2.1.0: РАЗРЕШАЕМ Swift/Kotlin-классы.
// =============================================================================
BOOL _mpu_isUnsafeClassName(const char *cn) {
    if (!cn || cn[0] == 0) return YES;
    for (const char *p = cn; *p; p++) {
        unsigned char c = (unsigned char)*p;
        if (c < 0x20) return YES;          // нечитаемые символы
    }
    if (strncmp(cn, "__NSCF",     6) == 0) return YES;
    if (strncmp(cn, "__NSDictI",  9) == 0) return YES;
    if (strncmp(cn, "__NSArrayI", 10) == 0) return YES;
    if (strncmp(cn, "OS_",        3) == 0) return YES;
    return NO;
}

CIContext *_mpu_ciContextShared(void) {
    static CIContext *ctx = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try { ctx = [CIContext contextWithOptions:nil]; }
        @catch (__unused NSException *e) { ctx = nil; }
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

static CVPixelBufferRef _mpu_makeEmpty(size_t w, size_t h, OSType fmt) {
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey:            @(fmt),
        (id)kCVPixelBufferIOSurfacePropertiesKey:        @{},
        (id)kCVPixelBufferCGImageCompatibilityKey:       @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (id)kCVPixelBufferWidthKey:                      @(w),
        (id)kCVPixelBufferHeightKey:                     @(h),
    };
    CVPixelBufferRef pb = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, w, h, fmt,
                        (__bridge CFDictionaryRef)attrs, &pb);
    return pb;
}

CVPixelBufferRef _mpu_convertPixelBuffer(CVPixelBufferRef src, OSType targetFormat) {
    if (!src) return NULL;
    OSType srcFmt = CVPixelBufferGetPixelFormatType(src);
    if (targetFormat == 0 || srcFmt == targetFormat) {
        return (CVPixelBufferRef)CFRetain(src);
    }

    size_t w = CVPixelBufferGetWidth(src);
    size_t h = CVPixelBufferGetHeight(src);
    CVPixelBufferRef dst = _mpu_makeEmpty(w, h, targetFormat);
    if (!dst) return (CVPixelBufferRef)CFRetain(src);

    CIContext *ctx = _mpu_ciContextShared();
    if (!ctx) { CVPixelBufferRelease(dst); return (CVPixelBufferRef)CFRetain(src); }
    @try {
        CIImage *ci = [CIImage imageWithCVPixelBuffer:src];
        if (ci) {
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            [ctx render:ci toCVPixelBuffer:dst bounds:ci.extent colorSpace:cs];
            CGColorSpaceRelease(cs);
            return dst;
        }
    } @catch (__unused NSException *e) {}
    CVPixelBufferRelease(dst);
    return (CVPixelBufferRef)CFRetain(src);
}

OSType _mpu_outputPixelFormat(id output) {
    if (!output) return 0;
    @try {
        if (![output respondsToSelector:@selector(videoSettings)]) return 0;
        NSDictionary *vs = [output performSelector:@selector(videoSettings)];
        if (![vs isKindOfClass:[NSDictionary class]]) return 0;
        NSNumber *n = vs[(id)kCVPixelBufferPixelFormatTypeKey];
        if ([n isKindOfClass:[NSNumber class]]) return (OSType)n.unsignedIntValue;
    } @catch (__unused NSException *e) {}
    return 0;
}
