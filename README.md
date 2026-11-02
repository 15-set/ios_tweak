# Insulation-Mod

Insulation（解除温控）0.0.18 的 Logos 源码级重建版，新增「充电电池温控保护」（key: `chragingBatteryThermalProtect` / `chargingBatteryTempThreshold`）。详见 [CHANGES.md](CHANGES.md)。

## 为什么不在本机构建

开发机是 Windows 10：无 clang/make/ldid/dpkg-deb/perl，无 iOS SDK；WSL 功能刚启用、需重启后安装发行版。iOS tweak 只能交叉编译，所以用 **GitHub Actions 云端编译**（ubuntu-latest 上装 theos + iPhoneOS SDK，见 [.github/workflows/build.yml](.github/workflows/build.yml)），或重启后走本机 WSL2（见 NEXT-STEPS-WSL.md）。

## 推送到 GitHub（在本仓库根目录执行）

```powershell
cd C:\Users\Administrator\Documents\ios_tweak
git init
git add .
git commit -m "Insulation 0.0.19: Logos rebuild + charging battery thermal protect"
git branch -M main
git remote add origin https://github.com/<你的用户名>/<仓库名>.git   # 先在 github.com 建好空仓库
git push -u origin main
```

> 本机 github.com 间歇性连接重置（实测偶发 000/200 波动）；push 失败时直接重试，或稍后网络稳定时再推。无任何代理介入（已核实 WinHTTP/WinINET/环境变量均为直连）。

## 从 CI 取 deb

push 后进入仓库 **Actions** 页 → 选最新 `build-insulation` 运行 → 页面底部 Artifacts 下载：

| Artifact | 产物 | 适用 |
|---|---|---|
| `insulation-rootless` | `com.be-huge.insulation_0.0.19_iphoneos-arm64.deb` | palera1n / Dopamine（iOS 15+，路径前缀 `/var/jb`） |
| `insulation-rootful` | `com.be-huge.insulation_0.0.19_iphoneos-arm.deb` | 传统越狱（iOS 12.2~14） |

两个 matrix 产物文件名天然不同（架构后缀不同），不会混淆。

**注意**：GitHub 私有仓库的 Actions 有每月免费分钟数限制（免费账户约 2000 分钟/月）；单次构建约几分钟，通常够用。公开仓库无此限制。

## 如果你有 Mac

不必走 CI：装好 Xcode 命令行工具 + theos 后直接 `./build.sh`（默认 rootless），比云端快得多。

## 真机安装

```bash
# 拷贝到设备后（rootless 示例）
ssh root@<设备IP>
dpkg -i com.be-huge.insulation_0.0.19_iphoneos-arm64.deb
# postinst 由 theos 自动生成, 会 killall thermalmonitord 使其重载
```
