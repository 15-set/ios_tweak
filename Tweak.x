/*
 * =====================================================================================
 *  Insulation (解除温控) — Logos 重建版 + 「电池原生温控」开关
 * =====================================================================================
 *
 *  原插件: com.be-huge.insulation 0.0.18 (rootless, Swift/Orion 编译产物)
 *  本文件: 以 Logos 语法对原插件做源码级重建，并加入新增功能。
 *
 *  注释约定:
 *    [UPSTREAM]  — 与上游开源代码 github.com/be-huge/insulation(main) 完全一致，逐行有出处
 *    [EVIDENCE]  — 来自 deb 二进制的证据(导出符号 / 字符串 / selector / 类型编码)，行为为重建推断
 *    [INFERRED]  — 证据不足以逐行还原，按日志字符串语义做出的合理重建(详见 CHANGES.md)
 *    [NEW]       — 本次改造新增
 *    [MODIFIED]  — 本次改造修改
 *
 *  二进制证据摘要(arm64 slice, 未剥离符号表, 312 symbols):
 *    - Orion ClassHook 痕迹: $s5Orion17ClassHookProtocolP..., method_setImplementation 等
 *    - 6 个 hook 类: CommonProductClassHook / HidSensorsHook / ComponentControlHook /
 *      MitigationControllerHook / CPMSHelperHook / NSDictionaryHook
 *    - 注入目标: filter plist Executables = ( "thermalmonitord" )
 *    - 关键日志串: "insulation cpu level lock %d -> %d",
 *      "insulation component %d power limit %d -> %d",
 *      "thermalPowerMode fullPower -> thermal mitigations disabled (%d)" 等
 *
 *  支持系统: iOS 12.2+ (control Depends: firmware >= 12.2);
 *            rootless 构建 (THEOS_PACKAGE_SCHEME=rootless) 实际对应 iOS 15+ (palera1n/Dopamine)
 *  编译 SDK: theos 最新 iOS SDK (TARGET = iphone:clang:latest:14.0/15.0, 见 Makefile)
 * =====================================================================================
 */

#import <Foundation/Foundation.h>
#import <notify.h>
#import <os/lock.h>
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>          /* [BUILD-FIX-C] dlsym: SCPreferences* 在 iOS SDK 标记 unavailable, 改运行时取符号 */
#import <signal.h>         /* [NEW] kill(getpid(), SIGKILL) 重启 thermalmonitord */
#import <unistd.h>         /* [NEW] getpid */
#import <sys/stat.h>       /* [NEW] chmod: 调试日志可被 mobile 用户 tail */
#import <stdio.h>          /* [NEW] snprintf: 落盘诊断 */
#import <stdarg.h>         /* [NEW] va_list */
#import <fcntl.h>          /* [NEW] open/O_APPEND: 多路径探测 */
#import <errno.h>          /* [NEW] errno: 记录失败原因 */
#import <string.h>         /* [NEW] strlen */

/* [BUILD-FIX-A] 私有类前向声明: 与下方 @interface 并存合法, 双保险保证
 * 全局指针及 Logos 生成代码处的类型可见性 */
@class CommonProduct;
@class MitigationController;
@class ComponentControl;
@class CPMSHelper;
@class HidSensors;
@class ThermalManager;

/*
 * [BUILD-FIX] rootless 路径换算
 *   1) theos 的 <libroot.h> 只转发 <libroot/libroot.h>, 其中真实 API 是
 *      JBROOT_PATH_NSSTRING / JBROOT_PATH_CSTRING (libroot_dyn_jbrootpath),
 *      并不存在 jbroot() 函数 —— 原写法会 implicit declaration + 链接失败。
 *   2) `static NSString *const` 不能用函数/消息调用做初始化 (非编译期常量)。
 *   故改为惰性函数 InsPrefsPath(): 业务语义不变, 仍读写同一个 prefs plist。
 *   证据: 原 deb dylib 含 "@rpath/libroot.dylib" 与 libroot_dyn_* 符号。
 */
#define kInsPrefsPathRel @"/var/mobile/Library/Preferences/com.be-huge.insulation-prefs.plist"

#if __has_include(<libroot.h>)
    #import <libroot.h>
    #define INS_HAS_LIBROOT 1
#endif

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

#pragma mark - 常量

#define ILog(fmt, ...) NSLog(@"[Insulation] " fmt, ##__VA_ARGS__)

/* [NEW] 不依赖 `log stream` 的落盘诊断: 直接追加到固定文件, 手机端 `tail` 即可看。
 *   [FIX] 之前只试 /var/mobile/Library/Preferences 与 /var/tmp 两条路径且失败静默;
 *         thermalmonitord 大概率被 sandbox 限制(或 uid/HOME 不是 mobile), 导致两个路径都 fopen 失败。
 *         现在: 多候选 open() 探测 + 记录每条候选的 errno + 选定路径写日志 + NSLog 兜底。 */
#define kInsDebugLogMaxPath 512
static char gInsDebugLogPath[kInsDebugLogMaxPath];

static NSString *InsErrName(int e) {
    const char *n = "?";
    switch (e) {
        case EACCES: n = "EACCES"; break;
        case EPERM:  n = "EPERM";  break;
        case ENOENT: n = "ENOENT"; break;
        case EROFS:  n = "EROFS";  break;
        case ENOTDIR:n = "ENOTDIR";break;
        case ENAMETOOLONG: n = "ENAMETOOLONG"; break;
        default: break;
    }
    return [NSString stringWithFormat:@"%d(%s)", e, n];
}

