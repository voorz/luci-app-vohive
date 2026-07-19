# 预置核心二进制（Fallback）

本目录用于存放 **VoHive 核心二进制的预置副本**，作为 CI 在核心 release 仓库找不到对应版本时的兜底来源。

## 命名规范

文件名必须与上游 release asset 一致：

```
vohive_v<version>_linux_<arch>
```

示例：

| 文件名 | 架构 |
|--------|------|
| `vohive_v1.5.4_linux_arm64` | aarch64 / arm64 |
| `vohive_v1.5.4_linux_amd64` | x86_64 / amd64 |
| `vohive_v1.5.4_linux_armv7` | armv7l / armv7 |

## CI 构建逻辑（`.github/workflows/release.yml`）

对每个架构（`arm64` / `amd64` / `armv7`）依次：

1. **先查核心 release 仓库**（默认 `voorz/vohive-next`）：
   尝试下载 `vohive_${VOHIVE_VERSION}_linux_${arch}`
2. **查不到则查本目录**：
   按版本倒序取该架构最新的预置文件（`vohive_v*_linux_${arch}`），复制为构建产物 `vohive-${arch}`，并从文件名解析出真实版本写入 `.version-${arch}`。
3. **都没有则跳过该架构**：
   该架构的 `vohive-core-*` 包不会进入本次 Release，构建不会失败。

> 因此你可以只预置部分架构（例如只放 `arm64`），其余架构在核心仓库就绪后会自动从线上拉取。

## 版本元数据

- 下载成功：版本元数据 = `VOHIVE_VERSION`（workflow 输入）
- 兜底预置：版本元数据 = 从预置文件名解析出的真实版本（如 `v1.5.4`）
- 最终写入包内的 `/etc/vohive/bin/version`

## 注意

- 本目录下的 `vohive_v*_linux_*` 文件 **会被 git 跟踪并提交**（作为兜底资产）。
- CI 生成的 `vohive-arm64` / `vohive-amd64` / `vohive-armv7`、`.version-*`、`.available` 是构建产物，已被 `.gitignore` 忽略，不会提交。
- 请不要把上游 release 里同名的 asset 手动重命名——必须保持 `vohive_v<version>_linux_<arch>` 格式，否则 CI 无法解析版本。
