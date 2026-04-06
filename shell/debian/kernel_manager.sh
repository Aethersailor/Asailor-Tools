#!/bin/bash

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
  echo -e "\e[31m请使用 root 权限运行此脚本 (sudo)！\e[0m"
  exit 1
fi

GREEN='\e[32m'
YELLOW='\e[33m'
RED='\e[31m'
BLUE='\e[34m'
NC='\e[0m'

echo -e "${BLUE}--- Debian 内核深度管理助手 (增强版) ---${NC}"

# 1. 获取当前信息
RUNNING_KERNEL=$(uname -r)
# 获取所有状态为 ii 的内核镜像包名
INSTALLED_IMAGE_PKGS=$(dpkg --list | grep '^ii  linux-image-[0-9]' | awk '{print $2}')

# 提取版本号列表并排序
VERSION_LIST=$(echo "$INSTALLED_IMAGE_PKGS" | sed 's/linux-image-//' | sort -V)
LATEST_INSTALLED=$(echo "$VERSION_LIST" | tail -n 1)

echo -e "当前运行内核: ${GREEN}$RUNNING_KERNEL${NC}"
echo -e "系统最新内核: ${GREEN}$LATEST_INSTALLED${NC}"

# 2. 状态判断
if dpkg --compare-versions "$RUNNING_KERNEL" lt "$LATEST_INSTALLED"; then
    echo -e "\n${YELLOW}[提示] 当前不是最新内核，新内核需重启后生效。${NC}"
    read -p "是否立即重启？[y/N]: " REBOOT_CONFIRM
    [[ "$REBOOT_CONFIRM" =~ ^[Yy]$ ]] && reboot || exit 0
fi

if [ "$RUNNING_KERNEL" != "$LATEST_INSTALLED" ]; then
    echo -e "${RED}[警告] 当前运行的内核既不是最新版，也不在安装列表中，为安全起见停止操作。${NC}"
    exit 1
fi

# 3. 识别旧内核
OLD_VERSIONS=$(echo "$VERSION_LIST" | grep -v "$RUNNING_KERNEL")

if [ -z "$OLD_VERSIONS" ]; then
    echo -e "${BLUE}没有发现旧版本内核，系统很干净。${NC}"
    exit 0
fi

echo -e "\n${YELLOW}发现以下旧内核版本及其关联组件：${NC}"
for VER in $OLD_VERSIONS; do
    # 动态搜索所有包含该版本号的已安装包（覆盖 image, modules, headers, kbuild 等）
    RELATED_PKGS=$(dpkg --list | grep "^ii" | grep "$VER" | awk '{print $2}')
    echo -e "${BLUE}版本 [$VER] 相关包：${NC}"
    echo "$RELATED_PKGS" | sed 's/^/  - /'
done

read -p "是否确认【深度彻底清理】以上所有包及残留文件？[y/N]: " PURGE_CONFIRM
if [[ ! "$PURGE_CONFIRM" =~ ^[Yy]$ ]]; then
    echo "操作取消。"
    exit 0
fi

# 4. 执行彻底清理流程
for VER in $OLD_VERSIONS; do
    echo -e "\n${RED}正在处理版本: $VER${NC}"
    
    # A. 动态获取该版本的所有包并 Purge
    RELATED_PKGS=$(dpkg --list | grep "^ii" | grep "$VER" | awk '{print $2}')
    if [ -n "$RELATED_PKGS" ]; then
        echo -e "Step 1: 正在 Purge 软件包..."
        apt-get purge -y $RELATED_PKGS
    fi

    # B. 强制物理清理（处理你遇到的 Directory not empty 问题）
    echo -e "Step 2: 正在强制清理物理残留..."
    # 清理模块目录
    [ -d "/lib/modules/$VER" ] && rm -rf "/lib/modules/$VER"
    # 清理 /boot 目录下所有包含该版本号的文件 (vmlinuz, initrd, config, System.map)
    rm -f /boot/*"$VER"*
done

# C. 自动清理孤儿依赖
echo -e "\n${BLUE}Step 3: 正在执行 autoremove 清理冗余依赖...${NC}"
apt-get autoremove --purge -y

# D. 更新引导
echo -e "\n${BLUE}Step 4: 正在更新 GRUB...${NC}"
update-grub

# 5. 结果确认
echo -e "\n${GREEN}--- 清理任务完成 ---${NC}"
echo -e "当前 /boot 目录内容："
ls -lh /boot | grep -E "vmlinuz|initrd"

echo -e "\n当前 GRUB 引导菜单有效项："
grep -i "menuentry" /boot/grub/grub.cfg | grep "Linux" | cut -d "'" -f 2 | sed 's/^/  /'