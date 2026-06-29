// KYCBypassHooks.x - MediaPlaybackUtils v1.8.6 (logos-safe)
// FIX 9:  self-contained — никаких внешних helper'ов, кроме SharedState.
// v1.8.5: VNImageRequestHandler init-методы переведены на MSHookMessageEx,
//         потому что свежий logos из master-theos ломается на %orig(args)
//         ("Invalid argument structure") и склеивает соседние конструкции.
// v1.8.6: AVCapturePhotoOutput capturePhotoWithSettings:delegate: тоже
//         переведён на MSHookMessageEx — тот же баг logos с %orig(args)
//         в многоаргументном методе с `id<Protocol>`-параметром приводил
//         к "function definition is not allowed here" (см. typedef ниже).

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <Vision/Vision.h>
#import <VisionKit/VisionKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import "SharedState.h"

#define MPU_KYC_LOG(fmt, ...) NSLog(@"[MPU/KYC] " fmt, ##__VA_ARGS__)

// ── локальный ленивый CIContext (Metal → software fallback) ────────────────
static CIContext *_kyc_ciContextShared(void) {
    static CIContext *ctx = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            ctx = [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer: @YES }];
        } @catch (__unused NSException *e) { ctx = nil; }
        if (!ctx) {
            @try { ctx = [CIContext contextWithOptions:nil]; }
            @catch (__unused NSException *e) { ctx = nil; }
        }
    });
    return ctx;
}

// ── фильтр опасных имён классов (Swift/Kotlin/служебные) ──────────────────
static BOOL _kyc_isUnsafeClassName(const char *cn) {
    if (!cn || cn[0] == 0) return YES;
    if (cn[0] == '_' && (cn[1] == 'T' || cn[1] == '$')) return YES;
    for (const char *p = cn; *p; p++) {
        unsigned char c = (unsigned char)*p;
        if (c == '.' || c == '$' || c == ':' || c >= 0x80) return YES;
    }
    if (strncmp(cn, "__NS", 4) == 0) return YES;
    if (strncmp(cn, "_NS",  3) == 0) return YES;
    if (strncmp(cn, "OS_",  3) == 0) return YES;
    return NO;
}

// ── gatekeeper для процесса (синхронен с Tweak.x) ─────────────────────────
static BOOL _kyc_processIsLoadable(void) {
    NSString *bid  = [[NSBundle mainBundle] bundleIdentifier];
    NSString *path = [[NSBundle mainBundle] bundlePath];
    NSString *exe  = [[NSBundle mainBundle] executablePath];
    if (!bid) return NO;

    if ([path hasSuffix:@".appex"])           return NO;
    if ([path containsString:@".appex/"])     return NO;
    if ([bid hasSuffix:@".widget"])           return NO;
    if ([bid hasSuffix:@".widgets"])          return NO;
    if ([bid containsString:@".widget."])     return NO;
    if ([bid hasSuffix:@".extension"])        return NO;
    if ([bid containsString:@".extension."])  return NO;
    if ([bid hasSuffix:@".WidgetExtension"])  return NO;
    if ([bid hasSuffix:@".intents"])          return NO;
    if ([bid hasSuffix:@".ShareExtension"])   return NO;
    if ([bid hasSuffix:@".NotificationServiceExtension"]) return NO;
    if ([bid hasSuffix:@".NotificationContentExtension"]) return NO;

    if ([bid hasPrefix:@"com.apple."])        return NO;
    if ([path hasPrefix:@"/usr/"])            return NO;
    if ([path hasPrefix:@"/System/"])         return NO;

    NSString *exeName = [exe lastPathComponent];
    if (exeName) {
        NSArray *banned = @[ @"navd", @"destinationd", @"mapspushd", @"geod",
                             @"locationd", @"routined", @"callservicesd",
                             @"identityservicesd", @"coreduetd", @"contextstored",
                             @"spotlightd", @"searchd", @"suggestd",
                             @"assistantd", @"mediaserverd", @"assetsd",
                             @"cameracaptured", @"backboardd", @"runningboardd" ];
        for (NSString *n in banned) if ([exeName isEqualToString:n]) return NO;
    }
    return YES;
}

// ── общий копировщик текущего фрейма ──────────────────────────────────────
static CVPixelBufferRef _kyc_copyBuffer(void) CF_RETURNS_RETAINED {
    if (!_enabled || !_v_lock) return NULL;
    CVPixelBufferRef pb = NULL;
    @synchronized(_v_lock) {
        if (_lastBuffer) pb = CVPixelBufferRetain(_lastBuffer);
    }
    return pb;
}

