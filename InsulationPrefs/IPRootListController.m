/*
 * IPRootListController.m — InsulationPrefs 面板控制器 (ObjC 版)
 *
 * 原实现: InsulationPrefs/RootListController.swift (Swift/Orion, PSListController 子类,
 *         直接读写 plist 文件而非 cfprefsd)。本文件按原风格以 ObjC 重建。
 *   [UPSTREAM] readPreferenceValue/setPreferenceValue 直接读写
 *              /var/mobile/Library/Preferences/com.be-huge.insulation-prefs.plist,
 *              并按 specifier 的 PostNotification 发 Darwin 通知。
 *   [NEW]      chargingBatteryTempThreshold 输入校验: 非整数/越界 → 纠正到 [35,50] (默认 45),
 *              写回纠正后的值并刷新 cell 显示。
 */
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <CoreFoundation/CFNotificationCenter.h>

/* [BUILD-FIX] 与原 Tweak.x 同一问题: theos 的 libroot 没有 jbroot(), 真实 API 是
 * JBROOT_PATH_NSSTRING; 且静态 NSString 常量不能用函数初始化 → 改惰性函数。
 * 业务语义不变: 仍读写 /var/mobile/Library/Preferences/com.be-huge.insulation-prefs.plist */
#if __has_include(<libroot.h>)
    #import <libroot.h>
    #define INS_HAS_LIBROOT 1
#endif

#define kInsPrefsPathRel @"/var/mobile/Library/Preferences/com.be-huge.insulation-prefs.plist"

static NSString *InsPrefsPath(void) {
    static NSString *path = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
#ifdef INS_HAS_LIBROOT
        path = JBROOT_PATH_NSSTRING(kInsPrefsPathRel);
#else
        path = kInsPrefsPathRel;
#endif
    });
    return path;
}

/* [NEW] 阈值约束, 与 Tweak.x 保持一致 */
#define kInsThresholdMin 35
#define kInsThresholdMax 50
#define kInsThresholdDefault 45
#define kPrefChargingBatteryTempThreshold @"chargingBatteryTempThreshold"

@interface IPRootListController : PSListController
@end

@implementation IPRootListController

/* [UPSTREAM] 与原 Swift 版相同: 优先复用已加载的 specifiers, 否则从 Root.plist 加载 */
- (NSMutableArray *)specifiers {
    NSMutableArray *specifiers = [self valueForKey:@"_specifiers"];
    if (!specifiers) {
        specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        [self setValue:specifiers forKey:@"_specifiers"];
    }
    return specifiers;
}

/* [UPSTREAM] 直接读 plist 文件, 缺省回退 specifier 的 default */
- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:InsPrefsPath()];
    id key = specifier.properties[@"key"];
    id def = specifier.properties[@"default"];
    return prefs[key] ?: def;
}

/* [UPSTREAM + NEW] 直接写 plist 文件, 然后按 specifier 的 PostNotification 发 Darwin 通知 */
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:InsPrefsPath()] ?: [NSMutableDictionary new];
    NSString *key = specifier.properties[@"key"];

    id finalValue = value;
    BOOL corrected = NO;

    /* [NEW] 「充电电池控温阈值」输入校验: 只接受 35~50 的整数, 越界/非法 → 纠正 */
    if ([key isEqualToString:kPrefChargingBatteryTempThreshold]) {
        NSString *raw = [[value description] stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSScanner *scanner = [NSScanner scannerWithString:raw];
        NSInteger parsed = 0;
        BOOL validInt = raw.length > 0 && [scanner scanInteger:&parsed] && scanner.atEnd;
        if (!validInt) {
            parsed = kInsThresholdDefault;   /* 非整数输入 → 拒绝, 回落默认值 */
            corrected = YES;
        }
        if (parsed < kInsThresholdMin) { parsed = kInsThresholdMin; corrected = YES; }  /* 越界 → clamp */
        if (parsed > kInsThresholdMax) { parsed = kInsThresholdMax; corrected = YES; }
        finalValue = @(parsed);
    }

    prefs[key] = finalValue;
    [prefs writeToFile:kInsPrefsPath atomically:YES];

    /* [NEW] 输入被纠正时刷新 cell, 让界面上立即显示纠正后的值 */
    if (corrected) {
        [self reloadSpecifier:specifier animated:YES];
    }

    /* [UPSTREAM] 按 cell 声明的 PostNotification 发 Darwin 通知
     * (原面板对 thermalPowerMode 发 com.be-huge.insulation-executePuppetEvent;
     *  [NEW] 新 cell 声明 com.be-huge.insulation-batteryProtectChanged) */
    NSString *notification = specifier.properties[@"PostNotification"];
    if (notification.length > 0) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)notification, NULL, NULL, true);
    }
}

@end
