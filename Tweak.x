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
/* [FIX][SAFETY] 不再自杀重启 thermalmonitord; 保留 unistd.h 供 getpid/getuid/geteuid */
#import <unistd.h>         /* [NEW] getpid/getuid/geteuid */
#import <stdarg.h>         /* [MODIFIED] va_list — InsDebugLog 改用 NSLog */

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

/* [MODIFIED] 放弃落盘日志: 设备实测 9 条候选路径 + HOME 全部失败
 *   (thermalmonitord 的 sandbox 不允许写这些位置, 与 uid 无关)。
 *   改为统一 NSLog → Apple 统一日志, 设备侧 Console.app / PC 侧 idevicesyslog 可见。
 *   Console 过滤方式见交付说明: 进程名 thermalmonitord 或消息含 "Insulation"。 */
static void InsDebugLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[Insulation] pid=%d %@", getpid(), line);
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
- (void)setCPULowPowerTarget:(int)a3;
- (void)setCPUPowerCeiling:(int)a3 fromDecisionSource:(int)a4;
- (void)setCPUPowerFloor:(int)a3 fromDecisionSource:(int)a4;
- (void)setCPUPowerZoneTarget:(int)a3;
- (void)setMaxPackagePower:(int)a3;
- (void)setPowerSaveActive:(BOOL)a3;
- (void)updateCPU;
- (void)updateGPU;
- (void)updatePackage;
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
    BOOL fullPower = (gPowerMode == InsPowerModeFullPower);
    os_unfair_lock_unlock(&gLock);

    /* [EVIDENCE] 0xc3d0..0xc450: fullPower ↔ "engageBehavior=false / engageBehaviorPersistentlyEnabled=true",
     *           其他模式 → Reset (移除两个键)。对应日志 "thermalPowerMode fullPower -> thermal mitigations disabled (%d)"。
     *           [EVIDENCE] 0x13f64 insulationSetThermalMitigationsEnabled 的写键为 engageBehavior/engageBehaviorPersistentlyEnabled。 */
    InsSCSetValue(CFSTR("engageBehavior"), fullPower ? kCFBooleanFalse : NULL);
    InsSCSetValue(CFSTR("engageBehaviorPersistentlyEnabled"), fullPower ? kCFBooleanTrue : NULL);

    /* [EVIDENCE] SetOSNotifEnabled 写键: OSThermalNotificationEnabled / OSThermalNotificationPersistentlyEnabled;
     *           开启分支实参 (0,1) → 键值 (false, true); 关闭分支走 Reset(移除)。 */
    InsSCSetValue(CFSTR("OSThermalNotificationEnabled"), suppress ? kCFBooleanFalse : NULL);
    InsSCSetValue(CFSTR("OSThermalNotificationPersistentlyEnabled"), suppress ? kCFBooleanTrue : NULL);
    ILog(@"thermalSuppressNotificationsEnabled: %@ -> %d", suppress ? @"on" : @"off", suppress);

    /* [EVIDENCE] SetHIPEnabled 写键: hipOverride / hipPersistentlyEnabled, 实参 (0,1) → (false, true);
     *           随后 SetSimulateHIPEnabled 写 simulateHip=false; 关闭分支 ResetHIP + ResetSimulateHIP。 */
    InsSCSetValue(CFSTR("hipOverride"), pocket ? kCFBooleanFalse : NULL);
    InsSCSetValue(CFSTR("hipPersistentlyEnabled"), pocket ? kCFBooleanTrue : NULL);
    InsSCSetValue(CFSTR("simulateHip"), pocket ? kCFBooleanFalse : NULL);
    ILog(@"thermalDisablePocketSunlightEnabled: %@ -> %d/%d", pocket ? @"on" : @"off", pocket, 0);

    /* [EVIDENCE] SetSunlightOverride 写键: sunlightOverride / sunlightOverridePersistentlyEnabled, 实参 (1,1) → (true, true)。 */
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
 *   [EVIDENCE] 全二进制中 setCPULevel:/setPowerSaveActive:/updateCPU 的 msgSend 只出现在
 *   applyPowerMode(0xbe04) 内; 其余命中都是 ctor 里的 class_getInstanceMethod 安装点
 *   (0x143e4 = setCPMSMitigationsEnabled: 的 method_setImplementation) 或 Swift 惰性 selector
 *   (0x18c30)。即: lowPower 之外没有任何代码再改 CPU 档位。
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
        case InsPowerModeFullPower: {
            /* [EVIDENCE] 0xbe90..0xbf3c fullPower 分支:
             *   updateCPU → PS:NO → CPULevel:0
             *   → setCPULowPowerTarget:max([self+0x38], 0xC350=50000)
             *   → setCPUPowerCeiling:…fromDecisionSource:0 → setCPUPowerFloor:0… → setCPUPowerZoneTarget:…
             *   ([self+0x38] 对应 IPowerHepler.observedCPUPowerMax) */
            unsigned cap = gObservedCPUPowerMax > 50000u ? gObservedCPUPowerMax : 50000u;
            [mc updateCPU];
            [mc setPowerSaveActive:NO];
            [mc setCPULevel:0];
            [mc setCPULowPowerTarget:(int)cap];
            [mc setCPUPowerCeiling:(int)cap fromDecisionSource:0];
            [mc setCPUPowerFloor:0 fromDecisionSource:0];
            [mc setCPUPowerZoneTarget:(int)cap];
            ILog(@"insulation: full power mode");
            ILog(@"thermalPowerMode fullPower -> thermal mitigations disabled (%d)", 0);
            break;
        }
        case InsPowerModeLowPower:
            /* [EVIDENCE] 与 0xbe04 的 lowPower 分支逐指令一致 (0xc020..0xc0e4):
             *   档位是 2, 不是 1。顺序: PS:YES → CPULevel:2 → updateCPU → PS:YES → CPULevel:2。
             *   该分支不调用 setCPMSMitigationsEnabled:/CPUPowerCeiling/ZoneTarget。 */
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
            /* [EVIDENCE] 0xc190..0xc2d4 off/native 分支:
             *   PS:NO → CPULevel:0 → updateCPU → updateGPU → updatePackage → PS:NO → CPULevel:0 */
            [mc setPowerSaveActive:NO];
            [mc setCPULevel:0];
            [mc updateCPU];
            [mc updateGPU];
            [mc updatePackage];
            [mc setPowerSaveActive:NO];
            [mc setCPULevel:0];
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