static void InsDebugLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSString *entry = [NSString stringWithFormat:@"[%@ pid=%d uid=%d] %@\n",
                       [NSDate date], getpid(), getuid(), line];

    if (gInsDebugLogPath[0] == '\0') {
        /* 顺序按“daemon 最可能可写”排列: Media → Preferences → 插件目录 → tmp → root */
        const char *fixedCands[] = {
            "/var/mobile/Media/insulation-debug.log",
            "/var/jb/var/mobile/Media/insulation-debug.log",
            "/var/mobile/Library/Preferences/insulation-debug.log",
            "/var/jb/var/mobile/Library/Preferences/insulation-debug.log",
            "/var/jb/Library/MobileSubstrate/DynamicLibraries/insulation-debug.log",
            "/private/var/tmp/insulation-debug.log",
            "/var/tmp/insulation-debug.log",
            "/tmp/insulation-debug.log",
            "/var/root/insulation-debug.log",
        };
        const int candCount = (int)(sizeof(fixedCands) / sizeof(fixedCands[0]));
        int errs[9] = {0};
        for (int i = 0; i < candCount; i++) {
            int fd = open(fixedCands[i], O_WRONLY | O_CREAT | O_APPEND, 0644);
            if (fd >= 0) {
                close(fd);
                chmod(fixedCands[i], 0644);
                snprintf(gInsDebugLogPath, sizeof(gInsDebugLogPath), "%s", fixedCands[i]);
                NSLog(@"[Insulation][debuglog] 选用路径: %s", fixedCands[i]);
                break;
            }
            errs[i] = errno;
        }
        if (gInsDebugLogPath[0] == '\0') {
            NSString *homePath = [NSHomeDirectory() stringByAppendingPathComponent:@"insulation-debug.log"];
            int fd = open(homePath.UTF8String, O_WRONLY | O_CREAT | O_APPEND, 0644);
            if (fd >= 0) {
                close(fd);
                chmod(homePath.UTF8String, 0644);
                snprintf(gInsDebugLogPath, sizeof(gInsDebugLogPath), "%s", homePath.UTF8String);
                NSLog(@"[Insulation][debuglog] 选用路径: %@", homePath);
            } else {
                NSMutableString *detail = [NSMutableString string];
                for (int i = 0; i < candCount; i++) {
                    [detail appendFormat:@"%@=%@ ", [NSString stringWithUTF8String:fixedCands[i]], InsErrName(errs[i])];
                }
                [detail appendFormat:@"HOME=%@=%@", homePath, InsErrName(errno)];
                NSLog(@"[Insulation][debuglog] 全部路径失败 uid=%d euid=%d | %@",
                      getuid(), geteuid(), detail);
            }
        }
    }

    if (gInsDebugLogPath[0] != '\0') {
        int fd = open(gInsDebugLogPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            const char *s = entry.UTF8String;
            (void)write(fd, s, strlen(s));
            close(fd);
        } else {
            NSLog(@"[Insulation][debuglog] 追加失败 path=%s errno=%d", gInsDebugLogPath, errno);
            gInsDebugLogPath[0] = '\0';   /* 下次重新探测 */
        }
    }

    /* 统一日志兜底: 即使落盘失败, Console/log stream 也能看到 */
    NSLog(@"[Insulation] %@", line);
}

/* Darwin 通知名 (与原 deb 二进制字符串一致) */
#define kInsNotifExecutePuppet   "com.be-huge.insulation-executePuppetEvent"
#define kInsNotifRuntimeState    "com.be-huge.insulation.runtimeState"
#define kInsNotifRestartTM       "com.be-huge.insulation-restartThermalMonitor"
/* [NEW] 新增设置项变更通知 (由新面板 cell 的 PostNotification 发出) */
#define kInsNotifBatteryChanged  "com.be-huge.insulation-batteryProtectChanged"

/* 原有偏好 key (deb Root.plist 为证) */
#define kPrefPowerMode                    @"thermalPowerMode"                    // off/lowPower/fullPower
#define kPrefPreventDimming               @"thermalPreventDimmingEnabled"
#define kPrefSuppressNotifications        @"thermalSuppressNotificationsEnabled"
#define kPrefDisablePocketSunlight        @"thermalDisablePocketSunlightEnabled"
#define kPrefSunlightLocked               @"thermalSunlightLockedEnabled"

/* [NEW] 开关 key (沿用历史 key 名, 不改名以免旧配置失效)
 *        语义: YES = 电池温控永久交还系统原生 / NO = 完全恢复插件原行为 */
#define kPrefChargingBatteryProtect       @"chragingBatteryThermalProtect"       // [NEW] 开关, 默认 NO

#pragma mark - 目标类声明 (来自上游 insulationC/include/Power_header 目录下的头文件, [UPSTREAM])

@interface CommonProduct : NSObject
- (int)gasGaugeBatteryTemperature;
- (id)initProduct:(id)arg1;
- (void)putDeviceInLowTempSimulationMode:(id)arg1;
- (void)putDeviceInThermalSimulationMode:(id)arg1;
- (void)thermalUpdatesToWatchdogEnabled:(id)arg1;
- (void)setThermalState:(int)a3;
- (BOOL)getPotentialForcedThermalPressureLevel;
- (id)getPotentialForcedThermalLevel:(id)a3;
- (void)tryTakeAction;
- (void)handleMCSThermalPressure;
- (void)simulateLightThermalPressure;
- (void)updatePowerzoneTelemetry;
@end

@interface MitigationController : NSObject
- (BOOL)powerSaveActive;
- (int)CPULevel;
- (int)getCPUTargetPower;
- (int)getPackageCPUPowerTarget;
- (void)setCPMSMitigationsEnabled:(BOOL)a3;
- (void)setCPULevel:(int)a3;
- (void)setCPUPowerCeiling:(int)a3 fromDecisionSource:(int)a4;
- (void)setCPUPowerFloor:(int)a3 fromDecisionSource:(int)a4;
- (void)setCPUPowerZoneTarget:(int)a3;
- (void)setMaxPackagePower:(int)a3;
- (void)setPowerSaveActive:(BOOL)a3;
- (void)updateCPU;
- (instancetype)initForFastLoop:(BOOL)a3 noDisplay:(BOOL)a4 powerSaveParams:(id)a5 powerZoneParams:(id)a6;
@end

@interface ComponentControl : NSObject
@property(readonly, nonatomic) int mitigationType;
- (unsigned)currentPower;
- (unsigned)computePowerTarget;
- (unsigned)powerTarget;
- (void)updatePowerParameters:(id)a3;
@end

@interface CPMSHelper : NSObject
+ (id)sharedInstance;
- (unsigned)getMaxPowerForComponent:(int)a3;
- (unsigned)getMinPowerForComponent:(int)a3;
@end

@interface HidSensors : NSObject
+ (id)sharedInstance;
- (void)handleTemperatureEvent:(int)a3 service:(id)a4;
@end

@interface ThermalManager : NSObject
- (void *)getConfigurationFor:(id)a3;
@end

#pragma mark - [NEW] IOKit 私有声明 (仅用于电池传感器属性读取)

/* [BUILD-FIX-D] IOHIDServiceClient 属性读取
 *   IOHIDServiceClientGetProperty 是 IOKit 的私有导出, 不在 SDK 的 IOKit.tbd (stub) 里,
 *   直接 extern 引用会在链接期报 Undefined symbols (arm64 / arm64e 均会)。
 *   改 dlsym(RTLD_DEFAULT, ...) 运行时解析 + dispatch_once 缓存: 签名/返回所有权(Get 规则,
 *   不转移持有)与原 ABI 完全一致。解析失败 → 返回 NULL → 调用方按「非电池服务」处理
 *   (= 保持吞掉事件, 与原版行为一致的安全侧)。 */
typedef const struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef CFTypeRef (*InsIOHIDGetProperty_t)(IOHIDServiceClientRef service, CFStringRef key);

