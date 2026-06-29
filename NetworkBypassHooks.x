// NetworkBypassHooks.x — MediaPlaybackUtils
// Снимает ATS-ограничения в целевом приложении, чтобы AVPlayer / NSURLSession
// могли тянуть cleartext HTTP-поток (например http://192.168.1.44:8888/...m3u8).
//
// Без этого iOS блокирует незащищённый HTTP внутри сторонних приложений,
// _lastBuffer остаётся пустым, и реальная камера не подменяется.

#import <Foundation/Foundation.h>
#import "SharedState.h"

// Готовый ATS-словарь, разрешающий любые (в т.ч. локальные cleartext) загрузки.
static NSDictionary *_mpu_permissiveATS(void) {
    static NSDictionary *ats = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ats = @{
            @"NSAllowsArbitraryLoads":            @YES,
            @"NSAllowsArbitraryLoadsForMedia":    @YES,
            @"NSAllowsArbitraryLoadsInWebContent":@YES,
            @"NSAllowsLocalNetworking":           @YES,
        };
    });
    return ats;
}

%hook NSBundle

- (id)objectForInfoDictionaryKey:(NSString *)key {
    if ([key isEqualToString:@"NSAppTransportSecurity"] && self == [NSBundle mainBundle]) {
        return _mpu_permissiveATS();
    }
    return %orig;
}

- (NSDictionary *)infoDictionary {
    NSDictionary *orig = %orig;
    if (self != [NSBundle mainBundle]) return orig;
    NSDictionary *cur = orig[@"NSAppTransportSecurity"];
    if ([cur isKindOfClass:[NSDictionary class]] &&
        [cur[@"NSAllowsArbitraryLoads"] boolValue]) {
        return orig; // уже разрешено — не трогаем
    }
    NSMutableDictionary *m = orig ? [orig mutableCopy] : [NSMutableDictionary new];
    m[@"NSAppTransportSecurity"] = _mpu_permissiveATS();
    return m;
}

%end

%ctor {
    @autoreleasepool {
        if (!_mpu_processIsLoadable()) return;
        %init;
    }
}