#pragma mark - [EVIDENCE] 热抑制判定 (对应 0.0.18 CommonProduct 手装 hook 的公共守卫)

/*
 * [EVIDENCE] 0.0.18 arm64 slice:
 *   - 0x14174 objc_getClass("CommonProduct") 之后逐个 class_getInstanceMethod + method_setImplementation,
 *     共安装 15 个方法 (见下方 Hook 1 新增段)。
 *   - 每个方法开头调用两个辅助函数:
 *       0x14e14 → 读 com.be-huge.insulation-prefs.plist 的 thermalPreventDimmingEnabled(bool)
 *       0x14ea0 → 同一 plist 的 thermalPowerMode == "fullPower"
 *     即公共守卫 = 防暗屏开关 || fullPower 模式。
 */
static BOOL InsShouldSuppressThermal(void) {
    os_unfair_lock_lock(&gLock);
    BOOL dim  = gPreventDimming;
    BOOL full = (gPowerMode == InsPowerModeFullPower);
    os_unfair_lock_unlock(&gLock);
    return dim || full;
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
 * [EVIDENCE] 手装 hook 0x1451c 的判定: 防暗屏开 → 不调原生; 否则 fullPower 且 state!=0 → 不调原生;
 *           其余(含 fullPower + state==0) → 调原生。 */
- (void)setThermalState:(int)state {
    os_unfair_lock_lock(&gLock);
    BOOL dim  = gPreventDimming;
    BOOL full = (gPowerMode == InsPowerModeFullPower);
    os_unfair_lock_unlock(&gLock);

    if (full && state != 0) {
        ILog(@"insulation thermal state %@ -> Darwin pressure %d (%d)", @(state), 0, 0);
        notify_set_state(gRuntimeStateToken, 0);
        notify_post("com.apple.system.thermalpressurelevel");  /* kOSThermalNotificationPressureLevelName 值, 二进制字符串为证 */
        return;
    }
    if (dim) return;
    %orig;
}

/* ===== [EVIDENCE] 以下 14 个方法为 0.0.18 在 CommonProduct 上额外手装的 hook
 *       (注册点 0x14174 objc_getClass("CommonProduct") → 0x144b8..0x14dc4 的 block)。
 *       守卫统一为 InsShouldSuppressThermal() (= 防暗屏 || fullPower), 行为按各 block 反汇编实现。 */

/* 0x144b8: 抑制热压力档位 */
- (int)thermalPressureLevel {
    if (InsShouldSuppressThermal()) return 0;
    return %orig;
}

/* 0x14590: 抑制潜在强制压力档位 */
- (BOOL)getPotentialForcedThermalPressureLevel {
    if (InsShouldSuppressThermal()) return NO;
    return %orig;
}

/* 0x145f4: 抑制潜在强制热档位 */
- (id)getPotentialForcedThermalLevel:(id)a3 {
    if (InsShouldSuppressThermal()) return nil;
    return %orig;
}

/* 0x14684: 强制把看门狗上报参数改为 NO, 但仍调用原生 */
- (void)thermalUpdatesToWatchdogEnabled:(BOOL)enabled {
    if (InsShouldSuppressThermal()) { %orig(NO); return; }
    %orig;
}

/* 0x14704: fullPower/防暗屏时改写热配置字典 (对应原版"解除温控"的核心运行时补丁)
 *   键表 (0x24dc0..0x24f40) 与取值 (false/0/50000=0xC350) 均来自反汇编。
 *   防暗屏为真时额外压掉 3 个显示相关键。 */
- (id)getConfigurationFor:(id)a3 {
    id cfg = %orig;
    os_unfair_lock_lock(&gLock);
    BOOL dim  = gPreventDimming;
    BOOL full = (gPowerMode == InsPowerModeFullPower);
    os_unfair_lock_unlock(&gLock);
    if ((!dim && !full) || ![cfg isKindOfClass:[NSDictionary class]]) return cfg;

    NSMutableDictionary *d = [cfg mutableCopy];
    if (dim) {
        d[@"needsPushingTSFDtoDisplayDriver"] = @NO;
        d[@"displayBrightnessMitigation"]     = @NO;
        d[@"displayMitigation"]               = @NO;
    }
    d[@"needsContextualClamp"]            = @NO;
    d[@"shouldEnforceLightThermalPressure"] = @NO;
    d[@"shouldEnforceThermalPressure"]     = @NO;
    d[@"thermalPressureMitigation"]        = @NO;
    d[@"performanceMitigation"]            = @NO;
    d[@"CPMSMitigationState"]              = @0;
    d[@"CPMSMitigationLevel"]              = @0;
    d[@"forcedThermalLevel"]               = @0;
    d[@"maxPower"]                         = @50000;
    d[@"packagePowerTarget"]               = @50000;
    return d;
}

/* 0x149f8 / 0x14a88 / 0x14b18: 吞掉热建议与热缓解决策, 返回 nil */
- (id)getThermalSuggestion:(id)a3 {
    if (InsShouldSuppressThermal()) return nil;
    return %orig;
}
- (id)thermalSuggestion:(id)a3 {
    if (InsShouldSuppressThermal()) return nil;
    return %orig;
}
- (id)thermalMitigation:(id)a3 {
    if (InsShouldSuppressThermal()) return nil;
    return %orig;
}

/* 0x14ba8: 热压力决策改回 @0 (注意是 NSNumber 0, 不是 nil) */
- (id)thermalPressure:(id)a3 {
    if (InsShouldSuppressThermal()) return @0;
    return %orig;
}

/* 0x14c3c: DVD1 档位强制 0, 仍调用原生 */
- (void)setDVD1Level:(int)level {
    if (InsShouldSuppressThermal()) { %orig(0); return; }
    %orig;
}

/* 0x14ca0: CPMS 缓解开关 (防暗屏→NO; fullPower→NO; 否则原值) */
- (void)setCPMSMitigationsEnabled:(BOOL)enabled {
    if (InsShouldSuppressThermal()) { %orig(NO); return; }
    %orig;
}

/* 0x14d0c: 最大封装功耗抬到 0xC350(50000), 仍调用原生 */
- (void)setMaxPackagePower:(int)power {
    if (InsShouldSuppressThermal()) { %orig(50000); return; }
    %orig;
}

/* 0x14d74 / 0x14dc4: 低功耗目标 / 功率区目标 直接吞掉 */
- (void)setPackageLowPowerTarget:(int)target {
    if (InsShouldSuppressThermal()) return;
    %orig;
}
- (void)setPackagePowerZoneTarget:(int)target {
    if (InsShouldSuppressThermal()) return;
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
/* [EVIDENCE] 前置声明: 重试表实现见 "初始化" 段 (0xc8bc 的 0.25/1/2/4/6/8/10s) */
static void InsReapplySoon(int attempt, NSString *tag);

%hook MitigationController

- (id)initForFastLoop:(BOOL)fast noDisplay:(BOOL)noDisplay powerSaveParams:(id)psp powerZoneParams:(id)pzp {
    id res = %orig;
    /* [EVIDENCE] 0xef6c..0xef80 (MitigationControllerHook.initForFastLoop 内部):
     *   0xef68 x0 = ClassHook.target (= 本方法 self)
     *   0xef70 str x0,[x23,#0x60]  → IPowerHepler.mitigationControllerObject(+0x60)
     *   0xef80 bl 0xcc2c           → 立即 applyPowerMode
     * 结论: x21(+0x60) 与本方法 self 是同一对象; 且原版每次 init 都覆盖。
     *       我们这里必须"每次无条件覆盖", 不能只在 nil 时捕获(否则会拿到过期实例)。 */
    os_unfair_lock_lock(&gLock);
    gMitigationController = self;   /* [EVIDENCE] mitigationControllerObject */
    os_unfair_lock_unlock(&gLock);

    InsReloadPrefs();
    InsApplyPowerMode();            /* 与原版一致: init 返回后立即下发 */
    InsReapplySoon(1, @"initForFastLoop");
    InsDebugLog(@"initForFastLoop: controller 绑定 mc=%p mode=%ld", 
                (void *)(__bridge void *)self, (long)gPowerMode);
    return res;
}

- (void)setCPULevel:(int)level {
    /* [B] initForFastLoop 未命中时的兜底捕获点之一 */
    if (gMitigationController == nil) InsCaptureController(self);

    InsPowerMode mode;
    os_unfair_lock_lock(&gLock); mode = gPowerMode; os_unfair_lock_unlock(&gLock);
    /* [DIAG] 决定性证据: 打印系统/自身每次 setCPULevel: 的实例与档位,
     *   Console 里能看到 "level=2" 是否真的落地、以及 daemon 自己是否又把它改回去。 */
    InsDebugLog(@"setCPULevel: self=%p level=%d mode=%ld",
                (void *)(__bridge void *)self, level, (long)mode);
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

/* [FIX][SAFETY] 不再 kill thermalmonitord。
 *   [EVIDENCE] 原版对 -restartThermalMonitor 的真实做法 (0x13240 → 0x1343c → 0x137f0):
 *     DispatchQueue.global().asyncAfter(.now() + 0.2s) { 0x13400:
 *       NSLog("insulation: restarting thermalmonitord after CPU mode change");
 *       kill(getpid(), SIGKILL); }
 *   即在系统原生环境里靠 launchd 重新拉起 daemon, 由新的 initForFastLoop 应用档位。
 *   实测 (Dopamine 2.4.9.25 隐根 / iOS 15): kill(getpid(), SIGKILL) 后 launchd 没有把该 daemon
 *   拉起, `ps -A | grep thermalmonitord` 为空 → 热控进程缺失、日志为零、频率不降。
 *   结论: "SIGKILL + KeepAlive" 在本机不可靠, 安全优先, 彻底去掉自杀重启。
 *   替代: 进程内重应用, 延迟序列与原版 0xc8bc 的重试表一致 (0.25/1/2/4/6/8/10s),
 *   再配合 setCPULevel: 常驻钳制把 level 锁在 2。
 *   launchctl kickstart 的 label 需设备侧 `launchctl list | grep -i thermal` 取证;
 *   在未取证前不盲调外部 launchctl —— 避免再次把 daemon 停掉却拉不起来。
 *   [INFERRED] 进程内重应用能覆盖 daemon 内部状态: apply 直接调 MitigationController 的
 *   setPowerSaveActive:/setCPULevel:/updateCPU, 与 daemon 自身热循环走同一入口。
 */
static BOOL gReapplyInProgress = NO;

/* [EVIDENCE] 0xc8bc 的重试表: d8 = [0x29e28 + i + 0x28] (double),
 *   实测常量序列 0.25 / 1 / 2 / 4 / 6 / 8 / 10 秒。原版在每次 refresh 后按此序列补刀。 */
static const double kInsReapplyDelays[] = {0.25, 1.0, 2.0, 4.0, 6.0, 8.0, 10.0};

static void InsReapplySoon(int attempt, NSString *tag) {
    int total = (int)(sizeof(kInsReapplyDelays) / sizeof(kInsReapplyDelays[0]));
    if (attempt < 1 || attempt > total) return;
    NSTimeInterval delay = kInsReapplyDelays[attempt - 1];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        InsReloadPrefs();
        InsApplyPowerMode();
        InsPowerMode mode;
        os_unfair_lock_lock(&gLock); mode = gPowerMode; os_unfair_lock_unlock(&gLock);
        InsDebugLog(@"reapply(%@): attempt=%d/%d delay=%.2fs mode=%ld pid=%d",
                    tag, attempt, total, delay, (long)mode, getpid());
        InsReapplySoon(attempt + 1, tag);
    });
}

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
    BOOL busy = gReapplyInProgress;
    if (!busy) gReapplyInProgress = YES;
    os_unfair_lock_unlock(&gLock);

    if (busy) {
        InsDebugLog(@"重应用请求忽略: 已有流程在进行");
        return;
    }

    InsDebugLog(@"模式切换通知: 目标=%ld(%@), 改为进程内重应用(不重启 daemon)", (long)target, raw);

    /* 先刷新 gPowerMode, 让 setCPULevel: hook 立即按新档位钳制, 再主动 apply 一次 */
    InsReloadPrefs();
    InsApplyPowerMode();
    InsReapplySoon(1, @"mode-change");

    /* 0.5s 后释放去抖, 允许用户连续切换 */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        os_unfair_lock_lock(&gLock); gReapplyInProgress = NO; os_unfair_lock_unlock(&gLock);
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
        /* [A] 心跳: 证明 dylib 被注入到了哪个进程、以什么身份执行; 位于 %init 之前。
         *     Console 过滤 "INS_LOAD" 即可确认是否加载进 thermalmonitord。 */
        InsDebugLog(@"INS_LOAD hello uid=%d euid=%d mode=%ld", getuid(), geteuid(), (long)gPowerMode);

        InsReloadPrefs();

        /* [EVIDENCE] runtime state notify token */
        notify_register_check(kInsNotifRuntimeState, &gRuntimeStateToken);

        /* Darwin 通知监听 (原插件: executePuppetEvent; [NEW] 新增 batteryProtectChanged) */
        CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(center, NULL, InsOnPrefsChanged,
                                        CFSTR(kInsNotifExecutePuppet), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(center, NULL, InsOnPrefsChanged,
                                        CFSTR(kInsNotifBatteryChanged), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        /* [FIX] 面板切换 CPU 模式后只发信号 → 进程内重应用; 通知名沿用原版协议 */
        CFNotificationCenterAddObserver(center, NULL, InsOnRestartRequested,
                                        CFSTR(kInsNotifRestartTM), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        %init;

        /* daemon 启动路径: ctor 已读到新的 thermalPowerMode; 若 MitigationController
         * 尚未创建则自动推迟, 由 initForFastLoop: 应用(并附带 0.25~10s 重试表)。
         * [B] 再叠加 2s 定时兜底(最多 5 次): 即使 initForFastLoop: 未命中也能补 apply。 */
        InsApplyPowerMode();
        InsFallbackApply(1);

        os_unfair_lock_lock(&gLock);
        InsPowerMode startupMode = gPowerMode;
        BOOL startupProtect = gChargingProtectEnabled;
        BOOL startupReleased = gBatteryThermalReleased;
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
