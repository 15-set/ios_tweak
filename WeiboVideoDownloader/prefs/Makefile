# ============================================================
#  设置面板 Bundle（PreferenceLoader）
#  安装到 /var/jb/Library/PreferenceBundles（rootless 由 Theos 前缀 /var/jb）
# ============================================================

export THEOS_PACKAGE_SCHEME = rootless

# 子工程按 rootless 固定：iOS 15.0 起、arm64 + arm64e 双切片
# （Preferences 进程是 arm64e，纯 arm64 的 bundle 会被系统拒绝加载）
export TARGET = iphone:clang:latest:15.0

BUNDLE_NAME = WeiboVideoDownloaderPrefs

WeiboVideoDownloaderPrefs_FILES = WVDListController.m

# 明确指定 bundle 的 Info.plist（NSPrincipalClass = WVDListController）
WeiboVideoDownloaderPrefs_INFOPLIST_FILE = Resources/Info.plist

WeiboVideoDownloaderPrefs_FRAMEWORKS = UIKit Foundation

# Preferences.framework 是私有框架（PSListController 所在）。
# 注意：Xcode 的 iPhoneOS SDK 里有它的头文件，但**没有 Preferences.tbd**，
# 直接写 _PRIVATE_FRAMEWORKS = Preferences 会报
#   ld: framework 'Preferences' not found
# 这里只用到 ObjC 类和消息（PSListController / PSSpecifier），没有 C 函数或全局变量，
# 因此改成动态解析：未定义符号在 dlopen 时由 Preferences 进程自己解析。
# （变量名必须是 <实例>_LDFLAGS）
WeiboVideoDownloaderPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup

WeiboVideoDownloaderPrefs_ARCHS = arm64 arm64e
WeiboVideoDownloaderPrefs_CFLAGS = -fobjc-arc

WeiboVideoDownloaderPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/bundle.mk
