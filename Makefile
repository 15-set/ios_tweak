# Insulation (Logos 重建版) — theos Makefile
#
# 构建:
#   rootless (palera1n/Dopamine, iOS 15+):  THEOS_PACKAGE_SCHEME=rootless make package
#   roothide:                              THEOS_PACKAGE_SCHEME=roothide make package
#   rootful  (iOS 12.2~14):                make package
#
# SDK/系统版本:
#   - 编译 SDK: theos 最新 iOS SDK (iphone:clang:latest)
#   - 部署目标: rootful 12.2+ (沿用原包 firmware >= 12.2); rootless/roothide 15.0+ (与原 Makefile 一致)

INSTALL_TARGET_PROCESSES = thermalmonitord

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
TARGET = iphone:clang:latest:15.0
else ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
TARGET = iphone:clang:latest:15.0
else
TARGET = iphone:clang:latest:12.2
endif

# [BUILD-FIX-E] arm64e 切片收敛为 arm64:
#   CI 用 install-theos 自带的 Linux 工具链 ($THEOS/toolchain/linux/iphone/bin/clang, 实为 clang-11),
#   其 arm64e 代码生成是旧 ABI, 与 iOS 14+ 的 pAC ABI 不兼容, 链接期报
#   "object file ... was built with an incompatible arm64e ABI compiler", 且真机有崩溃风险。
#   A12+ 设备的 dyld 允许 arm64 slice 回退加载 (历史上 arm64-only 插件在 arm64e 设备上均可运行),
#   功能不受影响, 仅失去 pointer-auth 优化。需要双切片时可用
#   `make ARCHS="arm64 arm64e"` (命令行覆盖本文件, 但必须使用新工具链: theos docker 镜像 / macOS)。
ARCHS = arm64
DEBUG = 0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = insulation

$(TWEAK_NAME)_FILES = Tweak.x
$(TWEAK_NAME)_CFLAGS = -fobjc-arc
$(TWEAK_NAME)_FRAMEWORKS = Foundation CoreFoundation SystemConfiguration
$(TWEAK_NAME)_PRIVATE_FRAMEWORKS = IOKit

# rootless/roothide 下 libroot 由 theos 自动链接 (上游 Makefile 未显式 -lroot 亦可成功,
# 见原 deb 的 @rpath/libroot.dylib)。此处不手动加 LIBRARIES += root, 避免 -lroot 找不到。

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += InsulationPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk
