#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

@interface VVCamState : NSObject
+ (instancetype)shared;
@property (atomic, assign) BOOL enabled;
- (void)reload;
- (BOOL)hasMedia;
// Возвращает текущий кадр в BGRA (для видео — следующий кадр с зацикливанием). Caller освобождает CVPixelBufferRelease.
- (CVPixelBufferRef)copyCurrentPixelBuffer CF_RETURNS_RETAINED;
@end
