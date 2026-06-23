// SharedState.m — единственное физическое хранилище общих глобалов.
// Линкуется ровно один раз. Все остальные .x/.m видят их через extern из SharedState.h.

#import "SharedState.h"

BOOL              _enabled        = NO;
CVPixelBufferRef  _lastBuffer     = NULL;
id                _v_lock         = nil;
CFTimeInterval    _lastBufferTime = 0;

NSMutableSet     *_mpu_globalHookedClasses = nil;
id                _mpu_globalHookedLock    = nil;
