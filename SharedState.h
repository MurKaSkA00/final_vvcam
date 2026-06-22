1. SharedState.h
// SharedState.h - MediaPlaybackUtils v1.7.6
// Общие переменные между Tweak.x / WebRTCHooks.x / BrowserHooks.x / AntifraudHooks.x
#ifndef SHARED_STATE_H
#define SHARED_STATE_H

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

extern BOOL              _enabled;
extern CVPixelBufferRef  _lastBuffer;
extern id                _v_lock;
extern CFTimeInterval    _lastBufferTime;

// FIX 3: общий набор уже свизленных классов — иначе Tweak.x + WebRTCHooks.x +
// BrowserHooks.x могли свизлить один класс несколько раз и уходить в бесконечную
// рекурсию IMP. Используется во всех трёх модулях.
extern NSMutableSet     *_mpu_globalHookedClasses;
extern id                _mpu_globalHookedLock;

#endif
