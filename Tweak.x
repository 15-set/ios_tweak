/*
 * =====================================================================================
 *  Insulation (解除温控) — Logos 重建版 + 「充电电池温控保护」改造
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
#import <math.h>          /* [BUILD-FIX] isnan / NAN 显式引入, 不依赖 Foundation 间接包含 */
#import <notify.h>
#import <os/lock.h>
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>          /* [BUILD-FIX-C] dlsym: SCPreferences* 在 iOS SDK 标记 unavailable, 改运行时取符号 */

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

/* [NEW] 新增偏好 key —— 严格按需求原文命名 (chraging 为需求中的原拼写, 不改名) */
#define kPrefChargingBatteryProtect       @"chragingBatteryThermalProtect"       // [NEW] 开关, 默认 NO
#define kPrefChargingBatteryTempThreshold @"chargingBatteryTempThreshold"        // [NEW] 整数, 默认 45, 范围 35~50

#define kInsThresholdMin 35   // [NEW]
#define kInsThresholdMax 50   // [NEW]
#define kInsThresholdDefault 45   // [NEW]
#define kInsHysteresisDelta 2.0f  // [NEW] 回差: 温度回落 2℃ 后才恢复插件控制
#define kInsTempPollInterval 5.0  // [NEW] 电池温度低频轮询周期(秒), 详见 CHANGES.md 耗电说明

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
- (id)initForFastLoop:(BOOL)a3 noDisplay:(BOOL)a4 powerSaveParams:(id)a5 powerZoneParams:(id)a6;
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

#pragma mark - [NEW] IOKit / IOPowerSources 私有声明 (iOS 上无公开头文件, 符号长期稳定)

/* [BUILD-FIX-B] SDK 自带 IOKit ps 头则优先使用; 不存在则回落手写 extern (符号长期稳定, ABI 一致) */
#if __has_include(<IOKit/ps/IOPowerSources.h>)
    #import <IOKit/ps/IOPowerSources.h>
    #import <IOKit/ps/IOPSKeys.h>
#else
    typedef void (*IOPowerSourceCallbackType)(void *context);
    extern CFRunLoopSourceRef IOPSNotificationCreateRunLoopSource(IOPowerSourceCallbackType callback, void *context);
    extern CFTypeRef IOPSCopyPowerSourcesInfo(void);
    extern CFArrayRef IOPSCopyPowerSourcesList(CFTypeRef blob);
    extern CFDictionaryRef IOPSGetPowerSourceDescription(CFTypeRef blob, CFTypeRef ps);
#endif

/* IOHIDServiceClient 属性读取 (IOKit 导出, thermalmonitord 进程内可用) */
typedef const struct __IOHIDServiceClient *IOHIDServiceClientRef;
extern CFTypeRef IOHIDServiceClientGetProperty(IOHIDServiceClientRef service, CFStringRef key);

/* IOPS 字典键 (IOPSKeys.h 等价物) */
#define kInsIOPSType           CFSTR("Type")
#define kInsIOPSInternalBatt   CFSTR("InternalBattery")
#define kInsIOPSIsCharging     CFSTR("IsCharging")
#define kInsIOPSIsPresent      CFSTR("IsPresent")
#define kInsIOPSTemperature    CFSTR("Temperature")

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

#pragma mark - [NEW] 充电电池温控保护 状态机

/*
 * 滞回状态机 (施密特触发):
 *   PLUGIN_CONTROL  --(充电中 && 温度 >= 阈值)-->          NATIVE_RELEASED
 *   NATIVE_RELEASED --(温度 <= 阈值-2 || 拔线 || 开关关)-->  PLUGIN_CONTROL
 * 阈值附近抖动不会引起反复切换 (2℃ 回差)。
 */
static BOOL     gChargingProtectEnabled = NO;    /* [NEW] key: chragingBatteryThermalProtect */
static NSInteger gBatteryTempThreshold = kInsThresholdDefault; /* [NEW] key: chargingBatteryTempThreshold */
static BOOL     gIsCharging = NO;                /* [NEW] 由 IOPS 电源通知驱动, 非轮询 */
static float    gLastBatteryTempC = NAN;         /* [NEW] 最近一次电池温度(℃), NaN = 读取失败 */
static BOOL     gBatteryThermalReleased = NO;    /* [NEW] NO=插件接管(原行为) / YES=电池温控已交原生 */

