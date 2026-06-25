// KYCBypassHooks.x - MediaPlaybackUtils v1.8.3
// =============================================================================
// Подмена камеры для KYC/банковских/шопинг-приложений.
//
// FIX 9 (v1.8.3) — устранены краши Citibank / Capital One (EASEApp) / Widgets /
// navd / destinationd / mapspushd:
//
//   1) %ctor больше НЕ создаёт CIContext. Это валило системные сервисы карт
//      без GPU (CIContext init → краш). Теперь _kyc_ciContext получается
//      лениво через общий _mpu_ciContextShared() (Metal → software fallback).
//
//   2) Делегатные хуки UIImagePickerController / VNDocumentCameraViewController /
//      AVCapturePhotoOutput раньше делали method_setImplementation на Method,
//      который мог быть УНАСЛЕДОВАН от superclass (Citibank/Capital One — это
//      Swift/ObjC SDK с глубокой иерархией делегатов). Это меняло реализацию
//      В СУПЕРКЛАССЕ и ломало ВСЕ его другие подклассы → отсюда краш
//      \"objc_msgSend в IdentitySilentMobileAuth SDK\" и
//      \"_platform_memcmp → MediaPlaybackUtils.dylib\".
//
//      Теперь используется правильный паттерн (как в Tweak.x FIX 6):
//        - skip Swift/Kotlin/служебных классов (_mpu_isUnsafeClassName)
//        - class_addMethod(cls, sel, newIMP, types) — если YES, в leaf-класс
//          добавлен наш override, capturedIMP указывает на super (корректно).
//        - если NO — класс уже имеет свою IMP, делаем class_replaceMethod
//          и сохраняем prev как capturedIMP.
//        - трекинг через _mpu_globalHookedClasses — никаких повторных хуков.
//
//   3) %ctor использует общий _mpu_processIsLoadable() — отбрасывает
//      .appex (Widgets), системные демоны, /System/, /usr/, com.apple.*.
//
//   4) VNDocumentCameraScan imageOfPageAtIndex: используется только если
//      ассоциированный fake image присутствует — без побочных эффектов на
//      другие приложения.
// =============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <Vision/Vision.h>
#import <VisionKit/VisionKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import \"SharedState.h\"

#define MPU_KYC_LOG(fmt, ...) NSLog(@\"[MPU/KYC] \" fmt, ##__VA_ARGS__)

// ── общий helper: текущий заменяющий pixel buffer (retained) ─────────────────
static CVPixelBufferRef _kyc_copyBuffer(void) CF_RETURNS_RETAINED {
    if (!_enabled || !_v_lock) return NULL;
    CVPixelBufferRef pb = NULL;
    @synchronized(_v_lock) {
        if (_lastBuffer) pb = CVPixelBufferRetain(_lastBuffer);
    }
    return pb;
}

