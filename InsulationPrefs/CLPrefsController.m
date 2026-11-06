/*
 * CLPrefsController.m — 「内置 ChargeLimiter 功能」页
 *
 * 不再安装/打开桌面上的 ChargeLimiter.app：充电控制完全在插件内完成。
 * 随 deb 安装的 ChargeLimiterDaemon 由 launchd 常驻，监听 127.0.0.1:1230。
 * 协议与 daemon 源码一致（ChargeLimiter/daemon.mm 的 handleReq + CLSimpleHTTPServer.m）：
 *   POST /  body: {"api": "...", ...}
 *   set_conf {key,val} / get_conf / get_bat_info / set_charge_status {flag}
 *   apply_now / reset_conf
 * 所有请求返回 {"status": 0, "data": {...}}，status == 0 表示成功。
 */

#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <errno.h>

#define kCLAPIPort 1230

/* 后台未返回数据时用于展示的默认值（与 daemon initConf 一致） */
#define kCLDefaultAbove 80
#define kCLDefaultBelow 20
#define kCLDefaultTempAbove 40
#define kCLDefaultTempBelow 35

#pragma mark - 本地 HTTP 客户端（daemon 只监听 127.0.0.1）

static NSDictionary *CLAPISend(NSDictionary *req, NSString **errorText) {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        if (errorText) *errorText = @"无法创建 socket";
        return nil;
    }

    struct timeval tv = { .tv_sec = 3, .tv_usec = 0 };
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kCLAPIPort);
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");

    if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        if (errorText) *errorText = @"后台服务未运行";
        close(sock);
        return nil;
    }

    NSData *body = [NSJSONSerialization dataWithJSONObject:req options:0 error:nil];
    NSString *head = [NSString stringWithFormat:
        @"POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
        (unsigned long)body.length];
    NSMutableData *packet = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [packet appendData:body];

    const uint8_t *bytes = packet.bytes;
    NSUInteger total = packet.length, sent = 0;
    while (sent < total) {
        ssize_t n = send(sock, bytes + sent, total - sent, 0);
        if (n <= 0) break;
        sent += (NSUInteger)n;
    }

    NSMutableData *resp = [NSMutableData data];
    uint8_t buf[4096];
    while (YES) {
        ssize_t n = recv(sock, buf, sizeof(buf), 0);
        if (n <= 0) break;
        [resp appendBytes:buf length:(NSUInteger)n];
    }
    close(sock);

    if (resp.length == 0) {
        if (errorText) *errorText = @"后台无响应";
        return nil;
    }

    NSString *text = [[NSString alloc] initWithData:resp encoding:NSUTF8StringEncoding];
    NSRange sep = [text rangeOfString:@"\r\n\r\n"];
    if (sep.location == NSNotFound) {
        if (errorText) *errorText = @"响应格式错误";
        return nil;
    }
    NSString *json = [text substringFromIndex:NSMaxRange(sep)];
    NSData *jsonData = [json dataUsingEncoding:NSUTF8StringEncoding];
    id obj = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) {
        if (errorText) *errorText = @"响应解析失败";
        return nil;
    }
    return obj;
}

#pragma mark - 控制器

@interface CLPrefsController : PSListController
@property (nonatomic, strong) NSMutableDictionary *conf;
@property (nonatomic, strong) NSDictionary *bat;
@property (nonatomic, weak) PSSpecifier *statusGroup;
@property (nonatomic, weak) PSSpecifier *toggleButton;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, strong) NSString *lastError;
@end

@implementation CLPrefsController

- (void)dealloc {
    [_pollTimer invalidate];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"充电限制";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!self.pollTimer) {
        self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                           target:self
                                                         selector:@selector(onPollTimer:)
                                                         userInfo:nil
                                                          repeats:YES];
    }
    [self refreshState];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.pollTimer invalidate];
    self.pollTimer = nil;
}

- (void)onPollTimer:(NSTimer *)timer {
    [self refreshState];
}

#pragma mark - 描述符