static CFTypeRef InsIOHIDServiceClientGetProperty(IOHIDServiceClientRef service, CFStringRef key) {
    static InsIOHIDGetProperty_t pGet;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_GLOBAL);
        pGet = (InsIOHIDGetProperty_t)dlsym(RTLD_DEFAULT, "IOHIDServiceClientGetProperty");
        if (!pGet) ILog(@"IOHIDServiceClientGetProperty 符号解析失败 (dlsym), 电池传感器判定恒为「非电池」");
    });
    return pGet ? pGet(service, key) : NULL;
}

#pragma mark - 全局状态

typedef NS_ENUM(NSInteger, InsPowerMode) {
    InsPowerModeOff = 0,     /* 苹果原生温控 */
    InsPowerModeLowPower,    /* 模拟低电频率 */
    InsPowerModeFullPower,   /* 防止温控降频 */
};

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;

static InsPowerMode  gPowerMode = InsPowerModeOff;
static BOOL          gPreventDimming = NO;
static BOOL          gSuppressNotifications = NO;
static BOOL          gDisablePocketSunlight = NO;
static BOOL          gSunlightLocked = NO;

static CommonProduct        *gCommonProduct = nil;        /* [UPSTREAM] commonProductObject */
static MitigationController *gMitigationController = nil; /* [EVIDENCE] mitigationControllerObject */

/* [EVIDENCE] 0.0.18 二进制中的实例变量名: observedCPUPowerMax / observedComponentPowerGlobalMax 等 */
static unsigned gObservedCPUPowerMax = 0;
static unsigned gObservedComponentPowerGlobalMax = 0;

static int gRuntimeStateToken = 0;   /* notify_set_state token, [EVIDENCE] com.be-huge.insulation.runtimeState */

#pragma mark - [NEW] 电池原生温控 开关状态

/* [NEW]
 *   gChargingProtectEnabled = YES → 电池温控事件永久放行给系统原生 (%orig)
 *   gChargingProtectEnabled = NO  → 完全恢复插件原行为(继续吞掉电池温度事件)
 *   gBatteryThermalReleased  —— 上面开关的直通副本, 供 hook 热路径读取
 * 说明: 不区分充电状态、不比较温度、无阈值/回差; CPU 路径永不受这个开关影响。
 */
static BOOL gChargingProtectEnabled = NO;     /* [NEW] key: chragingBatteryThermalProtect, 默认 NO */
static BOOL gBatteryThermalReleased  = NO;    /* NO=插件接管(原行为) / YES=电池温控已永久交还原生 */

#pragma mark - 偏好读取

static void InsReloadPrefs(void) {
    NSString *path = InsPrefsPath();
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:path];
    /* [FIX] 隐根/roothide 下 jbroot 前缀路径可能不含用户域偏好, 回退真实路径读取 */
    if (!p) p = [NSDictionary dictionaryWithContentsOfFile:kInsPrefsPathRel];
    p = p ?: @{};

    os_unfair_lock_lock(&gLock);

    NSString *mode = [p[kPrefPowerMode] isKindOfClass:[NSString class]] ? p[kPrefPowerMode] : @"off";
    if ([mode isEqualToString:@"lowPower"])      gPowerMode = InsPowerModeLowPower;
    else if ([mode isEqualToString:@"fullPower"]) gPowerMode = InsPowerModeFullPower;
    else                                          gPowerMode = InsPowerModeOff;

    gPreventDimming        = [p[kPrefPreventDimming] boolValue];
    gSuppressNotifications = [p[kPrefSuppressNotifications] boolValue];
    gDisablePocketSunlight = [p[kPrefDisablePocketSunlight] boolValue];
    gSunlightLocked        = [p[kPrefSunlightLocked] boolValue];

    /* [NEW] 开关默认关闭; 打开 = 电池温控永久交还原生, 关闭 = 恢复插件原行为。
     *       直通赋值: 不做任何充电状态 / 温度 / 阈值 / 回差判断。 */
    BOOL enabled = [p[kPrefChargingBatteryProtect] boolValue];
    gChargingProtectEnabled = enabled;
    BOOL wasReleased = gBatteryThermalReleased;
    gBatteryThermalReleased = enabled;

    os_unfair_lock_unlock(&gLock);

    /* [DIAG] 每次重载都打印实际读到的值, 与面板侧 "已同步" 日志成对定位 */
    ILog(@"读取偏好: path=%@ thermalPowerMode=%@", path, mode);
    InsDebugLog(@"读取偏好: path=%@ thermalPowerMode=%@ released=%@",
                path, mode, enabled ? @"YES" : @"NO");

    if (wasReleased != enabled) {
        ILog(@"电池温控控制权: %@ | 开关=%@ | CPU 路径不受影响(永不放行)",
             enabled ? @"已永久交还原生" : @"插件接管(原行为)",
             enabled ? @"开" : @"关");
    }
}

#pragma mark - [NEW] 电池温度传感器识别 (用于只放开电池这一路)

/*
 * 原插件在 HidSensors handleTemperatureEvent:service: 吞掉【所有】HID 温度传感器事件,
 * SOC(=CPU 温控输入)与电池温度事件在同一处被拦截。service 参数(IOHIDServiceClient)
 * 携带传感器的属性, 可据此区分来源。此处按属性做电池传感器匹配:
 *   - 任一字符串属性包含 "batt" / "gas gauge" (大小写不敏感)
 *   - HID PrimaryUsagePage == 0x84 (Power Devices page)
 * 识别不出 → 返回 NO → 保持吞掉 (=原版行为), 绝不误放行。
 */
static BOOL InsIsBatteryThermalService(id service) {
    if (!service) return NO;
    IOHIDServiceClientRef sc = (IOHIDServiceClientRef)CFBridgingRetain(service);
    BOOL isBattery = NO;
    CFStringRef keys[] = { CFSTR("Product"), CFSTR("Transport"), CFSTR("Manufacturer"), CFSTR("Name") };
    for (int i = 0; i < 4 && !isBattery; i++) {
        CFTypeRef v = InsIOHIDServiceClientGetProperty(sc, keys[i]);
        if (v && CFGetTypeID(v) == CFStringGetTypeID()) {
            NSString *s = [(__bridge NSString *)v lowercaseString];
            if ([s containsString:@"batt"] || [s containsString:@"gas"]) isBattery = YES;
        }
    }
    if (!isBattery) {
        CFTypeRef page = InsIOHIDServiceClientGetProperty(sc, CFSTR("PrimaryUsagePage"));
        if (page && CFGetTypeID(page) == CFNumberGetTypeID()) {
            int32_t p = 0; CFNumberGetValue((CFNumberRef)page, kCFNumberSInt32Type, &p);
            if (p == 0x84) isBattery = YES;   /* Power Devices usage page */
        }
    }
    /* 首次见到每个 service 时 dump 属性, 便于真机核对电池传感器标识 */
    static NSMutableSet *sSeenServices;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ sSeenServices = [NSMutableSet new]; });
    @synchronized (sSeenServices) {
        NSValue *key = [NSValue valueWithPointer:(void *)sc];
        if (![sSeenServices containsObject:key]) {
            [sSeenServices addObject:key];
            ILog(@"HID 温度传感器发现: Product=%@ Transport=%@ Manufacturer=%@ UsagePage=%@ → 判定:%@",
                 /* [MEM-FIX] IOHIDServiceClientGetProperty 是 Get 规则(不拥有),
                  * 原 CFBridgingRelease 会把非持有对象 -release → over-release, 真机可能崩溃。
                  * 改用 __bridge 不转移所有权; sc 已被 CFBridgingRetain 持有, 调用期间属性有效。 */
                 (__bridge id)InsIOHIDServiceClientGetProperty(sc, CFSTR("Product")),
                 (__bridge id)InsIOHIDServiceClientGetProperty(sc, CFSTR("Transport")),
                 (__bridge id)InsIOHIDServiceClientGetProperty(sc, CFSTR("Manufacturer")),
                 (__bridge id)InsIOHIDServiceClientGetProperty(sc, CFSTR("PrimaryUsagePage")),
                 isBattery ? @"电池" : @"其他");
        }
    }
    CFRelease(sc);
    return isBattery;
}

