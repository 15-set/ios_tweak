# InsulationPrefs (偏好面板 bundle)

# 子工程不会继承主 Makefile 的 TARGET / ARCHS:
#   theos 的 master/aggregate.mk 只执行 `$(MAKE) -C $$d THEOS_BUILD_DIR=...`,
#   主 Makefile 里的 TARGET / ARCHS 不下传, 因此这里必须按 scheme 自己重算。
#
# [BUILD-FIX-G] 与主工程一致: rootless/roothide 用 15.0 部署目标 + arm64/arm64e 双切片。
#   真机 dlopen 证据: Preferences 是 arm64e 进程, 纯 arm64 的 bundle 会被拒绝
#   ("have 'arm64', need 'arm64e'"); arm64e 只能是 ABI v2, 因此必须配 clang-16(CI 已替换)。
#   rootful 部署 12.2<14.0, clang>=12 产不出 arm64e(v1), 只能保持 arm64 单切片。
ifeq ($(filter rootless roothide,$(THEOS_PACKAGE_SCHEME)),)
TARGET := iphone:clang:latest:12.2
InsulationPrefs_ARCHS = arm64
else
TARGET := iphone:clang:latest:15.0
InsulationPrefs_ARCHS = arm64 arm64e
endif

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = InsulationPrefs

InsulationPrefs_FILES = IPRootListController.m
InsulationPrefs_CFLAGS = -fobjc-arc
InsulationPrefs_PRIVATE_FRAMEWORKS = Preferences
InsulationPrefs_INSTALL_PATH = /Library/PreferenceBundles

# libroot 由 theos 在 rootless/roothide 方案下自动链接, 不手动 -lroot

include $(THEOS_MAKE_PATH)/bundle.mk