- (id)specifiers {
    NSArray *existing = [self valueForKey:@"_specifiers"];
    if (existing.count > 0) return existing;

    NSMutableArray *arr = [NSMutableArray array];

    PSSpecifier *status = [PSSpecifier groupSpecifierWithName:@"实时电池状态"];
    [status setProperty:@"正在读取…" forKey:@"footerText"];
    [arr addObject:status];
    self.statusGroup = status;

    PSSpecifier *limitGroup = [PSSpecifier groupSpecifierWithName:@"充电限制"];
    [limitGroup setProperty:@"达到充电上限后自动停止充电；电量低于回充下限后自动恢复。设置立即写入后台服务。"
                   forKey:@"footerText"];
    [arr addObject:limitGroup];

    [arr addObject:[self linkListCellWithLabel:@"充电上限"
                                           key:@"cl_charge_above"
                                        values:[self valuesFrom:50 to:100 step:5]
                                        suffix:@"%%"]];
    [arr addObject:[self linkListCellWithLabel:@"回充下限"
                                           key:@"cl_charge_below"
                                        values:[self valuesFrom:20 to:80 step:5]
                                        suffix:@"%%"]];

    PSSpecifier *toggle = [self buttonCellWithLabel:@"暂停充电" action:@selector(toggleCharge:)];
    [arr addObject:toggle];
    self.toggleButton = toggle;

    PSSpecifier *tempGroup = [PSSpecifier groupSpecifierWithName:@"温度保护"];
    [tempGroup setProperty:@"电池温度高于上限时自动停充，降到下限以下后恢复充电。阈值单位为 °C。"
                   forKey:@"footerText"];
    [arr addObject:tempGroup];

    PSSpecifier *tempSwitch = [PSSpecifier preferenceSpecifierNamed:@"启用温度保护"
                                                             target:self
                                                                set:@selector(setPreferenceValue:specifier:)
                                                                get:@selector(readPreferenceValue:)
                                                             detail:nil
                                                               cell:PSSwitchCell
                                                               edit:nil];
    [tempSwitch setProperty:@"cl_enable_temp" forKey:@"key"];
    [tempSwitch setProperty:@NO forKey:@"default"];
    [arr addObject:tempSwitch];

    [arr addObject:[self linkListCellWithLabel:@"温度上限"
                                           key:@"cl_temp_above"
                                        values:[self valuesFrom:35 to:55 step:1]
                                        suffix:@" °C"]];
    [arr addObject:[self linkListCellWithLabel:@"温度下限"
                                           key:@"cl_temp_below"
                                        values:[self valuesFrom:25 to:45 step:1]
                                        suffix:@" °C"]];

    PSSpecifier *actions = [PSSpecifier groupSpecifierWithName:@"其他"];
    [actions setProperty:@"内置 ChargeLimiter 功能：全部设置都在本插件内生效，不会打开桌面 app。"
                   forKey:@"footerText"];
    [arr addObject:actions];

    [arr addObject:[self buttonCellWithLabel:@"立即应用配置" action:@selector(applyNow:)]];
    [arr addObject:[self buttonCellWithLabel:@"恢复默认设置 (80% / 温度保护关闭)" action:@selector(resetDefaults:)]];

    [self setValue:arr forKey:@"_specifiers"];
    return arr;
}

- (NSArray *)valuesFrom:(NSInteger)from to:(NSInteger)to step:(NSInteger)step {
    NSMutableArray *vals = [NSMutableArray array];
    for (NSInteger v = from; v <= to; v += step) [vals addObject:@(v)];
    return vals;
}

- (PSSpecifier *)linkListCellWithLabel:(NSString *)label
                                   key:(NSString *)key
                                values:(NSArray *)values
                                suffix:(NSString *)suffix {
    NSMutableArray *titles = [NSMutableArray array];
    for (NSNumber *v in values) [titles addObject:[NSString stringWithFormat:@"%@%@", v, suffix]];

    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:label
                                                    target:self
                                                       set:nil
                                                       get:@selector(readPreferenceValue:)
                                                    detail:nil
                                                      cell:PSLinkListCell
                                                      edit:nil];
    [s setProperty:key forKey:@"key"];
    [s setProperty:values forKey:@"validValues"];
    [s setProperty:titles forKey:@"validTitles"];
    return s;
}

