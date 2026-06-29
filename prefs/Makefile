TARGET := iphone:clang:latest:14.0
ARCHS := arm64
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = MediaPlaybackUtils

MediaPlaybackUtils_FILES = MPURootListController.m
MediaPlaybackUtils_FRAMEWORKS = UIKit Foundation
MediaPlaybackUtils_INSTALL_PATH = /Library/PreferenceBundles
MediaPlaybackUtils_CFLAGS = -fobjc-arc
MediaPlaybackUtils_LDFLAGS += -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk

# NOTE: PreferenceLoader entry plist installation is handled by the top-level
# `layout/Library/PreferenceLoader/Preferences/MediaPlaybackUtils.plist`.
# We previously copied `prefs/entry.plist` here too, which (a) referenced a
# non-existent icon and (b) overwrote the clean layout/ version because
# subproject stages run after the main stage. The result: on palera1n the
# Settings entry silently disappeared. Do NOT re-add this rule.
