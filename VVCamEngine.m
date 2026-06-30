#import "VVCamEngine.h"
#import "VVCamState.h"
#import <CoreImage/CoreImage.h>

static CIContext *VVCamCtx(void) {
    static CIContext *ctx; static dispatch_once_t once;
    dispatch_once(&once, ^{
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        ctx = dev ? [CIContext contextWithMTLDevice:dev] : [CIContext contextWithOptions:nil];
    });
    return ctx;
}

@implementation VVCamEngine

+ (BOOL)renderSource:(CVPixelBufferRef)src into:(CVPixelBufferRef)dst {
    if (!src || !dst) return NO;
    size_t dw = CVPixelBufferGetWidth(dst);
    size_t dh = CVPixelBufferGetHeight(dst);
    size_t sw = CVPixelBufferGetWidth(src);
    size_t sh = CVPixelBufferGetHeight(src);
    if (sw == 0 || sh == 0) return NO;

    CIImage *img = [CIImage imageWithCVPixelBuffer:src];

    // aspect-fill + центрирование
    CGFloat scale = MAX((CGFloat)dw / sw, (CGFloat)dh / sh);
    img = [img imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CGFloat tx = ((CGFloat)dw - sw * scale) * 0.5;
    CGFloat ty = ((CGFloat)dh - sh * scale) * 0.5;
    img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(tx, ty)];

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    [VVCamCtx() render:img toCVPixelBuffer:dst bounds:CGRectMake(0, 0, dw, dh) colorSpace:cs];
    CGColorSpaceRelease(cs);
    return YES;
}

+ (CVPixelBufferRef)createTargetLike:(CVPixelBufferRef)sample CF_RETURNS_RETAINED {
    size_t w = CVPixelBufferGetWidth(sample);
    size_t h = CVPixelBufferGetHeight(sample);
    OSType fmt = CVPixelBufferGetPixelFormatType(sample);
    NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    CVPixelBufferRef out = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, fmt,
                            (__bridge CFDictionaryRef)attrs, &out) != kCVReturnSuccess) return NULL;
    return out;
}

+ (CMSampleBufferRef)replacementForSampleBuffer:(CMSampleBufferRef)original {
    VVCamState *st = [VVCamState shared];
    if (![st hasMedia]) return NULL;
    if (!original || !CMSampleBufferIsValid(original)) return NULL;

    CVPixelBufferRef origPB = CMSampleBufferGetImageBuffer(original);
    if (!origPB) return NULL;

    CVPixelBufferRef ours = [st copyCurrentPixelBuffer];
    if (!ours) return NULL;

    CVPixelBufferRef target = [self createTargetLike:origPB];
    if (!target) { CVPixelBufferRelease(ours); return NULL; }

    BOOL ok = [self renderSource:ours into:target];
    CVPixelBufferRelease(ours);
    if (!ok) { CVPixelBufferRelease(target); return NULL; }

    CMSampleTimingInfo timing = {0};
    CMSampleBufferGetSampleTimingInfo(original, 0, &timing);

    CMVideoFormatDescriptionRef fmtDesc = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, target, &fmtDesc) != noErr) {
        CVPixelBufferRelease(target);
        return NULL;
    }

    CMSampleBufferRef out = NULL;
    OSStatus s = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, target, fmtDesc, &timing, &out);
    CFRelease(fmtDesc);
    CVPixelBufferRelease(target);
    if (s != noErr) return NULL;
    return out; // +1, caller releases
}

+ (BOOL)fillPixelBuffer:(CVPixelBufferRef)target {
    VVCamState *st = [VVCamState shared];
    if (![st hasMedia] || !target) return NO;
    CVPixelBufferRef ours = [st copyCurrentPixelBuffer];
    if (!ours) return NO;
    BOOL ok = [self renderSource:ours into:target];
    CVPixelBufferRelease(ours);
    return ok;
}

+ (CGImageRef)currentCGImage {
    VVCamState *st = [VVCamState shared];
    if (![st hasMedia]) return NULL;
    CVPixelBufferRef ours = [st copyCurrentPixelBuffer];
    if (!ours) return NULL;
    CIImage *img = [CIImage imageWithCVPixelBuffer:ours];
    CGImageRef cg = [VVCamCtx() createCGImage:img fromRect:img.extent];
    CVPixelBufferRelease(ours);
    return cg; // +1
}

@end
