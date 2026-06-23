TARGET := iphone:clang:latest:14.0
ARCHS := arm64
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MediaPlaybackUtils

MediaPlaybackUtils_FILES = Tweak.x AntifraudHooks.x BrowserHooks.x JailbreakBypass.x StealthHooks.x WebRTCHooks.x FrameProcessor.m MediaBufferAdapter.m
MediaPlaybackUtils_CFLAGS = -fobjc-arc
MediaPlaybackUtils_FRAMEWORKS = UIKit AVFoundation CoreMedia CoreVideo CoreImage QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall -9 Preferences || true"
