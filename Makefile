export THEOS_PACKAGE_SCHEME = rootless

ARCHS = arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = vvcam

vvcam_FILES = Tweak.x VVCamState.m VVCamEngine.m
vvcam_CFLAGS = -fobjc-arc
vvcam_FRAMEWORKS = AVFoundation CoreMedia CoreVideo CoreImage UIKit QuartzCore ImageIO MobileCoreServices

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard" || true
