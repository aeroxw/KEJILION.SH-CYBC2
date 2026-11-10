#!/bin/sh
# =============================================================================
# 云存宝 C2 存储配置脚本（独立版 / POSIX sh 兼容）
# -----------------------------------------------------------------------------
# 用途：把 Docker 镜像、应用数据、建站数据、包缓存与临时目录全部放到 M.2 SSD
#       上，避免撑爆 C2 的系统分区（以及 OpenWrt 上占内存的 /tmp、/var）。
#
# 运行环境：云存宝 C2 (OpenWrt 18.06 / aarch64 / busybox ash)，
#           也兼容任意带 busybox 或 coreutils 的 Linux。
#           不依赖 bash，不依赖 python，不依赖 jq。
#
# 用法：
#   sh c2_storage.sh              # 查看当前状态与可用的 SSD 挂载点
#   sh c2_storage.sh check        # 环境自检（系统 / 组件 / 磁盘）
#   sh c2_storage.sh apply        # 自动检测 SSD 并一键配置
#   sh c2_storage.sh apply /mnt/sda1/kejilion   # 指定目录配置
#   sh c2_storage.sh revert       # 恢复默认布局（数据搬回系统盘）
#
# 一键安装（在 C2 上直接执行）：
#   wget -O c2_storage.sh https://raw.githubusercontent.com/aeroxw/KEJILION.SH-CYBC2/main/c2_storage.sh
#   chmod +x c2_storage.sh && sh c2_storage.sh apply
#
# 原理：不去改动上游脚本里上百处硬编码路径，而是把数据目录整体迁移到 SSD，
#       再用符号链接接管原路径，这样既保证所有硬编码自动生效，
#       又不影响与上游仓库的合并。
# =============================================================================

C2_CONF_DIR="${C2_CONF_DIR:-/etc/kejilion}"
C2_CONF_FILE="${C2_CONF_FILE:-$C2_CONF_DIR/c2.conf}"
C2_DOCKER_CONF="${C2_DOCKER_CONF:-/etc/docker/daemon.json}"
C2_OPKG_CACHE="${C2_OPKG_CACHE:-/var/cache/opkg}"
C2_PROFILE_DIR="${C2_PROFILE_DIR:-/etc/profile.d}"
C2_PROFILE="${C2_PROFILE:-/etc/profile}"

RED=''
GREEN=''
YELLOW=''
BLUE=''
NC=''
if [ -t 1 ]; then
	RED='\033[31m'
	GREEN='\033[32m'
	YELLOW='\033[33m'
	BLUE='\033[34m'
	NC='\033[0m'
fi

info() { printf '%s\n' "$*"; }
ok() { printf '%s\n' "${GREEN}$*${NC}"; }
warn() { printf '%s\n' "${YELLOW}$*${NC}"; }
err() { printf '%s\n' "${RED}$*${NC}" >&2; }
title() {
	printf '%s\n' "${BLUE}$*${NC}"
	printf '%s\n' "------------------------------------------------"
}

# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------

# 统一取容量：兼容 GNU df 与 busybox df（长设备名时 GNU df 会折行）
# 输出两列：总容量(KB) 与 可用容量(KB)
df_kb() {
	_path="$1"
	_out=$(df -k -- "$_path" 2>/dev/null) || _out=$(df -k "$_path" 2>/dev/null) || return 1
	printf '%s\n' "$_out" | awk '
		NF >= 6 && $2 ~ /^[0-9]+$/ { tb = $2; ab = $4 }
		NF == 5 && $1 ~ /^[0-9]+$/ { tb = $1; ab = $3 }
		END { if (tb > 0) printf "%.0f\t%.0f\n", tb, ab }
	'
}

_kb_to_human() {
	printf '%s' "$1" | awk -F'\t' '
		{
			v = $1 / 1048576
			if (v >= 1024) printf "%.1fG", v / 1024
			else printf "%.0fM", v
		}
	'
}

df_size() {
	_vals=$(df_kb "$1") || return 1
	[ -n "$_vals" ] || return 1
	_kb_to_human "$(printf '%s' "$_vals" | cut -f1)"
}

df_avail() {
	_vals=$(df_kb "$1") || return 1
	[ -n "$_vals" ] || return 1
	_kb_to_human "$(printf '%s' "$_vals" | cut -f2)"
}

