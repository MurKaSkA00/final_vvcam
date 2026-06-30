#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

@interface VVCamEngine : NSObject
// Возвращает новый CMSampleBuffer с нашим кадром в формате/размере/тайминге оригинала, либо NULL.
+ (CMSampleBufferRef)replacementForSampleBuffer:(CMSampleBufferRef)original CF_RETURNS_RETAINED;
// Заполняет уже существующий целевой pixel buffer нашим кадром (для фото). YES при успехе.
+ (BOOL)fillPixelBuffer:(CVPixelBufferRef)target;
// Готовое CGImage нашего кадра (для фото-репрезентаций).
+ (CGImageRef)currentCGImage CF_RETURNS_RETAINED;
@end
