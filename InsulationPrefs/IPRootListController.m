/*
 * IPRootListController.m — InsulationPrefs 面板控制器 (ObjC 版)
 *
 * 原实现: InsulationPrefs/RootListController.swift (Swift/Orion, PSListController 子类,
 *         直接读写 plist 文件而非 cfprefsd)。本文件按原风格以 ObjC 重建。
 *   [UPSTREAM] readPreferenceValue/setPreferenceValue 直接读写
 *              /var/mobile/Library/Preferences/com.be-huge.insulation-prefs.plist,
 *              并按 specifier 的 PostNotification 发 Darwin 通知。
 *   [NEW]      不支持充电状态/温度/阈值/回差判断: 「电池原生温控」只是一个布尔开关,
 *              面板只负责把该 key 写入 plist 并发出 Darwin 通知, 语义全部由 Tweak.x 处理。
 */
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreFoundation/CFNotificationCenter.h>
#import <dlfcn.h>   /* [NEW] 打开内嵌 ChargeLimiter.app 时动态取 LSApplicationWorkspace */

/* [BUILD-FIX] 与原 Tweak.x 同一问题: theos 的 libroot 没有 jbroot(), 真实 API 是
 * JBROOT_PATH_NSSTRING; 且静态 NSString 常量不能用函数初始化 → 改惰性函数。
 * 业务语义不变: 仍读写 /var/mobile/Library/Preferences/com.be-huge.insulation-prefs.plist */
#if __has_include(<libroot.h>)
    #import <libroot.h>
    #define INS_HAS_LIBROOT 1
#endif

#define kInsPrefsPathRel @"/var/mobile/Library/Preferences/com.be-huge.insulation-prefs.plist"
/* [FIX-CFPREFS] 面板侧统一改走 CFPreferences: 与 cfprefsd 协作, `defaults read` 立即可见,
 * 且不会再出现"直写文件 → cfprefsd 缓存仍旧 / flush 时覆盖"的经典问题。
 * 域必须与 Root.plist 的 defaults 字段、文件名完全一致。 */
static NSString *const kInsPrefsDomain = @"com.be-huge.insulation-prefs";

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

@interface IPRootListController : PSListController
@end

/* [NEW] LSApplicationWorkspace 的私有接口声明(仅用于编译期的静态类型, 不做链接:
 * 类与消息都走 ObjC 运行时动态解析)。用声明替代 performSelector: 是因为 theos 默认带
 * `-Werror,-Warc-performSelector-leaks`, performSelector: 会被判为编译错误。 */
@interface NSObject (CLAppLaunch)
+ (id)defaultWorkspace;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleIdentifier;
@end

@implementation IPRootListController

/* [UPSTREAM] 与原 Swift 版相同: 优先复用已加载的 specifiers, 否则从 Root.plist 加载
 * [FIX] 返回类型对齐 PSListController 的 NSArray*, 且 Root.plist 加载失败时兜底空数组,
 *       避免把 nil 存进 _specifiers 后由 tableView 数据源取下标 */
- (NSArray *)specifiers {
    NSArray *specifiers = [self valueForKey:@"_specifiers"];
    if (!specifiers) {
        specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self] ?: @[];
        [self setValue:specifiers forKey:@"_specifiers"];
    }
    return specifiers;
}

/* [FIX-CFPREFS] 面板读值优先走 CFPreferences(与 cfprefsd 一致), 取不到再回退直读文件
 * [FIX] key / 路径为 nil 时不再把 nil 交给 dictionaryWithContentsOfFile: / 下标 */
- (id)readPreferenceValue:(PSSpecifier *)specifier {
    id def = specifier.properties[@"default"];
    id key = specifier.properties[@"key"];
    if (!key) return def;

    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    (__bridge CFStringRef)kInsPrefsDomain);
    if (v) return (__bridge_transfer id)v;

    NSString *path = InsPrefsPath();
    NSDictionary *prefs = path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
    return prefs[key] ?: def;
}