#pragma mark - 偏好读取

static void InsReloadPrefs(void) {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:InsPrefsPath()] ?: @{};

    os_unfair_lock_lock(&gLock);

    NSString *mode = [p[kPrefPowerMode] isKindOfClass:[NSString class]] ? p[kPrefPowerMode] : @"off";
    if ([mode isEqualToString:@"lowPower"])      gPowerMode = InsPowerModeLowPower;
    else if ([mode isEqualToString:@"fullPower"]) gPowerMode = InsPowerModeFullPower;
    else                                          gPowerMode = InsPowerModeOff;

    gPreventDimming        = [p[kPrefPreventDimming] boolValue];
    gSuppressNotifications = [p[kPrefSuppressNotifications] boolValue];
    gDisablePocketSunlight = [p[kPrefDisablePocketSunlight] boolValue];
    gSunlightLocked        = [p[kPrefSunlightLocked] boolValue];

    /* [NEW] 开关默认关闭; 阈值读取时 clamp 到 [35,50], 缺省 45 */
    gChargingProtectEnabled = [p[kPrefChargingBatteryProtect] boolValue];
    id thObj = p[kPrefChargingBatteryTempThreshold];
    NSInteger th = thObj ? [thObj integerValue] : kInsThresholdDefault;
    if (th < kInsThresholdMin) th = kInsThresholdMin;
    if (th > kInsThresholdMax) th = kInsThresholdMax;
    gBatteryTempThreshold = th;

    /* [NEW] 开关被关闭时立刻清滞回状态, 恢复插件接管 */
    if (!gChargingProtectEnabled) gBatteryThermalReleased = NO;

    os_unfair_lock_unlock(&gLock);
}

#pragma mark - [NEW] 充电状态 (事件驱动: IOPS 电源变化通知, 不使用轮询猜测)

static BOOL InsPollChargingState(void) {
    BOOL charging = NO;
    BOOL sawExternal = NO;

    CFTypeRef blob = IOPSCopyPowerSourcesInfo();
    if (!blob) return NO;
    CFArrayRef list = blob ? IOPSCopyPowerSourcesList(blob) : NULL;
    if (list) {
        CFIndex n = CFArrayGetCount(list);
        for (CFIndex i = 0; i < n; i++) {
            CFTypeRef ps = CFArrayGetValueAtIndex(list, i);
            CFDictionaryRef d = IOPSGetPowerSourceDescription(blob, ps);
            if (!d) continue;
            CFStringRef type = CFDictionaryGetValue(d, kInsIOPSType);
            if (type && CFStringCompare(type, kInsIOPSInternalBatt, 0) == kCFCompareEqualTo) {
                CFBooleanRef c = CFDictionaryGetValue(d, kInsIOPSIsCharging);
                if (c && CFBooleanGetValue(c)) charging = YES;
            } else {
                CFBooleanRef present = CFDictionaryGetValue(d, kInsIOPSIsPresent);
                if (present && CFBooleanGetValue(present)) sawExternal = YES;
            }
        }
        CFRelease(list);
    }
    CFRelease(blob);

    /* 降级: 无 IsCharging 字段时, 有外部电源接入即视为充电 */
    if (!charging && sawExternal) charging = YES;
    return charging;
}

static void InsUpdateChargingState(NSString *reason);

static void InsPowerSourceChanged(void *context) {
    /* IOPS 通知回调 (runloop 线程): 电源插拔/状态变化时触发 */
    InsUpdateChargingState(@"power source changed");
}

static void InsPowerSourceThreadMain(void) {
    @autoreleasepool {
        CFRunLoopSourceRef src = IOPSNotificationCreateRunLoopSource(InsPowerSourceChanged, NULL);
        if (src) {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopDefaultMode);
            /* [MEM-FIX] Create 规则: IOPSNotificationCreateRunLoopSource 返回 +1;
             * CFRunLoopAddSource 会 retain, 此处归还持有的 +1, 否则泄漏一个 source。 */
            CFRelease(src);
            CFRunLoopRun();
        }
    }
}

