// WebRTCHooks.x - MediaPlaybackUtils v2.1.0 "All Apps"
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#include <stdatomic.h>
#import "SharedState.h"

static atomic_bool _webrtc_scanDone = ATOMIC_VAR_INIT(false);

static BOOL _webrtc_isInterestingClass(const char *cn) {
    if (!cn) return NO;
    if (strstr(cn, "Camera"))           return YES;
    if (strstr(cn, "Capture"))          return YES;
    if (strstr(cn, "VideoOutput"))      return YES;
    if (strstr(cn, "SampleBuffer"))     return YES;
    if (strstr(cn, "VideoFrame"))       return YES;
    if (strstr(cn, "WebRTC"))           return YES;
    if (strstr(cn, "RTCVideo"))         return YES;
    if (strstr(cn, "Liveness"))         return YES;
    if (strstr(cn, "KYC"))              return YES;
    if (strstr(cn, "FaceCapture"))      return YES;
    return NO;
}

static void _webrtc_hookClass(Class cls) {
    if (!cls) return;
    const char *cn = class_getName(cls);
    if (_mpu_isUnsafeClassName(cn)) return;
    NSString *name = [NSString stringWithUTF8String:cn];
    if (!name) return;

    if (!_mpu_globalHookedClasses) {
        _mpu_globalHookedClasses = [NSMutableSet new];
        _mpu_globalHookedLock    = [NSObject new];
    }
    @synchronized(_mpu_globalHookedLock) {
        if ([_mpu_globalHookedClasses containsObject:name]) return;
    }

    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    Method mSuper = class_getInstanceMethod(class_getSuperclass(cls), sel);
    if (m == mSuper) {
        const char *types = method_getTypeEncoding(m);
        if (!types) return;
        if (!class_addMethod(cls, sel, method_getImplementation(m), types)) return;
        m = class_getInstanceMethod(cls, sel);
        if (!m) return;
    }

    __block IMP capturedIMP = method_getImplementation(m);

    IMP newIMP = imp_implementationWithBlock(^(id self_,
        AVCaptureOutput *output, CMSampleBufferRef sb, AVCaptureConnection *conn) {

        if (!_enabled) {
            ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))
                capturedIMP)(self_, sel, output, sb, conn);
            return;
        }

        CVPixelBufferRef raw = NULL;
        @synchronized(_v_lock) { if (_lastBuffer) raw = CVPixelBufferRetain(_lastBuffer); }
        if (!raw) {
            ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))
                capturedIMP)(self_, sel, output, sb, conn);
            return;
        }

        OSType want = _mpu_outputPixelFormat(output);
        if (want == 0 && sb) {
            CVImageBufferRef ib = CMSampleBufferGetImageBuffer(sb);
            if (ib) want = CVPixelBufferGetPixelFormatType(ib);
        }
        CVPixelBufferRef src = _mpu_convertPixelBuffer(raw, want);
        CVPixelBufferRelease(raw);
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
            } else if (sb) {
                ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))
                    capturedIMP)(self_, sel, output, sb, conn);
            }
            CFRelease(fmt);
        } else if (sb) {
            ((void(*)(id,SEL,AVCaptureOutput*,CMSampleBufferRef,AVCaptureConnection*))
                capturedIMP)(self_, sel, output, sb, conn);
        }
        CVPixelBufferRelease(src);
    });

    method_setImplementation(m, newIMP);

    @synchronized(_mpu_globalHookedLock) { [_mpu_globalHookedClasses addObject:name]; }
    NSLog(@"[MPU/WebRTC] Hooked: %@", name);
}

static void _webrtc_scanAllClasses_mainThread(void) {
    bool expected = false;
    if (!atomic_compare_exchange_strong(&_webrtc_scanDone, &expected, true)) return;

    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return;

    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        const char *cn = class_getName(cls);
        if (_mpu_isUnsafeClassName(cn)) continue;
        if (!_webrtc_isInterestingClass(cn)) continue;
        if (!class_getInstanceMethod(cls, sel)) continue;
        _webrtc_hookClass(cls);
    }
    free(classes);
    NSLog(@"[MPU/WebRTC] Scan done (main, %u classes)", count);
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
    dispatch_async(dispatch_get_main_queue(), ^{
        _webrtc_scanAllClasses_mainThread();
    });
}
%end

%ctor {
    @autoreleasepool {
        if (!_mpu_processIsLoadable()) return;

        if (!_v_lock) _v_lock = [NSObject new];
        if (!_mpu_globalHookedClasses) {
            _mpu_globalHookedClasses = [NSMutableSet new];
            _mpu_globalHookedLock    = [NSObject new];
        }

        %init;
        NSLog(@"[MPU/WebRTC] Loaded for %@", [[NSBundle mainBundle] bundleIdentifier]);
    }
}
