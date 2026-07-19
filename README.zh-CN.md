<p align="center">
  <img src="static/vohive-wrt.png" alt="VoHive × OpenWrt — Vohive Dashboard for Luci-App" width="100%" />
</p>

<h1 align="center">luci-app-vohive</h1>

<p align="center">
  <strong>VoHive 的 OpenWrt / ImmortalWrt LuCI 管理插件</strong><br />
  在路由器 Web 界面中完成核心安装、服务控制、配置管理与 USB 驱动运维
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT" /></a>
  <a href="https://openwrt.org/"><img src="https://img.shields.io/badge/OpenWrt-24.x%20%7C%2025.x-00B5E2?logo=openwrt&logoColor=white" alt="OpenWrt" /></a>
  <a href="https://github.com/openwrt/luci"><img src="https://img.shields.io/badge/LuCI-Application-green" alt="LuCI" /></a>
  <img src="https://img.shields.io/badge/Package-ipk%20%7C%20apk-orange" alt="Package formats" />
  <img src="https://img.shields.io/badge/Arch-arm64%20%7C%20amd64%20%7C%20armv7-informational" alt="Architectures" />
  <a href="https://github.com/kedaya2025/luci-app-vohive/releases"><img src="https://img.shields.io/github/v/release/kedaya2025/luci-app-vohive?include_prereleases&label=release" alt="Release" /></a>
</p>

<p align="center">
  <sub>原作者 / 开发者：<a href="https://github.com/Demogorgon314"><strong>@Demogorgon314</strong></a></sub>
</p>

<p align="center">
  <a href="README.md">English</a> · 简体中文
</p>

---

## 简介

`luci-app-vohive` 为 [VoHive](https://github.com/voorz/vohive-next) 提供官方风格的路由器侧管理界面，安装后出现在：

```text
LuCI → 服务 → VoHive
```

插件本身**不内置** VoHive 二进制；可按需安装对应架构的 `vohive-core-*` 包，或在页面内从 GitHub Release 在线安装 / 更新 / 回滚核心。

默认核心 Release 仓库：

```text
https://github.com/voorz/vohive-next
```

---

## 功能特性

| 模块 | 说明 |
|------|------|
| **核心管理** | 从 GitHub Release 列出版本，安装 / 更新 / 回滚 VoHive 核心 |
| **任务进度** | 下载与安装过程展示进度、已下载大小、总大小与速度 |
| **服务控制** | 启动、停止、重启基于 procd 的 VoHive 服务 |
| **配置管理** | 通过 UCI 编辑，并渲染为 `/etc/vohive/config/config.yaml` |
| **状态与日志** | 核心版本、架构、服务状态、端口监听与近期日志 |
| **插件自更新** | 支持 OpenWrt 24（`opkg` / `.ipk`）与 25（`apk` / `.apk`） |
| **驱动管理** | USB 接口驱动绑定状态查看与手动管理，缓解 4G 模块被 `option` 占用等问题 |
| **QMI 恢复** | 提供 QMI 通信恢复能力，便于模块异常后自愈 |

核心回滚仅保留上一版本与架构元数据，回滚时重新下载旧版 core，**不在闪存中常驻第二份完整二进制**。

---

## 快速安装

### 1. 确认系统与架构

```sh
# OpenWrt 版本（24.x → .ipk，25.x → .apk）
cat /etc/openwrt_release

# 机器架构
uname -m
```

| `uname -m` | 选择的 core 包 |
|------------|----------------|
| `aarch64` / `arm64` | `vohive-core-arm64` |
| `x86_64` / `amd64` | `vohive-core-amd64` |
| `armv7l` / `armv7` | `vohive-core-armv7` |

### 2. 仅安装 LuCI 插件

从 [Releases](https://github.com/kedaya2025/luci-app-vohive/releases) 下载对应格式的包：

**OpenWrt 24.x（opkg）**

```sh
opkg install luci-app-vohive_<version>-r1_all.ipk
```

**OpenWrt 25.x（apk）**

```sh
apk add --allow-untrusted luci-app-vohive-<version>-r1*.apk
```

进入 **服务 → VoHive**，在页面中点击「安装 / 更新核心」即可拉取二进制。

### 3. 插件 + 预置核心（可选）

```sh
# 示例：24.x + arm64
opkg install luci-app-vohive_<version>-r1_all.ipk vohive-core-arm64_1.6.1-r1_all.ipk

# 示例：24.x + amd64 / armv7
opkg install luci-app-vohive_<version>-r1_all.ipk vohive-core-amd64_1.6.1-r1_all.ipk
opkg install luci-app-vohive_<version>-r1_all.ipk vohive-core-armv7_1.6.1-r1_all.ipk
```

> 安装后默认 **不启用** 服务（`enabled=0`）。在 LuCI 中配置账号端口等信息并启用后，再启动服务。

---

## 贡献

欢迎通过 Issue / Pull Request 参与改进。提交前请尽量说明复现环境（OpenWrt 版本、架构、模块型号）。

---

## 相关链接

- [VoHive 核心项目](https://github.com/voorz/vohive-next)
- [本插件 Releases](https://github.com/kedaya2025/luci-app-vohive/releases)
- [OpenWrt 官方文档](https://openwrt.org/docs/start)
- [LuCI 项目](https://github.com/openwrt/luci)

---

## 许可证

本仓库 LuCI 插件源码以 **MIT** 许可发布（见包内 `PKG_LICENSE`）。

VoHive **核心二进制**及其许可证以 [voorz/vohive-next](https://github.com/voorz/vohive-next) 为准；`vohive-core-*` 包仅用于分发预编译 core，不改变上游授权条款。

---

<p align="center">
  <sub>VoHive Dashboard for LuCI-App · Built for OpenWrt</sub>
</p>
