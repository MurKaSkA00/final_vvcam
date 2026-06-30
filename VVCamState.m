#import "VVCamState.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>

// =============================================================================
//  Preferences sources
//  Исторически в проекте было два несвязанных места, куда писались настройки:
//    1) com.vvcam.plist                       — старая схема runtime
//    2) com.proximacore.mediaplaybackutils    — то, что пишет prefs UI
//                                                (MPURootListController.m)
//  Чтобы не править UI прямо сейчас, runtime читает оба плиста и берёт
//  то, что найдёт (приоритет — у "новой" схемы).
// =============================================================================
static NSString * const kPrefsPathLegacy = @"/var/mobile/Library/Preferences/com.vvcam.plist";
static NSString * const kPrefsPathUI     = @"/var/mobile/Library/Preferences/com.proximacore.mediaplaybackutils.plist";
static NSString * const kNotifyLegacy    = @"com.vvcam/settingschanged";
static NSString * const kNotifyUI        = @"com.proximacore.mpu/cfg";

// Дефолтные пути к медиа — пользователь просто кладёт файл в Documents.
// Имя ОБЯЗАТЕЛЬНО строчными: vvcam.jpg / vvcam.mp4 и т.п.
static NSArray<NSString *> *VVCamDefaultCandidates(void) {
    return @[
        @"/var/mobile/Documents/vvcam.mp4",
        @"/var/mobile/Documents/vvcam.mov",
        @"/var/mobile/Documents/vvcam.m4v",
        @"/var/mobile/Documents/vvcam.jpg",
        @"/var/mobile/Documents/vvcam.jpeg",
        @"/var/mobile/Documents/vvcam.png",
    ];
}

@interface VVCamState ()
@property (nonatomic, copy)   NSString *mediaPath;
@property (nonatomic, assign) BOOL isVideo;
// image
@property (nonatomic, assign) CVPixelBufferRef imageBuffer;
// video
@property (nonatomic, strong) NSURL *videoURL;
@property (nonatomic, strong) AVAssetReader *reader;
@property (nonatomic, strong) AVAssetReaderTrackOutput *trackOutput;
@end

static CVPixelBufferRef VVCamBufferFromImage(UIImage *img) {
    if (!img) return NULL;
    CGImageRef cg = img.CGImage;
    if (!cg) return NULL;
    size_t w = CGImageGetWidth(cg);
    size_t h = CGImageGetHeight(cg);
    NSDictionary *attrs = @{
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess) return NULL;
    CVPixelBufferLockBaseAddress(pb, 0);
    void *base = CVPixelBufferGetBaseAddress(pb);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, CVPixelBufferGetBytesPerRow(pb), cs,
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

@implementation VVCamState

+ (instancetype)shared {
    static VVCamState *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [VVCamState new]; [s reload]; [s registerNotify]; });
    return s;
}

- (void)registerNotify {
    int token;
    notify_register_dispatch(kNotifyLegacy.UTF8String, &token, dispatch_get_main_queue(), ^(int t){
        [self reload];
    });
    int token2;
    notify_register_dispatch(kNotifyUI.UTF8String, &token2, dispatch_get_main_queue(), ^(int t){
        [self reload];
    });
}

- (void)dealloc {
    if (_imageBuffer) CVPixelBufferRelease(_imageBuffer);
}

// Объединяем две схемы preferences. Приоритет — у UI-схемы.
- (NSDictionary *)loadMergedPrefs {
    NSDictionary *legacy = [NSDictionary dictionaryWithContentsOfFile:kPrefsPathLegacy] ?: @{};
    NSDictionary *uiPrefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPathUI]    ?: @{};

    BOOL enabled = YES;
    if (uiPrefs[@"enabled"])      enabled = [uiPrefs[@"enabled"] boolValue];
    else if (legacy[@"Enabled"])  enabled = [legacy[@"Enabled"] boolValue];

    // MediaPath может прийти из любого источника
    NSString *path = uiPrefs[@"MediaPath"] ?: legacy[@"MediaPath"];

    return @{ @"enabled": @(enabled), @"MediaPath": path ?: @"" };
}

- (void)reload {
    @synchronized (self) {
        NSDictionary *prefs = [self loadMergedPrefs];
        NSString *path      = prefs[@"MediaPath"];
        BOOL enabledPref    = [prefs[@"enabled"] boolValue];

        // reset old state
        if (_imageBuffer) { CVPixelBufferRelease(_imageBuffer); _imageBuffer = NULL; }
        self.reader = nil; self.trackOutput = nil; self.videoURL = nil;

        // Если в prefs пусто — пробуем дефолтные кандидаты в Documents
        if (path.length == 0) {
            for (NSString *c in VVCamDefaultCandidates()) {
                if ([[NSFileManager defaultManager] fileExistsAtPath:c]) { path = c; break; }
            }
        }

        self.mediaPath = path;
        self.enabled   = enabledPref && (path.length > 0);

        NSLog(@"[VVCAM] reload media=%@ enabled=%d proc=%@",
              path ?: @"<none>", (int)self.enabled,
              [NSProcessInfo processInfo].processName);

        if (!self.enabled) return;

        NSString *ext = path.pathExtension.lowercaseString;
        self.isVideo = ([ext isEqualToString:@"mp4"]
                        || [ext isEqualToString:@"mov"]
                        || [ext isEqualToString:@"m4v"]);

        if (self.isVideo) {
            self.videoURL = [NSURL fileURLWithPath:path];
            [self setupVideoReader];
        } else {
            UIImage *img = [UIImage imageWithContentsOfFile:path];
            _imageBuffer = VVCamBufferFromImage(img);
            if (!_imageBuffer) {
                NSLog(@"[VVCAM] failed to decode image at %@", path);
                self.enabled = NO;
            }
        }
    }
}

- (void)setupVideoReader {
    if (!self.videoURL) return;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:self.videoURL options:nil];
    AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!track) { self.enabled = NO; return; }
    NSError *err = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&err];
    if (!reader) return;
    NSDictionary *settings = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                                (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    AVAssetReaderTrackOutput *out = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:settings];
    out.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:out]) return;
    [reader addOutput:out];
    [reader startReading];
    self.reader = reader;
    self.trackOutput = out;
}

- (BOOL)hasMedia {
    return self.enabled && (self.isVideo ? (self.videoURL != nil) : (_imageBuffer != NULL));
}

- (CVPixelBufferRef)copyCurrentPixelBuffer {
    @synchronized (self) {
        if (!self.enabled) return NULL;

        if (!self.isVideo) {
            if (_imageBuffer) { CVPixelBufferRetain(_imageBuffer); return _imageBuffer; }
            return NULL;
        }

        if (!self.reader || self.reader.status != AVAssetReaderStatusReading) [self setupVideoReader];

        CMSampleBufferRef sb = self.trackOutput ? [self.trackOutput copyNextSampleBuffer] : NULL;
        if (!sb) { [self setupVideoReader]; sb = self.trackOutput ? [self.trackOutput copyNextSampleBuffer] : NULL; }
        if (!sb) return NULL;

        CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
        if (pb) CVPixelBufferRetain(pb);
        CFRelease(sb);
        return pb;
    }
}

@end
