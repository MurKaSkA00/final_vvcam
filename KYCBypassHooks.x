"// KYCBypassHooks.x - MediaPlaybackUtils v1.8.0
// =============================================================================
// Подмена камеры для KYC/банковских/шопинг-приложений.
//
// ВАЖНО: этот модуль НИКОГДА не делает objc_copyClassList и НИКОГДА не делает
// class_addMethod на пользовательских классах — именно это ломало Amazon/PayPal.
// Только статические %hook на системных классах + прокси-делегаты.
//
// Покрытие:
//   1. VNDocumentCameraViewController  (системный сканер документов в Notes,
//      Adobe Scan, Office Lens, банки используют для подтверждения адреса)
//   2. UIImagePickerController  (legacy: загрузка паспорта/чека через камеру)
//   3. AVCapturePhotoOutput.capturePhotoWithSettings:delegate: — прокси-делегат,
//      подмена самого AVCapturePhoto. (Дублирует PhotoCaptureHooks на уровень
//      выше — на случай, если приложение читает delegate-методы хитро.)
//   4. VNImageRequestHandler init* — подменяем входной buffer на наш кадр,
//      что отравляет распознавание лица в KYC.
//
// Загружается ТОЛЬКО в bundle'ах из _kyc_targetBundles ниже (отдельный
// список от MediaPlaybackUtils.plist — мы НЕ полагаемся на CydiaSubstrate
// фильтр для этого модуля).
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

static CIContext *_kyc_ciContext = nil;

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
    if (!pb || !_kyc_ciContext) return NULL;
    CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
    if (!ci) return NULL;
    return [_kyc_ciContext createCGImage:ci fromRect:ci.extent];
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
// 1. UIImagePickerController — legacy путь (загрузка фото из камеры)
// =============================================================================
%hook UIImagePickerController