# 判断路径是否为独立挂载点
is_mounted() {
	_path="${1:-}"
	[ -n "$_path" ] || return 1
	_path="${_path%/}"
	[ -n "$_path" ] || _path="/"
	while read -r _dev _mp _fstype _rest; do
		[ "$_mp" = "$_path" ] && return 0
	done < /proc/mounts
	return 1
}

# 判断路径是否落在内存盘（tmpfs/ramfs）上
is_ramfs() {
	_path="${1:-}"
	[ -n "$_path" ] || return 1
	_path="${_path%/}"
	[ -n "$_path" ] || _path="/"
	while read -r _dev _mp _fstype _rest; do
		if [ "$_mp" = "$_path" ]; then
			case "$_fstype" in
				tmpfs|ramfs) return 0 ;;
			esac
			return 1
		fi
	done < /proc/mounts
	return 1
}

# 存储根是否与系统根位于同一设备
on_system_disk() {
	_root="${1:-/}"
	_root_dev=$(stat -c %d -- "$_root" 2>/dev/null) || return 1
	_sys_dev=$(stat -c %d -- / 2>/dev/null) || return 1
	[ -n "$_root_dev" ] && [ "$_root_dev" = "$_sys_dev" ]
}

# 设备是否为固态（非旋转）
dev_is_ssd() {
	_src="${1:-}"
	_base="${_src##*/}"
	[ -n "$_base" ] || return 2
	for _cand in "$_base" "${_base%p[0-9]}" "${_base%%[0-9]*}"; do
		if [ -e "/sys/block/$_cand/queue/rotational" ]; then
			[ "$(cat "/sys/block/$_cand/queue/rotational" 2>/dev/null)" = "0" ] && return 0
			return 1
		fi
	done
	return 2
}

# 块设备容量（读 /sys/block/<name>/size，单位为 512 字节扇区）
block_size_human() {
	_name="${1:-}"
	_sectors=$(cat "/sys/block/$_name/size" 2>/dev/null)
	[ -n "$_sectors" ] || return 1
	_gb=$((_sectors / 2097152))
	if [ "$_gb" -gt 0 ]; then
		printf '%sG' "$_gb"
	else
		printf '%sM' "$((_sectors * 512 / 1048576))"
	fi
}

# ---------------------------------------------------------------------------
# 符号链接与迁移
# ---------------------------------------------------------------------------

