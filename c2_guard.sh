#!/bin/sh
# =============================================================================
# 云存宝 C2 定制守护（独立版 / POSIX sh 兼容）
# -----------------------------------------------------------------------------
# 背景：
#   KPanel 这类第三方应用在安装时会把上游版本的 kejilion.sh 直接覆盖到
#   /usr/local/bin/k 与 /root/kejilion.sh（KPanel 的 sharedScriptMigration）。
#   上游脚本里的 install_add_docker_cn 用 `cat > /etc/docker/daemon.json` 写配置，
#   一旦触发就会抹掉 data-root / allow-direct-routing / exec-opts 等
#   C2 必须的设置，导致 Docker 数据退回系统盘、容器网络直接建不起来。
#
#   本脚本独立于 kejilion.sh 运行，负责把 C2 定制守住：
#     1. 共享脚本：/usr/local/bin/k、/root/kejilion.sh、/usr/bin/k 软链必须保持 C2 版
#     2. Docker 配置：/etc/docker/daemon.json 的 SSD 与容器网络必需项
#     3. containerd：/etc/containerd/config.toml 的 root 必须落在 SSD
#     4. 目录软链：/home/docker、/home/web 必须指向 SSD
#     5. 存储挂载：存储根未挂载时告警
#
# 用法：
#   sh c2_guard.sh check              # 校验并修复（守护默认动作）
#   sh c2_guard.sh status            # 只读体检，不做任何修改
#   sh c2_guard.sh install           # 安装 systemd 定时器 + 路径监视并启用
#   sh c2_guard.sh uninstall         # 停用并移除 systemd 单元
#
# 环境变量（测试用）：
#   C2_CONF_FILE      配置文件路径，默认 /etc/kejilion/c2.conf
#   C2_GUARD_LOG      日志路径，默认 /var/log/c2-guard.log
#   C2_GUARD_NO_DOCKER_RESTART=1  修复 Docker 配置后不重启 dockerd
# =============================================================================

C2_CONF_FILE="${C2_CONF_FILE:-/etc/kejilion/c2.conf}"
C2_DOCKER_CONF="${C2_DOCKER_CONF:-/etc/docker/daemon.json}"
C2_CONTAINERD_CONF="${C2_CONTAINERD_CONF:-/etc/containerd/config.toml}"
C2_GUARD_LOG="${C2_GUARD_LOG:-/var/log/c2-guard.log}"
C2_GUARD_SBIN="${C2_GUARD_SBIN:-/usr/local/sbin/c2-guard}"
C2_GUARD_UNIT_DIR="${C2_GUARD_UNIT_DIR:-/etc/systemd/system}"
C2_LOG_MAX_BYTES="${C2_LOG_MAX_BYTES:-524288}"
# 受守护的路径（测试时可覆盖）
C2_GUARD_SCRIPT_PATH="${C2_GUARD_SCRIPT_PATH:-/usr/local/bin/k}"
C2_GUARD_ROOT_SCRIPT="${C2_GUARD_ROOT_SCRIPT:-/root/kejilion.sh}"
C2_GUARD_BIN_LINK="${C2_GUARD_BIN_LINK:-/usr/bin/k}"
C2_GUARD_HOME_DOCKER="${C2_GUARD_HOME_DOCKER:-/home/docker}"
C2_GUARD_HOME_WEB="${C2_GUARD_HOME_WEB:-/home/web}"

# C2 版脚本的标志：上游没有 c2_menu 函数
C2_SCRIPT_MARKER="${C2_SCRIPT_MARKER:-c2_menu()}"
# 判定脚本体积下限，避免把残缺文件当成有效脚本
C2_SCRIPT_MIN_BYTES="${C2_SCRIPT_MIN_BYTES:-200000}"
# 权威副本与下载地址（权威副本放在 SSD 上，系统盘重装也不丢）
C2_SCRIPT_URLS="${C2_SCRIPT_URLS:-https://raw.githubusercontent.com/aeroxw/KEJILION.SH-CYBC2/main/kejilion.sh
https://ghproxy.net/https://raw.githubusercontent.com/aeroxw/KEJILION.SH-CYBC2/main/kejilion.sh
https://gh.kejilion.pro/raw.githubusercontent.com/aeroxw/KEJILION.SH-CYBC2/main/kejilion.sh}"

