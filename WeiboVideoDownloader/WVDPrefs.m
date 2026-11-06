//
//  WVDPrefs.m
//  微博视频下载器 - 偏好设置读取
//
//  注意：
//   * 这段代码会被高频调用（网络任务、播放器每次布局），所以加了一个 1 秒的进程内缓存，
//     避免每次都去问 cfprefsd；设置面板改动后最多 1 秒生效。
//   * 两个进程（微博 Tweak / 设置面板）共用同一个 CFPreferences 域名。
//

#import "WVDPrefs.h"
#import <CoreFoundation/CFPreferences.h>

NSString * const kWVDPrefDomain = @"com.wvd.weibovideo";

/// 缓存有效期（秒）
static const CFAbsoluteTime kWVDPrefCacheInterval = 1.0;

/// 读取指定 key；不存在时返回 nil（由调用方给出默认值）
static id WVDCopyPreference(NSString *key) {
    return (__bridge_transfer id)CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                          (__bridge CFStringRef)kWVDPrefDomain);
}

/// 带缓存的布尔读取
static BOOL WVDCopyBoolPreference(NSString *key, BOOL defaultValue) {
    static NSMutableDictionary<NSString *, NSNumber *> *valueCache = nil;
    static NSMutableDictionary<NSString *, NSNumber *> *timeCache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        valueCache = [NSMutableDictionary dictionary];
        timeCache = [NSMutableDictionary dictionary];
    });

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

    // 网络回调可能在后台线程调用这里，做一次同步避免字典并发读写
    @synchronized (valueCache) {
        NSNumber *lastTime = timeCache[key];
        NSNumber *cachedValue = valueCache[key];

        if (cachedValue == nil || lastTime == nil || now - lastTime.doubleValue > kWVDPrefCacheInterval) {
            id value = WVDCopyPreference(key);
            cachedValue = @(value == nil ? defaultValue : [value boolValue]);
            valueCache[key] = cachedValue;
            timeCache[key] = @(now);
        }

        return cachedValue.boolValue;
    }
}

BOOL WVDIsEnabled(void) {
    return WVDCopyBoolPreference(@"enabled", YES);
}

BOOL WVDShouldShowAlerts(void) {
    return WVDCopyBoolPreference(@"showAlerts", YES);
}
