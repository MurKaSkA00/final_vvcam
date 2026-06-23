make
TARGET := iphone:clang:latest:14.0
ARCHS := arm64
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

# Path to PrivateFrameworks from any iPhoneOS SDK installed in $THEOS/sdks/
PRIVATE_FRAMEWORKS_PATH := $(firstword $(wildcard $(THEOS)/sdks/iPhoneOS*.sdk))/System/Library/PrivateFrameworks

BUNDLE_NAME = MediaPlaybackUtilsPrefs

MediaPlaybackUtilsPrefs_FILES = MPURootListController.m
MediaPlaybackUtilsPrefs_INSTALL_PATH = /Library/PreferenceBundles
MediaPlaybackUtilsPrefs_FRAMEWORKS = UIKit
MediaPlaybackUtilsPrefs_PRIVATE_FRAMEWORKS = Preferences
MediaPlaybackUtilsPrefs_CFLAGS = -fobjc-arc
MediaPlaybackUtilsPrefs_LDFLAGS = -F$(PRIVATE_FRAMEWORKS_PATH)

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/MediaPlaybackUtils.plist$(ECHO_END)