- (PSSpecifier *)buttonCellWithLabel:(NSString *)label action:(SEL)action {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:label
                                                    target:self
                                                       set:nil
                                                       get:nil
                                                    detail:nil
                                                      cell:PSButtonCell
                                                      edit:nil];
    [s setButtonAction:action];
    return s;
}

#pragma mark - 读写配置

- (NSInteger)intForKey:(NSString *)key fallback:(NSInteger)fallback {
    id v = self.conf[key];
    if ([v respondsToSelector:@selector(intValue)]) return [v intValue];
    return fallback;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = specifier.properties[@"key"];
    if ([key isEqualToString:@"cl_enable_temp"]) {
        return @([self.conf[@"enable_temp"] boolValue]);
    }
    if ([key isEqualToString:@"cl_charge_above"]) {
        return @([self intForKey:@"charge_above" fallback:kCLDefaultAbove]);
    }
    if ([key isEqualToString:@"cl_charge_below"]) {
        return @([self intForKey:@"charge_below" fallback:kCLDefaultBelow]);
    }
    if ([key isEqualToString:@"cl_temp_above"]) {
        return @([self intForKey:@"charge_temp_above" fallback:kCLDefaultTempAbove]);
    }
    if ([key isEqualToString:@"cl_temp_below"]) {
        return @([self intForKey:@"charge_temp_below" fallback:kCLDefaultTempBelow]);
    }
    return specifier.properties[@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = specifier.properties[@"key"];
    if ([key isEqualToString:@"cl_enable_temp"]) {
        [self setConfKey:@"enable_temp" value:@([value boolValue])];
    }
}

- (void)setConfKey:(NSString *)key value:(id)value {
    NSDictionary *req = @{ @"api": @"set_conf", @"key": key, @"val": value };
    [self sendRequest:req completion:^(NSDictionary *resp) {
        if ([resp[@"status"] integerValue] == 0) {
            self.conf[key] = value;
        } else {
            self.lastError = resp[@"error"] ?: @"写入失败";
        }
    }];
}

#pragma mark - 请求/状态

- (void)sendRequest:(NSDictionary *)req completion:(void (^)(NSDictionary *resp))completion {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *err = nil;
        NSDictionary *resp = CLAPISend(req, &err);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.lastError = resp ? nil : (err ?: @"后台服务未运行");
            if (completion) completion(resp ?: @{});
        });
    });
}

- (void)refreshState {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *err1 = nil, *err2 = nil;
        NSDictionary *confResp = CLAPISend(@{ @"api": @"get_conf" }, &err1);
        NSDictionary *batResp = CLAPISend(@{ @"api": @"get_bat_info" }, &err2);

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;

            NSDictionary *confData = confResp[@"data"];
            if ([confData isKindOfClass:[NSDictionary class]]) {
                self.conf = [confData mutableCopy];
            }
            NSDictionary *batData = batResp[@"data"];
            if ([batData isKindOfClass:[NSDictionary class]]) {
                self.bat = batData;
            }
            self.lastError = confResp ? nil : (err1 ?: err2 ?: @"后台服务未运行");

            [self updateStatusCell];
            [self updateToggleButton];
            [self reloadSpecifier:[self specifierForKey:@"cl_charge_above"] animated:NO];
            [self reloadSpecifier:[self specifierForKey:@"cl_charge_below"] animated:NO];
            [self reloadSpecifier:[self specifierForKey:@"cl_enable_temp"] animated:NO];
            [self reloadSpecifier:[self specifierForKey:@"cl_temp_above"] animated:NO];
            [self reloadSpecifier:[self specifierForKey:@"cl_temp_below"] animated:NO];
        });
    });
}

- (PSSpecifier *)specifierForKey:(NSString *)key {
    for (PSSpecifier *s in [self specifiers]) {
        if ([s.properties[@"key"] isEqualToString:key]) return s;
    }
    return nil;
}