/* [FIX-CFPREFS] 写入改走 CFPreferences + CFPreferencesAppSynchronize:
 *   1) `defaults read com.be-huge.insulation-prefs thermalPowerMode` 立即可见;
 *   2) 不再与 cfprefsd 缓存打架(直写文件会被 flush 覆盖);
 *   3) 同步落盘后再发 Darwin 通知, tweak 侧直读文件不会读到旧值。
 * 仍按 specifier 的 PostNotification 发 Darwin 通知(原版 executePuppetEvent 语义)。 */
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = specifier.properties[@"key"];
    if (!key || !value) return;

    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)kInsPrefsDomain);
    Boolean synced = CFPreferencesAppSynchronize((__bridge CFStringRef)kInsPrefsDomain);

    /* [DIAG] 回读确认, 便于一次定位"到底写没写进去" */
    CFPropertyListRef readback = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                           (__bridge CFStringRef)kInsPrefsDomain);
    NSLog(@"[InsulationPrefs] key=%@ value=%@ 已同步 (domain=%@ sync=%d readback=%@)",
          key, value, kInsPrefsDomain, (int)synced,
          readback ? (__bridge id)readback : @"(nil)");
    if (readback) CFRelease(readback);

    /* [UPSTREAM] 按 cell 声明的 PostNotification 发 Darwin 通知
     * (原面板对 thermalPowerMode 发 com.be-huge.insulation-executePuppetEvent;
     *  [NEW] 「电池原生温控」开关声明 com.be-huge.insulation-batteryProtectChanged) */
    NSString *notification = specifier.properties[@"PostNotification"];
    if (notification.length > 0) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)notification, NULL, NULL, true);
    }

    /* [NEW] 与原版一致: CPU 模式切换后请求 thermalmonitord 重启。
     * 面板(mobile)无权 kill root daemon, 只发 Darwin 通知;
     * 由 daemon 内的 tweak 观察该通知后自己 kill(getpid()), launchd 拉起。
     * 证据: 原 deb 含 com.be-huge.insulation-restartThermalMonitor 与
     *       "insulation: restarting thermalmonitord after CPU mode change"。 */
    if ([key isEqualToString:@"thermalPowerMode"]) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR("com.be-huge.insulation-restartThermalMonitor"),
                                             NULL, NULL, true);
        NSLog(@"[InsulationPrefs] 已请求重启 thermalmonitord (key=%@ value=%@)", key, value);
    }
}

#pragma mark - CPU 模式: 原版「选中即生效」交互

/* [EVIDENCE] 0.0.18 面板二进制里的字符串:
 *   tableView:didSelectRowAtIndexPath: / cpuModeMenuOverlay / cpuModeMenuItemTapped:
 *   cpuModeKey / cpuModeValues / cpuModeTitles / dismissCPUModeMenu
 *   writeToFile:atomically: / _CFNotificationCenterPostNotification
 * → 原版根本不用 detail 跳页: 它在 didSelectRowAtIndexPath: 里弹出自己的选项菜单,
 *   选中后由面板自己写 plist 并立刻发 com.be-huge.insulation-executePuppetEvent,
 *   dylib 收到后马上重读并应用 thermalPowerMode(因此无需 respring)。
 *
 * 我们此前补 detail=PSListItemsController 造成两个偏差:
 *   1) 交互变成"跳页"(原版是就地弹菜单);
 *   2) 写值由系统 PSListItemsController 走 CFPreferences 域, 不经过本类的
 *      setPreferenceValue:(自写 plist + 按 PostNotification 发通知),
 *      于是 tweak 收不到通知 / 读到的还是旧值 → "选了模拟低电频率但不生效"。
 * 这里恢复原版机制: 点行 → 弹菜单 → 本类写 plist + 发通知 + 刷新 cell 显示。
 * 其余 cell(开关/分组)不在本方法处理, 交回 super。 */

