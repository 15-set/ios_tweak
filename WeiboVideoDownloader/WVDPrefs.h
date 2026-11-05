//
//  WVDPrefs.h
//  微博视频下载器 - 偏好设置读取
//
//  说明：Tweak 运行在微博进程里，设置面板运行在“设置”App 进程里，
//  两者不是同一个沙盒，所以不能直接用 NSUserDefaults standardUserDefaults，
//  必须使用统一的 CFPreferences 域名（见下方 kWVDPrefDomain）。
//  该域名与 prefs/Resources/Root.plist 里每个 PSSwitchCell 的 "defaults" 值保持一致。
//

#import <Foundation/Foundation.h>

/// 偏好设置域名（必须与设置面板 Root.plist 中的 defaults 一致）
extern NSString * const kWVDPrefDomain;

/// 总开关，默认开启
BOOL WVDIsEnabled(void);

/// 是否显示“开始下载 / 下载成功 / 下载失败”提示弹窗，默认开启
BOOL WVDShouldShowAlerts(void);
