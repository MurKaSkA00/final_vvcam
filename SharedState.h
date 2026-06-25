// SharedState.h - MediaPlaybackUtils v1.8.3
// Общие переменные и helper-функции между Tweak.x / WebRTCHooks.x /
// BrowserHooks.x / AntifraudHooks.x / KYCBypassHooks.x / PhotoCaptureHooks.x
#ifndef SHARED_STATE_H
#define SHARED_STATE_H

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>

extern BOOL              _enabled;
extern CVPixelBufferRef  _lastBuffer;
extern id                _v_lock;
extern CFTimeInterval    _lastBufferTime;

// FIX 3: общий набор уже свизленных классов — иначе Tweak.x + WebRTCHooks.x +
// BrowserHooks.x могли свизлить один класс несколько раз и уходить в бесконечную
// рекурсию IMP. Используется во всех трёх модулях.
extern NSMutableSet     *_mpu_globalHookedClasses;
extern id                _mpu_globalHookedLock;

// =============================================================================
// FIX 9 (v1.8.3): единый строгий gatekeeper — вызывается из %ctor КАЖДОГО модуля.
// Возвращает NO для:
//   - всех Apple-системных процессов (com.apple.*)
//   - всех app-extensions (.appex / NSExtension в Info.plist) — Widgets, KYCBypass,
//     CallKit-extensions, FileProvider'ы и т.д. Из-за них падали Capital One Widgets
//     (FBLPromises EXC_BREAKPOINT в dyld initializers).
//   - всех бинарей под /System/, /usr/, /Library/, /var/jb/usr/, /var/jb/System/
//     (это где живут navd / destinationd / mapspushd / locationd / searchd и т.п.).
//   - jailbreak / package manager / debugger процессов.
// =============================================================================
BOOL _mpu_processIsLoadable(void);

// FIX 8/9: общая проверка Swift/Kotlin/служебных имён классов.
// class_addMethod / method_setImplementation на таких классах ломает
// swift_getSingletonMetadata в Citi / PayPal / Capital One / банках.
BOOL _mpu_isUnsafeClassName(const char *cn);

// FIX 9 (v1.8.3): безопасное лениво-инициализируемое создание CIContext.
// Изначально пытается Metal, при ошибке — software renderer.
// В системных сервисах без GPU (navd/destinationd/mapspushd) Metal-путь падает
// в _CIContext init → этот helper защищён @try / software fallback.
// Никогда не вызывать из %ctor! Только из горячего пути.
CIContext *_mpu_ciContextShared(void);

#endif