- (PSSpecifier *)ins_specifierForKey:(NSString *)key {
    for (PSSpecifier *s in [self specifiers]) {
        if ([s.properties[@"key"] isEqualToString:key]) return s;
    }
    return nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    PSSpecifier *spec = [self ins_specifierForKey:@"thermalPowerMode"];
    id label = spec.properties[@"label"];

    /* [FIX-A2] 不能只靠 cell 文本比较(文本可能尚未布局为 nil / 带空格):
     * 优先取 cell 自身的 specifier(PSTableCell.specifier) 比对 key, 取不到再退回文本比较。
     * 只有「CPU 模式」这一行走自定义菜单, 其余保持系统默认行为。 */
    BOOL isCPURow = NO;
    if (spec) {
        id cellSpec = nil;
        @try { cellSpec = [cell valueForKey:@"specifier"]; } @catch (NSException *e) { cellSpec = nil; }
        if ([cellSpec isKindOfClass:[PSSpecifier class]]) {
            id cellKey = ((PSSpecifier *)cellSpec).properties[@"key"];
            isCPURow = [cellKey isEqualToString:@"thermalPowerMode"];
        }
        if (!isCPURow) isCPURow = [cell.textLabel.text isEqualToString:label];
    }
    if (!isCPURow) {
        [super tableView:tableView didSelectRowAtIndexPath:indexPath];
        return;
    }

    [tableView deselectRowAtIndexPath:indexPath animated:NO];

    NSArray *values = spec.properties[@"validValues"];
    NSArray *titles = spec.properties[@"validTitles"];
    if (values.count == 0) return;

    UIAlertController *menu = [UIAlertController alertControllerWithTitle:label
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSUInteger i = 0; i < values.count; i++) {
        id value = values[i];
        NSString *title = (i < titles.count) ? titles[i] : [value description];
        [menu addAction:[UIAlertAction actionWithTitle:title
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *action) {
            /* 走本类覆写: 直接写 plist 文件 + 按 specifier 的 PostNotification 发通知 */
            [self setPreferenceValue:value specifier:spec];
            [self reloadSpecifier:spec animated:YES];
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    if (menu.popoverPresentationController) {   /* iPad 上 action sheet 需要锚点, 否则崩溃 */
        menu.popoverPresentationController.sourceView = cell;
        menu.popoverPresentationController.sourceRect = cell.bounds;
    }
    [self presentViewController:menu animated:YES completion:nil];
}

#pragma mark - [NEW] ChargeLimiter 功能页入口

/* [NEW] Root.plist 里的 PSButtonCell(action=openChargeLimiter:) → 打开随 deb 内嵌的
 *       ChargeLimiter.app (bundle id: com.chargelimiter.mod, URL scheme: cl://)。
 *       走 LSApplicationWorkspace 而不是 openURL:
 *         Settings.app 的 Info.plist 没有登记 cl 到 LSApplicationQueriesSchemes,
 *         canOpenURL 会返回 NO, 但 openApplicationWithBundleID 不受该白名单限制。
 *       不修改 ChargeLimiter 自身任何逻辑, 只是"启动它"。 */
- (void)openChargeLimiter:(PSSpecifier *)specifier {
    NSString *bundleID = @"com.chargelimiter.mod";
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (!workspaceClass) {
        dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
        workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    }

    id workspace = [workspaceClass defaultWorkspace];
    if (workspace && [workspace respondsToSelector:@selector(openApplicationWithBundleID:)]) {
        [workspace openApplicationWithBundleID:bundleID];
        NSLog(@"[InsulationPrefs] 已请求打开 ChargeLimiter (%@)", bundleID);
        return;
    }

    /* 兜底: 走 URL scheme (个别机型上 LSApplicationWorkspace 未注册时) */
    NSURL *url = [NSURL URLWithString:@"cl://"];
    if (url) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        NSLog(@"[InsulationPrefs] 回退 cl:// 打开 ChargeLimiter");
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"未找到 ChargeLimiter"
                                                                  message:@"请确认 deb 安装完整（应包含 /Applications/ChargeLimiter.app），然后 respring 重试。"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
