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

@interface IPRootListController : PSListController
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

/* [UPSTREAM] 直接读 plist 文件, 缺省回退 specifier 的 default
 * [FIX] key / 路径为 nil 时不再把 nil 交给 dictionaryWithContentsOfFile: / 下标 */
- (id)readPreferenceValue:(PSSpecifier *)specifier {
    id def = specifier.properties[@"default"];
    id key = specifier.properties[@"key"];
    NSString *path = InsPrefsPath();
    if (!key || !path) return def;
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:path];
    return prefs[key] ?: def;
}

/* [UPSTREAM + NEW] 直接写 plist 文件, 然后按 specifier 的 PostNotification 发 Darwin 通知 */
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = specifier.properties[@"key"];
    NSString *path = InsPrefsPath();
    /* [FIX] 原实现会把 nil key 交给 prefs[key] = ... (KVC/字典 nil key 抛异常),
     *       nil 路径交给 writeToFile: → 直接放弃本次写入, 不影响面板其余交互 */
    if (!key || !path) return;

    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:path] ?: [NSMutableDictionary new];

    prefs[key] = value;
    [prefs writeToFile:path atomically:YES];

    /* [UPSTREAM] 按 cell 声明的 PostNotification 发 Darwin 通知
     * (原面板对 thermalPowerMode 发 com.be-huge.insulation-executePuppetEvent;
     *  [NEW] 「电池原生温控」开关声明 com.be-huge.insulation-batteryProtectChanged) */
    NSString *notification = specifier.properties[@"PostNotification"];
    if (notification.length > 0) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)notification, NULL, NULL, true);
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
    PSSpecifier *spec = [self ins_specifierForKey:@"thermalPowerMode"];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    id label = spec.properties[@"label"];

    /* 只有「CPU 模式」这一行走自定义菜单, 其余保持系统默认行为 */
    if (!spec || ![cell.textLabel.text isEqualToString:label]) {
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

@end