static CGImageRef _kyc_createCGImage(CVPixelBufferRef pb) CF_RETURNS_RETAINED {
    if (!pb) return NULL;
    CIContext *ctx = _kyc_ciContextShared();
    if (!ctx) return NULL;
    CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
    if (!ci) return NULL;
    return [ctx createCGImage:ci fromRect:ci.extent];
}

static UIImage *_kyc_replacementUIImage(void) {
    CVPixelBufferRef pb = _kyc_copyBuffer();
    if (!pb) return nil;
    CGImageRef cg = _kyc_createCGImage(pb);
    CVPixelBufferRelease(pb);
    if (!cg) return nil;
    UIImage *img = [UIImage imageWithCGImage:cg scale:1.0
                                 orientation:UIImageOrientationUp];
    CGImageRelease(cg);
    return img;
}

// ── безопасный delegate-hook helper ───────────────────────────────────────
static BOOL _kyc_hookClassMethod(Class cls, SEL sel,
                                 IMP newIMP, IMP *outCapturedIMP)
{
    if (!cls || !sel || !newIMP || !outCapturedIMP) return NO;

    const char *cnRaw = class_getName(cls);
    if (_kyc_isUnsafeClassName(cnRaw)) {
        MPU_KYC_LOG(@"skip unsafe delegate class: %s", cnRaw ?: "(null)");
        return NO;
    }
    NSString *cn = NSStringFromClass(cls);
    if (!cn) return NO;

    @synchronized(_mpu_globalHookedLock) {
        if ([_mpu_globalHookedClasses containsObject:cn]) return YES;
    }

    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    const char *types = method_getTypeEncoding(m);
    if (!types) return NO;

    *outCapturedIMP = method_getImplementation(m);

    BOOL added = class_addMethod(cls, sel, newIMP, types);
    if (!added) {
        IMP prev = class_replaceMethod(cls, sel, newIMP, types);
        if (prev) *outCapturedIMP = prev;
    }

    @synchronized(_mpu_globalHookedLock) {
        [_mpu_globalHookedClasses addObject:cn];
    }
    MPU_KYC_LOG(@"hooked %@ on class %@", NSStringFromSelector(sel), cn);
    return YES;
}

// =============================================================================
// 1) UIImagePickerController
// =============================================================================
%hook UIImagePickerController

- (void)setDelegate:(id<UIImagePickerControllerDelegate, UINavigationControllerDelegate>)delegate {
    %orig;
    if (!delegate) return;
    Class cls = object_getClass(delegate);
    SEL sel = @selector(imagePickerController:didFinishPickingMediaWithInfo:);

    __block IMP capturedIMP = NULL;
    IMP newIMP = imp_implementationWithBlock(^(id self_,
        UIImagePickerController *picker, NSDictionary *info) {
        if (!capturedIMP) return;
        if (!_enabled) {
            ((void(*)(id,SEL,UIImagePickerController*,NSDictionary*))
                capturedIMP)(self_, sel, picker, info);
            return;
        }
        UIImage *fake = _kyc_replacementUIImage();
        if (!fake) {
            ((void(*)(id,SEL,UIImagePickerController*,NSDictionary*))
                capturedIMP)(self_, sel, picker, info);
            return;
        }
        NSMutableDictionary *patched = [info mutableCopy];
        patched[UIImagePickerControllerOriginalImage] = fake;
        if (patched[UIImagePickerControllerEditedImage]) {
            patched[UIImagePickerControllerEditedImage] = fake;
        }
        MPU_KYC_LOG(@"UIImagePicker -> replaced");
        ((void(*)(id,SEL,UIImagePickerController*,NSDictionary*))
            capturedIMP)(self_, sel, picker, patched);
    });

    if (!_kyc_hookClassMethod(cls, sel, newIMP, &capturedIMP)) {
        imp_removeBlock(newIMP);
    }
}

%end

// =============================================================================
// 2) VNDocumentCameraViewController
// =============================================================================
%hook VNDocumentCameraViewController

