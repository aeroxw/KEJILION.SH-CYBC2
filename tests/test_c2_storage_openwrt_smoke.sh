#!/bin/bash
# 云存宝 C2：OpenWrt / busybox 兼容性冒烟测试
#
# 覆盖：
#   1) 独立版 c2_storage.sh 的 POSIX 语法（dash / busybox sh）与 bashism 检查
#   2) 独立版脚本的迁移、软链接、data-root 写入等核心函数
#   3) 主脚本 kejilion.sh 中 OpenWrt 兼容层是否存在且已被调用
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
script_path="${1:-$repo_root/kejilion.sh}"
standalone_path="${2:-$repo_root/c2_storage.sh}"

[ -f "$script_path" ]
[ -f "$standalone_path" ]

# ---------------------------------------------------------------------------
# 1) 独立版脚本必须是 POSIX sh 可解析的
# ---------------------------------------------------------------------------
if command -v dash >/dev/null 2>&1; then
	dash -n "$standalone_path"
elif command -v busybox >/dev/null 2>&1; then
	busybox sh -n "$standalone_path"
else
	sh -n "$standalone_path"
fi

# 不得出现 bash 专属语法，否则在 OpenWrt 的 ash 下会直接语法错误
# 注意：POSIX 字符类 [[:space:]] 也是以 [[ 开头，这里要排除掉
bashism_re='\[\[[^:]|=~|shopt[[:space:]]+-|declare[[:space:]]+-[aA]|local[[:space:]]+-n|function[[:space:]]+[A-Za-z_]+\(\)|\$\{[A-Za-z_][A-Za-z0-9_]*\[@\]|^[[:space:]]*source[[:space:]]'
if grep -nE "$bashism_re" "$standalone_path" >/dev/null 2>&1; then
	echo "c2_storage.sh contains bash-only syntax:" >&2
	grep -nE "$bashism_re" "$standalone_path" >&2
	exit 1
fi

# 必须是 LF 行尾，否则在 Linux 上会因 shebang 带 \r 而无法执行
if grep -q $'\r' "$standalone_path" 2>/dev/null; then
	echo "c2_storage.sh contains CRLF line endings" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# 2) 加载独立版脚本并测试核心函数
