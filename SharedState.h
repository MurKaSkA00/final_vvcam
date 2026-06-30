// SharedState.h - MediaPlaybackUtils v2.1.0 "All Apps"
#ifndef SHARED_STATE_H
#define SHARED_STATE_H

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>

extern BOOL              _enabled;
extern CVPixelBufferRef  _lastBuffer;
extern id                _v_lock;
extern CFTimeInterval    _lastBufferTime;

extern NSMutableSet     *_mpu_globalHookedClasses;
extern id                _mpu_globalHookedLock;

// Единый gatekeeper — вызывать из %ctor каждого модуля.
BOOL       _mpu_processIsLoadable(void);

// v2.1.0: ТОЛЬКО заведомо служебные имена. Swift/Kotlin-классы теперь
// разрешены (мы хукаем их через method_setImplementation, не addMethod).
BOOL       _mpu_isUnsafeClassName(const char *cn);

// Ленивая безопасная инициализация CIContext (Metal → software fallback).
CIContext *_mpu_ciContextShared(void);

// v2.1.0: конвертер CVPixelBuffer в произвольный OSType формат.
// Если src уже в нужном формате — retain.
// Возвращает retained буфер (caller должен CVPixelBufferRelease).
CVPixelBufferRef _mpu_convertPixelBuffer(CVPixelBufferRef src,
                                          OSType targetFormat) CF_RETURNS_RETAINED;

// v2.1.0: вытащить ожидаемый pixel-format из AVCaptureVideoDataOutput.
// Возвращает 0, если не задан.
OSType _mpu_outputPixelFormat(id avCaptureVideoDataOutput);

#endif