# 链接当前是否已指向目标目录
symlink_points_to() {
	_link="${1:-}"
	_target="${2:-}"
	[ -n "$_link" ] && [ -n "$_target" ] || return 1
	[ -L "$_link" ] || return 1
	[ -d "$_target" ] || return 1
	_current=$(readlink "$_link" 2>/dev/null)
	[ -n "$_current" ] || return 1
	[ "$_current" = "$_target" ] && return 0
	case "$_current" in
		/*) _abs="$_current" ;;
		*) _abs="$(dirname "$_link")/$_current" ;;
	esac
	[ "$_abs" = "$_target" ] && return 0
	_resolved=$(readlink -f "$_link" 2>/dev/null)
	[ -n "$_resolved" ] || return 1
	[ "$_resolved" = "$(readlink -f "$_target" 2>/dev/null)" ] && return 0
	return 1
}

# 建立符号链接，已指向同一目标时不做任何改动
make_symlink() {
	_link="${1:-}"
	_target="${2:-}"
	[ -n "$_link" ] && [ -n "$_target" ] || return 1
	mkdir -p "$(dirname "$_link")" 2>/dev/null
	if [ -L "$_link" ]; then
		symlink_points_to "$_link" "$_target" && return 0
		rm -f "$_link"
	elif [ -d "$_link" ]; then
		# 空目录占用时先移除，避免 ln -s 失败
		rmdir "$_link" 2>/dev/null || return 1
	fi
	ln -s "$_target" "$_link"
}

# 把源目录内容迁移到目标目录，随后源目录被软链接接管
# POSIX 兼容：不使用 bash 的 shopt dotglob，隐藏文件通过 find 一并迁移
migrate_dir() {
	_src="${1:-}"
	_dst="${2:-}"
	[ -n "$_src" ] && [ -n "$_dst" ] || return 1
	# 目标路径转为绝对路径，避免 cd 之后相对路径失效
	case "$_dst" in
		/*) ;;
		*) _dst="$(pwd)/$_dst" ;;
	esac
	[ -d "$_dst" ] || mkdir -p "$_dst" || return 1
	if [ -L "$_src" ]; then
		symlink_points_to "$_src" "$_dst" && return 0
		rm -f "$_src"
	fi
	if [ -d "$_src" ] && [ ! -L "$_src" ]; then
		( cd "$_src" && find . -mindepth 1 -maxdepth 1 -exec mv -f {} "$_dst/" \; ) >/dev/null 2>&1
		# 迁移后源目录应为空；非空说明仍有残留，保留原目录以免丢数据
		rmdir "$_src" 2>/dev/null || true
	fi
	return 0
}

# ---------------------------------------------------------------------------
# 配置文件
# ---------------------------------------------------------------------------

conf_load() {
	C2_ENABLED="false"
	C2_STORAGE_ROOT=""
	[ -f "$C2_CONF_FILE" ] || return 0
	_enabled=$(sed -n 's/^[[:space:]]*C2_ENABLED[[:space:]]*=[[:space:]]*\(.*\)$/\1/p' "$C2_CONF_FILE" 2>/dev/null | head -n1 | tr -d '"'"'"'[:space:]')
	_root=$(sed -n 's/^[[:space:]]*C2_STORAGE_ROOT[[:space:]]*=[[:space:]]*\(.*\)$/\1/p' "$C2_CONF_FILE" 2>/dev/null | head -n1 | tr -d '"'"'"' ')
	[ "$_enabled" = "true" ] && C2_ENABLED="true"
	case "$_root" in
		/*) C2_STORAGE_ROOT="$_root" ;;
	esac
	[ -n "$C2_STORAGE_ROOT" ] || C2_ENABLED="false"
	return 0
}

conf_save() {
	_root="${1:-}"
	case "$_root" in
		/*) ;;
		*) return 1 ;;
	esac
	mkdir -p "$C2_CONF_DIR" 2>/dev/null || return 1
	cat > "$C2_CONF_FILE" << EOF
# 云存宝 C2 存储配置（由 c2_storage.sh 生成，请勿手工编辑）
C2_ENABLED="true"
C2_STORAGE_ROOT="$_root"
EOF
	chmod 0644 "$C2_CONF_FILE" 2>/dev/null
	C2_ENABLED="true"
	C2_STORAGE_ROOT="$_root"
	return 0
}

conf_clear() {
	rm -f "$C2_CONF_FILE" 2>/dev/null
	C2_ENABLED="false"
	C2_STORAGE_ROOT=""
	return 0
}

# ---------------------------------------------------------------------------
# Docker data-root（不依赖 jq，纯 POSIX 实现）
# ---------------------------------------------------------------------------

write_data_root() {
	_target="${1:-}"
	_conf="$C2_DOCKER_CONF"
	[ -n "$_target" ] || return 1
	mkdir -p "$(dirname "$_conf")" 2>/dev/null || return 1
	mkdir -p "$_target" 2>/dev/null || return 1

	if [ -f "$_conf" ] && [ -s "$_conf" ]; then
		cp -p "$_conf" "$_conf.bak.$(date +%s)" 2>/dev/null || true
		if grep -q '"data-root"' "$_conf" 2>/dev/null; then
			# 已有 data-root：就地替换其值，保留其它配置
			# 使用 BRE 语法（不用 -r），兼容 busybox sed
			sed "s#\(\"data-root\"[[:space:]]*:[[:space:]]*\)\"[^\"]*\"#\1\"$_target\"#" "$_conf" > "$_conf.tmp" 2>/dev/null && mv -f "$_conf.tmp" "$_conf"
		elif [ "$(tr -d ' \t\r\n' < "$_conf")" = "{}" ]; then
			printf '{"data-root": "%s"}\n' "$_target" > "$_conf.tmp" 2>/dev/null && mv -f "$_conf.tmp" "$_conf"
		else
			# 在第一个 { 之后插入 data-root，保留原有其它键
			awk -v dr="$_target" '{
				if (!done) {
					p = index($0, "{")
					if (p > 0) {
						print substr($0, 1, p) "\"data-root\": \"" dr "\", " substr($0, p + 1)
						done = 1
						next
					}
				}
				print
			}' "$_conf" > "$_conf.tmp" 2>/dev/null && mv -f "$_conf.tmp" "$_conf"
		fi
	else
		printf '{"data-root": "%s"}\n' "$_target" > "$_conf" 2>/dev/null || return 1
	fi
	return 0
}

# 恢复时把 data-root 写回默认值，而不是从 JSON 里删键
# （从 JSON 删键容易留下尾随逗号导致 dockerd 解析失败）
reset_data_root() {
	write_data_root "/var/lib/docker"
}

# ---------------------------------------------------------------------------
# 服务启停：兼容 systemd / rc.service / service / init.d / 裸 dockerd
# ---------------------------------------------------------------------------

service_action() {
	_action="${1:-}"
	_name="${2:-docker}"
	case "$_action" in
		start|stop|restart|reload|status) ;;
		*) return 1 ;;
	esac
	[ -n "$_name" ] || return 1
	if command -v systemctl >/dev/null 2>&1; then
		systemctl "$_action" "$_name" >/dev/null 2>&1 && return 0
	fi
	if command -v rc-service >/dev/null 2>&1; then
		rc-service "$_name" "$_action" >/dev/null 2>&1 && return 0
	fi
	if command -v service >/dev/null 2>&1; then
		service "$_name" "$_action" >/dev/null 2>&1 && return 0
	fi
	if [ -x "/etc/init.d/$_name" ]; then
		"/etc/init.d/$_name" "$_action" >/dev/null 2>&1 && return 0
	fi
	return 1
}

docker_running() {
	if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
		return 0
	fi
	if command -v pidof >/dev/null 2>&1 && pidof dockerd >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

docker_service_action() {
	_action="${1:-}"
	case "$_action" in
		start|stop|restart|reload) ;;
		*) return 1 ;;
	esac
	service_action "$_action" docker && return 0
	# OpenWrt 的 dockerd 包服务名通常是 dockerd
	service_action "$_action" dockerd && return 0
	return 1
}

# ---------------------------------------------------------------------------
# 挂载点检测
# ---------------------------------------------------------------------------

# 列出可作为 SSD 存储的候选挂载点
detect_candidates() {
	while read -r _dev _mp _fstype _rest; do
		case "$_fstype" in
			tmpfs|devtmpfs|proc|sysfs|cgroup|cgroup2|overlay|squashfs|ramfs|fuseblk|efivarfs|debugfs|tracefs|securityfs|mqueue|hugetlbfs|configfs|pstore|bpf|binfmt_misc|nsfs|autofs|rootfs|udf|iso9660) continue ;;
		esac
		[ "$_mp" = "/" ] && continue
		[ -d "$_mp" ] || continue
		_size=$(df_size "$_mp")
		[ -n "$_size" ] || continue
		if dev_is_ssd "$_dev"; then _kind="SSD"; else _kind="HDD"; fi
		printf '%s\t%s\t%s\t%s\n' "$_mp" "$_dev" "$_size" "$_kind"
	done < /proc/mounts
}

list_disks() {
	_dev _mp _fstype _base _size
	printf '%s\n' "已挂载的块设备:"
	while read -r _dev _mp _fstype _rest; do
		case "$_fstype" in
			tmpfs|devtmpfs|proc|sysfs|cgroup|cgroup2|overlay|squashfs|ramfs|efivarfs|debugfs|tracefs|securityfs|mqueue|hugetlbfs|configfs|pstore|bpf|binfmt_misc|nsfs|autofs|rootfs|udf|iso9660) continue ;;
		esac
		_base="${_dev##*/}"
		case "$_base" in
			loop*|ram*|zram*|dm-*) continue ;;
		esac
		_size=$(df_size "$_mp")
		if dev_is_ssd "$_dev"; then
			printf '  %s  设备=%s  容量=%s  类型=SSD\n' "$_mp" "$_dev" "${_size:-未知}"
		else
			printf '  %s  设备=%s  容量=%s  类型=HDD/其它\n' "$_mp" "$_dev" "${_size:-未知}"
		fi
	done < /proc/mounts
	printf '%s\n' "未挂载的块设备:"
	for _dev in /dev/sd? /dev/nvme?n? /dev/mmcblk?; do
		[ -b "$_dev" ] || continue
		_base="${_dev##*/}"
		if awk -v d="$_dev" '$1==d || index($1, d)==1 {found=1} END{exit found?0:1}' /proc/mounts 2>/dev/null; then
			continue
		fi
		_size=$(block_size_human "$_base")
		if [ -n "$_size" ]; then
			printf '  %s  容量=%s  (尚未挂载，需先格式化并挂载)\n' "$_dev" "$_size"
		else
			printf '  %s  (尚未挂载，需先格式化并挂载)\n' "$_dev"
		fi
	done
}