- (void)updateStatusCell {
    if (!self.statusGroup) return;
    NSString *text = nil;

    if (!self.conf || !self.bat) {
        text = self.lastError.length ? [NSString stringWithFormat:@"后台服务未运行（%@）。请重新安装 deb 或重启设备。", self.lastError]
                                     : @"正在读取…";
    } else {
        NSInteger cap = [self.bat[@"CurrentCapacity"] integerValue];
        double temp = [self.bat[@"Temperature"] doubleValue] / 100.0;
        BOOL charging = [self.bat[@"IsCharging"] boolValue];
        BOOL plugged = [self.bat[@"ExternalConnected"] boolValue];

        NSString *state = charging ? @"充电中" : (plugged ? @"已接电源 · 未充电" : @"未接电源");
        text = [NSString stringWithFormat:@"电量 %ld%%    ·    温度 %.1f °C    ·    %@",
                (long)cap, temp, state];
        NSInteger above = [self intForKey:@"charge_above" fallback:kCLDefaultAbove];
        text = [text stringByAppendingFormat:@"\n充电上限 %ld%% · %@", (long)above,
                [self.conf[@"enable_temp"] boolValue] ? @"温度保护已开启" : @"温度保护已关闭"];
    }

    [self.statusGroup setProperty:text forKey:@"footerText"];
    [self reloadSpecifier:self.statusGroup animated:NO];
}

- (void)updateToggleButton {
    if (!self.toggleButton) return;
    BOOL commandEnabled = [self.bat[@"ChargeCommandEnabled"] boolValue];
    NSString *label = commandEnabled ? @"暂停充电（立即停止）" : @"恢复充电";
    if (!self.bat) label = @"暂停充电";
    [self.toggleButton setProperty:label forKey:@"label"];
    [self reloadSpecifier:self.toggleButton animated:NO];
}

#pragma mark - 交互

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    PSSpecifier *spec = nil;
    @try { spec = [cell valueForKey:@"specifier"]; } @catch (NSException *e) { spec = nil; }
    if (![spec isKindOfClass:[PSSpecifier class]]) spec = nil;

    NSString *key = spec.properties[@"key"];
    if (key.length == 0) {
        [super tableView:tableView didSelectRowAtIndexPath:indexPath];
        return;
    }

    [tableView deselectRowAtIndexPath:indexPath animated:NO];

    NSArray *values = spec.properties[@"validValues"];
    NSArray *titles = spec.properties[@"validTitles"];
    if (values.count == 0) return;

    UIAlertController *menu = [UIAlertController alertControllerWithTitle:spec.properties[@"label"]
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSUInteger i = 0; i < values.count; i++) {
        NSNumber *value = values[i];
        NSString *title = (i < titles.count) ? titles[i] : [value description];
        [menu addAction:[UIAlertAction actionWithTitle:title
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *action) {
            [self commitValue:value forKey:key];
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (menu.popoverPresentationController) {
        menu.popoverPresentationController.sourceView = cell;
        menu.popoverPresentationController.sourceRect = cell.bounds;
    }
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)commitValue:(NSNumber *)value forKey:(NSString *)key {
    if ([key isEqualToString:@"cl_charge_above"]) {
        [self setConfKey:@"charge_above" value:value];
    } else if ([key isEqualToString:@"cl_charge_below"]) {
        [self setConfKey:@"charge_below" value:value];
    } else if ([key isEqualToString:@"cl_temp_above"]) {
        [self setConfKey:@"temp_mode" value:@0];
        [self setConfKey:@"charge_temp_above" value:value];
    } else if ([key isEqualToString:@"cl_temp_below"]) {
        [self setConfKey:@"temp_mode" value:@0];
        [self setConfKey:@"charge_temp_below" value:value];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self refreshState]; });
}

- (void)toggleCharge:(PSSpecifier *)specifier {
    BOOL commandEnabled = [self.bat[@"ChargeCommandEnabled"] boolValue];
    BOOL target = !commandEnabled;
    [self sendRequest:@{ @"api": @"set_charge_status", @"flag": @(target) } completion:^(NSDictionary *resp) {
        [self refreshState];
    }];
}

- (void)applyNow:(PSSpecifier *)specifier {
    [self sendRequest:@{ @"api": @"apply_now" } completion:^(NSDictionary *resp) {
        [self refreshState];
    }];
}

- (void)resetDefaults:(PSSpecifier *)specifier {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"恢复默认设置"
                                                                   message:@"将充电上限恢复为 80%、回充下限 20%，并关闭温度保护。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"恢复"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        [self sendRequest:@{ @"api": @"reset_conf" } completion:^(NSDictionary *resp) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self refreshState]; });
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
