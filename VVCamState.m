#import "VVCamState.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>

static NSString * const kPrefsPath = @"/var/jb/var/mobile/Library/Preferences/com.vvcam.plist";
static NSString * const kNotify    = @"com.vvcam/settingschanged";
static NSString * const kDefVideo  = @"/var/jb/var/mobile/Documents/vvcam.mp4";
static NSString * const kDefImage  = @"/var/jb/var/mobile/Documents/vvcam.jpg";

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
    notify_register_dispatch(kNotify.UTF8String, &token, dispatch_get_main_queue(), ^(int t){
        [self reload];
    });
}

- (void)dealloc {
    if (_imageBuffer) CVPixelBufferRelease(_imageBuffer);
}

- (void)reload {
    @synchronized (self) {
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
        NSString *path = prefs[@"MediaPath"];
        BOOL enabledPref = prefs[@"Enabled"] ? [prefs[@"Enabled"] boolValue] : YES;

        if (path.length == 0) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:kDefVideo]) path = kDefVideo;
            else if ([[NSFileManager defaultManager] fileExistsAtPath:kDefImage]) path = kDefImage;
        }

        self.mediaPath = path;
        self.enabled = enabledPref && (path.length > 0);

        // reset old state
        if (_imageBuffer) { CVPixelBufferRelease(_imageBuffer); _imageBuffer = NULL; }
        self.reader = nil; self.trackOutput = nil; self.videoURL = nil;

        if (path.length == 0) { self.enabled = NO; return; }

        NSString *ext = path.pathExtension.lowercaseString;
        self.isVideo = ([ext isEqualToString:@"mp4"] || [ext isEqualToString:@"mov"] || [ext isEqualToString:@"m4v"]);

        if (self.isVideo) {
            self.videoURL = [NSURL fileURLWithPath:path];
            [self setupVideoReader];
        } else {
            UIImage *img = [UIImage imageWithContentsOfFile:path];
            _imageBuffer = VVCamBufferFromImage(img);
            if (!_imageBuffer) self.enabled = NO;
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
