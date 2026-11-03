DEBUG = 0
FINALPACKAGE = 1

ARCHS = arm64 arm64e

# Share the SDK and deployment targets with the PreferenceBundle.
include AxsWeChatMomentsBuild.mk
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AxsWeChatMoments
AxsWeChatMoments_FILES = $(wildcard Hooks/*.xm Sources/*.m)
AxsWeChatMoments_CFLAGS = -fobjc-arc -I./Headers -I./Sources
AxsWeChatMoments_FRAMEWORKS = UIKit Foundation CoreFoundation
AxsWeChatMoments_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk


