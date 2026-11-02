# NEXT-STEPS: 本机 WSL2 构建路线（重启后执行）

> 本文档与 CI 方案（GitHub Actions，见 README.md）**并列**，二选一即可。
> 放在本仓库根目录，是因为重启后的操作都以本目录为起点（`./build.sh` 就在仓库里）。

## 当前状态（已执行完毕，勿重复）

- `dism /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart` → 成功（exit 3010 = 待重启）
- `dism /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart` → 成功（exit 3010）
- 回读状态：两个功能 `State=Enabled, RestartRequired=Possible` —— **已启用，重启后生效**
- 未重启、未装发行版（重启前 `wsl --status` 仍报错属正常）

## 重启后的步骤

```powershell
# 1. Windows PowerShell（管理员）：完成 WSL2 初始化
wsl --set-default-version 2
wsl --update
wsl --install -d Ubuntu-22.04    # 首次启动会要求设 UNIX 用户名/密码
```

```bash
# 2. Ubuntu 内：构建依赖
sudo apt update
sudo apt install -y git make perl clang ldid dpkg fakeroot \
    libplist-utils libssl-dev zlib1g-dev zstd curl unzip ca-certificates
# libplist-utils 提供 plistutil：theos 需要它把 ASCII 格式 insulation.plist 转二进制

# 3. theos（二选一，取决于网络实测）
export THEOS=$HOME/theos

# 3a. 在线：raw.githubusercontent.com 在本机网络下被墙（连接重置），
#     官方 install-theos 脚本走 raw 域会失败 → 直接用 git clone（走 github.com 主域）
git clone --recursive https://github.com/theos/theos.git $THEOS
git clone --depth 1 https://github.com/theos/sdks.git $THEOS/sdks
# 若 github.com 间歇重置导致 clone 中断：直接重试即可（实测为波动型丢包）

# 3b. 离线：在可联网机器上下载后拷贝进 WSL
#   - theos 仓库 + 全部 submodule（vendor/logos、vendor/lib、vendor/include 等，缺一个都会编不了）
#     可用 https://codeload.github.com/theos/theos/tar.gz/refs/heads/master 下载主仓 tarball
#     （本机实测 codeload 可达，但慢约 100KB/s），submodule 需逐个同法下载
#   - sdks: https://codeload.github.com/theos/sdks/tar.gz/refs/heads/master
#   解压到 $HOME/theos 与 $HOME/theos/sdks

# 4. 拷贝项目（不要在 /mnt/c 下 make：NTFS 挂载点权限/大小写/性能都会出问题）
mkdir -p ~/Insulation-Mod
cp -r /mnt/c/Users/Administrator/Documents/ios_tweak/* ~/Insulation-Mod/
cd ~/Insulation-Mod && sed -i 's/\r$//' build.sh && chmod +x build.sh

# 5. 构建
./build.sh                                   # 默认 rootless
# rootful:  THEOS_PACKAGE_SCHEME=rootful ./build.sh

# 6. 产物回拷 Windows
cp packages/*.deb /mnt/c/Users/Administrator/Documents/
```

产物：`packages/com.be-huge.insulation_0.0.19_iphoneos-arm64.deb`（rootless）/ `..._iphoneos-arm.deb`（rootful）。

## CI vs WSL2 取舍（自行选择）

| | GitHub Actions CI | 本机 WSL2 |
|---|---|---|
| 网络依赖 | 仅需 push 成功一次（github.com 波动，重试即可；CI 构建在 GitHub 云端，网络干净） | theos/SDK 要在本机网络下下载（raw 域被墙需绕、github 波动需重试、sdks 约数百 MB、速度慢） |
| 准备工作 | 建 GitHub 仓库 + push | 重启电脑 + 装 Ubuntu + apt + 拷项目 |
| 复现/分享 | 每次 push 自动出双包（rootless+rootful），artifact 可随时下载 | 纯手工，每次自己来 |
| 限制 | 私有仓库有免费分钟数（约 2000 分钟/月，够用） | 无 |
| 建议 | **优先 CI** | 无 GitHub 账号 / 不想公开代码时用 |

## 不做的事（边界）

本准备阶段没有：重启机器、安装发行版、改动用户已装软件。这些都在重启后由你（或下一次会话）执行。