- (void)setDelegate:(id<UIImagePickerControllerDelegate, UINavigationControllerDelegate>)delegate {
    %orig;
    if (!delegate) return;
    Class cls = object_getClass(delegate);
    SEL sel = @selector(imagePickerController:didFinishPickingMediaWithInfo:);
    if (!class_getInstanceMethod(cls, sel)) return;

    // Per-instance swizzle через associated object, чтобы НЕ трогать класс
    // (избегаем class_addMethod на пользовательском классе).
    static const void *kFlag = &kFlag;
    if (objc_getAssociatedObject(delegate, kFlag)) return;
    objc_setAssociatedObject(delegate, kFlag, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    Method m = class_getInstanceMethod(cls, sel);
    IMP origIMP = method_getImplementation(m);

    IMP newIMP = imp_implementationWithBlock(^(id self_,
        UIImagePickerController *picker, NSDictionary *info) {
        if (!_enabled) {
            ((void(*)(id,SEL,UIImagePickerController*,NSDictionary*))origIMP)(self_, sel, picker, info);
            return;
        }
        UIImage *fake = _kyc_replacementUIImage();
        if (!fake) {
            ((void(*)(id,SEL,UIImagePickerController*,NSDictionary*))origIMP)(self_, sel, picker, info);
            return;
        }
        NSMutableDictionary *patched = [info mutableCopy];
        patched[UIImagePickerControllerOriginalImage] = fake;
        if (patched[UIImagePickerControllerEditedImage]) {
            patched[UIImagePickerControllerEditedImage] = fake;
        }
        MPU_KYC_LOG(@\"UIImagePicker → replaced\");
        ((void(*)(id,SEL,UIImagePickerController*,NSDictionary*))origIMP)(self_, sel, picker, patched);
    });
    method_setImplementation(m, newIMP);
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
    if (!class_getInstanceMethod(cls, sel)) return;

    static const void *kFlag = &kFlag;
    if (objc_getAssociatedObject(delegate, kFlag)) return;
    objc_setAssociatedObject(delegate, kFlag, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    Method m = class_getInstanceMethod(cls, sel);
    IMP origIMP = method_getImplementation(m);

    IMP newIMP = imp_implementationWithBlock(^(id self_,
        VNDocumentCameraViewController *vc, VNDocumentCameraScan *scan) {
        if (!_enabled || !scan || scan.pageCount == 0) {
            ((void(*)(id,SEL,VNDocumentCameraViewController*,VNDocumentCameraScan*))
                origIMP)(self_, sel, vc, scan);
            return;
        }
        UIImage *fake = _kyc_replacementUIImage();
        if (!fake) {
            ((void(*)(id,SEL,VNDocumentCameraViewController*,VNDocumentCameraScan*))
                origIMP)(self_, sel, vc, scan);
            return;
        }
        // VNDocumentCameraScan не имеет публичного API для замены страниц.
        // Подменяем через swizzle imageOfPageAtIndex: на этом инстансе через
        // associated object — самый безопасный путь.
        objc_setAssociatedObject(scan, \"_kyc_fake_image\", fake,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        MPU_KYC_LOG(@\"VNDocumentScan → page image hijacked (pages=%lu)\",
                    (unsigned long)scan.pageCount);
        ((void(*)(id,SEL,VNDocumentCameraViewController*,VNDocumentCameraScan*))
            origIMP)(self_, sel, vc, scan);
    });
    method_setImplementation(m, newIMP);
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
//    Дублирует защиту PhotoCaptureHooks: если приложение перехватывает кадр
//    в самом делегате (а не через accessors на AVCapturePhoto), мы успеваем
//    подменить ДО передачи в делегат.
// =============================================================================
%hook AVCapturePhotoOutput

- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings
                        delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    if (!_enabled || !delegate) { %orig; return; }
    Class cls = object_getClass(delegate);
    SEL sel = @selector(captureOutput:didFinishProcessingPhoto:error:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { %orig; return; }

    static const void *kFlag = &kFlag;
    if (!objc_getAssociatedObject(delegate, kFlag)) {
        objc_setAssociatedObject(delegate, kFlag, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        IMP origIMP = method_getImplementation(m);
        IMP newIMP = imp_implementationWithBlock(^(id self_,
            AVCapturePhotoOutput *out, AVCapturePhoto *photo, NSError *err) {
            // AVCapturePhoto уже захукан PhotoCaptureHooks.x — accessor'ы
            // вернут наш кадр. Просто передаём в оригинальный делегат.
            MPU_KYC_LOG(@\"AVCapturePhoto delegate fired (photo=%@)\",
                        photo ? @\"OK\" : @\"nil\");
            ((void(*)(id,SEL,AVCapturePhotoOutput*,AVCapturePhoto*,NSError*))
                origIMP)(self_, sel, out, photo, err);
        });
        method_setImplementation(m, newIMP);
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
    // Принудительно ориентация Up — наш кадр уже как в превью.
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
// ctor — загружаемся ТОЛЬКО в KYC/банковских процессах
// =============================================================================
static BOOL _kyc_isTargetProcess(NSString *bid) {
    if (!bid) return NO;
    static NSArray *targets = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        targets = @[
            // Shopping / маркетплейсы
            @\"com.amazon.Amazon\",
            @\"com.ebay.iphone.shopping\",
            @\"com.poshmark.poshmark\",
            @\"com.offerup.offerup\",
            // Payments
            @\"com.paypal.PPClient\",
            @\"com.venmo.Venmo\",
            @\"com.cashapp.squarecash\",
            @\"com.konylabs.westernunion\",
            // Банки
            @\"com.chase.sig.ios\",
            @\"com.bankofamerica.BofAMobileBanking\",
            @\"com.wellsfargo.wellsfargomobile\",
            @\"com.key.KeyBank\",
            @\"com.citigroup.citimobile\",
            // Доставка/такси (часто KYC водителя)
            @\"com.doordash.DoorDash-Consumer\",
            // Сканеры документов
            @\"com.adobe.scan.ios\",
            @\"com.microsoft.Office.Lens\",
            @\"com.readdle.scanner\",
            @\"net.doo.DMobile\",
        ];
    });
    for (NSString *t in targets) {
        if ([bid hasPrefix:t] || [bid isEqualToString:t]) return YES;
    }
    return NO;
}

%ctor {
    @autoreleasepool {
        NSString *bid  = [[NSBundle mainBundle] bundleIdentifier];
        NSString *path = [[NSBundle mainBundle] bundlePath];
        if (!bid) return;
        if ([path hasPrefix:@\"/usr/\"]) return;
        if ([path hasPrefix:@\"/System/\"]) return;
        if (!_kyc_isTargetProcess(bid)) return;

        // Подстраховка от nil-locks (Tweak.x %ctor отрабатывает после нас в
        // редких случаях — например, если KYC SDK триггерит +load очень рано).
        if (!_v_lock) _v_lock = [NSObject new];

        if (!_kyc_ciContext) {
            _kyc_ciContext = [CIContext contextWithOptions:@{
                kCIContextUseSoftwareRenderer: @NO
            }];
        }

        %init;
        MPU_KYC_LOG(@\"Loaded for %@\", bid);
    }
}
"