# ---------------------------------------------------------------------------
# 状态 / 自检
# ---------------------------------------------------------------------------

show_status() {
	conf_load
	title "云存宝C2 存储状态"
	if [ -f /etc/openwrt_release ]; then
		printf '%s\n' "系统: OpenWrt"
	fi
	if [ "$C2_ENABLED" = "true" ] && [ -n "$C2_STORAGE_ROOT" ]; then
		_root="${C2_STORAGE_ROOT%/}"
		printf '%s\n' "模式: ${GREEN}已启用 SSD 存储${NC}"
		printf '%s\n' "存储根目录: $_root"
		if on_system_disk "$_root"; then
			printf '%s\n' "${YELLOW}警告: 存储根目录仍在系统盘上，软件并没有真正装到 SSD${NC}"
		fi
		if is_ramfs "$_root"; then
			printf '%s\n' "${YELLOW}警告: 存储根目录位于内存盘(tmpfs)上，重启后会丢失${NC}"
		fi
		for _item in "$_root/docker" "$_root/web" "$_root/docker-data"; do
			[ -d "$_item" ] && printf '  %s  %s  可用 %s\n' "$_item" "$(df_size "$_item")" "$(df_avail "$_item")"
		done
		printf '%s\n' "/home/docker -> $(readlink -f /home/docker 2>/dev/null || echo '未链接')"
		printf '%s\n' "/home/web    -> $(readlink -f /home/web 2>/dev/null || echo '未链接')"
		if [ -f "$C2_DOCKER_CONF" ]; then
			printf '%s\n' "Docker data-root: $(sed -n 's/.*"data-root"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$C2_DOCKER_CONF" 2>/dev/null | head -n1)"
		fi
	else
		printf '%s\n' "模式: ${YELLOW}未启用（软件安装在系统盘）${NC}"
	fi
	printf '%s\n' "------------------------------------------------"
}

