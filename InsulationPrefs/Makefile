# InsulationPrefs (偏好面板 bundle)

TARGET := iphone:clang:latest:12.2

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = InsulationPrefs

InsulationPrefs_FILES = IPRootListController.m
InsulationPrefs_CFLAGS = -fobjc-arc
InsulationPrefs_PRIVATE_FRAMEWORKS = Preferences
InsulationPrefs_INSTALL_PATH = /Library/PreferenceBundles

# [FIX-ARCH] 子工程不会继承主 Makefile 的 ARCHS:
#   theos master/aggregate.mk 只用 `$(MAKE) -C $$d THEOS_BUILD_DIR=...` 调子工程,
#   只透传命令行变量与环境变量, 本文件的 ARCHS 不在其中;
#   而 targets/_common/iphone.mk:52 的默认值是 `ARCHS ?= arm64 arm64e`,
#   CI 的 Linux 工具链是 clang-11, 其 arm64e 是"旧 ABI", 与 iOS 14+ 的 pAC ABI 不兼容。
#   arm64e 设备上 dyld 会优先选 arm64e 切片 → 面板装载即崩。
#   显式收敛为 arm64(与主工程一致): arm64 切片可以被 arm64e 的 Settings 进程正常加载。
InsulationPrefs_ARCHS = arm64

# libroot 由 theos 在 rootless/roothide 方案下自动链接, 不手动 -lroot

include $(THEOS_MAKE_PATH)/bundle.mk
