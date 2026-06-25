// SharedState.h - MediaPlaybackUtils v1.8.4
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

// Проверка опасных (Swift/Kotlin/служебных) имён классов.
BOOL       _mpu_isUnsafeClassName(const char *cn);

// Ленивая безопасная инициализация CIContext (Metal → software fallback).
// НЕ вызывать из %ctor — только из горячего пути!
CIContext *_mpu_ciContextShared(void);

#endif