#pragma mark - [EVIDENCE]/[INFERRED] OSThermalStatus 写入 (高级功能开关的落盘)

/*
 * [EVIDENCE] 二进制字符串: SCPreferencesCreate/SetValue/CommitChanges/ApplyChanges +
 * "OSThermalStatus.plist" + OSThermalNotificationEnabled / OSThermalNotificationPersistentlyEnabled /
 * engageBehavior / engageBehaviorPersistentlyEnabled / hipOverride / hipPersistentlyEnabled /
 * simulateHip / sunlightOverride / sunlightOverridePersistentlyEnabled
 * 导出函数: insulationSetOSNotifEnabled / insulationSetHIPEnabled / insulationSetSunlightOverride ...
 * [INFERRED] 具体键值映射按日志字符串语义重建。
 */
/* [BUILD-FIX-C] SCPreferencesCreate/SetValue/RemoveValue/CommitChanges/ApplyChanges 在 iOS SDK
 * 标记 API_UNAVAILABLE(ios), 直接调用即编译错误; 运行时符号仍由 SystemConfiguration.framework
 * 导出 → 改 dlsym 解析 + 自有不透明类型。写入目标 (域 "insulation" 的 OSThermalStatus.plist)
 * 与调用序列 (create → set/remove → commit → apply → release) 与原实现完全一致;
 * 符号缺失 → 打日志并安全跳过 (等价于原 prefs==NULL 早退路径的扩展)。 */
typedef const struct InsSCPreferencesOpaque *InsSCPreferencesRef;
typedef InsSCPreferencesRef (*InsSCCreate_t)(CFAllocatorRef, CFStringRef, CFStringRef);
typedef Boolean (*InsSCSet_t)(InsSCPreferencesRef, CFStringRef, CFTypeRef);
typedef Boolean (*InsSCRemove_t)(InsSCPreferencesRef, CFStringRef);
typedef Boolean (*InsSCCommit_t)(InsSCPreferencesRef);
typedef Boolean (*InsSCApply_t)(InsSCPreferencesRef);

static void InsSCSetValue(CFStringRef key, CFTypeRef value) {
    static InsSCCreate_t pCreate;
    static InsSCSet_t    pSet;
    static InsSCRemove_t pRemove;
    static InsSCCommit_t pCommit;
    static InsSCApply_t  pApply;
    static BOOL          sResolved = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        /* 确保 SystemConfiguration.framework 已加载 (本 dylib 已链接它, 此为双保险) */
        dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration", RTLD_LAZY | RTLD_GLOBAL);
        pCreate = (InsSCCreate_t)dlsym(RTLD_DEFAULT, "SCPreferencesCreate");
        pSet    = (InsSCSet_t)dlsym(RTLD_DEFAULT, "SCPreferencesSetValue");
        pRemove = (InsSCRemove_t)dlsym(RTLD_DEFAULT, "SCPreferencesRemoveValue");
        pCommit = (InsSCCommit_t)dlsym(RTLD_DEFAULT, "SCPreferencesCommitChanges");
        pApply  = (InsSCApply_t)dlsym(RTLD_DEFAULT, "SCPreferencesApplyChanges");
        sResolved = (pCreate && pSet && pRemove && pCommit && pApply);
        if (!sResolved) ILog(@"SCPreferences 符号解析失败 (dlsym), OSThermalStatus.plist 写入将被跳过");
    });
    if (!sResolved) return;

    InsSCPreferencesRef prefs = pCreate(kCFAllocatorDefault, CFSTR("insulation"), CFSTR("OSThermalStatus.plist"));
    if (!prefs) {
        ILog(@"SCPreferencesCreate 返回 NULL, 跳过 key=%@", key);
        return;
    }
    if (value) pSet(prefs, key, value);
    else       pRemove(prefs, key);
    pCommit(prefs);
    pApply(prefs);
    CFRelease(prefs);
}

static void InsApplyAdvancedSwitches(void) {
    os_unfair_lock_lock(&gLock);
    BOOL suppress = gSuppressNotifications;
    BOOL pocket   = gDisablePocketSunlight;
    BOOL sunLock  = gSunlightLocked;
    os_unfair_lock_unlock(&gLock);

    /* [INFERRED] 日志串: "thermalSuppressNotificationsEnabled: on -> %d" 等 */
    InsSCSetValue(CFSTR("OSThermalNotificationEnabled"), suppress ? kCFBooleanFalse : kCFBooleanTrue);
    InsSCSetValue(CFSTR("OSThermalNotificationPersistentlyEnabled"), suppress ? kCFBooleanFalse : kCFBooleanTrue);
    ILog(@"thermalSuppressNotificationsEnabled: %@ -> %d", suppress ? @"on" : @"off", suppress);

    InsSCSetValue(CFSTR("hipOverride"), pocket ? kCFBooleanFalse : NULL);
    InsSCSetValue(CFSTR("hipPersistentlyEnabled"), pocket ? kCFBooleanFalse : NULL);
    InsSCSetValue(CFSTR("simulateHip"), pocket ? kCFBooleanFalse : NULL);
    ILog(@"thermalDisablePocketSunlightEnabled: %@ -> %d/%d", pocket ? @"on" : @"off", pocket, 0);

    InsSCSetValue(CFSTR("sunlightOverride"), sunLock ? kCFBooleanTrue : NULL);
    InsSCSetValue(CFSTR("sunlightOverridePersistentlyEnabled"), sunLock ? kCFBooleanTrue : NULL);
    ILog(@"thermalSunlightLockedEnabled: %@ -> %d", sunLock ? @"on" : @"off", sunLock);
}

