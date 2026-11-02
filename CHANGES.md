# Insulation 改造说明（电池原生温控开关）

基于 `insulation-0.0.18-iphoneos-arm64.deb`（com.be-huge.insulation）逆向分析 + 源码重建。

---

## 1. 原插件分析结论

### 1.1 包结构（deb 解包实测）

| 项 | 内容 | 证据 |
|---|---|---|
| 包名/版本 | com.be-huge.insulation 0.0.18，Maintainer: doimty | control |
| 依赖 | dev.theos.orion (>= 1.0.0), firmware (>= 12.2) | control |
| 布局 | rootless（`/var/jb/...`），链接 `@rpath/libroot.dylib` | data.tar / 二进制字符串 |
| postinst | `killall thermalmonitord` | control.tar.gz |
| 注入目标 | **仅 thermalmonitord** | insulation.plist filter：`Executables = ( "thermalmonitord" )` |
| 主库 | insulation.dylib，FAT（arm64 + arm64e），**符号表未剥离**（312 符号） | Mach-O 解析 |
| 面板 | InsulationPrefs.bundle（Swift 编译，NSPrincipalClass=`InsulationPrefs.RootListController`），Root.plist + PreferenceLoader 入口 | bundle 内容 |

### 1.2 实现方式：Swift/Orion，非 Logos

