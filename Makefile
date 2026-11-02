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

# [BUILD-FIX-G] 恢复 arm64 + arm64e 双切片 (rootless / roothide):
#   真机证据: Preferences 进程是 arm64e, dlopen_preflight 拒绝纯 arm64 的 InsulationPrefs.bundle,
#   报 "mach-o file, but is an incompatible architecture (have 'arm64', need 'arm64e')";
#   同理被注入 thermalmonitord(arm64e) 的 insulation.dylib 也只有 arm64 切片 → 实际上从未被加载。
#   结论: 目标进程架构决定可加载切片, 必须带上 arm64e 切片(独立 App 进程的 arm64 回退规则不适用)。
#
#   arm64e 必须是 iOS 14+ 的 ABI v2 (ptrauth):
#     - 只有 Apple 下游 clang(Xcode 自带)能产出 v2; 实测 Ubuntu clang-16 即便传
#       `-target arm64e-apple-ios15.0` 仍产出 v1(cpusubtype=0x00000002), 会被系统拒绝;
#       theos 源码也把非 macOS 的 IS_NEW_ABI 强制为 0 → Linux 构建路径不可行;
#     - CI 因此改用 macOS runner + Xcode iPhoneOS SDK(.github/workflows/build.yml);
#       SDK>=13 时 theos 自己会传 `-target arm64e-apple-ios15.0`, Apple clang>=12 且
#       部署目标>=14.0 才产出 v2;
#     - macOS 上 theos 自动判定 IS_NEW_ABI=1 并链接 $THEOS/lib/libroot.a(v2 stub),
#       无需手动传 IS_NEW_ABI=1; 若混入 libroot_oldabi.a 的 v1 arm64e 对象,
#       ld64 会报 "incompatible arm64e ABI compiler"。
#
#   rootful 仍只能用 arm64:
#     部署目标 12.2 < 14.0, clang>=12 不再为 iOS<14 生成 arm64e(v1), 双切片会直接链接失败;
#     iOS 12/13 的 arm64e 设备需要 Xcode 11/旧工具链单独出包。
ifneq ($(filter rootless roothide,$(THEOS_PACKAGE_SCHEME)),)
ARCHS = arm64 arm64e
else
ARCHS = arm64
endif
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