#pragma mark - [EVIDENCE] 模式应用 (thermalPowerMode: off/lowPower/fullPower)

/*
 * [EVIDENCE] 日志串:
 *   "insulation: native thermal mode restored"
 *   "insulation: low power mode at CPU level %d" / "insulation simulates low power mode at CPU level %d"
 *   "insulation: full power mode" / "insulation disables CPU mitigations with full target %d"
 *   "thermalPowerMode fullPower -> thermal mitigations disabled (%d)"
 *   "thermalPowerMode native/lowPower -> thermal mitigations reset (%d)"
 * [EVIDENCE] 反汇编 (arm64 slice, applyPowerMode = 0xbe04..0xc2d4):
 *   lowPower 分支 0xc020..0xc0e4: setPowerSaveActive:YES → setCPULevel:2 → updateCPU
 *                                  → setPowerSaveActive:YES → setCPULevel:2
 *   日志 "insulation: low power mode at CPU level %d" 的实参为 w24=2 (0xc0d4 处 mov w24,#2 的来源)。
 *   lowPower 分支不调用 setCPMSMitigationsEnabled: / setCPUPowerCeiling: / setCPUPowerZoneTarget:。
 *   CPMS 缓解开关只出现在启动 initForFastLoop 路径 (0x12094: w2=1)。
 */
static void InsApplyPowerMode(void) {
    os_unfair_lock_lock(&gLock);
    InsPowerMode mode = gPowerMode;
    os_unfair_lock_unlock(&gLock);

    MitigationController *mc = gMitigationController;
    if (!mc) {
        /* daemon 启动早期 ctor 阶段 MitigationController 还没创建;
         * 真正的应用点在 Hook 4 的 initForFastLoop: 里(见该处注释)。 */
        ILog(@"等待 MitigationController 初始化后应用模式(%ld)", (long)mode);
        InsDebugLog(@"apply 推迟: MitigationController=nil, mode=%ld", (long)mode);
        return;
    }

    switch (mode) {
        case InsPowerModeFullPower:
            [mc setCPMSMitigationsEnabled:NO];   /* 关闭 CPMS 缓解 → CPU 不降频 */
            ILog(@"insulation: full power mode");
            ILog(@"thermalPowerMode fullPower -> thermal mitigations disabled (%d)", 0);
            break;
        case InsPowerModeLowPower:
            /* [EVIDENCE] 与 0xbe04 的 lowPower 分支一致: 档位是 2, 不是 1。
             * 顺序: PS:YES → CPULevel:2 → updateCPU → PS:YES → CPULevel:2 */
            [mc setCPMSMitigationsEnabled:YES];  /* [EVIDENCE] 启动路径 0x12094 传 w2=1; 切换路径不下发 */
            [mc setPowerSaveActive:YES];         /* [EVIDENCE] 0xc028 / 0xc060, w2=1 */
            [mc setCPULevel:2];                  /* [EVIDENCE] 0xc03c, w24=2 */
            [mc updateCPU];                      /* [EVIDENCE] 0xc050 */
            [mc setPowerSaveActive:YES];         /* [EVIDENCE] 0xc060, w2=1 */
            [mc setCPULevel:2];                  /* [EVIDENCE] 0xc0d4, w24=2 */
            ILog(@"insulation: low power mode at CPU level %d", 2);
            ILog(@"thermalPowerMode native/lowPower -> thermal mitigations reset (%d)", 0);
            break;
        case InsPowerModeOff:
        default:
            [mc setCPMSMitigationsEnabled:YES];
            [mc setPowerSaveActive:NO];
            /* 不在这里强设 setCPULevel:0: 会把正在生效的原生热缓解一并清掉;
             * lowPower→off 由 daemon 重启保证不残留我们加的 level 1 钳制。 */
            ILog(@"insulation: native thermal mode restored");
            ILog(@"thermalPowerMode native/lowPower -> thermal mitigations reset (%d)", 0);
            break;
    }

    InsDebugLog(@"apply 完成: mode=%ld mc=%p CPULevel=%d",
                (long)mode, (void *)(__bridge void *)mc, (int)[mc CPULevel]);

    /* [EVIDENCE] 发布运行时状态: notify_set_state + com.be-huge.insulation.runtimeState */
    uint64_t stateCode = (uint64_t)mode;
    notify_set_state(gRuntimeStateToken, stateCode);
    notify_post(kInsNotifRuntimeState);
}

/* [B][INFERRED] 兜底捕获: 若 initForFastLoop: 没命中(或 hook 失败), 从同类的
 * updateCPU / setCPULevel: 的 self 抓 MitigationController 实例。
 * [EVIDENCE] 这两个 selector 都属于 MitigationController (Power_header/MitigationController.h)。
 * 抓到后异步补一次 apply, 避免在 hook 内同步重入。 */
static void InsCaptureController(MitigationController *mc) {
    if (!mc) return;
    BOOL first = NO;
    os_unfair_lock_lock(&gLock);
    if (gMitigationController == nil) {
        gMitigationController = mc;
        first = YES;
    }
    os_unfair_lock_unlock(&gLock);
    if (!first) return;

    InsDebugLog(@"capture: 兜底抓到 mc=%p", (void *)(__bridge void *)mc);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        InsApplyPowerMode();
    });
}

/* [B][INFERRED] ctor 之后的定时兜底: initForFastLoop: 未命中时也能等到 controller。 */
static void InsFallbackApply(int attempt) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (gMitigationController != nil) {
            InsDebugLog(@"fallback: 第%d次已有 controller, 重新 apply", attempt);
            InsApplyPowerMode();
        } else if (attempt < 5) {
            InsDebugLog(@"fallback: 第%d次仍无 controller, 继续等待", attempt);
            InsFallbackApply(attempt + 1);
        } else {
            InsDebugLog(@"fallback: 5 次后仍无 controller (initForFastLoop 可能未命中)");
        }
    });
}

#pragma mark - Hook 1: CommonProduct  [UPSTREAM, 与上游 Tweak.x.swift 一致]

%hook CommonProduct

/* [UPSTREAM] 捕获 CommonProduct 实例并把热模拟模式钉在 nominal */
- (id)initProduct:(id)arg1 {
    id res = %orig;
    gCommonProduct = self;
    [self putDeviceInThermalSimulationMode:@"nominal"];
    return res;
}

/* [UPSTREAM] 吞掉热决策动作 / 轻度压力模拟 / powerzone 遥测上报 */
- (void)tryTakeAction { /* swallow */ }
- (void)simulateLightThermalPressure { /* swallow */ }
- (void)updatePowerzoneTelemetry { /* swallow */ }