C2_DEFAULT_MIRRORS='["https://docker.xuanyuan.me","https://docker.1ms.run","https://docker.m.daocloud.io"]'
C2_DEFAULT_DNS='["223.5.5.5","119.29.29.29"]'

RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
if [ -t 1 ]; then
	RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[34m'; NC='\033[0m'
fi

info() { printf '%s\n' "$*"; }
ok()   { printf '%s\n' "${GREEN}$*${NC}"; }
warn() { printf '%s\n' "${YELLOW}$*${NC}"; }
err()  { printf '%s\n' "${RED}$*${NC}" >&2; }
title() {
	printf '%s\n' "${BLUE}$*${NC}"
	printf '%s\n' "------------------------------------------------"
}

have_cmd() {
	command -v "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# 日志
# ---------------------------------------------------------------------------

log() {
	[ -n "${C2_GUARD_LOG:-}" ] || return 0
	_mkdir=$(dirname "$C2_GUARD_LOG") 2>/dev/null
	[ -d "$_mkdir" ] || mkdir -p "$_mkdir" 2>/dev/null || return 0
	# 超限则保留末尾若干行，避免日志无限增长
	if [ -f "$C2_GUARD_LOG" ]; then
		_size=$(wc -c < "$C2_GUARD_LOG" 2>/dev/null | tr -d ' ')
		case "$_size" in
			''|*[!0-9]*) _size=0 ;;
		esac
		if [ "$_size" -gt "$C2_LOG_MAX_BYTES" ]; then
			tail -n 200 "$C2_GUARD_LOG" > "$C2_GUARD_LOG.trim" 2>/dev/null &&
				mv -f "$C2_GUARD_LOG.trim" "$C2_GUARD_LOG" 2>/dev/null
		fi
	fi
	printf '%s [c2-guard] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$C2_GUARD_LOG" 2>/dev/null
	return 0
}

# ---------------------------------------------------------------------------
# 配置
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

# ---------------------------------------------------------------------------
# 共享脚本
# ---------------------------------------------------------------------------

# 文件是否为 C2 版脚本
script_is_c2() {
	_f="${1:-}"
	[ -f "$_f" ] || return 1
	_size=$(wc -c < "$_f" 2>/dev/null | tr -d ' ')
	case "$_size" in
		''|*[!0-9]*) return 1 ;;
	esac
	[ "$_size" -gt "$C2_SCRIPT_MIN_BYTES" ] || return 1
	grep -q "$C2_SCRIPT_MARKER" "$_f" 2>/dev/null || return 1
	grep -q '^permission_granted=' "$_f" 2>/dev/null || return 1
	if have_cmd bash; then
		bash -n "$_f" >/dev/null 2>&1 || return 1
	fi
	return 0
}

# 从候选地址下载 C2 版脚本到目标路径
download_script() {
	_dest="${1:-}"
	[ -n "$_dest" ] || return 1
	_tmp="$_dest.download.$$"
	for _url in $C2_SCRIPT_URLS; do
		rm -f "$_tmp" 2>/dev/null
		if have_cmd curl; then
			curl -fsSL --connect-timeout 15 --max-time 120 -o "$_tmp" "$_url" >/dev/null 2>&1 || continue
		elif have_cmd wget; then
			wget -q -T 30 -O "$_tmp" "$_url" >/dev/null 2>&1 || continue
		else
			return 1
		fi
		if script_is_c2 "$_tmp"; then
			mv -f "$_tmp" "$_dest" 2>/dev/null || continue
			chmod 0755 "$_dest" 2>/dev/null
			return 0
		fi
	done
	rm -f "$_tmp" 2>/dev/null
	return 1
}

# 存储根目录（必要时重新读取配置）
storage_root() {
	[ -n "${C2_STORAGE_ROOT:-}" ] || conf_load
	printf '%s' "${C2_STORAGE_ROOT:-}"
}

# 权威副本路径（放在 SSD 上）
canonical_path() {
	printf '%s' "$(storage_root)/c2/kejilion.sh"
}

# 确保 SSD 上存在可用的权威副本，返回其路径
ensure_canonical() {
	_canon=$(canonical_path)
	if script_is_c2 "$_canon"; then
		printf '%s' "$_canon"
		return 0
	fi
	_mkdir=$(dirname "$_canon")
	[ -d "$_mkdir" ] || mkdir -p "$_mkdir" 2>/dev/null || return 1
	log "SSD 权威副本缺失或已损坏，尝试重新下载"
	if download_script "$_canon"; then
		log "已重建权威副本: $_canon"
		printf '%s' "$_canon"
		return 0
	fi
	log "权威副本重建失败（全部下载地址不可用）"
	return 1
}

# 恢复共享脚本为 C2 版
restore_shared_script() {
	_granted="false"
	if grep -q '^permission_granted="true"' $C2_GUARD_SCRIPT_PATH 2>/dev/null; then
		_granted="true"
	elif grep -q '^permission_granted="true"' $C2_GUARD_ROOT_SCRIPT 2>/dev/null; then
		_granted="true"
	fi

	_canon=$(ensure_canonical) || return 1

	cp -f "$_canon" $C2_GUARD_SCRIPT_PATH 2>/dev/null || return 1
	chmod 0755 $C2_GUARD_SCRIPT_PATH 2>/dev/null
	cp -f "$_canon" $C2_GUARD_ROOT_SCRIPT 2>/dev/null || return 1
	chmod 0755 $C2_GUARD_ROOT_SCRIPT 2>/dev/null
	ln -sf "$C2_GUARD_SCRIPT_PATH" "$C2_GUARD_BIN_LINK" 2>/dev/null

	if [ "$_granted" = "true" ]; then
		sed -i 's/^permission_granted="false"/permission_granted="true"/' "$C2_GUARD_SCRIPT_PATH" "$C2_GUARD_ROOT_SCRIPT" 2>/dev/null
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Docker daemon.json
# ---------------------------------------------------------------------------

# 修复 Docker 配置，返回 0 表示无需改动，返回 10 表示已改动
repair_daemon_json() {
	[ -f "$C2_DOCKER_CONF" ] || return 0
	have_cmd jq || { log "jq 缺失，跳过 daemon.json 校验"; return 0; }
	jq empty "$C2_DOCKER_CONF" >/dev/null 2>&1 || { log "daemon.json 不是合法 JSON，跳过"; return 0; }

	_data_root="$(storage_root)/docker-data"
	_tmp="${C2_DOCKER_CONF}.c2guard.$$"
	_old="${C2_DOCKER_CONF}.c2guard.old.$$"
	_new="${C2_DOCKER_CONF}.c2guard.new.$$"

	jq --arg dr "$_data_root" --argjson mirrors "$C2_DEFAULT_MIRRORS" --argjson dns "$C2_DEFAULT_DNS" '
		. + {
			"data-root": $dr,
			"allow-direct-routing": true,
			"ip6tables": false
		}
		| .["exec-opts"] = (((.["exec-opts"] // []) | map(select(. != "native.cgroupdriver=systemd"))) + ["native.cgroupdriver=systemd"])
		| .["registry-mirrors"] = (((.["registry-mirrors"] // []) | if length > 0 then . else $mirrors end))
		| .["dns"] = (((.["dns"] // []) | if length > 0 then . else $dns end))
	' "$C2_DOCKER_CONF" > "$_tmp" 2>/dev/null || { rm -f "$_tmp" 2>/dev/null; return 1; }

	jq -S . "$C2_DOCKER_CONF" > "$_old" 2>/dev/null
	jq -S . "$_tmp" > "$_new" 2>/dev/null
	if cmp -s "$_old" "$_new"; then
		rm -f "$_tmp" "$_old" "$_new" 2>/dev/null
		return 0
	fi

	cp -p "$C2_DOCKER_CONF" "${C2_DOCKER_CONF}.bak.$(date +%s)" 2>/dev/null
	mv -f "$_tmp" "$C2_DOCKER_CONF" 2>/dev/null || { rm -f "$_tmp" "$_old" "$_new" 2>/dev/null; return 1; }
	rm -f "$_old" "$_new" 2>/dev/null
	log "已修复 daemon.json（data-root / allow-direct-routing / exec-opts / 镜像源 / DNS）"
	return 10
}

# ---------------------------------------------------------------------------
# containerd
# ---------------------------------------------------------------------------

# 修复 containerd 的 root，返回 0 表示无需改动，返回 10 表示已改动
repair_containerd_root() {
	[ -f "$C2_CONTAINERD_CONF" ] || return 0
	_target="$(storage_root)/containerd-data"
	_current=$(sed -n 's/^root[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$C2_CONTAINERD_CONF" 2>/dev/null | head -n1)
	[ "$_current" = "$_target" ] && return 0

	if [ -z "$_current" ]; then
		# 没有顶层 root，补一行到文件开头
		_tmp="${C2_CONTAINERD_CONF}.c2guard.$$"
		{ printf 'root = "%s"\n' "$_target"; cat "$C2_CONTAINERD_CONF"; } > "$_tmp" 2>/dev/null &&
			mv -f "$_tmp" "$C2_CONTAINERD_CONF" 2>/dev/null
	else
		# 只替换顶层 root（行首无缩进），不动插件段内的 root
		sed -i "s#^root[[:space:]]*=[[:space:]]*\"[^\"]*\"#root = \"$_target\"#" "$C2_CONTAINERD_CONF" 2>/dev/null
	fi
	_after=$(sed -n 's/^root[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$C2_CONTAINERD_CONF" 2>/dev/null | head -n1)
	[ "$_after" = "$_target" ] || return 1
	log "已修复 containerd root: $_target"
	return 10
}

# ---------------------------------------------------------------------------
# 目录软链
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

# 校验 /home/docker 与 /home/web 的软链，返回 0 表示正常
check_symlink() {
	_link="${1:-}"
	_target="${2:-}"
	[ -n "$_link" ] && [ -n "$_target" ] || return 1
	if symlink_points_to "$_link" "$_target"; then
		return 0
	fi
	if [ -L "$_link" ]; then
		_old=$(readlink "$_link" 2>/dev/null)
		# 旧目标是空目录或已消失时可以直接改指，否则只告警不擅自动数据
		if [ -n "$_old" ] && [ -d "$_old" ] && [ -n "$(ls -A "$_old" 2>/dev/null)" ]; then
			warn "软链 $_link 指向 $_old（含数据，需人工确认），期望 $_target"
			return 1
		fi
		rm -f "$_link" 2>/dev/null
	elif [ -d "$_link" ]; then
		warn "$_link 是真实目录而不是软链，请用 c2_storage.sh apply 重新接管"
		return 1
	fi
	mkdir -p "$_target" 2>/dev/null
	ln -s "$_target" "$_link" 2>/dev/null || { warn "重建软链 $_link 失败"; return 1; }
	log "已重建软链 $_link -> $_target"
	return 0
}

# ---------------------------------------------------------------------------
# 挂载检查
# ---------------------------------------------------------------------------

# 路径是否落在独立文件系统上（存储根通常是挂载点的子目录，例如 /storage/kejilion）
# 做法：找出路径所属的最长挂载点，若该挂载点不是 "/" 即为独立文件系统
on_separate_fs() {
	_path="${1:-}"
	[ -n "$_path" ] || return 1
	_path="${_path%/}"
	[ -n "$_path" ] || _path="/"
	[ -d "$_path" ] || return 1
	_best=""
	_best_len=0
	while read -r _dev _mp _fstype _rest; do
		case "$_path" in
			"$_mp") ;;
			"$_mp"/*) ;;
			*) continue ;;
		esac
		_len=${#_mp}
		if [ "$_len" -gt "$_best_len" ]; then
			_best="$_mp"
			_best_len="$_len"
		fi
	done < /proc/mounts
	[ -n "$_best" ] || return 1
	[ "$_best" != "/" ] || return 1
	return 0
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

# 只读体检
show_status() {
	conf_load
	title "云存宝C2 定制守护状态"
	if [ "$C2_ENABLED" != "true" ] || [ -z "$C2_STORAGE_ROOT" ]; then
		printf '%s\n' "存储模式: ${YELLOW}未启用（软件仍在系统盘）${NC}"
	else
		printf '%s\n' "存储模式: ${GREEN}已启用 SSD 存储${NC}"
		printf '%s\n' "存储根目录: ${C2_STORAGE_ROOT}"
		if on_separate_fs "$C2_STORAGE_ROOT"; then
			printf '%s\n' "存储挂载: ${GREEN}已挂载到独立文件系统${NC}"
		else
			printf '%s\n' "存储挂载: ${YELLOW}未挂载（软件不会落到 SSD）${NC}"
		fi
	fi

	for _f in "$C2_GUARD_SCRIPT_PATH" "$C2_GUARD_ROOT_SCRIPT"; do
		if script_is_c2 "$_f"; then
			printf '%s\n' "$_f: ${GREEN}C2 版${NC}"
		elif [ -f "$_f" ]; then
			printf '%s\n' "$_f: ${YELLOW}已被覆盖${NC}"
		else
			printf '%s\n' "$_f: ${YELLOW}缺失${NC}"
		fi
	done

	if [ -L "$C2_GUARD_BIN_LINK" ]; then
		printf '%s\n' "$C2_GUARD_BIN_LINK -> $(readlink "$C2_GUARD_BIN_LINK")"
	else
		printf '%s\n' "$C2_GUARD_BIN_LINK: ${YELLOW}不是指向 $C2_GUARD_SCRIPT_PATH 的软链${NC}"
	fi

	_canon=$(canonical_path)
	if script_is_c2 "$_canon"; then
		printf '%s\n' "权威副本: ${GREEN}$_canon${NC}"
	else
		printf '%s\n' "权威副本: ${YELLOW}$_canon 缺失或已损坏${NC}"
	fi

	if [ -f "$C2_DOCKER_CONF" ] && have_cmd jq; then
		printf '%s\n' "Docker data-root: $(jq -r '."data-root" // "未设置"' "$C2_DOCKER_CONF" 2>/dev/null)"
		printf '%s\n' "allow-direct-routing: $(jq -r '."allow-direct-routing" // "未设置"' "$C2_DOCKER_CONF" 2>/dev/null)"
		printf '%s\n' "exec-opts: $(jq -c '."exec-opts" // []' "$C2_DOCKER_CONF" 2>/dev/null)"
	fi
	if [ -f "$C2_CONTAINERD_CONF" ]; then
		printf '%s\n' "containerd root: $(sed -n 's/^root[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$C2_CONTAINERD_CONF" 2>/dev/null | head -n1)"
	fi
	printf '%s\n' "------------------------------------------------"
}

# 校验并修复
do_check() {
	conf_load
	if [ "$C2_ENABLED" != "true" ] || [ -z "$C2_STORAGE_ROOT" ]; then
		warn "未启用 C2 存储模式，跳过守护"
		return 0
	fi

	_need_restart=0

	# 1. 共享脚本
	if ! script_is_c2 "$C2_GUARD_SCRIPT_PATH"; then
		if restore_shared_script; then
			log "共享脚本已被第三方覆盖，已恢复为 C2 版"
			info "${GREEN}已恢复共享脚本为 C2 版${NC}"
		else
			err "共享脚本恢复失败"
			log "共享脚本恢复失败"
		fi
	fi
	if ! script_is_c2 "$C2_GUARD_ROOT_SCRIPT"; then
		cp -f "$(canonical_path)" $C2_GUARD_ROOT_SCRIPT 2>/dev/null && chmod 0755 $C2_GUARD_ROOT_SCRIPT 2>/dev/null
	fi
	if [ ! -L "$C2_GUARD_BIN_LINK" ] || [ "$(readlink "$C2_GUARD_BIN_LINK" 2>/dev/null)" != "$C2_GUARD_SCRIPT_PATH" ]; then
		ln -sf "$C2_GUARD_SCRIPT_PATH" "$C2_GUARD_BIN_LINK" 2>/dev/null
		log "已重建 $C2_GUARD_BIN_LINK 软链"
	fi

	# 2. Docker 配置
	repair_daemon_json
	_rc=$?
	if [ "$_rc" -eq 10 ]; then
		_need_restart=1
	fi

	# 3. containerd
	repair_containerd_root
	_rc=$?
	if [ "$_rc" -eq 10 ]; then
		_need_restart=1
	fi

	# 4. 目录软链
	check_symlink "$C2_GUARD_HOME_DOCKER" "${C2_STORAGE_ROOT%/}/docker"
	check_symlink "$C2_GUARD_HOME_WEB" "${C2_STORAGE_ROOT%/}/web"

	# 5. 挂载
	if ! on_separate_fs "$C2_STORAGE_ROOT"; then
		warn "存储根 $C2_STORAGE_ROOT 未挂载到独立文件系统，软件无法落到 SSD"
		log "存储根未挂载"
	fi

	# 6. 需要时重启 docker 让配置生效
	if [ "$_need_restart" = "1" ] && [ "${C2_GUARD_NO_DOCKER_RESTART:-0}" != "1" ]; then
		if have_cmd systemctl && systemctl is-active --quiet docker.service 2>/dev/null; then
			log "Docker 配置已变更，正在重启 dockerd"
			systemctl restart docker.service >/dev/null 2>&1 && info "${GREEN}已重启 Docker 使新配置生效${NC}"
		fi
	fi
	return 0
}

# ---------------------------------------------------------------------------
# systemd 单元
# ---------------------------------------------------------------------------

# 建立 SSD 上的权威副本（优先复制本机现有 C2 版脚本，其次下载）
# 已存在时同样刷新，保证权威副本与当前安装版本一致
seed_canonical() {
	_canon=$(canonical_path)
	_mkdir=$(dirname "$_canon")
	[ -d "$_mkdir" ] || mkdir -p "$_mkdir" 2>/dev/null || return 1
	for _src in "$C2_GUARD_SCRIPT_PATH" "$C2_GUARD_ROOT_SCRIPT"; do
		if script_is_c2 "$_src"; then
			cp -f "$_src" "$_canon" 2>/dev/null || continue
			chmod 0755 "$_canon" 2>/dev/null
			log "已用本机 C2 版脚本刷新权威副本: $_canon"
			return 0
		fi
	done
	# 本机没有可用副本时退回下载
	ensure_canonical >/dev/null 2>&1
}

install_units() {
	have_cmd systemctl || { err "未检测到 systemd，无法安装守护单元"; return 1; }

	# 先把权威副本落到 SSD 上，之后即使断网也能恢复
	seed_canonical

	cat > "$C2_GUARD_UNIT_DIR/c2-guard.service" << EOF
[Unit]
Description=云存宝C2 定制守护
After=network-online.target docker.service
Wants=network-online.target
ConditionPathExists=$C2_CONF_FILE

[Service]
Type=oneshot
ExecStart=$C2_GUARD_SBIN check
EOF

	cat > "$C2_GUARD_UNIT_DIR/c2-guard.timer" << EOF
[Unit]
Description=定时检查云存宝C2 定制是否被覆盖

[Timer]
OnBootSec=3min
OnUnitActiveSec=10min
AccuracySec=1min
Persistent=true
Unit=c2-guard.service

[Install]
WantedBy=timers.target
EOF

	cat > "$C2_GUARD_UNIT_DIR/c2-guard.path" << EOF
[Unit]
Description=监视共享脚本被改写并即时恢复

[Path]
PathChanged=$C2_GUARD_SCRIPT_PATH
PathChanged=$C2_GUARD_ROOT_SCRIPT
Unit=c2-guard.service

[Install]
WantedBy=paths.target
EOF

	systemctl daemon-reload >/dev/null 2>&1
	systemctl enable --now c2-guard.timer >/dev/null 2>&1
	systemctl enable --now c2-guard.path >/dev/null 2>&1
	ok "已安装并启用 C2 守护（定时器 + 路径监视）"
	return 0
}

uninstall_units() {
	have_cmd systemctl || return 1
	systemctl disable --now c2-guard.timer >/dev/null 2>&1
	systemctl disable --now c2-guard.path >/dev/null 2>&1
	rm -f "$C2_GUARD_UNIT_DIR/c2-guard.service" \
		"$C2_GUARD_UNIT_DIR/c2-guard.timer" \
		"$C2_GUARD_UNIT_DIR/c2-guard.path" 2>/dev/null
	systemctl daemon-reload >/dev/null 2>&1
	ok "已停用并移除 C2 守护单元"
	return 0
}

usage() {
	cat << EOF
云存宝 C2 定制守护脚本

用法:
  sh c2_guard.sh check       校验并修复被覆盖的 C2 定制（守护默认动作）
  sh c2_guard.sh status      只读体检，不做任何修改
  sh c2_guard.sh install     安装 systemd 定时器与路径监视并启用
  sh c2_guard.sh uninstall   停用并移除 systemd 单元
EOF
}

main() {
	_cmd="${1:-check}"
	case "$_cmd" in
		check|"") do_check ;;
		status) show_status ;;
		install) install_units ;;
		uninstall) uninstall_units ;;
		-h|--help|help) usage ;;
		*)
			err "未知命令: $_cmd"
			usage
			exit 1
			;;
	esac
}

# C2_GUARD_LIB_ONLY=1 时只加载函数不执行，供测试引用
if [ "${C2_GUARD_LIB_ONLY:-0}" != "1" ]; then
	main "$@"
fi
