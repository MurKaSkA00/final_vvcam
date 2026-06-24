#import "MPURootListController.h"
#import <notify.h>

#define MPU_BUNDLE_ID  @"com.proximacore.mediaplaybackutils"
#define MPU_NOTIF_NAME "com.proximacore.mpu/cfg"

@implementation MPURootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationItem.title = @"Media Playback Utilities";
}

// Зеркалим prefs из /var/jb/... в /var/mobile/... чтобы third-party sandbox их видел
- (void)_mpu_mirrorPrefs {
    NSArray *srcCandidates = @[
        [NSString stringWithFormat:@"/var/jb/var/mobile/Library/Preferences/%@.plist", MPU_BUNDLE_ID],
        [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", MPU_BUNDLE_ID],
    ];
    NSString *dst = [NSString stringWithFormat:
        @"/var/mobile/Library/Preferences/%@.plist", MPU_BUNDLE_ID];

    NSData *data = nil;
    for (NSString *src in srcCandidates) {
        data = [NSData dataWithContentsOfFile:src];
        if (data) break;
    }
    if (data) {
        [data writeToFile:dst atomically:YES];
        // делаем читаемым всем (на случай если umask порезал)
        [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0644}
                                         ofItemAtPath:dst error:nil];
    }
    notify_post(MPU_NOTIF_NAME);
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    // дать cfprefsd флашнуть на диск
    CFPreferencesSynchronize((__bridge CFStringRef)MPU_BUNDLE_ID,
                             kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    [self _mpu_mirrorPrefs];
}

@end