/* [EVIDENCE] selector 存在于二进制; [INFERRED] 同样吞掉 MCS 热压力处理 */
- (void)handleMCSThermalPressure { /* swallow */ }

/* [EVIDENCE] selector setThermalState: + 日志串 "insulation thermal state %@ -> Darwin pressure %d (%d)"
 * [INFERRED] fullPower 模式下拦截热状态广播, 向 Darwin 通知压为 normal, 不走原生 */
- (void)setThermalState:(int)state {
    InsPowerMode mode;
    os_unfair_lock_lock(&gLock); mode = gPowerMode; os_unfair_lock_unlock(&gLock);
    if (mode == InsPowerModeFullPower) {
        ILog(@"insulation thermal state %@ -> Darwin pressure %d (%d)", @(state), 0, 0);
        notify_set_state(gRuntimeStateToken, 0);
        notify_post("com.apple.system.thermalpressurelevel");  /* kOSThermalNotificationPressureLevelName 值, 二进制字符串为证 */
        return;
    }
    %orig;
}

%end

#pragma mark - Hook 2: HidSensors  [UPSTREAM + NEW 电池温控放行点]

/*
 * ★★★ 电池温控的唯一放行点 ★★★
 * 原插件在此吞掉所有 HID 温度传感器事件(空实现, [UPSTREAM] 逐行一致),
 * 因此 SOC(CPU 温控输入) 与电池温度事件在同一处被拦截。
 * [NEW] 开关打开(gBatteryThermalReleased=YES) 时: 仅当该事件来自电池传感器,
 *       调用 %orig 放行 —— 电池温控永久交还苹果原生策略, 不看充电状态/温度。
 *       开关关闭时恒为 NO → 与原版逐字等价; CPU 相关事件任何情况下都不放行。
 */
%hook HidSensors

- (void)handleTemperatureEvent:(int)temp service:(id)service {
    os_unfair_lock_lock(&gLock);
    BOOL released = gBatteryThermalReleased;   // [NEW] 开关关闭时恒为 NO → 与原版逐字节等价
    os_unfair_lock_unlock(&gLock);

    if (released && InsIsBatteryThermalService(service)) {
        %orig;   // [NEW] 只放行电池传感器事件, 让 thermalmonitord 原生逻辑收到电池温度
        return;
    }
    /* [UPSTREAM] 原实现: 空函数, 吞掉温度事件 */
    return;
}

%end

#pragma mark - Hook 3: NSDictionary  [UPSTREAM + INFERRED 防暗屏补丁]

/*
 * [UPSTREAM] patchThermalPlist: 拉平 backlightComponentControl 的
 * BacklightBrightness/BacklightPower 数组, expectsCPMSSupport=0,
 * 可选以 cpuMinPowerValue 覆盖 maxThermalPower/minThermalPower。
 */
static NSDictionary *InsPatchThermalPlist(NSDictionary *origObj) {
    NSMutableDictionary *dict = [origObj mutableCopy];

    NSMutableDictionary *backlight = [dict[@"backlightComponentControl"] mutableCopy];
    if (backlight) {
        NSMutableArray *arr = [backlight[@"BacklightBrightness"] mutableCopy];
        if (arr.count > 0) {
            id first = arr.firstObject;
            for (NSUInteger i = 1; i < arr.count; i++) arr[i] = first;
            backlight[@"BacklightBrightness"] = arr;
        }
        arr = [backlight[@"BacklightPower"] mutableCopy];
        if (arr.count > 0) {
            id first = arr.firstObject;
            for (NSUInteger i = 1; i < arr.count; i++) arr[i] = first;
            backlight[@"BacklightPower"] = arr;
        }
        backlight[@"expectsCPMSSupport"] = @0;

        /* [UPSTREAM] cpuMinPowerValue (0.0.18 面板已不提供该 key, 保留以兼容旧配置) */
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:InsPrefsPath()];
        NSInteger powerValue = [[prefs[@"cpuMinPowerValue"] description] stringByTrimmingCharactersInSet:
                                [NSCharacterSet whitespaceAndNewlineCharacterSet]].integerValue;
        if (powerValue > 0) {
            backlight[@"maxThermalPower"] = @(powerValue);
            backlight[@"minThermalPower"] = @(powerValue);
        }

        /* [INFERRED] 防止温控暗屏: 关掉 display 相关缓解项
         * 证据: 字符串 displayBrightnessMitigation/displayMitigation/needsContextualClamp/
         * shouldEnforceLightThermalPressure/shouldEnforceThermalPressure/thermalPressureMitigation/
         * performanceMitigation + "insulation thermal manager dim patch exception: %@" (@try/@catch 痕迹) */
        BOOL preventDimming;
        os_unfair_lock_lock(&gLock); preventDimming = gPreventDimming; os_unfair_lock_unlock(&gLock);
        if (preventDimming) {
            @try {
                for (NSString *key in @[@"displayBrightnessMitigation", @"displayMitigation",
                                        @"thermalPressureMitigation", @"performanceMitigation"]) {
                    NSMutableDictionary *m = [backlight[key] mutableCopy];
                    if (m) {
                        m[@"enabled"] = @0;
                        backlight[key] = m;
                    }
                }
                backlight[@"needsContextualClamp"] = @0;
                backlight[@"shouldEnforceLightThermalPressure"] = @0;
                backlight[@"shouldEnforceThermalPressure"] = @0;
            } @catch (NSException *e) {
                ILog(@"insulation thermal manager dim patch exception: %@", e);
            }
        }
        dict[@"backlightComponentControl"] = backlight;
    }
    return dict;
}

%hook NSDictionary

+ (id)dictionaryWithContentsOfFile:(NSString *)path {
    id res = %orig;
    if ([path containsString:@"/System/Library/ThermalMonitor/"]) {
        if ([res isKindOfClass:[NSDictionary class]]) {
            return InsPatchThermalPlist(res);
        }
    }
    return res;
}

%end

#pragma mark - Hook 4: MitigationController  [EVIDENCE/INFERRED — CPU 不降频核心]

/*
 * [EVIDENCE] 类型编码 @40@0:8B16B20@24@32 ↔ initForFastLoop:noDisplay:powerSaveParams:powerZoneParams:
 * [EVIDENCE] 日志串 "insulation cpu level lock %d -> %d" / "insulation cpu level restore %d -> 0" /
 *            "insulation component %d power limit %d -> %d"
 * [INFERRED] fullPower 下: setCPULevel: 强制为 0(不限频); 功率 ceiling/floor 抬到观测最大值。
 * 这是 CPU 不降频的核心路径 —— 本改造对此不做任何改动。
 */
%hook MitigationController