#pragma mark - [NEW] 电池温度读取 (真实 IOKit 实现 + 安全降级)

/*
 * 方案 A: AppleSmartBattery 的 "Temperature" 属性 (单位 0.01℃, 如 3050 = 30.5℃)
 * 方案 B (降级): IOPSCopyPowerSourcesInfo 内部电池源自带的 "Temperature" 键 (同单位)
 * 读取失败返回 NaN → 调用方一律按「未达阈值」处理 (绝不误触发放开), 并打日志。
 */
static float InsReadBatteryTempCelsius(void) {
    /* [BUILD-FIX] kIOMainPortDefault 仅 iOS 15+ SDK 提供, 而部署目标可为 12.2;
     * kIOMasterPortDefault 在所有版本可用(已废弃但等价于 MACH_PORT_NULL), 保证跨 SDK 可编译 */
    io_service_t svc = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (svc != IO_OBJECT_NULL) {
        CFTypeRef raw = IORegistryEntryCreateCFProperty(svc, CFSTR("Temperature"), kCFAllocatorDefault, 0);
        IOObjectRelease(svc);
        if (raw) {
            float v = NAN;
            if (CFGetTypeID(raw) == CFNumberGetTypeID()) {
                v = [(NSNumber *)CFBridgingRelease(raw) floatValue] / 100.0f;
            } else {
                CFRelease(raw);
            }
            if (!isnan(v) && v > -40.0f && v < 120.0f) return v;  /* 合理范围校验 */
        }
    }

    CFTypeRef blob = IOPSCopyPowerSourcesInfo();
    if (blob) {
        CFArrayRef list = IOPSCopyPowerSourcesList(blob);
        float result = NAN;
        if (list) {
            CFIndex n = CFArrayGetCount(list);
            for (CFIndex i = 0; i < n; i++) {
                CFDictionaryRef d = IOPSGetPowerSourceDescription(blob, CFArrayGetValueAtIndex(list, i));
                if (!d) continue;
                CFStringRef type = CFDictionaryGetValue(d, kInsIOPSType);
                if (type && CFStringCompare(type, kInsIOPSInternalBatt, 0) == kCFCompareEqualTo) {
                    CFNumberRef t = CFDictionaryGetValue(d, kInsIOPSTemperature);
                    if (t && CFGetTypeID(t) == CFNumberGetTypeID()) {
                        float v = [(__bridge NSNumber *)t floatValue] / 100.0f;
                        if (v > -40.0f && v < 120.0f) result = v;
                    }
                }
            }
            CFRelease(list);
        }
        CFRelease(blob);
        return result;
    }
    return NAN;
}

#pragma mark - [NEW] 滞回状态机求值

/*
 * 注意: 该函数只决定「电池温控这一路」的归属。
 * CPU/SOC 不降频逻辑不读这个状态, 任何模式下都保持原拦截, 绝不受影响。
 */
static void InsEvaluateBatteryProtection(NSString *reason) {
    os_unfair_lock_lock(&gLock);
    BOOL enabled  = gChargingProtectEnabled;
    BOOL charging = gIsCharging;
    float tempC   = gLastBatteryTempC;
    NSInteger th  = gBatteryTempThreshold;
    BOOL was      = gBatteryThermalReleased;

    BOOL want;
    if (!enabled || !charging) {
        want = NO;                       /* 开关关闭 / 未充电: 完全等同原版, 插件接管 */
    } else if (isnan(tempC)) {
        want = NO;                       /* 温度读取失败: 安全按未达阈值, 保持插件接管 */
    } else if (was) {
        want = (tempC > (float)th - kInsHysteresisDelta);  /* 已放开: 降到 阈值-2℃ 以下才收回 */
    } else {
        want = (tempC >= (float)th);                       /* 未放开: 达到阈值才放开 */
    }
    gBatteryThermalReleased = want;
    os_unfair_lock_unlock(&gLock);

    if (want != was) {
        ILog(@"电池温控控制权切换: %@ -> %@ | 原因:%@ | 温度:%.1f℃ 阈值:%ld℃ 充电:%d | 时间:%@",
             was ? @"已交原生" : @"插件接管",
             want ? @"已交原生" : @"插件接管",
             reason, tempC, (long)th, charging, [NSDate date]);
    }
}