// CGImage из pixel buffer (CGImageRelease на стороне вызывающего)
static CGImageRef _kyc_createCGImage(CVPixelBufferRef pb) CF_RETURNS_RETAINED {
    if (!pb) return NULL;
    CIContext *ctx = _mpu_ciContextShared();
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

// =============================================================================
// FIX 9 (v1.8.3): универсальный безопасный delegate-hook helper.
// Заменяет старый method_setImplementation(m, newIMP), который ломал
// унаследованные методы в Citi / Capital One.
//
//   cls   — класс делегата (object_getClass(delegate))
//   sel   — селектор делегатного метода
//   block — Objective-C блок-обёртка, ВНУТРИ которой вызывается capturedIMP:
//           ((void(*)(id,SEL,...))capturedIMP)(self_, sel, ...)
//
// Возвращает YES при успешном хуке (или если класс уже захукан),
// NO — если класс пропущен (Swift/Kotlin/служебный) или метод не найден.
// =============================================================================
static BOOL _kyc_hookClassMethod(Class cls, SEL sel,
                                  const char **outTypes, IMP newIMP,
                                  IMP *outCapturedIMP)
{
    if (!cls || !sel || !newIMP || !outCapturedIMP) return NO;

    const char *cnRaw = class_getName(cls);
    if (_mpu_isUnsafeClassName(cnRaw)) {
        MPU_KYC_LOG(@\"skip unsafe delegate class: %s\", cnRaw ?: \"(null)\");
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
    if (outTypes) *outTypes = types;

    // Сначала capturedIMP — это либо собственная IMP класса, либо унаследованная.
    *outCapturedIMP = method_getImplementation(m);

    BOOL added = class_addMethod(cls, sel, newIMP, types);
    if (!added) {
        IMP prev = class_replaceMethod(cls, sel, newIMP, types);
        if (prev) *outCapturedIMP = prev;
    }

    @synchronized(_mpu_globalHookedLock) {
        [_mpu_globalHookedClasses addObject:cn];
    }
    MPU_KYC_LOG(@\"hooked %@ on class %@\", NSStringFromSelector(sel), cn);
    return YES;
}

// =============================================================================
// 1. UIImagePickerController — legacy путь (загрузка фото из камеры)
// =============================================================================
%hook UIImagePickerController

- (void)setDelegate:(id<UIImagePickerControllerDelegate, UINavigationControllerDelegate>)delegate {
    %orig;
    if (!delegate) return;
    Class cls = object_getClass(delegate);
    SEL sel = @selector(imagePickerController:didFinishPickingMediaWithInfo:);

    __block IMP capturedIMP = NULL;
    const char *types = NULL;
    IMP newIMP = imp_implementationWithBlock(^(id self_,
        UIImagePickerController *picker, NSDictionary *info) {
        if (!capturedIMP) return;
        if (!_enabled) {
            ((void(*)(id,SEL,UIImagePickerController*,NSDictionary*))capturedIMP)(self_, sel, picker, info);
            return;
        }
        UIImage *fake = _kyc_replacementUIImage();
        if (!fake) {
            ((void(*)(id,SEL,UIImagePickerController*,NSDictionary*))capturedIMP)(self_, sel, picker, info);
            return;
        }
        NSMutableDictionary *patched = [info mutableCopy];
        patched[UIImagePickerControllerOriginalImage] = fake;
        if (patched[UIImagePickerControllerEditedImage]) {
            patched[UIImagePickerControllerEditedImage] = fake;
        }
        MPU_KYC_LOG(@\"UIImagePicker → replaced\");
        ((void(*)(id,SEL,UIImagePickerController*,NSDictionary*))capturedIMP)(self_, sel, picker, patched);
    });

    if (!_kyc_hookClassMethod(cls, sel, &types, newIMP, &capturedIMP)) {
        imp_removeBlock(newIMP);
    }
}

%end

// =============================================================================
// 2. VNDocumentCameraViewController — системный сканер документов
// =============================================================================
%hook VNDocumentCameraViewController

- (void)setDelegate:(id<VNDocumentCameraViewControllerDelegate>)delegate {
    %orig;
    if (!delegate) return;
    Class cls = object_getClass(delegate);
    SEL sel = @selector(documentCameraViewController:didFinishWithScan:);

    __block IMP capturedIMP = NULL;
    const char *types = NULL;
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
        objc_setAssociatedObject(scan, \"_kyc_fake_image\", fake,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        MPU_KYC_LOG(@\"VNDocumentScan → page image hijacked (pages=%lu)\",
                    (unsigned long)scan.pageCount);
        ((void(*)(id,SEL,VNDocumentCameraViewController*,VNDocumentCameraScan*))
            capturedIMP)(self_, sel, vc, scan);
    });

    if (!_kyc_hookClassMethod(cls, sel, &types, newIMP, &capturedIMP)) {
        imp_removeBlock(newIMP);
    }
}

%end

%hook VNDocumentCameraScan
- (UIImage *)imageOfPageAtIndex:(NSUInteger)index {
    UIImage *fake = objc_getAssociatedObject(self, \"_kyc_fake_image\");
    if (fake) return fake;
    return %orig;
}
%end

// =============================================================================
// 3. AVCapturePhotoOutput.capturePhotoWithSettings:delegate: — прокси-делегат
// =============================================================================
%hook AVCapturePhotoOutput

- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings
                        delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    if (!_enabled || !delegate) { %orig; return; }
    Class cls = object_getClass(delegate);
    SEL sel = @selector(captureOutput:didFinishProcessingPhoto:error:);

    __block IMP capturedIMP = NULL;
    const char *types = NULL;
    IMP newIMP = imp_implementationWithBlock(^(id self_,
        AVCapturePhotoOutput *out, AVCapturePhoto *photo, NSError *err) {
        if (!capturedIMP) return;
        MPU_KYC_LOG(@\"AVCapturePhoto delegate fired (photo=%@)\",
                    photo ? @\"OK\" : @\"nil\");
        ((void(*)(id,SEL,AVCapturePhotoOutput*,AVCapturePhoto*,NSError*))
            capturedIMP)(self_, sel, out, photo, err);
    });

    if (!_kyc_hookClassMethod(cls, sel, &types, newIMP, &capturedIMP)) {
        imp_removeBlock(newIMP);
    }
    %orig;
}

%end

// =============================================================================
// 4. Vision: VNImageRequestHandler — подмена входного буфера для face/text
// =============================================================================
%hook VNImageRequestHandler

- (instancetype)initWithCVPixelBuffer:(CVPixelBufferRef)pixelBuffer
                              options:(NSDictionary<VNImageOption, id> *)options {
    if (!_enabled) return %orig;
    CVPixelBufferRef ours = _kyc_copyBuffer();
    if (!ours) return %orig;
    self = %orig(ours, options);
    CVPixelBufferRelease(ours);
    MPU_KYC_LOG(@\"VNImageRequestHandler(CVPixelBuffer) substituted\");
    return self;
}

- (instancetype)initWithCVPixelBuffer:(CVPixelBufferRef)pixelBuffer
                          orientation:(CGImagePropertyOrientation)orientation
                              options:(NSDictionary<VNImageOption, id> *)options {
    if (!_enabled) return %orig;
    CVPixelBufferRef ours = _kyc_copyBuffer();
    if (!ours) return %orig;
    self = %orig(ours, kCGImagePropertyOrientationUp, options);
    CVPixelBufferRelease(ours);
    MPU_KYC_LOG(@\"VNImageRequestHandler(CVPixelBuffer, orientation) substituted\");
    return self;
}

- (instancetype)initWithCMSampleBuffer:(CMSampleBufferRef)sampleBuffer
                               options:(NSDictionary<VNImageOption, id> *)options {
    if (!_enabled) return %orig;
    CVPixelBufferRef ours = _kyc_copyBuffer();
    if (!ours) return %orig;
    self = [self initWithCVPixelBuffer:ours options:options];
    CVPixelBufferRelease(ours);
    return self;
}

%end

// =============================================================================
// ctor — единый общий gatekeeper, без CIContext init
// =============================================================================
%ctor {
    @autoreleasepool {
        // FIX 9 (v1.8.3): общий gatekeeper отбрасывает все .appex / системные
        // демоны / com.apple.* / /System/ / /usr/ . Это убирает краши в
        // Widgets (FBLPromises), navd, destinationd, mapspushd.
        if (!_mpu_processIsLoadable()) return;

        // FIX 9: НЕ создаём CIContext в %ctor! Раньше [CIContext contextWithOptions:]
        // падал в системных сервисах без GPU. Теперь — лениво через
        // _mpu_ciContextShared() в _kyc_createCGImage().

        // Подстраховка от nil-locks
        if (!_v_lock) _v_lock = [NSObject new];
        if (!_mpu_globalHookedClasses) {
            _mpu_globalHookedClasses = [NSMutableSet new];
            _mpu_globalHookedLock    = [NSObject new];
        }

        %init;
        MPU_KYC_LOG(@\"Loaded for %@\", [[NSBundle mainBundle] bundleIdentifier]);
    }
}