- (id)initForFastLoop:(BOOL)fast noDisplay:(BOOL)noDisplay powerSaveParams:(id)psp powerZoneParams:(id)pzp {
    id res = %orig;
    gMitigationController = self;   /* [EVIDENCE] mitigationControllerObject */
    InsApplyPowerMode();            /* 启动时按当前模式应用一次 */
    InsDebugLog(@"initForFastLoop: 已按当前模式应用 (mc=%p)", (void *)(__bridge void *)self);
    return res;
}

- (void)setCPULevel:(int)level {
    /* [B] initForFastLoop 未命中时的兜底捕获点之一 */
    if (gMitigationController == nil) InsCaptureController(self);

    InsPowerMode mode;
    os_unfair_lock_lock(&gLock); mode = gPowerMode; os_unfair_lock_unlock(&gLock);
    if (mode == InsPowerModeFullPower && level != 0) {
        ILog(@"insulation cpu level lock %d -> %d", level, 0);
        %orig(0);        /* 强制 CPU level 0 = 不降频 */
        return;
    }
    /* [EVIDENCE] 0xb760..0xb964 (setCPULevel hook): lowPower 下目标恒为 2;
     * 非 2 的调用都会被改成 2, 并打印 "insulation cpu level lock %d -> %d"。
     * [FIX] 原实现钳制到 1 是错的 —— 原版 lowPower 档位是 2。 */
    if (mode == InsPowerModeLowPower && level != 2) {
        ILog(@"insulation cpu level lock %d -> %d", level, 2);
        %orig(2);
        return;
    }
    %orig;
}

- (void)updateCPU {
    /* [B] 兜底捕获点之二: thermalmonitord 热循环会周期性调用 updateCPU */
    if (gMitigationController == nil) InsCaptureController(self);
    %orig;
}

- (void)setCPUPowerCeiling:(int)ceiling fromDecisionSource:(int)src {
    if (ceiling > (int)gObservedCPUPowerMax) gObservedCPUPowerMax = ceiling;  /* 记录观测到的上限 */
    InsPowerMode mode;
    os_unfair_lock_lock(&gLock); mode = gPowerMode; os_unfair_lock_unlock(&gLock);
    if (mode == InsPowerModeFullPower && gObservedCPUPowerMax > 0 && ceiling < (int)gObservedCPUPowerMax) {
        ILog(@"insulation component %d power limit %d -> %d", 0, ceiling, gObservedCPUPowerMax);
        %orig((int)gObservedCPUPowerMax, src);
        return;
    }
    %orig;
}

- (void)setCPUPowerFloor:(int)floor_ fromDecisionSource:(int)src {
    %orig;   /* [INFERRED] floor 不干预 */
}

- (void)setCPUPowerZoneTarget:(int)target {
    InsPowerMode mode;
    os_unfair_lock_lock(&gLock); mode = gPowerMode; os_unfair_lock_unlock(&gLock);
    if (mode == InsPowerModeFullPower && gObservedCPUPowerMax > 0 && target < (int)gObservedCPUPowerMax) {
        ILog(@"insulation component %d power limit %d -> %d", 0, target, gObservedCPUPowerMax);
        %orig((int)gObservedCPUPowerMax);
        return;
    }
    %orig;
}

- (void)setCPMSMitigationsEnabled:(BOOL)enabled {
    InsPowerMode mode;
    os_unfair_lock_lock(&gLock); mode = gPowerMode; os_unfair_lock_unlock(&gLock);
    if (mode == InsPowerModeFullPower && enabled) {
        ILog(@"thermalPowerMode fullPower -> thermal mitigations disabled (%d)", 1);
        %orig(NO);
        return;
    }
    %orig;
}

%end

#pragma mark - Hook 5: ComponentControl  [EVIDENCE/INFERRED]

/*
 * [EVIDENCE] 类型编码 I16@0:8 (unsigned getter): currentPower/powerTarget/computePowerTarget
 * [INFERRED] fullPower 下 powerTarget 不低于观测到的全局最大值 → 功率目标不被热缓解压低。
 */
%hook ComponentControl

- (unsigned)powerTarget {
    unsigned orig = %orig;
    InsPowerMode mode;
    os_unfair_lock_lock(&gLock); mode = gPowerMode; os_unfair_lock_unlock(&gLock);
    if (mode == InsPowerModeFullPower && gObservedComponentPowerGlobalMax > orig) {
        ILog(@"insulation component %d power limit %d -> %d", self.mitigationType, orig, gObservedComponentPowerGlobalMax);
        return gObservedComponentPowerGlobalMax;
    }
    return orig;
}

- (unsigned)computePowerTarget {
    unsigned orig = %orig;
    InsPowerMode mode;
    os_unfair_lock_lock(&gLock); mode = gPowerMode; os_unfair_lock_unlock(&gLock);
    if (mode == InsPowerModeFullPower && gObservedComponentPowerGlobalMax > orig) {
        return gObservedComponentPowerGlobalMax;
    }
    return orig;
}

%end

#pragma mark - Hook 6: CPMSHelper  [EVIDENCE/INFERRED]

/*
 * [EVIDENCE] 类型编码 I24@0:8q16 ↔ getMaxPowerForComponent:/getMinPowerForComponent:
 * [INFERRED] fullPower 下: 记录并抬高各组件功率上限 (解除 CPMS 功率钳制)。
 */
%hook CPMSHelper

- (unsigned)getMaxPowerForComponent:(int)component {
    unsigned orig = %orig;
    if (orig > gObservedComponentPowerGlobalMax) gObservedComponentPowerGlobalMax = orig;
    InsPowerMode mode;
    os_unfair_lock_lock(&gLock); mode = gPowerMode; os_unfair_lock_unlock(&gLock);
    if (mode == InsPowerModeFullPower && gObservedComponentPowerGlobalMax > orig) {
        ILog(@"insulation component %d power limit %d -> %d", component, orig, gObservedComponentPowerGlobalMax);
        return gObservedComponentPowerGlobalMax;
    }
    return orig;
}

- (unsigned)getMinPowerForComponent:(int)component {
    return %orig;   /* 下限不动 */
}

%end

#pragma mark - 初始化  [UPSTREAM InsulationTInit + NEW]

/* [NEW] 原版重启语义: 面板只发 Darwin 通知(无权杀 root daemon),
 *       由 thermalmonitord 内的本 tweak 自己 kill(getpid(), SIGKILL),
 *       launchd(KeepAlive) 拉起 → ctor 重新读偏好并由 initForFastLoop: 应用模式。
 *       证据: 原 deb 导入 _kill/_getpid, 字符串 "insulation: restarting thermalmonitord
 *       after CPU mode change" + 通知名 com.be-huge.insulation-restartThermalMonitor。
 *       自保护: 模式未变化 / 已在重启流程中 → 不重启, 避免通知抖动造成重启循环。 */
static BOOL gRestartInProgress = NO;
/* 本进程启动时读到的模式(ctor 里写入)。重启判断必须与它比较, 不能与 gPowerMode 比较:
 * executePuppet 通知会先把同进程内的 gPowerMode 更新为新值, 若比较它会永远认为"没变化"而跳过重启。 */