static void InsUpdateChargingState(NSString *reason) {
    BOOL now = InsPollChargingState();
    BOOL changed;
    os_unfair_lock_lock(&gLock);
    changed = (now != gIsCharging);
    gIsCharging = now;
    os_unfair_lock_unlock(&gLock);

    if (changed) {
        ILog(@"充电状态变化: %@ | 原因:%@ | 时间:%@", now ? @"充电中" : @"未充电", reason, [NSDate date]);
    }
    /* 拔线/停止充电 → InsEvaluateBatteryProtection 内 want=NO, 立刻清滞回恢复插件接管 */
    InsEvaluateBatteryProtection(reason);
}

/* [NEW] 低频温度轮询: 每 5s 一次, 仅在 (开关开 && 充电中) 时真正读传感器。
 * 耗电考虑: 一次 IOKit 属性读取为微秒级; 5s 周期 + 2s leeway, 对功耗影响可忽略。
 * 充电状态本身不靠轮询 —— 由 IOPS 通知事件驱动 (见上)。 */
static void InsTempPollTick(void) {
    os_unfair_lock_lock(&gLock);
    BOOL need = gChargingProtectEnabled && gIsCharging;
    os_unfair_lock_unlock(&gLock);
    if (!need) return;

    float t = InsReadBatteryTempCelsius();
    os_unfair_lock_lock(&gLock);
    gLastBatteryTempC = t;
    NSInteger th = gBatteryTempThreshold;
    BOOL released = gBatteryThermalReleased;
    os_unfair_lock_unlock(&gLock);

    if (isnan(t)) {
        static BOOL sLoggedReadFail = NO;
        if (!sLoggedReadFail) {
            ILog(@"电池温度读取失败, 按未达阈值处理 (插件保持接管)");
            sLoggedReadFail = YES;
        }
    } else {
        ILog(@"电池温度 %.1f℃ | 阈值 %ld℃ | 控制权:%@ | 充电中", t, (long)th, released ? @"已交原生" : @"插件接管");
    }
    InsEvaluateBatteryProtection(@"temp poll");
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
        CFTypeRef v = IOHIDServiceClientGetProperty(sc, keys[i]);
        if (v && CFGetTypeID(v) == CFStringGetTypeID()) {
            NSString *s = [(__bridge NSString *)v lowercaseString];
            if ([s containsString:@"batt"] || [s containsString:@"gas"]) isBattery = YES;
        }
    }
    if (!isBattery) {
        CFTypeRef page = IOHIDServiceClientGetProperty(sc, CFSTR("PrimaryUsagePage"));
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
                 (__bridge id)IOHIDServiceClientGetProperty(sc, CFSTR("Product")),
                 (__bridge id)IOHIDServiceClientGetProperty(sc, CFSTR("Transport")),
                 (__bridge id)IOHIDServiceClientGetProperty(sc, CFSTR("Manufacturer")),
                 (__bridge id)IOHIDServiceClientGetProperty(sc, CFSTR("PrimaryUsagePage")),
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
 * [INFERRED] 具体调用序列按语义重建; 通过 hook 中捕获的 mitigationControllerObject 下发。
 */
static void InsApplyPowerMode(void) {
    os_unfair_lock_lock(&gLock);
    InsPowerMode mode = gPowerMode;
    os_unfair_lock_unlock(&gLock);

    MitigationController *mc = gMitigationController;
    switch (mode) {
        case InsPowerModeFullPower:
            [mc setCPMSMitigationsEnabled:NO];   /* 关闭 CPMS 缓解 → CPU 不降频 */
            ILog(@"insulation: full power mode");
            ILog(@"thermalPowerMode fullPower -> thermal mitigations disabled (%d)", 0);
            break;
        case InsPowerModeLowPower:
            [mc setCPMSMitigationsEnabled:YES];  /* [INFERRED] 恢复缓解, 模拟低电 */
            [mc setPowerSaveActive:YES];         /* [INFERRED] 模拟低电量模式 */
            ILog(@"insulation: low power mode at CPU level %d", mc ? [mc CPULevel] : 0);
            ILog(@"thermalPowerMode native/lowPower -> thermal mitigations reset (%d)", 0);
            break;
        case InsPowerModeOff:
        default:
            [mc setCPMSMitigationsEnabled:YES];
            [mc setPowerSaveActive:NO];
            ILog(@"insulation: native thermal mode restored");
            ILog(@"thermalPowerMode native/lowPower -> thermal mitigations reset (%d)", 0);
            break;
    }

    /* [EVIDENCE] 发布运行时状态: notify_set_state + com.be-huge.insulation.runtimeState */
    uint64_t stateCode = (uint64_t)mode;
    notify_set_state(gRuntimeStateToken, stateCode);
    notify_post(kInsNotifRuntimeState);
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
 * [NEW] 仅当 (开关开 && 充电中 && 温度≥阈值 && 滞回状态=已交原生) 且该事件
 *       来自电池传感器时, 调用 %orig 放行 —— 即把电池温控交还苹果原生策略。
 *       其余情况与原版完全相同(吞掉)。CPU 相关传感器事件永远不放行。
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
    return res;
}

- (void)setCPULevel:(int)level {
    InsPowerMode mode;
    os_unfair_lock_lock(&gLock); mode = gPowerMode; os_unfair_lock_unlock(&gLock);
    if (mode == InsPowerModeFullPower && level != 0) {
        ILog(@"insulation cpu level lock %d -> %d", level, 0);
        %orig(0);        /* 强制 CPU level 0 = 不降频 */
        return;
    }
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

static void InsOnPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    InsReloadPrefs();
    NSString *n = (__bridge NSString *)name;
    if ([n isEqualToString:@kInsNotifExecutePuppet]) {
        /* [UPSTREAM] executePuppetEvent → 应用 thermalPowerMode (0.0.18 的 puppet 即 power mode) */
        InsApplyPowerMode();
        InsApplyAdvancedSwitches();
    }
    /* [NEW] 电池保护参数变化: 阈值/开关立刻生效并重新求值滞回状态 */
    InsEvaluateBatteryProtection(@"prefs changed");
}

%ctor {
    @autoreleasepool {
        InsReloadPrefs();

        /* [EVIDENCE] runtime state notify token */
        notify_register_check(kInsNotifRuntimeState, &gRuntimeStateToken);

        /* Darwin 通知监听 (原插件: executePuppetEvent; [NEW] 新增 batteryProtectChanged) */
        CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(center, NULL, InsOnPrefsChanged,
                                        CFSTR(kInsNotifExecutePuppet), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(center, NULL, InsOnPrefsChanged,
                                        CFSTR(kInsNotifBatteryChanged), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        /* [NEW] 充电插拔: IOPS 电源变化通知, 独立 runloop 线程, 事件驱动 */
        [NSThread detachNewThreadWithBlock:^{ InsPowerSourceThreadMain(); }];

        /* [NEW] 电池温度低频轮询定时器 (5s, leeway 2s) */
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kInsTempPollInterval * NSEC_PER_SEC)),
                                  (uint64_t)(kInsTempPollInterval * NSEC_PER_SEC), (uint64_t)(2 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(timer, ^{ InsTempPollTick(); });
        dispatch_resume(timer);

        %init;

        os_unfair_lock_lock(&gLock);
        ILog(@"insulation loaded (Logos 重建版 + 充电电池温控保护) | mode=%ld protect=%d threshold=%ld℃",
             (long)gPowerMode, gChargingProtectEnabled, (long)gBatteryTempThreshold);
        os_unfair_lock_unlock(&gLock);
    }
}