show_check() {
	title "云存宝C2 环境自检"
	if [ -f /etc/openwrt_release ]; then
		printf '%s\n' "系统: OpenWrt ($(tr '\n' ' ' < /etc/openwrt_release | cut -c1-70))"
		printf '%s\n' "${YELLOW}      OpenWrt 默认没有 bash 与 Docker，需要先补齐基础组件${NC}"
	elif [ -f /etc/os-release ]; then
		printf '%s\n' "系统: $(grep -m1 '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d'"' -f2)"
	else
		printf '%s\n' "系统: $(uname -srm)"
	fi
	printf '%s\n' "架构: $(uname -m)"
	printf '%s\n' "Shell: $0"
	for _pm in apt dnf yum apk pacman zypper opkg; do
		if command -v "$_pm" >/dev/null 2>&1; then
			printf '%s\n' "包管理器: $_pm"
			break
		fi
	done
	for _c in curl git jq tar unzip docker dockerd; do
		if command -v "$_c" >/dev/null 2>&1; then
			printf '%s\n' "组件: $_c  已安装"
		else
			printf '%s\n' "组件: $_c  ${YELLOW}缺失${NC}"
		fi
	done
	for _p in /tmp /var; do
		if is_ramfs "$_p"; then
			printf '%s\n' "${YELLOW}注意: $_p 位于内存盘(tmpfs)上，大文件请放到 SSD${NC}"
		fi
	done
	printf '%s\n' "---- 磁盘 ----"
	list_disks
	printf '%s\n' "------------------------------------------------"
}

# ---------------------------------------------------------------------------
# 应用 / 恢复
# ---------------------------------------------------------------------------

