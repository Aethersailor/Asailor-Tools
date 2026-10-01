#!/usr/bin/env bash
# Conservative APT kernel cleanup for Debian, Proxmox VE and Armbian.
# Package contents identify kernels; names alone never authorize removal.
# Running, retained, held and boot-selected kernels are protected.
# Generated/unowned files are never deleted by this script.
set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C

die() { printf '错误: %s\n' "$*" >&2; exit 1; }
warn() { printf '警告: %s\n' "$*" >&2; }
usage() {
    cat <<'EOF'
用法: kernel_manager.sh [--dry-run] [--keep N]

  --dry-run  只读取系统状态并执行 APT 模拟，不创建锁或修改系统
  --keep N   每个内核风格/Armbian 硬件家族至少保留最新 N 个内核，默认 2
  -h, --help 显示帮助

当前运行内核、hold 内核和启动配置引用的内核始终保留。
PVE 还保留 proxmox-boot-tool 自动选择、手工选择及固定的内核。
--keep 1 是显式减少备用内核的选择，不能覆盖上述保护。
执行模式显示计划并要求从终端输入 y，不支持无人值守清理。
仅通过 APT purge 已确认的软件包；不执行 autoremove、不手删残留、不重启。
未知包布局、启动布局和读取错误会使脚本停止或保留无法确认的组件。
EOF
}
# Bash must parse this entire function before any maintenance starts. A
# truncated curl stream cannot execute purge without its verification tail.
main() {
DRY_RUN=0
KEEP=2
while (($#)); do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --keep)
            (($# >= 2)) || die '--keep 缺少数量。'
            [[ $2 =~ ^[1-9][0-9]?$ ]] || die '--keep 必须为 1 至 99 的整数。'
            KEEP=$2; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知参数: $1" ;;
    esac
    shift
done
((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))) || die '需要 Bash 4.4 或更新版本。'
((EUID == 0)) || die '请使用 root 权限运行。'
for command_name in apt-get apt-mark dpkg dpkg-query uname sort realpath sha256sum cat; do
    command -v "$command_name" >/dev/null || die "缺少必需命令: $command_name"
done
[[ $(uname -s) == Linux ]] || die '仅支持 Linux 系统。'
[[ ! -e /.dockerenv && ! -e /run/.containerenv && ! -e /run/systemd/container ]] || die '容器使用宿主内核，拒绝清理。'
if command -v systemd-detect-virt >/dev/null; then
    if container_type=$(systemd-detect-virt --container); then
        die "容器使用宿主内核，拒绝清理: $container_type"
    else
        detection_status=$?
        ((detection_status == 1)) || die '无法确认是否运行于容器。'
    fi
fi

# This lock serializes this tool only. APT's locked transaction is checked below.
GUARD_DIR=''
cleanup_guard() {
    if [[ -n $GUARD_DIR ]]; then
        rm -f -- "$GUARD_DIR/guard" "$GUARD_DIR/allowed" "$GUARD_DIR/receipt"
        rmdir -- "$GUARD_DIR"
    fi
}
trap cleanup_guard EXIT
if ((!DRY_RUN)); then
    command -v flock >/dev/null || die '缺少 flock。'
    exec 9>/run/lock/kernel-manager.lock
    flock -n 9 || die '另一个 kernel_manager 实例正在运行。'
fi
audit_dpkg() {
    local audit
    audit=$(dpkg --audit 2>&1) || die "dpkg 审计失败: $audit"
    [[ -z $audit ]] || die "包管理器状态不完整，请先修复: $audit"
}
inventory() {
    dpkg-query -W -f='${binary:Package};${db:Status-Status};${Version};${Architecture};${Depends}, ${Pre-Depends};${Armbian-Kernel-Version-Family}\n'
}
read_release_field() {
    local file=$1 key=$2 line value='' seen=0
    [[ -r $file ]] || die "无法读取 $file。"
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line == "$key="* ]]; then
            ((seen == 0)) || die "$file 包含重复的 $key。"
            seen=1; value=${line#*=}
            value=${value%\"}; value=${value#\"}
            value=${value%\'}; value=${value#\'}
        fi
    done <"$file"
    printf '%s' "$value"
}
valid_abi() { [[ $1 =~ ^[0-9][0-9A-Za-z.+~_-]*$ ]]; }
audit_dpkg
RUNNING_KERNEL=$(uname -r)
valid_abi "$RUNNING_KERNEL" || die "无法安全识别运行内核: $RUNNING_KERNEL"
NATIVE_ARCH=$(dpkg --print-architecture) || die '无法读取本机架构。'
INITIAL_INVENTORY=$(inventory) || die '无法读取已安装软件包。'
INITIAL_HOLDS=$(apt-mark showhold) || die '无法读取 hold 列表。'
declare -a PACKAGES=() ABIS=() CANDIDATES=() CANDIDATE_ABIS=()
declare -A VERSION=() ARCH=() DEPENDS=() META_ABI=() BY_BASE=()
declare -A FILES=() IMAGE=() IMAGE_PATH=() GROUP=() ORDER_VERSION=() COMPONENTS=()
declare -A PROTECTED=() HELD=() CANDIDATE_SET=()
while IFS=';' read -r package status version arch depends metadata; do
    [[ -n $package ]] || continue
    [[ $status == installed ]] || continue
    PACKAGES+=("$package")
    VERSION["$package"]=$version; ARCH["$package"]=$arch
    DEPENDS["$package"]=$depends; META_ABI["$package"]=$metadata
    base=${package%%:*}
    if [[ $arch == "$NATIVE_ARCH" || $arch == all ]]; then
        [[ -z ${BY_BASE[$base]+x} ]] || die "同名软件包架构不明确: $base"
        BY_BASE["$base"]=$package
    fi
done <<<"$INITIAL_INVENTORY"
while IFS= read -r package; do
    [[ -n $package ]] && HELD["${package%%:*}"]=1
done <<<"$INITIAL_HOLDS"
PLATFORM=Debian
ARM_FAMILY=''
if [[ -n ${BY_BASE[pve-manager]+x} ]]; then
    PLATFORM=PVE
elif [[ -e /etc/armbian-release ]]; then
    PLATFORM=Armbian
    ARM_FAMILY=$(read_release_field /etc/armbian-release LINUXFAMILY)
    [[ $ARM_FAMILY =~ ^[a-z0-9][a-z0-9-]*$ ]] || die '无法识别 Armbian LINUXFAMILY。'
else
    os_id=$(read_release_field /etc/os-release ID)
    [[ $os_id == debian || $os_id == ubuntu ]] || die "未适配的发行版: $os_id"
fi
load_files() {
    local package=$1
    if [[ -z ${FILES[$package]+x} ]]; then
        FILES["$package"]=$(dpkg-query -L "$package") || die "无法读取软件包文件清单: $package"
    fi
}
protect() {
    local abi=$1 reason=$2
    PROTECTED["$abi"]="${PROTECTED[$abi]:+${PROTECTED[$abi]}, }$reason"
}
verify_kernel_paths() {
    local package=$1 abi=$2 path owned_abi
    while IFS= read -r path; do
        owned_abi=''
        case "$path" in
            /lib/modules/*) owned_abi=${path#/lib/modules/}; owned_abi=${owned_abi%%/*} ;;
            /usr/lib/modules/*) owned_abi=${path#/usr/lib/modules/}; owned_abi=${owned_abi%%/*} ;;
            /boot/vmlinuz-*|/boot/vmlinux-*) owned_abi=${path#/boot/vmlinu?-} ;;
            /boot/initrd.img-*) owned_abi=${path#/boot/initrd.img-} ;;
            /boot/uInitrd-*) owned_abi=${path#/boot/uInitrd-} ;;
            /boot/dtb-*) owned_abi=${path#/boot/dtb-}; owned_abi=${owned_abi%%/*} ;;
        esac
        [[ -z $owned_abi || $owned_abi == "$abi" ]] || die "软件包包含其它 ABI 的启动/模块文件，拒绝清理: $package: $path"
    done <<<"${FILES[$package]}"
}
for package in "${PACKAGES[@]}"; do
    base=${package%%:*}
    [[ ${ARCH[$package]} == "$NATIVE_ARCH" || ${ARCH[$package]} == all ]] || continue
    case "$base" in
        *-dbg|*-dbgsym|*-signed-template) continue ;;
        linux-image-*|proxmox-kernel-*|pve-kernel-*) ;;
        *) continue ;;
    esac
    load_files "$package"
    found_abi=''; image_path=''
    while IFS= read -r path; do
        case "$path" in
            /boot/vmlinuz-*|/boot/vmlinux-*)
                abi=${path#/boot/vmlinu?-}
                valid_abi "$abi" || die "软件包包含异常内核路径: $package: $path"
                [[ -z $found_abi || $found_abi == "$abi" ]] || die "软件包包含多个内核，拒绝猜测: $package"
                found_abi=$abi; image_path=$path ;;
        esac
    done <<<"${FILES[$package]}"
    # Metapackages do not own a kernel image; unsigned suffixes do not matter.
    [[ -n $found_abi ]] || continue
    abi=$found_abi
    verify_kernel_paths "$package" "$abi"
    [[ -z ${IMAGE[$abi]+x} ]] || die "同一内核由多个镜像包拥有: $abi"
    IMAGE["$abi"]=$package; IMAGE_PATH["$abi"]=$image_path
    ABIS+=("$abi"); COMPONENTS["$abi"]=$package; ORDER_VERSION["$abi"]=$abi
    if [[ $PLATFORM == PVE ]]; then
        [[ $base == proxmox-kernel-* || $base == pve-kernel-* ]] && [[ $abi == *-pve ]] || die "PVE 安装了非 PVE 内核，请分开管理: $package"
        GROUP["$abi"]=pve
    elif [[ $PLATFORM == Armbian ]]; then
        [[ $base == linux-image-*"-$ARM_FAMILY" ]] || die "存在非当前硬件家族的内核: $package"
        suffix=${base#linux-image-}
        [[ $abi == *"-$suffix" ]] || die "Armbian 包名与内核文件不一致: $package: $abi"
        [[ -z ${META_ABI[$package]} || ${META_ABI[$package]} == "$abi" ]] || die "Armbian 内核元数据不一致: $package"
        GROUP["$abi"]="armbian-$ARM_FAMILY"; ORDER_VERSION["$abi"]=${abi%"-$suffix"}
    else
        if [[ $abi =~ ^[0-9][0-9A-Za-z.+~_]*(-[0-9][0-9A-Za-z.+~_]*)?-(.+)$ ]]; then
            GROUP["$abi"]=${BASH_REMATCH[2]}
        else
            die "无法识别内核风格: $abi"
        fi
    fi
done
((${#ABIS[@]})) || die '没有识别到由软件包实际拥有的内核镜像。'
[[ -n ${IMAGE[$RUNNING_KERNEL]+x} ]] || die '当前运行内核不属于已识别的镜像包，拒绝清理。'

# Attach only ABI-specific modules/headers/DTBs with file-content evidence.
for abi in "${ABIS[@]}"; do
    for package in "${PACKAGES[@]}"; do
        base=${package%%:*}
        [[ ${ARCH[$package]} == "$NATIVE_ARCH" || ${ARCH[$package]} == all ]] || continue
        matching=0
        case "$base" in
            "linux-headers-$abi"|"linux-modules-$abi"|"linux-modules-extra-$abi"|\
            "linux-binary-$abi"|"linux-binary-unsigned-$abi"|"linux-base-$abi"|\
            "proxmox-headers-$abi"|"pve-headers-$abi") matching=1 ;;
        esac
        if [[ $PLATFORM == Armbian ]]; then
            suffix=${IMAGE[$abi]%%:*}; suffix=${suffix#linux-image-}
            [[ $base == "linux-headers-$suffix" || $base == "linux-dtb-$suffix" ]] && matching=1
        fi
        ((matching)) || continue
        load_files "$package"
        evidence=0
        while IFS= read -r path; do
            case "$path" in
                "/lib/modules/$abi"|"/lib/modules/$abi/"*|"/usr/lib/modules/$abi"|"/usr/lib/modules/$abi/"*|\
                "/usr/src/linux-headers-$abi"|"/usr/src/linux-headers-$abi/"*|"/boot/dtb-$abi"|"/boot/dtb-$abi/"*) evidence=1 ;;
            esac
        done <<<"${FILES[$package]}"
        if ((evidence)); then
            verify_kernel_paths "$package" "$abi"
            [[ -z ${META_ABI[$package]} || ${META_ABI[$package]} == "$abi" ]] || die "组件元数据不一致: $package"
            COMPONENTS["$abi"]+=$'\n'"$package"
        else
            warn "未确认组件归属，保留: $package"
        fi
    done
done
protect "$RUNNING_KERNEL" '当前运行'
# Use dpkg's version comparison, not lexical ordering of kernel flavours.
declare -a SORTED_ABIS=() next=()
for abi in "${ABIS[@]}"; do
    inserted=0; next=()
    for other in "${SORTED_ABIS[@]}"; do
        if ((!inserted)) && dpkg --compare-versions "${ORDER_VERSION[$abi]}" gt "${ORDER_VERSION[$other]}"; then
            next+=("$abi"); inserted=1
        fi
        next+=("$other")
    done
    ((inserted)) || next+=("$abi")
    SORTED_ABIS=("${next[@]}")
done
declare -A GROUP_COUNT=()
for abi in "${SORTED_ABIS[@]}"; do
    group=${GROUP[$abi]}; count=${GROUP_COUNT[$group]:-0}
    if ((count < KEEP)); then protect "$abi" "保留 $group 最新 $KEEP 个"; fi
    GROUP_COUNT["$group"]=$((count + 1))
    while IFS= read -r package; do
        [[ -z ${HELD[${package%%:*}]+x} ]] || protect "$abi" "包已 hold: $package"
    done <<<"${COMPONENTS[$abi]}"
done
# All boot-tool selections are authoritative, including its automatic fallbacks.
PVE_SELECTION=''
if [[ $PLATFORM == PVE ]]; then
    command -v proxmox-boot-tool >/dev/null || die '缺少 proxmox-boot-tool。'
    PVE_SELECTION=$(proxmox-boot-tool kernel list 2>&1) || die "无法读取 PVE 内核选择: $PVE_SELECTION"
    section=''; saw_manual=0; saw_auto=0
    while IFS= read -r line; do
        case "$line" in
            'Manually selected kernels:') section=manual; saw_manual=1; continue ;;
            'Automatically selected kernels:') section=automatic; saw_auto=1; continue ;;
            'Pinned kernel:') section=pinned; continue ;;
            'Kernel pinned on next-boot:') section='next-boot'; continue ;;
        esac
        line=${line#"${line%%[![:space:]]*}"}; line=${line%"${line##*[![:space:]]}"}
        [[ -n $line ]] || continue
        valid_abi "$line" && [[ $line == *-pve && -n $section ]] || die "未知 PVE 内核列表格式: $line"
        [[ -n ${IMAGE[$line]+x} ]] || die "PVE 启动选择引用了未安装内核: $line"
        protect "$line" "PVE $section"
    done <<<"$PVE_SELECTION"
    ((saw_manual && saw_auto)) || die 'PVE 内核列表缺少必要分区。'
fi
boot_state() {
    local path
    local -a paths
    shopt -s nullglob
    paths=(/vmlinuz /initrd.img /boot/vmlinuz /boot/initrd.img
        /boot/Image /boot/zImage /boot/uImage /boot/uInitrd /boot/dtb
        /etc/kernel/proxmox-boot-manual-kernels /etc/kernel/proxmox-boot-pin
        /etc/kernel/next-boot-pin /etc/kernel/proxmox-boot-uuids
        /etc/default/grub /etc/default/grub.d/*.cfg /boot/grub/grubenv
        /boot/armbianEnv.txt /boot/boot.cmd /boot/extlinux/extlinux.conf
        /boot/loader/loader.conf /boot/loader/entries/*.conf)
    shopt -u nullglob
    for path in "${paths[@]}"; do
        printf '%s|' "$path"
        if [[ -L $path ]]; then realpath -e -- "$path" || return 1
        elif [[ -f $path ]]; then sha256sum -- "$path" || return 1
        elif [[ -e $path ]]; then
            [[ $path == /boot/dtb && -d $path ]] || return 1
            printf 'directory\n'
        else printf 'absent\n'
        fi
    done
}
INITIAL_BOOT_STATE=$(boot_state) || die '启动引用损坏或无法读取，拒绝清理。'
shopt -s nullglob
BOOT_CONFIGS=(/etc/default/grub /etc/default/grub.d/*.cfg /boot/armbianEnv.txt
    /boot/boot.cmd /boot/extlinux/extlinux.conf /boot/loader/loader.conf /boot/loader/entries/*.conf)
shopt -u nullglob
for path in "${BOOT_CONFIGS[@]}"; do
    [[ ! -e $path ]] && continue
    [[ -r $path ]] || die "无法读取启动配置: $path"
    content=$(cat -- "$path") || die "无法读取启动配置: $path"
    for abi in "${ABIS[@]}"; do
        escaped=${abi//./\\.}; escaped=${escaped//+/\\+}
        if [[ $content =~ (^|[^0-9A-Za-z.+~_-])$escaped([^0-9A-Za-z.+~_-]|$) || $content == *"gnulinux-$abi-"* ]]; then
            protect "$abi" "启动配置引用: $path"
        fi
    done
    if [[ $path == /etc/default/grub* ]]; then
        while IFS= read -r line; do
            if [[ $line =~ ^[[:space:]]*GRUB_DEFAULT=(.*)$ ]]; then
                choice=${BASH_REMATCH[1]}; choice=${choice%\"}; choice=${choice#\"}
                choice=${choice%\'}; choice=${choice#\'}
                default_known=0
                [[ $choice == 0 || $choice == saved || $choice == gnulinux-simple-* ]] && default_known=1
                for abi in "${ABIS[@]}"; do [[ $choice != *"gnulinux-$abi-"* ]] || default_known=1; done
                ((default_known)) || die "无法安全解析 GRUB_DEFAULT: $choice"
            fi
        done <<<"$content"
    fi
done
if [[ -e /boot/grub/grubenv ]]; then
    command -v grub-editenv >/dev/null || die '缺少 grub-editenv，无法检查保存的启动选择。'
    grub_environment=$(grub-editenv /boot/grub/grubenv list) || die '无法读取 GRUB 保存的启动选择。'
    for abi in "${ABIS[@]}"; do [[ $grub_environment != *"$abi"* ]] || protect "$abi" 'GRUB 保存的启动选择'; done
    while IFS= read -r line; do
        case "$line" in
            saved_entry=*|next_entry=*)
                choice=${line#*=}
                default_known=0
                [[ -z $choice || $choice == 0 || $choice == gnulinux-simple-* ]] && default_known=1
                for abi in "${ABIS[@]}"; do [[ $choice != *"gnulinux-$abi-"* ]] || default_known=1; done
                ((default_known)) || die "无法解析 GRUB 保存的启动选择: $line" ;;
        esac
    done <<<"$grub_environment"
fi
for path in /vmlinuz /initrd.img /boot/vmlinuz /boot/initrd.img /boot/Image /boot/zImage /boot/uImage /boot/uInitrd /boot/dtb; do
    [[ -L $path ]] || continue
    target=$(realpath -e -- "$path") || die "启动链接损坏: $path"
    matched=0
    for abi in "${ABIS[@]}"; do
        case "$target" in
            "${IMAGE_PATH[$abi]}"|"/boot/initrd.img-$abi"|"/boot/uInitrd-$abi"|"/boot/dtb-$abi"|"/boot/dtb-$abi/"*|"/usr/lib/linux-image-$abi/"*)
                protect "$abi" "启动链接: $path"; matched=1 ;;
        esac
    done
    ((matched)) || die "启动链接目标无法归属已安装内核: $path -> $target"
done
printf '%s\n' "--- $PLATFORM 内核安全管理助手 ---" "当前运行内核: $RUNNING_KERNEL" '受保护内核:'
for abi in "${SORTED_ABIS[@]}"; do
    if [[ -n ${PROTECTED[$abi]+x} ]]; then
        printf '  - %s (%s)\n' "$abi" "${PROTECTED[$abi]}"
        [[ -s ${IMAGE_PATH[$abi]} ]] || die "受保护内核镜像缺失: ${IMAGE_PATH[$abi]}"
        [[ -s /boot/initrd.img-$abi ]] || die "受保护内核 initrd 缺失: $abi"
        [[ -d /lib/modules/$abi && ! -L /lib/modules/$abi ]] || die "受保护内核模块目录异常: $abi"
    else
        CANDIDATE_ABIS+=("$abi")
        while IFS= read -r package; do CANDIDATE_SET["$package"]=1; done <<<"${COMPONENTS[$abi]}"
    fi
done
if ((${#CANDIDATE_ABIS[@]} == 0)); then
    printf '没有可清理的内核软件包。未归属软件包的旧文件不在自动删除范围内。\n'
    exit 0
fi
if [[ $PLATFORM == Armbian ]]; then
    [[ -L /boot/Image || -L /boot/zImage || -L /boot/uImage ]] || die 'Armbian 启动镜像没有可验证的版本链接；FAT/定制布局暂不自动清理。'
    [[ -L /boot/uInitrd ]] || die 'Armbian uInitrd 没有可验证的版本链接，拒绝清理。'
elif [[ $PLATFORM == Debian ]]; then
    command -v update-grub >/dev/null && [[ -d /boot/grub ]] || die '非 GRUB 的 Debian 启动布局暂不自动清理。'
fi
dependency_names() {
    local relations=${1//|/,} relation dependency
    local -a parts=()
    IFS=',' read -r -a parts <<<"$relations"
    for relation in "${parts[@]}"; do
        dependency=${relation#"${relation%%[![:space:]]*}"}
        dependency=${dependency%%[[:space:](]*}; dependency=${dependency%%:*}
        [[ -z $dependency ]] || printf '%s\n' "$dependency"
    done
}
# Common headers are shared: every installed reverse dependent must be in scope.
declare -A COMMON_HEADERS=()
for package in "${!CANDIDATE_SET[@]}"; do
    names=$(dependency_names "${DEPENDS[$package]}")
    while IFS= read -r base; do
        if [[ $base =~ ^linux-headers-[0-9].*-common(-rt)?$ && -n ${BY_BASE[$base]+x} ]]; then COMMON_HEADERS["${BY_BASE[$base]}"]=1; fi
    done <<<"$names"
done
for common in "${!COMMON_HEADERS[@]}"; do
    base=${common%%:*}; shared=0
    [[ -z ${HELD[$base]+x} ]] || continue
    load_files "$common"
    while IFS= read -r path; do
        case "$path" in /boot/*|/lib/modules/*|/usr/lib/modules/*) shared=1 ;; esac
    done <<<"${FILES[$common]}"
    for package in "${PACKAGES[@]}"; do
        [[ -z ${CANDIDATE_SET[$package]+x} ]] || continue
        names=$(dependency_names "${DEPENDS[$package]}")
        while IFS= read -r dependency; do [[ $dependency != "$base" ]] || shared=1; done <<<"$names"
    done
    ((shared)) || CANDIDATE_SET["$common"]=1
done
sorted_candidates=$(printf '%s\n' "${!CANDIDATE_SET[@]}" | sort) || die '无法排序删除清单。'
mapfile -t CANDIDATES <<<"$sorted_candidates"
printf '\n将精确 purge 以下软件包:\n'; printf '  - %s\n' "${CANDIDATES[@]}"
APT_OPTIONS=(-o APT::Get::AutomaticRemove=false -o APT::Get::Fix-Broken=false
    -o APT::Get::Ignore-Hold=false -o APT::Get::allow-Change-Held-Packages=false
    -o APT::Get::allow-Remove-Essential=false -o Debug::NoLocking=false)
validate_simulation() {
    local output=$1 action package rest normalized candidate
    local -A removed=()
    [[ ! $output =~ essential\ packages\ will\ be\ removed|(^|$'\n')WARNING: ]] || die 'APT 模拟包含高风险警告。'
    while IFS=' ' read -r action package rest; do
        case "$action" in
            Inst|Conf) die "APT 还计划安装或配置软件包，拒绝执行: $package" ;;
            Remv|Purg)
                normalized=$package
                if [[ -z ${CANDIDATE_SET[$normalized]+x} ]]; then normalized=${BY_BASE[${package%%:*}]:-}; fi
                [[ -n $normalized && -n ${CANDIDATE_SET[$normalized]+x} ]] || die "APT 计划删除未授权包: $package"
                [[ $package != *:* || ${package##*:} == "${ARCH[$normalized]}" ]] || die "APT 计划删除其它架构: $package"
                removed["$normalized"]=1 ;;
        esac
    done <<<"$output"
    for candidate in "${CANDIDATES[@]}"; do [[ -n ${removed[$candidate]+x} ]] || die "APT 模拟缺少预期删除: $candidate"; done
}
simulate() {
    local output
    output=$(apt-get -s "${APT_OPTIONS[@]}" purge -- "${CANDIDATES[@]}" 2>&1) || die "APT 模拟失败: $output"
    validate_simulation "$output"
    printf '%s\n' "$output"
}
SIMULATION=$(simulate) || exit 1
printf '%s\n' "$SIMULATION"
if ((DRY_RUN)); then printf '\n--dry-run 已完成，系统未被修改。\n'; exit 0; fi
((KEEP != 1)) || warn '--keep 1 会减少备用内核；运行内核及启动选择仍受保护。'
[[ -r /dev/tty && -w /dev/tty ]] || die '执行模式需要交互式终端，请使用 --dry-run。'
printf '\n是否执行上述精确清理？[y/N]: ' >/dev/tty
IFS= read -r confirmation </dev/tty || die '无法读取确认。'
[[ $confirmation =~ ^[Yy]$ ]] || { printf '操作已取消。\n'; exit 0; }
audit_dpkg
current_inventory=$(inventory) || die '无法重新读取软件包状态。'
current_holds=$(apt-mark showhold) || die '无法重新读取 hold 状态。'
current_boot=$(boot_state) || die '无法重新读取启动状态。'
[[ $current_inventory == "$INITIAL_INVENTORY" ]] || die '确认期间软件包状态改变，请重新运行。'
[[ $current_holds == "$INITIAL_HOLDS" ]] || die '确认期间 hold 状态改变，请重新运行。'
[[ $current_boot == "$INITIAL_BOOT_STATE" ]] || die '确认期间启动配置改变，请重新运行。'
if [[ $PLATFORM == PVE ]]; then
    current_selection=$(proxmox-boot-tool kernel list 2>&1) || die '无法重新读取 PVE 内核选择。'
    [[ $current_selection == "$PVE_SELECTION" ]] || die 'PVE 内核选择改变，请重新运行。'
fi
FINAL_SIMULATION=$(simulate) || exit 1
[[ $SIMULATION == "$FINAL_SIMULATION" ]] || die '确认期间 APT 计划改变，请重新运行。'

# Check APT's actual, locked transaction before dpkg. Protocol v3 includes the
# installed version and architecture. The hook also works with curl | bash.
for command_name in mktemp chmod rm rmdir; do command -v "$command_name" >/dev/null || die "缺少必需命令: $command_name"; done
GUARD_DIR=$(mktemp -d /run/kernel-manager.XXXXXXXX) || die '无法创建事务校验目录。'
chmod 700 "$GUARD_DIR"
for package in "${CANDIDATES[@]}"; do printf '%s:%s;%s\n' "${package%%:*}" "${ARCH[$package]}" "${VERSION[$package]}"; done >"$GUARD_DIR/allowed"
{
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\nexport LC_ALL=C\n'
    printf 'EXPECTED_BOOT=%q\nEXPECTED_KERNEL=%q\n' "$INITIAL_BOOT_STATE" "$RUNNING_KERNEL"
    declare -f boot_state
    cat <<'GUARD'
fail() { printf '错误: APT 事务校验拒绝执行: %s\n' "$*" >&2; exit 1; }
root=${0%/*}
[[ ${DPKG_FRONTEND_LOCKED:-} == true ]] || fail 'APT 没有持有前端锁。'
[[ $(uname -r) == "$EXPECTED_KERNEL" ]] || fail '运行内核改变。'
current_boot=$(boot_state) || fail '无法读取启动配置。'
[[ $current_boot == "$EXPECTED_BOOT" ]] || fail '启动配置改变。'
holds=$(apt-mark showhold) || fail '无法读取 hold 列表。'
declare -A allowed=() seen=() held=()
while IFS=';' read -r key version; do allowed["$key"]=$version; done <"$root/allowed"
while IFS= read -r name; do [[ -z $name ]] || held["${name%%:*}"]=1; done <<<"$holds"
IFS= read -r line || fail '没有事务协议头。'
[[ $line == 'VERSION 3' ]] || fail "不支持的事务协议: $line"
separator=0
while IFS= read -r line; do if [[ -z $line ]]; then separator=1; break; fi; done
((separator)) || fail '事务协议不完整。'
while IFS= read -r line || [[ -n $line ]]; do
    fields=(); IFS=' ' read -r -a fields <<<"$line"
    ((${#fields[@]} == 9)) || fail '事务动作格式不明确。'
    [[ ${fields[8]} == '**REMOVE**' ]] || fail "额外的安装/配置动作: ${fields[0]}"
    key=${fields[0]}:${fields[2]}
    [[ -n ${allowed[$key]+x} ]] || fail "未授权软件包或架构: $key"
    [[ ${allowed[$key]} == "${fields[1]}" ]] || fail "软件包版本改变: $key"
    [[ -z ${held[${fields[0]}]+x} ]] || fail "软件包已 hold: $key"
    seen["$key"]=1
done
for key in "${!allowed[@]}"; do [[ -n ${seen[$key]+x} ]] || fail "事务缺少预期删除: $key"; done
printf 'verified\n' >"$root/receipt"
GUARD
} >"$GUARD_DIR/guard"
chmod 700 "$GUARD_DIR/guard"
DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTIONS[@]}" \
    -o "DPkg::Pre-Install-Pkgs::=$GUARD_DIR/guard" \
    -o "DPkg::Tools::Options::$GUARD_DIR/guard::Version=3" \
    -o "DPkg::Tools::Options::$GUARD_DIR/guard::InfoFD=0" purge -y -- "${CANDIDATES[@]}"
[[ -s $GUARD_DIR/receipt ]] || die 'APT 未执行事务校验，不能确认操作结果。'
if [[ $PLATFORM == PVE && -s /etc/kernel/proxmox-boot-uuids ]]; then
    proxmox-boot-tool refresh || die 'PVE 启动分区同步失败，请检查后再重启。'
elif [[ $PLATFORM == Debian || ( $PLATFORM == PVE && -d /boot/grub ) ]]; then
    update-grub || die 'GRUB 更新失败，请检查后再重启。'
fi
audit_dpkg
FINAL_INVENTORY=$(inventory) || die '无法读取清理后的软件包状态。'
declare -A FINAL_STATUS=()
while IFS=';' read -r package status rest; do [[ -z $package ]] || FINAL_STATUS["$package"]=$status; done <<<"$FINAL_INVENTORY"
for package in "${CANDIDATES[@]}"; do [[ ${FINAL_STATUS[$package]:-not-installed} == not-installed ]] || die "软件包未完整 purge: $package"; done
for abi in "${!PROTECTED[@]}"; do
    package=${IMAGE[$abi]}
    [[ ${FINAL_STATUS[$package]:-} == installed && -s ${IMAGE_PATH[$abi]} && -s /boot/initrd.img-$abi && -d /lib/modules/$abi ]] || die "清理后受保护内核不完整: $abi"
done
printf '\n已完成精确的软件包清理，受保护内核通过文件与包状态校验。\n'
printf '未执行 autoremove、手工残留删除或重启；文件校验不等于实机启动验证。\n'
}

main "$@"
