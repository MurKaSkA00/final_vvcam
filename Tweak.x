#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import "VVCamState.h"
#import "VVCamEngine.h"

// ---- guard: не трогаем системные демоны (mediaserverd/cameracaptured и т.п.) ----
static BOOL VVCamProcessAllowed(void) {
    NSString *exe = [[[NSBundle mainBundle] executablePath] lastPathComponent] ?: @"";
    NSString *e = exe.lowercaseString;
    NSArray *blocked = @[ @"mediaserverd", @"cameracaptured", @"avconferenced",
                          @"mediaplaybackd", @"audiomxd", @"replayd" ];
    for (NSString *b in blocked) if ([e isEqualToString:b]) return NO;
    return YES;
}

// =====================  VIDEO: безопасный свизл делегата  =====================
static SEL kVideoSel; // captureOutput:didOutputSampleBuffer:fromConnection:
static NSMutableDictionary<NSValue *, NSValue *> *gVideoOrig; // class -> orig IMP
static NSMutableSet<NSValue *> *gVideoSwizzled;

static IMP VVCamOrigVideoIMP(Class cls) {
    @synchronized (gVideoOrig) {
        Class c = cls;
        while (c) {
            NSValue *imp = gVideoOrig[[NSValue valueWithPointer:(__bridge const void *)c]];
            if (imp) return (IMP)[imp pointerValue];
            c = class_getSuperclass(c);
        }
    }
    return NULL;
}

static void VVCam_didOutputSampleBuffer(id self, SEL _cmd, AVCaptureOutput *output,
                                        CMSampleBufferRef sb, AVCaptureConnection *conn) {
    IMP orig = VVCamOrigVideoIMP(object_getClass(self));
    void (*callOrig)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *) =
        (void (*)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *))orig;

    if (![VVCamState shared].enabled) {
        if (callOrig) callOrig(self, _cmd, output, sb, conn);
        return;
    }

    CMSampleBufferRef rep = NULL;
    @try { rep = [VVCamEngine replacementForSampleBuffer:sb]; }
    @catch (__unused NSException *e) { rep = NULL; }

    if (rep) {
        if (callOrig) callOrig(self, _cmd, output, rep, conn);
        CFRelease(rep);
    } else if (callOrig) {
        callOrig(self, _cmd, output, sb, conn);
    }
}

static void VVCamSwizzleVideoDelegate(Class cls) {
    if (!cls) return;
    if (![cls instancesRespondToSelector:kVideoSel]) return; // только подходящие делегаты
    @synchronized (gVideoOrig) {
        NSValue *key = [NSValue valueWithPointer:(__bridge const void *)cls];
        if ([gVideoSwizzled containsObject:key]) return;
        [gVideoSwizzled addObject:key];

        Method m = class_getInstanceMethod(cls, kVideoSel);
        if (!m) return;
        const char *types = method_getTypeEncoding(m);
        IMP origImp = method_getImplementation(m);

        if (class_addMethod(cls, kVideoSel, (IMP)VVCam_didOutputSampleBuffer, types)) {
            gVideoOrig[key] = [NSValue valueWithPointer:origImp]; // был унаследован
        } else {
            IMP prev = method_setImplementation(m, (IMP)VVCam_didOutputSampleBuffer);
            gVideoOrig[key] = [NSValue valueWithPointer:prev];
        }
    }
}

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    @try { if (delegate) VVCamSwizzleVideoDelegate(object_getClass(delegate)); }
    @catch (__unused NSException *e) {}
    %orig;
}
%end

// =====================  PHOTO: подмена репрезентаций снимка  =====================
%hook AVCapturePhoto

- (CVPixelBufferRef)pixelBuffer {
    CVPixelBufferRef orig = %orig;
    if (![VVCamState shared].enabled || !orig) return orig;
    @try { [VVCamEngine fillPixelBuffer:orig]; } @catch (__unused NSException *e) {}
    return orig;
}

- (CGImageRef)CGImageRepresentation {
    if ([VVCamState shared].enabled) {
        @try {
            CGImageRef ours = [VVCamEngine currentCGImage];
            if (ours) return (CGImageRef)CFAutorelease(ours);
        } @catch (__unused NSException *e) {}
    }
    return %orig;
}

- (NSData *)fileDataRepresentation {
    if ([VVCamState shared].enabled) {
        @try {
            CGImageRef ours = [VVCamEngine currentCGImage];
            if (ours) {
                NSMutableData *data = [NSMutableData data];
                CGImageDestinationRef dest = CGImageDestinationCreateWithData(
                    (__bridge CFMutableDataRef)data, (CFStringRef)@"public.jpeg", 1, NULL);
                if (dest) {
                    NSDictionary *opts = @{ (id)kCGImageDestinationLossyCompressionQuality: @0.95 };
                    CGImageDestinationAddImage(dest, ours, (__bridge CFDictionaryRef)opts);
                    CGImageDestinationFinalize(dest);
                    CFRelease(dest);
                    CGImageRelease(ours);
                    if (data.length) return data;
                } else {
                    CGImageRelease(ours);
                }
            }
        } @catch (__unused NSException *e) {}
    }
    return %orig;
}

%end

// =====================  init  =====================
%ctor {
    if (!VVCamProcessAllowed()) return;
    @autoreleasepool {
        kVideoSel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
        gVideoOrig = [NSMutableDictionary new];
        gVideoSwizzled = [NSMutableSet new];
        [VVCamState shared]; // прогрев + регистрация notify
        %init;
    }
}