setup_cache() {
	_root="${1:-}"
	_cache="$_root/cache"
	mkdir -p "$_cache/apt/archives/partial" "$_cache/npm" "$_cache/pip" "$_cache/opkg" "$_cache/tmp" "$_root/backup" 2>/dev/null || return 1

	# apt（Debian/Ubuntu 系）
	if [ -d /etc/apt/apt.conf.d ]; then
		cat > /etc/apt/apt.conf.d/99kejilion-c2-storage.conf << EOF
Dir::Cache "$_cache/apt/";
Dir::Cache::archives "$_cache/apt/archives/";
EOF
	fi

	# opkg（OpenWrt / 嵌入式设备）：包下载缓存默认落在内存盘
	if command -v opkg >/dev/null 2>&1; then
		if [ -d "$C2_OPKG_CACHE" ] && [ ! -L "$C2_OPKG_CACHE" ]; then
			migrate_dir "$C2_OPKG_CACHE" "$_cache/opkg" >/dev/null 2>&1
			make_symlink "$C2_OPKG_CACHE" "$_cache/opkg" >/dev/null 2>&1
		fi
	fi

	command -v npm >/dev/null 2>&1 && npm config set cache "$_cache/npm" >/dev/null 2>&1
	command -v pip3 >/dev/null 2>&1 && pip3 config set global.cache-dir "$_cache/pip" >/dev/null 2>&1

	# 临时目录指向 SSD（OpenWrt 的 /tmp 是内存盘）
	mkdir -p "$C2_PROFILE_DIR" 2>/dev/null
	if [ -d "$C2_PROFILE_DIR" ]; then
		cat > "$C2_PROFILE_DIR/99kejilion-c2-storage.sh" << EOF
# 云存宝C2: 临时目录指向 SSD，避免 /tmp 内存盘被撑爆
export TMPDIR="$_cache/tmp"
EOF
		chmod 0644 "$C2_PROFILE_DIR/99kejilion-c2-storage.sh" 2>/dev/null
	fi
	if [ -f "$C2_PROFILE" ] && ! grep -q 'kejilion-c2-storage' "$C2_PROFILE" 2>/dev/null; then
		{
			printf '\n'
			printf '%s\n' "# kejilion-c2-storage: 临时目录指向 SSD"
			printf '%s\n' "[ -d \"$_cache/tmp\" ] && export TMPDIR=\"$_cache/tmp\""
		} >> "$C2_PROFILE" 2>/dev/null
	fi
	return 0
}

