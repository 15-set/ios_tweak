//
//  WVDListController.m
//  设置面板：只负责把 Resources/Root.plist 里的开关渲染出来。
//
//  开关的读写由 PSSwitchCell 通过 "defaults" 字段（com.wvd.weibovideo）
//  交给 CFPreferences，和 Tweak 里的 WVDPrefs.m 使用同一个域名，无需额外同步。
//

#import <Preferences/PSListController.h>

@interface WVDListController : PSListController
@end

@implementation WVDListController

/// 懒加载设置项；修改界面后重启“设置”App / respring 生效
- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

@end
