# Asailor-Tools

自用服务器维护工具。

## 内核清理

`shell/debian/kernel_manager.sh` 通过 APT 精确卸载已确认的旧内核软件包。默认保留每种内核风格的最新两个内核，以及当前运行内核、hold 内核和启动配置引用的内核。

| 平台 | 自动清理范围 |
| --- | --- |
| Debian / Ubuntu | 软件包实际拥有 `/boot/vmlinuz-<ABI>` 或 `/boot/vmlinux-<ABI>` 的内核，使用 GRUB 启动 |
| Proxmox VE | `pve-kernel-*` 和 `proxmox-kernel-*`；保护启动工具自动选择、手工选择及固定的内核 |
| Armbian | 按 `LINUXFAMILY`、软件包内容和内核元数据识别同一硬件家族的内核分支；保护可解析的 Image、uInitrd、DTB 和启动配置引用 |

需要 root、Bash 4.4 或更新版本，以及 APT/dpkg。执行时，APT 必须支持 v3 事务协议并持有前端锁；无法确认时停止操作。

### 使用

建议先完整下载，再检查语法和查看清理计划：

```bash
curl -fsSL -4 https://raw.githubusercontent.com/Aethersailor/Asailor-Tools/main/shell/debian/kernel_manager.sh -o kernel_manager.sh &&
bash -n kernel_manager.sh &&
bash kernel_manager.sh --dry-run
```

审阅计划后，执行同一份文件：

```bash
bash kernel_manager.sh
```

脚本会显示精确的软件包删除清单，完成 APT 模拟，并从交互式终端读取 `y` 确认。确认后再次检查包状态、hold 状态、启动配置和模拟结果，实际 APT 事务还会检查软件包、架构和版本，拒绝额外安装、配置或删除。

支持原有的 `curl ... | bash` 用法。全部维护逻辑位于一个完整函数内，Bash 必须先解析完整函数才能开始维护；下载在函数内部截断时不会执行卸载。完整下载仍然更便于检查内容和固定版本。

可设置最低保留数量：

```bash
bash kernel_manager.sh --dry-run --keep 3
bash kernel_manager.sh --keep 1
```

`--keep 1` 会显式减少备用内核，但不能覆盖当前运行内核、hold 或启动选择保护，因此实际保留数量可能更多。尚未重启进入新内核时，当前运行内核和最新内核仍会保留。

### 安全边界

- 元包、调试符号包和签名模板包不会仅因包名包含数字而被卸载。
- 共享的 `headers-common` 只有在全部已安装反向依赖都位于删除清单中、且没有 hold 时才会一并清理。
- 软件包内容跨越多个内核 ABI、启动链接损坏、读取失败或 APT 计划超出范围时停止操作。
- 容器、非 GRUB 的 Debian，以及不能可靠归属启动镜像的 Armbian FAT/定制布局不自动清理。
- 不执行 `autoremove`，不手工删除 `/boot` 或 `/lib/modules` 中的残留，不修改内核固定策略，不自动重启。
- 文件和软件包校验不能证明硬件能成功启动；未知布局会保留或拒绝处理。使用 Armbian 的同名分支包升级后留下的无归属文件，不在自动删除范围内。

APT/dpkg 会执行系统已有的软件包维护脚本和启动更新钩子。遇到实际 purge 或启动刷新失败时立即停止；卸载不是可自动回滚的事务，不能据此假定系统已经具备重启条件。

## 隔离测试

`tests/test_kernel_manager.py` 使用自建的假内核包，在无特权、禁用网络的 bubblewrap 命名空间内运行真实 APT 和 dpkg。假包只包含文本文件，不包含可启动的内核。

测试必须由普通用户在 x86_64 Linux 或 WSL 中运行，需要 Python 3.9+、bubblewrap、APT/dpkg 和 ShellCheck。宿主 `/usr` 和运行库只读，测试的 `/etc`、`/var`、`/boot`、模块目录和 headers 目录均挂载到专用临时目录；不使用 Docker、不访问服务器、不运行宿主内核清理或重启。

```bash
bash -n shell/debian/kernel_manager.sh
shellcheck shell/debian/kernel_manager.sh
python3 tests/test_kernel_manager.py
```

用例覆盖 Debian 常规与 unsigned 内核、新版 ABI、多种内核风格、元包、调试包、共享 headers、hold、PVE 选择与刷新、Armbian ARM64 包、损坏的启动配置、读取故障、确认期间状态变化、实际事务越界、下载截断及管道运行。测试结束校验宿主 dpkg 状态未变，并删除任务创建的临时目录。