# ---------------------------------------------------------------------------
test_root="/tmp/kejilion-c2-openwrt-smoke.$$"
mkdir -p "$test_root"
cleanup() {
	case "$test_root" in
		/tmp/*) rm -rf -- "$test_root" ;;
	esac
}
trap cleanup EXIT HUP INT TERM

C2_STORAGE_LIB_ONLY=1
export C2_STORAGE_LIB_ONLY
# shellcheck disable=SC1090
. "$standalone_path"

# 把脚本里写死的系统路径重定向到测试目录
C2_CONF_DIR="$test_root/etc/kejilion"
C2_CONF_FILE="$C2_CONF_DIR/c2.conf"
C2_DOCKER_CONF="$test_root/etc/docker/daemon.json"
C2_OPKG_CACHE="$test_root/var/cache/opkg"
C2_PROFILE_DIR="$test_root/etc/profile.d"
C2_PROFILE="$test_root/etc/profile"

json_valid() {
	if command -v python3 >/dev/null 2>&1; then
		python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" >/dev/null 2>&1
	elif command -v jq >/dev/null 2>&1; then
		jq empty "$1" >/dev/null 2>&1
	else
		return 0
	fi
}

# ---------------------------------------------------------------------------
# 迁移：隐藏文件与空目录
# ---------------------------------------------------------------------------
mkdir -p "$test_root/src/sub" "$test_root/dst"
printf 'x\n' >"$test_root/src/.hidden"
printf 'y\n' >"$test_root/src/sub/nested"
migrate_dir "$test_root/src" "$test_root/dst"
[ -f "$test_root/dst/.hidden" ]
[ -f "$test_root/dst/sub/nested" ]
[ ! -e "$test_root/src" ]

# 空目录迁移后应被移除，好让软链接接管该路径
mkdir -p "$test_root/src_empty" "$test_root/dst_empty"
migrate_dir "$test_root/src_empty" "$test_root/dst_empty"
[ ! -e "$test_root/src_empty" ]
make_symlink "$test_root/src_empty" "$test_root/dst_empty"
[ -L "$test_root/src_empty" ]

# 已经是目标软链接时不做任何改动
migrate_dir "$test_root/src_empty" "$test_root/dst_empty"
[ -L "$test_root/src_empty" ]

# ---------------------------------------------------------------------------
# 软链接幂等
# ---------------------------------------------------------------------------
mkdir -p "$test_root/t1" "$test_root/t2"
make_symlink "$test_root/link" "$test_root/t1"
symlink_points_to "$test_root/link" "$test_root/t1"
make_symlink "$test_root/link" "$test_root/t1"
symlink_points_to "$test_root/link" "$test_root/t1"
make_symlink "$test_root/link" "$test_root/t2"
symlink_points_to "$test_root/link" "$test_root/t2"
if symlink_points_to "$test_root/link" "$test_root/t1"; then
	echo "symlink still reported pointing at the old target" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# Docker data-root 写入（不依赖 jq）
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$C2_DOCKER_CONF")"

# 全新文件
write_data_root "$test_root/ssd/docker-data"
[ -f "$C2_DOCKER_CONF" ]
grep -q "\"data-root\"" "$C2_DOCKER_CONF"
json_valid "$C2_DOCKER_CONF"

# 已有 data-root：就地替换，保留其它键
printf '{"data-root": "/old/path", "registry-mirrors": ["https://example.com"]}\n' >"$C2_DOCKER_CONF"
write_data_root "$test_root/ssd/docker-data"
grep -q "$test_root/ssd/docker-data" "$C2_DOCKER_CONF"
grep -q "registry-mirrors" "$C2_DOCKER_CONF"
if grep -q "/old/path" "$C2_DOCKER_CONF"; then
	echo "old data-root was not replaced" >&2
	exit 1
fi
json_valid "$C2_DOCKER_CONF"

# 已有其它键但没有 data-root：插入后仍然是合法 JSON
printf '{"registry-mirrors": ["https://example.com"], "log-level": "warn"}\n' >"$C2_DOCKER_CONF"
write_data_root "$test_root/ssd/docker-data"
grep -q "\"data-root\"" "$C2_DOCKER_CONF"
grep -q "registry-mirrors" "$C2_DOCKER_CONF"
grep -q "log-level" "$C2_DOCKER_CONF"
json_valid "$C2_DOCKER_CONF"

# 空对象
printf '{}\n' >"$C2_DOCKER_CONF"
write_data_root "$test_root/ssd/docker-data"
grep -q "\"data-root\"" "$C2_DOCKER_CONF"
json_valid "$C2_DOCKER_CONF"

# 多行格式
printf '{\n  "log-level": "warn"\n}\n' >"$C2_DOCKER_CONF"
write_data_root "$test_root/ssd/docker-data"
grep -q "\"data-root\"" "$C2_DOCKER_CONF"
grep -q "log-level" "$C2_DOCKER_CONF"
json_valid "$C2_DOCKER_CONF"

# 恢复时写回默认值，而不是删除 JSON 键
reset_data_root
grep -q "/var/lib/docker" "$C2_DOCKER_CONF"
json_valid "$C2_DOCKER_CONF"

# ---------------------------------------------------------------------------
# 容量读取（兼容 GNU df / busybox df 的折行差异）
# ---------------------------------------------------------------------------
size=$(df_size /)
[ -n "$size" ]
avail=$(df_avail /)
[ -n "$avail" ]

# ---------------------------------------------------------------------------
# 配置文件读写
# ---------------------------------------------------------------------------
conf_save "$test_root/ssd"
[ -f "$C2_CONF_FILE" ]
C2_ENABLED="false"
C2_STORAGE_ROOT=""
conf_load
[ "$C2_ENABLED" = "true" ]
[ "$C2_STORAGE_ROOT" = "$test_root/ssd" ]
conf_clear
C2_ENABLED="false"
C2_STORAGE_ROOT=""
conf_load
[ "$C2_ENABLED" = "false" ]

# ---------------------------------------------------------------------------
# 3) 主脚本的 OpenWrt 兼容层
# ---------------------------------------------------------------------------
for helper in kj_service_action c2_service_action c2_docker_running c2_dockerd_start \
	c2_dockerd_stop c2_is_ramfs c2_df_size c2_df_avail c2_df_kb c2_list_disks \
	c2_block_size_human c2_profile_tmpdir c2_env_check c2_ensure_deps; do
	if ! grep -q "^${helper}() {" "$script_path"; then
		echo "missing OpenWrt compatibility helper: $helper" >&2
		exit 1
	fi
done

# opkg 包缓存必须被重定向到 SSD
if ! grep -q 'C2_OPKG_CACHE\|/var/cache/opkg' "$script_path"; then
	echo "opkg cache redirection is missing" >&2
	exit 1
fi

# 全局 start/stop/restart 不应再直接调用 systemctl
if grep -A3 '^start() {' "$script_path" | grep -q 'systemctl start'; then
	echo "start() still calls systemctl directly" >&2
	exit 1
fi
if grep -A3 '^stop() {' "$script_path" | grep -q 'systemctl stop'; then
	echo "stop() still calls systemctl directly" >&2
	exit 1
fi
if grep -A3 '^restart() {' "$script_path" | grep -q 'systemctl restart'; then
	echo "restart() still calls systemctl directly" >&2
	exit 1
fi

# C2 模块内不应再有裸 systemctl 调用
if grep -n 'systemctl stop docker\|systemctl start docker' "$script_path" >/dev/null 2>&1; then
	echo "C2 module still calls systemctl directly for docker" >&2
	exit 1
fi

# 菜单里必须挂上环境自检与补齐组件入口
if ! grep -q 'c2_env_check' "$script_path"; then
	echo "c2_env_check is not wired into the menu" >&2
	exit 1
fi
if ! grep -q 'c2_ensure_deps' "$script_path"; then
	echo "c2_ensure_deps is not wired into the menu" >&2
	exit 1
fi

echo "c2_openwrt_smoke=pass"
