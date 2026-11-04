DEBUG = 0
FINALPACKAGE = 1

ARCHS = arm64 arm64e

include WeChatMomentsBuild.mk
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WeChatMoments
WeChatMoments_FILES = $(wildcard Hooks/*.xm) $(wildcard Sources/*.m) $(wildcard Sources/*.c)

# -Wno-deprecated-declarations: 仍需兼容 iOS 15 的 UIApplication.windows 等旧接口。
# -Wno-unused-parameter: 代理/回调里的占位参数。
WeChatMoments_CFLAGS = -fobjc-arc -fblocks \
	-I./Headers -I./Sources \
	-Wno-deprecated-declarations -Wno-unused-parameter

WeChatMoments_FRAMEWORKS = UIKit Foundation CoreFoundation
WeChatMoments_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
