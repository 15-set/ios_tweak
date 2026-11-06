# ============================================================
#  微博视频下载器 (WeiboVideoDownloader)
#  Theos + Logos · arm64e · iOS 15.3.1 · Dopamine rootless
# ============================================================

# 目标平台：最低 iOS 15.0（当前设备 15.3.1）
export TARGET = iphone:clang:latest:15.0

# arm64 用于微博 App 本体（App Store 版本），arm64e 用于兼容 A12+ 设备上的 arm64e 进程
export ARCHS = arm64 arm64e

# rootless（无根）打包模式：Theos 会自动把所有安装路径前缀成 /var/jb
export THEOS_PACKAGE_SCHEME = rootless

# 安装完成后自动杀掉微博，便于重新注入（需要配置 THEOS_DEVICE_IP 才生效）
INSTALL_TARGET_PROCESSES = Weibo

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WeiboVideoDownloader

# 主 Tweak（Logos 文件）+ 纯 Objective-C 模块
WeiboVideoDownloader_FILES = Tweak.x \
                             WVDVideoURLStore.m \
                             WVDDownloader.m \
                             WVDActivity.m \
                             WVDPrefs.m

# 用到的系统框架
WeiboVideoDownloader_FRAMEWORKS = UIKit Foundation AVFoundation Photos

# 统一使用 ARC
WeiboVideoDownloader_CFLAGS = -fobjc-arc

# ------------------------------------------------------------
# 安装路径说明：
#   Dopamine 使用的 ElleKit 只会扫描
#     /var/jb/Library/MobileSubstrate/DynamicLibraries/
#   下的 <Tweak>.dylib + <Tweak>.plist，所以这里使用这个标准路径。
#   （rootless 模式下由 Theos 自动补上 /var/jb 前缀）
#
#   如果你确实希望文件出现在 /var/jb/Library/Tweaks/，
#   可以把下一行改成：
#     WeiboVideoDownloader_INSTALL_PATH = /Library/Tweaks
#   但必须自己在 DynamicLibraries 目录里补软链接，否则不会被注入。
# ------------------------------------------------------------
WeiboVideoDownloader_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

# 设置面板（PreferenceLoader Bundle）作为子工程参与编译
SUBPROJECTS += prefs

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall -9 Weibo"