二进制含 `$s5Orion17ClassHookProtocolP...`、`method_setImplementation` 等符号 —— 上游开源项目
[github.com/be-huge/insulation](https://github.com/be-huge/insulation) 的源码已逐文件比对获取。
**注意：上游 main 分支（2026-01-28）早于 deb 的构建（2026-05），deb 0.0.18 比上游多了
ComponentControlHook / MitigationControllerHook / CPMSHelperHook 及整套 thermalPowerMode 逻辑，
这部分上游无源码，属 doimty 维护的私有扩展，本重建按二进制证据推断还原（标注 [INFERRED]）。**

### 1.3 六个 hook 类（类名/selector/类型编码均来自二进制字符串）

| Hook 类 | 目标类（thermalmonitord 内） | 作用 | 证据级别 |
|---|---|---|---|
| CommonProductClassHook | CommonProduct | initProduct 捕获实例并钉 `putDeviceInThermalSimulationMode:@"nominal"`；吞掉 tryTakeAction / simulateLightThermalPressure / updatePowerzoneTelemetry / handleMCSThermalPressure；fullPower 下拦截 setThermalState: 改发 Darwin 压力通知 | 前 4 个 [UPSTREAM 逐行]；后两个 [INFERRED] |
| HidSensorsHook | HidSensors | `handleTemperatureEvent:(int)temp service:(id)service` **空实现，吞掉全部 HID 温度传感器事件** | [UPSTREAM 逐行] |
| NSDictionaryHook | NSDictionary | 拦截 `+dictionaryWithContentsOfFile:`，patch `/System/Library/ThermalMonitor/` 下 plist：拉平 BacklightBrightness/BacklightPower 数组、`expectsCPMSSupport=0`、可用 cpuMinPowerValue 覆盖 max/minThermalPower | [UPSTREAM 逐行] |
| MitigationControllerHook | MitigationController | initForFastLoop: 捕获实例；fullPower 下 setCPULevel:→0、setCPMSMitigationsEnabled:→NO、功率 ceiling 抬到观测上限 | [INFERRED]（日志串 "insulation cpu level lock %d -> %d"、"thermalPowerMode fullPower -> thermal mitigations disabled (%d)" + 类型编码 `@40@0:8B16B20@24@32`/`v24@0:8q16`/`v32@0:8q16q24`） |
| ComponentControlHook | ComponentControl | fullPower 下 powerTarget/computePowerTarget 抬到观测全局最大值 | [INFERRED]（类型编码 `I16@0:8` + 日志 "insulation component %d power limit %d -> %d"） |
| CPMSHelperHook | CPMSHelper | fullPower 下 getMaxPowerForComponent: 抬高上限 | [INFERRED]（类型编码 `I24@0:8q16`） |

另有导出函数 `_insulationSet/Reset{ThermalMitigations,HIP,OSNotifEnabled,SimulateHIP,SunlightOverride,...}`
与 `SCPreferences*` + `OSThermalStatus.plist` 字符串：对应面板"高级功能"三个开关写
OSThermalStatus.plist（[INFERRED]，日志串 `thermalSuppressNotificationsEnabled: on -> %d` 等）。

### 1.4 原有偏好 key（deb 内 Root.plist 二进制解码）

defaults 域：`com.be-huge.insulation-prefs`，文件 `…/Preferences/com.be-huge.insulation-prefs.plist`

| key | 类型 | 说明 |
|---|---|---|
| thermalPowerMode | off / lowPower / fullPower | "CPU 模式"（PostNotification: com.be-huge.insulation-executePuppetEvent） |
| thermalPreventDimmingEnabled | bool | 防止温控暗屏 |
| thermalSuppressNotificationsEnabled | bool | 禁温度计弹窗 |
| thermalDisablePocketSunlightEnabled | bool | 禁用口袋高温 |
| thermalSunlightLockedEnabled | bool | 锁定阳光暴晒 |

### 1.5 SOC/CPU 降频拦截 与 电池温控路径的区分（关键结论）

- **CPU/SOC 不降频路径**：MitigationControllerHook（setCPULevel/功率 ceiling/CPMS 开关）+
  ComponentControlHook + CPMSHelperHook + NSDictionaryHook 的功率补丁。这条路与电池传感器无关。
- **温度传感器输入路径**：`HidSensors handleTemperatureEvent:service:` 被空实现吞掉 ——
  **SOC 温度与电池温度（若经 HID Thermistor 上报）在同一个 hook 点被同时拦截**。
  `service` 参数（IOHIDServiceClient）携带传感器属性，可据此区分来源。
- **只放开电池一路的做法**：在该 hook 内按 service 属性识别电池传感器
  （Product/Transport/Manufacturer 含 "batt"/"gas"，或 HID PrimaryUsagePage==0x84 Power Devices），
  命中且满足充电+超温条件时调用 `%orig` 放行；其余事件维持吞掉。**CPU 相关 hook 全程不动。**
- 补充事实：iOS 充电降流/暂停还有一条不经过 thermalmonitord 的硬路径（powerd + AppleSmartBattery
  直接读电量计温度），该路径原插件从未拦截。因此放开 HID 电池事件后，原生电池保护是双保险。

## 2. 新增设置项

| key | 类型 | 默认 | 语义 |
|---|---|---|---|
| `chragingBatteryThermalProtect` | bool | NO | 打开 = 电池温控永久交还系统原生（不看充电状态/温度，无阈值无回差）；关闭 = 完全恢复插件原行为 |

新 cell 带 `PostNotification = com.be-huge.insulation-batteryProtectChanged`，Tweak 监听后即时生效。

## 3. 控制权模型（无状态机）

```
开关 = NO  →  插件接管：HidSensors 吞掉全部温度事件（与原版逐字等价）
开关 = YES →  已永久交还原生：仅电池传感器事件 %orig 放行；CPU/SOC 事件仍吞掉
```

- `InsReloadPrefs` 将开关直接同步到 `gBatteryThermalReleased`（无充电判断、无温度读取、无阈值/回差、无轮询）。
- **生效点**：`HidSensors handleTemperatureEvent:service:` —— 开关打开且事件来自电池传感器时 `%orig` 放行；其余与原版完全一致（吞掉）。
- **CPU 不降频**：MitigationController/ComponentControl/CPMSHelper/NSDictionary 各 hook 与该开关完全无关，任何开关状态下都保持原有拦截。

## 4. 场景推演

| 场景 | CPU 是否降频 | 电池温控由谁接管 | 说明 |
|---|---|---|---|
| ① 开关关闭（默认） | 取决于 CPU 模式（与 0.0.18 完全一致） | 插件（吞掉电池温度事件，同原版） | 与 0.0.18 逐字等价 |
| ② 开关打开（任意充电状态、任意温度） | 取决于 CPU 模式，**电池开关不影响 CPU 路径** | **苹果原生**（电池传感器事件 `%orig` 放行；另有 powerd/电量计硬路径兜底） | 无温度/充电判断，持久生效，重启后仍按 plist 值生效 |

## 5. 编译与安装

```bash
# 环境: macOS/iOS 设备上的 theos (含 iOS SDK)
cd Insulation-Mod

# rootless (palera1n/Dopamine, iOS 15+)
THEOS_PACKAGE_SCHEME=rootless make package FINALPACKAGE=1

# rootful (iOS 12.2~14)
make package THEOS_PACKAGE_SCHEME=rootful FINALPACKAGE=1
```

产物 deb 安装后 `postinst` 自动 `killall thermalmonitord` 使其重载注入。
目录布局（theos 约定）：

```
Insulation-Mod/
├── Makefile                 # 顶层: tweak + 子项目 aggregate
├── control                  # 包信息 (v0.0.19, Depends: mobilesubstrate, firmware>=12.2)
├── insulation.plist         # filter: Executables=(thermalmonitord) —— 与原包一致
├── Tweak.x                  # Logos 主源码
├── layout/DEBIAN/postinst   # killall thermalmonitord
├── CHANGES.md               # 本文件
└── InsulationPrefs/
    ├── Makefile             # bundle.mk, 装到 /Library/PreferenceBundles
    ├── IPRootListController.m   # 面板控制器 (ObjC, 原风格: 直接读写 plist 文件)
    ├── Resources/{Info.plist, Root.plist, icon*.png}
    └── layout/Library/PreferenceLoader/Preferences/InsulationPrefs.plist
```

## 6. 已知限制（如实说明）

1. **重建保真度**：原插件为 Swift/Orion 编译产物，本次交付为 Logos/ObjC 重建。
   CommonProduct 前 4 个方法、HidSensors、NSDictionary patch 与上游源码逐行一致（[UPSTREAM]）；
   0.0.18 私有的 MitigationController/ComponentControl/CPMSHelper 三个 hook 及 OSThermalStatus
   写入逻辑按二进制日志串/类型编码推断（[INFERRED]），数值细节（如 lowPower 模拟的具体 CPU level）
   可能与原版有出入。面板控制器由 Swift 移植为 ObjC，行为等价（直接读写同一 plist 文件）。
2. **电池传感器识别为启发式**：`handleTemperatureEvent:service:` 的 service 属性在不同机型/iOS
   版本上可能不同；识别不出时**保持原版吞掉行为（安全方向）**。Tweak 启动后会对每个 HID 温度
   传感器打一次属性日志，真机核对后可收窄匹配条件。
3. **simulation 钉住 nominal 的相互作用**：原插件 initProduct 会 `putDeviceInThermalSimulationMode:
   @"nominal"`，若某 iOS 版本上该模拟模式会压制真实传感器驱动的状态机，放行的电池事件效果可能
   被削弱；此时由 powerd/电量计硬路径兜底电池保护。本改造不能解除该钉住——解除会同时放开 CPU 温控，
   违背「CPU 不降频必须保留」。
4. **未真机/真链编译验证**：交付环境为 Windows，无 theos/iOS 交叉工具链，仅做了 Logos/ObjC 结构
   与语法自查（%hook/%orig/%ctor、plist 合法性、头文件声明）。首次编译如遇告警级问题请以编译器输出为准。
5. **依赖变化**：原版依赖 Orion（dev.theos.orion）；重建版基于 Logos，依赖改为 mobilesubstrate，
   rootless/roothide 下另链接 libroot（与原 deb 的 libroot 引用一致）。
6. **key 名拼写**：需求给定的开关 key 为 `chragingBatteryThermalProtect`（chraging 非 charging），
   已按原文实现，未擅自改名。