- (void)setDelegate:(id<VNDocumentCameraViewControllerDelegate>)delegate {
    %orig;
    if (!delegate) return;
    Class cls = object_getClass(delegate);
    SEL sel = @selector(documentCameraViewController:didFinishWithScan:);

    __block IMP capturedIMP = NULL;
    IMP newIMP = imp_implementationWithBlock(^(id self_,
        VNDocumentCameraViewController *vc, VNDocumentCameraScan *scan) {
        if (!capturedIMP) return;
        if (!_enabled || !scan || scan.pageCount == 0) {
            ((void(*)(id,SEL,VNDocumentCameraViewController*,VNDocumentCameraScan*))
                capturedIMP)(self_, sel, vc, scan);
            return;
        }
        UIImage *fake = _kyc_replacementUIImage();
        if (!fake) {
            ((void(*)(id,SEL,VNDocumentCameraViewController*,VNDocumentCameraScan*))
                capturedIMP)(self_, sel, vc, scan);
            return;
        }
        objc_setAssociatedObject(scan, "_kyc_fake_image", fake,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        MPU_KYC_LOG(@"VNDocumentScan -> page image hijacked (pages=%lu)",
                    (unsigned long)scan.pageCount);
        ((void(*)(id,SEL,VNDocumentCameraViewController*,VNDocumentCameraScan*))
            capturedIMP)(self_, sel, vc, scan);
    });

    if (!_kyc_hookClassMethod(cls, sel, newIMP, &capturedIMP)) {
        imp_removeBlock(newIMP);
    }
}

%end

%hook VNDocumentCameraScan
- (UIImage *)imageOfPageAtIndex:(NSUInteger)index {
    UIImage *fake = objc_getAssociatedObject(self, "_kyc_fake_image");
    if (fake) return fake;
    return %orig;
}
%end

// =============================================================================
// 3) AVCapturePhotoOutput
//
// v1.8.6: capturePhotoWithSettings:delegate: переведён на MSHookMessageEx.
// Причина — та же, что у VNImageRequestHandler init-методов и у
// captureStillImageAsynchronously... в PhotoCaptureHooks.x: свежий logos
// из master-theos ломается на %orig(args) в многоаргументном методе с
// `id<Protocol>`-параметром и склеивает следующие конструкции внутрь
// _logos_method$..., из-за чего "function definition is not allowed here".
// =============================================================================
typedef void (*mpu_capturePhoto_imp_t)(id, SEL,
                                       AVCapturePhotoSettings *,
                                       id<AVCapturePhotoCaptureDelegate>);
static mpu_capturePhoto_imp_t mpu_orig_capturePhoto = NULL;

static void mpu_new_capturePhoto(id self, SEL _cmd,
                                 AVCapturePhotoSettings *settings,
                                 id<AVCapturePhotoCaptureDelegate> delegate) {
    if (!_enabled || !delegate) {
        if (mpu_orig_capturePhoto) mpu_orig_capturePhoto(self, _cmd, settings, delegate);
        return;
    }
    Class cls = object_getClass(delegate);
    SEL sel = @selector(captureOutput:didFinishProcessingPhoto:error:);

    __block IMP capturedIMP = NULL;
    IMP newIMP = imp_implementationWithBlock(^(id self_,
        AVCapturePhotoOutput *out, AVCapturePhoto *photo, NSError *err) {
        if (!capturedIMP) return;
        MPU_KYC_LOG(@"AVCapturePhoto delegate fired (photo=%@)",
                    photo ? @"OK" : @"nil");
        ((void(*)(id,SEL,AVCapturePhotoOutput*,AVCapturePhoto*,NSError*))
            capturedIMP)(self_, sel, out, photo, err);
    });

    if (!_kyc_hookClassMethod(cls, sel, newIMP, &capturedIMP)) {
        imp_removeBlock(newIMP);
    }
    if (mpu_orig_capturePhoto) mpu_orig_capturePhoto(self, _cmd, settings, delegate);
}

// =============================================================================
// 4) VNImageRequestHandler — подмена входного буфера
//
// initWithCVPixelBuffer:options: и initWithCVPixelBuffer:orientation:options:
// перенесены на MSHookMessageEx (см. ниже), потому что свежий logos падает
// на %orig(ours, options). initWithCMSampleBuffer:options: оставлен в %hook —
// там %orig без аргументов нам не нужен (вызов идёт через [self init...]).
// =============================================================================
%hook VNImageRequestHandler

- (instancetype)initWithCMSampleBuffer:(CMSampleBufferRef)sampleBuffer
                               options:(NSDictionary *)options {
    if (!_enabled) return %orig;
    CVPixelBufferRef ours = _kyc_copyBuffer();
    if (!ours) return %orig;
    self = [self initWithCVPixelBuffer:ours options:options];
    CVPixelBufferRelease(ours);
    return self;
}

%end

// =============================================================================
// MSHookMessageEx для VNImageRequestHandler initWithCVPixelBuffer:*
// =============================================================================
typedef id (*mpu_vn_init_pb_t)(id, SEL, CVPixelBufferRef, NSDictionary *);
typedef id (*mpu_vn_init_pb_o_t)(id, SEL, CVPixelBufferRef,
                                CGImagePropertyOrientation, NSDictionary *);

static mpu_vn_init_pb_t   mpu_orig_vn_init_pb   = NULL;
static mpu_vn_init_pb_o_t mpu_orig_vn_init_pb_o = NULL;

static id mpu_new_vn_init_pb(id self, SEL _cmd,
                             CVPixelBufferRef pixelBuffer,
                             NSDictionary *options) {
    if (!_enabled || !mpu_orig_vn_init_pb)
        return mpu_orig_vn_init_pb ? mpu_orig_vn_init_pb(self, _cmd, pixelBuffer, options)
                                   : nil;
    CVPixelBufferRef ours = _kyc_copyBuffer();
    if (!ours)
        return mpu_orig_vn_init_pb(self, _cmd, pixelBuffer, options);
    id result = mpu_orig_vn_init_pb(self, _cmd, ours, options);
    CVPixelBufferRelease(ours);
    MPU_KYC_LOG(@"VNImageRequestHandler(CVPixelBuffer) substituted");
    return result;
}

static id mpu_new_vn_init_pb_o(id self, SEL _cmd,
                               CVPixelBufferRef pixelBuffer,
                               CGImagePropertyOrientation orientation,
                               NSDictionary *options) {
    if (!_enabled || !mpu_orig_vn_init_pb_o)
        return mpu_orig_vn_init_pb_o ? mpu_orig_vn_init_pb_o(self, _cmd, pixelBuffer,
                                                              orientation, options)
                                     : nil;
    CVPixelBufferRef ours = _kyc_copyBuffer();
    if (!ours)
        return mpu_orig_vn_init_pb_o(self, _cmd, pixelBuffer, orientation, options);
    id result = mpu_orig_vn_init_pb_o(self, _cmd, ours,
                                      kCGImagePropertyOrientationUp, options);
    CVPixelBufferRelease(ours);
    MPU_KYC_LOG(@"VNImageRequestHandler(CVPixelBuffer, orientation) substituted");
    return result;
}

// =============================================================================
// %ctor — gatekeeper, без CIContext init
// =============================================================================
%ctor {
    @autoreleasepool {
        if (!_kyc_processIsLoadable()) return;

        if (!_v_lock) _v_lock = [NSObject new];
        if (!_mpu_globalHookedClasses) {
            _mpu_globalHookedClasses = [NSMutableSet new];
            _mpu_globalHookedLock    = [NSObject new];
        }

        %init;

        // MSHookMessageEx для VNImageRequestHandler init-методов с буфером.
        Class clsVN = NSClassFromString(@"VNImageRequestHandler");
        if (clsVN) {
            SEL sel1 = @selector(initWithCVPixelBuffer:options:);
            if (class_getInstanceMethod(clsVN, sel1)) {
                MSHookMessageEx(clsVN, sel1, (IMP)mpu_new_vn_init_pb,
                                (IMP *)&mpu_orig_vn_init_pb);
                MPU_KYC_LOG(@"MSHookMessageEx: VN initWithCVPixelBuffer:options: hooked");
            }

            SEL sel2 = @selector(initWithCVPixelBuffer:orientation:options:);
            if (class_getInstanceMethod(clsVN, sel2)) {
                MSHookMessageEx(clsVN, sel2, (IMP)mpu_new_vn_init_pb_o,
                                (IMP *)&mpu_orig_vn_init_pb_o);
                MPU_KYC_LOG(@"MSHookMessageEx: VN initWithCVPixelBuffer:orientation:options: hooked");
            }
        }

        // MSHookMessageEx для AVCapturePhotoOutput capturePhotoWithSettings:delegate:
        // (v1.8.6: вынесено из %hook — см. комментарий у typedef выше)
        Class clsPO = NSClassFromString(@"AVCapturePhotoOutput");
        if (clsPO) {
            SEL selCP = @selector(capturePhotoWithSettings:delegate:);
            if (class_getInstanceMethod(clsPO, selCP)) {
                MSHookMessageEx(clsPO, selCP, (IMP)mpu_new_capturePhoto,
                                (IMP *)&mpu_orig_capturePhoto);
                MPU_KYC_LOG(@"MSHookMessageEx: AVCapturePhotoOutput capturePhotoWithSettings:delegate: hooked");
            }
        }

        MPU_KYC_LOG(@"Loaded for %@", [[NSBundle mainBundle] bundleIdentifier]);
    }
}
