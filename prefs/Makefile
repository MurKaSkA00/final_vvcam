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
