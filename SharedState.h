// SharedState.h - MediaPlaybackUtils v1.6.0
// Общие переменные между Tweak.x / WebRTCHooks.x / AntifraudHooks.x
#ifndef SHARED_STATE_H
#define SHARED_STATE_H

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

extern BOOL              _enabled;
extern CVPixelBufferRef  _lastBuffer;
extern id                _v_lock;
extern CFTimeInterval    _lastBufferTime;

#endif
