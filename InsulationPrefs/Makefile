# InsulationPrefs (偏好面板 bundle)

TARGET := iphone:clang:latest:12.2

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = InsulationPrefs

InsulationPrefs_FILES = IPRootListController.m
InsulationPrefs_CFLAGS = -fobjc-arc
InsulationPrefs_PRIVATE_FRAMEWORKS = Preferences
InsulationPrefs_INSTALL_PATH = /Library/PreferenceBundles

# libroot 由 theos 在 rootless/roothide 方案下自动链接, 不手动 -lroot

include $(THEOS_MAKE_PATH)/bundle.mk