apply_storage() {
	_root="${1:-}"
	[ -n "$_root" ] || return 1
	_root="${_root%/}"
	case "$_root" in
		/*) ;;
		*) err "无效的存储目录: $_root"; return 1 ;;
	esac
	mkdir -p "$_root" 2>/dev/null || { err "无法创建存储目录: $_root"; return 1; }

	if on_system_disk "$_root"; then
		warn "警告: $_root 仍位于系统盘上，软件不会真正安装到 SSD。"
		printf '%s\n' "请确认 SSD 已挂载，并选择挂载点下的目录。"
		return 1
	fi
	if is_ramfs "$_root"; then
		warn "警告: $_root 位于内存盘(tmpfs)上，重启后数据会丢失。"
	fi

	_docker_target="$_root/docker"
	_web_target="$_root/web"
	_data_target="$_root/docker-data"
	mkdir -p "$_docker_target" "$_web_target" "$_data_target" 2>/dev/null || { err "无法创建子目录"; return 1; }

	_was_running=0
	docker_running && _was_running=1
	if [ "$_was_running" = "1" ]; then
		printf '%s\n' "正在停止 Docker 以便安全迁移数据..."
		command -v docker >/dev/null 2>&1 && docker stop $(docker ps -q 2>/dev/null) >/dev/null 2>&1
		docker_service_action stop
	fi

	printf '%s\n' "正在迁移 Docker 存储目录 (/var/lib/docker)..."
	if [ -d /var/lib/docker ] && [ ! -L /var/lib/docker ]; then
		migrate_dir /var/lib/docker "$_data_target" || { err "迁移 Docker 存储目录失败"; return 1; }
	fi

	printf '%s\n' "正在迁移应用数据目录 (/home/docker)..."
	migrate_dir /home/docker "$_docker_target" || { err "迁移 /home/docker 失败"; return 1; }

	printf '%s\n' "正在迁移建站目录 (/home/web)..."
	migrate_dir /home/web "$_web_target" || { err "迁移 /home/web 失败"; return 1; }

	make_symlink /home/docker "$_docker_target" || { err "创建 /home/docker 链接失败"; return 1; }
	make_symlink /home/web "$_web_target" || { err "创建 /home/web 链接失败"; return 1; }

	printf '%s\n' "正在设置 Docker data-root..."
	write_data_root "$_data_target" || warn "设置 Docker data-root 失败，可稍后重试"

	setup_cache "$_root" || warn "配置缓存目录失败"

	conf_save "$_root" || { err "保存配置失败"; return 1; }

	if [ "$_was_running" = "1" ]; then
		printf '%s\n' "正在启动 Docker..."
		docker_service_action start
	fi

	ok "软件安装目录已切换到 SSD: $_root"
	return 0
}

revert_storage() {
	conf_load
	if [ "$C2_ENABLED" != "true" ] || [ -z "$C2_STORAGE_ROOT" ]; then
		printf '%s\n' "当前未启用 C2 存储模式"
		return 0
	fi
	_root="${C2_STORAGE_ROOT%/}"

	_was_running=0
	docker_running && _was_running=1
	if [ "$_was_running" = "1" ]; then
		command -v docker >/dev/null 2>&1 && docker stop $(docker ps -q 2>/dev/null) >/dev/null 2>&1
		docker_service_action stop
	fi

	[ -L /home/docker ] && rm -f /home/docker
	[ -L /home/web ] && rm -f /home/web
	mkdir -p /home/docker /home/web /var/lib/docker 2>/dev/null
	[ -d "$_root/docker" ] && migrate_dir "$_root/docker" /home/docker >/dev/null 2>&1
	[ -d "$_root/web" ] && migrate_dir "$_root/web" /home/web >/dev/null 2>&1
	[ -d "$_root/docker-data" ] && migrate_dir "$_root/docker-data" /var/lib/docker >/dev/null 2>&1

	reset_data_root
	conf_clear
	rm -f /etc/apt/apt.conf.d/99kejilion-c2-storage.conf 2>/dev/null
	rm -f "$C2_PROFILE_DIR/99kejilion-c2-storage.sh" 2>/dev/null

	if [ "$_was_running" = "1" ]; then
		docker_service_action start
	fi
	ok "已恢复默认布局，软件数据回到系统盘"
	return 0
}

auto_apply() {
	_candidates=$(detect_candidates)
	if [ -z "$_candidates" ]; then
		warn "未检测到独立的存储挂载点"
		printf '%s\n' "请确认 SSD 已正确挂载（OpenWrt 上通常在 /mnt/<分区>），"
		printf '%s\n' "或使用 apply <目录> 手动指定，例如: sh c2_storage.sh apply /mnt/sda1/kejilion"
		return 1
	fi
	printf '%s\n' "检测到的存储挂载点:"
	printf '%s' "$_candidates" | awk -F'\t' '{printf "  %s  设备=%s  容量=%s  类型=%s\n", $1, $2, $3, $4}'
	# 优先选择 SSD
	_pick=$(printf '%s\n' "$_candidates" | awk -F'\t' '$4=="SSD" {print $1; exit}')
	[ -n "$_pick" ] || _pick=$(printf '%s\n' "$_candidates" | awk -F'\t' 'NR==1 {print $1}')
	[ -n "$_pick" ] || { err "无效的挂载点"; return 1; }
	printf '%s\n' "将使用存储目录: $_pick/kejilion"
	apply_storage "$_pick/kejilion"
}

usage() {
	cat << EOF
云存宝 C2 存储配置脚本（独立版 / POSIX sh 兼容）

用法:
  sh c2_storage.sh                     查看当前状态与可用的 SSD 挂载点
  sh c2_storage.sh status              查看当前状态
  sh c2_storage.sh check               环境自检（系统 / 组件 / 磁盘）
  sh c2_storage.sh apply               自动检测 SSD 并一键配置
  sh c2_storage.sh apply <目录>        指定目录配置，例如 /mnt/sda1/kejilion
  sh c2_storage.sh revert              恢复默认布局（数据搬回系统盘）
EOF
}

main() {
	_cmd="${1:-status}"
	case "$_cmd" in
		status|"")
			show_status
			printf '%s\n' ""
			title "可用的存储挂载点"
			detect_candidates | awk -F'\t' '{printf "  %s  设备=%s  容量=%s  类型=%s\n", $1, $2, $3, $4}'
			printf '%s\n' "------------------------------------------------"
			;;
		check) show_check ;;
		apply)
			if [ -n "${2:-}" ]; then
				apply_storage "$2"
			else
				auto_apply
			fi
			;;
		revert) revert_storage ;;
		-h|--help|help) usage ;;
		*)
			err "未知命令: $_cmd"
			usage
			exit 1
			;;
	esac
}

# C2_STORAGE_LIB_ONLY=1 时只加载函数不执行，供测试引用
if [ "${C2_STORAGE_LIB_ONLY:-0}" != "1" ]; then
	main "$@"
fi