static InsPowerMode gStartupPowerMode = InsPowerModeOff;

static void InsOnRestartRequested(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                  const void *object, CFDictionaryRef userInfo) {
    NSString *path = InsPrefsPath();
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:path];
    if (!p) p = [NSDictionary dictionaryWithContentsOfFile:kInsPrefsPathRel];
    NSString *raw = [p[kPrefPowerMode] isKindOfClass:[NSString class]] ? p[kPrefPowerMode] : @"off";

    InsPowerMode target;
    if ([raw isEqualToString:@"lowPower"])       target = InsPowerModeLowPower;
    else if ([raw isEqualToString:@"fullPower"]) target = InsPowerModeFullPower;
    else                                          target = InsPowerModeOff;

    os_unfair_lock_lock(&gLock);
    InsPowerMode startup = gStartupPowerMode;
    BOOL busy = gRestartInProgress;
    if (!busy) gRestartInProgress = YES;
    os_unfair_lock_unlock(&gLock);

    if (busy) {
        InsDebugLog(@"重启请求忽略: 已有重启流程在进行");
        return;
    }
    if (target == startup) {
        ILog(@"重启请求忽略: 模式未变化(%@)", raw);
        InsDebugLog(@"重启请求忽略: 模式未变化(%@)", raw);
        os_unfair_lock_lock(&gLock); gRestartInProgress = NO; os_unfair_lock_unlock(&gLock);
        return;
    }

    ILog(@"收到重启请求: 启动模式=%ld -> 目标模式=%ld (0.4s 后重启 thermalmonitord)", (long)startup, (long)target);
    InsDebugLog(@"收到重启请求: 启动模式=%ld -> 目标模式=%ld", (long)startup, (long)target);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        ILog(@"insulation: restarting thermalmonitord after CPU mode change");
        InsDebugLog(@"kill(getpid()=%d, SIGKILL), 目标模式=%ld", getpid(), (long)target);
        kill(getpid(), SIGKILL);   /* [INFERRED] 原版用 _kill/_getpid 重启, 信号未逐字节确认 */
    });
}

static void InsOnPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    os_unfair_lock_lock(&gLock);
    InsPowerMode beforeMode = gPowerMode;
    BOOL beforeReleased = gBatteryThermalReleased;
    os_unfair_lock_unlock(&gLock);

    InsReloadPrefs();
    NSString *n = (__bridge NSString *)name;
    BOOL isPuppet  = [n isEqualToString:@kInsNotifExecutePuppet];
    BOOL isBattery = [n isEqualToString:@kInsNotifBatteryChanged];

    if (isPuppet) {
        /* [UPSTREAM] executePuppetEvent → 应用 thermalPowerMode (0.0.18 的 puppet 即 power mode) */
        InsApplyPowerMode();
        InsApplyAdvancedSwitches();
    }

    os_unfair_lock_lock(&gLock);
    BOOL modeSame     = (gPowerMode == beforeMode);
    BOOL releasedSame = (gBatteryThermalReleased == beforeReleased);
    os_unfair_lock_unlock(&gLock);

    /* [FIX] 面板写 cfprefsd 到文件落盘有微小延迟: 通知先到、文件还是旧值时,
     *       0.4s 后再重读一次; 只处理确实变了的情况(幂等, 不改原语义)。
     *       电池开关只需重读(热路径直接读 gBatteryThermalReleased), 不需要 apply。 */
    if ((isPuppet && modeSame) || (isBattery && releasedSame)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            InsReloadPrefs();

            os_unfair_lock_lock(&gLock);
            BOOL modeChanged = (gPowerMode != beforeMode);
            os_unfair_lock_unlock(&gLock);

            if (isPuppet && modeChanged) {
                ILog(@"[recheck] thermalPowerMode 已更新, 重新应用");
                InsApplyPowerMode();
                InsApplyAdvancedSwitches();
            }
        });
    }

    /* [NEW] 「电池原生温控」开关: InsReloadPrefs 已把开关状态直通到
     *       gBatteryThermalReleased(不做充电/温度判断), 此处无需再求值;
     *       控制权变化日志已在 InsReloadPrefs 内输出。 */
}

%ctor {
    @autoreleasepool {
        /* [A] 心跳: 证明代码执行到了 ctor、以什么身份执行; 位于 %init 之前。 */
        InsDebugLog(@"hello pid=%d uid=%d euid=%d mode=%ld",
                    getpid(), getuid(), geteuid(), (long)gPowerMode);

        InsReloadPrefs();

        /* [EVIDENCE] runtime state notify token */
        notify_register_check(kInsNotifRuntimeState, &gRuntimeStateToken);

        /* Darwin 通知监听 (原插件: executePuppetEvent; [NEW] 新增 batteryProtectChanged) */
        CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(center, NULL, InsOnPrefsChanged,
                                        CFSTR(kInsNotifExecutePuppet), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(center, NULL, InsOnPrefsChanged,
                                        CFSTR(kInsNotifBatteryChanged), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        /* [NEW] 面板切换 CPU 模式后请求重启 daemon (原版语义) */
        CFNotificationCenterAddObserver(center, NULL, InsOnRestartRequested,
                                        CFSTR(kInsNotifRestartTM), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        %init;

        /* daemon 启动路径: ctor 已读到新的 thermalPowerMode; 此处若 MitigationController
         * 尚未创建则自动推迟, 由 initForFastLoop: 应用。
         * [B] 再叠加 2s 定时兜底(最多 5 次): 即使 initForFastLoop: 未命中也能补 apply。 */
        InsApplyPowerMode();
        InsFallbackApply(1);

        os_unfair_lock_lock(&gLock);
        InsPowerMode startupMode = gPowerMode;
        BOOL startupProtect = gChargingProtectEnabled;
        BOOL startupReleased = gBatteryThermalReleased;
        gStartupPowerMode = startupMode;   /* 重启判据的基准: 本进程启动时的模式 */
        os_unfair_lock_unlock(&gLock);

        ILog(@"insulation loaded (Logos 重建版 + 电池原生温控开关) | mode=%ld | 开关=%@ | 电池温控控制权:%@ | CPU 路径不受影响(永不放行)",
             (long)startupMode,
             startupProtect ? @"开" : @"关",
             startupReleased ? @"已永久交还原生" : @"插件接管(原行为)");
        InsDebugLog(@"ctor 启动: pid=%d mode=%ld 开关=%@ 控制权=%@ mc=%p",
                    getpid(), (long)startupMode,
                    startupProtect ? @"开" : @"关",
                    startupReleased ? @"已永久交还原生" : @"插件接管(原行为)",
                    (void *)(__bridge void *)gMitigationController);
    }
}
