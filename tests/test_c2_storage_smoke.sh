#!/bin/bash
set -euo pipefail

script_path=${1:-"$(cd "$(dirname "$0")/.." && pwd)/kejilion.sh"}

# 抽取 C2 存储模块中被测的函数
for helper in c2_conf_load c2_conf_save c2_conf_clear c2_enabled c2_root \
	c2_path_docker c2_path_docker_data c2_path_web c2_path_cache c2_path_backup \
	c2_is_mounted c2_dev_is_ssd c2_symlink c2_symlink_points_to c2_migrate_dir c2_backup_root; do
	helper_body=$(
		awk -v name="$helper" '
			$0 ~ "^" name "\\(\\) \\{" { capture=1 }
			capture { print }
			capture && /^}/ { exit }
		' "$script_path"
	)
	[ -n "$helper_body" ]
	eval "$helper_body"
done

test_root="/tmp/kejilion-c2-storage-smoke.$$"
mkdir -p "$test_root"
cleanup() {
	case "$test_root" in
		/tmp/*) rm -rf -- "$test_root" ;;
	esac
}
trap cleanup EXIT HUP INT TERM

C2_CONFIG_DIR="$test_root/etc/kejilion"
C2_CONFIG_FILE="$C2_CONFIG_DIR/c2.conf"
C2_CONF_LOADED="false"
C2_ENABLED="false"
C2_STORAGE_ROOT=""
gl_huang=
gl_lv=
gl_bai=

# ---------------------------------------------------------------- 路径派生
[ "$(c2_path_docker /mnt/ssd/kjilion)" = "/mnt/ssd/kjilion/docker" ]
[ "$(c2_path_docker_data /mnt/ssd/kjilion)" = "/mnt/ssd/kjilion/docker-data" ]
[ "$(c2_path_web /mnt/ssd/kjilion)" = "/mnt/ssd/kjilion/web" ]
[ "$(c2_path_cache /mnt/ssd/kjilion)" = "/mnt/ssd/kjilion/cache" ]
[ "$(c2_path_backup /mnt/ssd/kjilion)" = "/mnt/ssd/kjilion/backup" ]

# ---------------------------------------------------------------- 配置读写
if c2_enabled; then
	echo "C2 mode reported enabled without a config file" >&2
	exit 1
fi

c2_conf_save /mnt/ssd/kejilion
[ -f "$C2_CONFIG_FILE" ]
c2_enabled
[ "$(c2_root)" = "/mnt/ssd/kejilion" ]

# 配置内容可被重新解析（模拟脚本重启后读取）
C2_CONF_LOADED="false"
C2_ENABLED="false"
C2_STORAGE_ROOT=""
c2_conf_load
c2_enabled
[ "$(c2_root)" = "/mnt/ssd/kejilion" ]

# 拒绝相对路径
C2_CONF_LOADED="false"
C2_ENABLED="false"
C2_STORAGE_ROOT=""
if c2_conf_save "relative/path" >/dev/null 2>&1; then
	echo "accepted a relative storage root" >&2
	exit 1
fi

# 配置文件中的非法值不应被采纳
C2_CONF_LOADED="false"
C2_ENABLED="false"
C2_STORAGE_ROOT=""
mkdir -p "$C2_CONFIG_DIR"
printf 'C2_ENABLED="true"\nC2_STORAGE_ROOT="not-absolute"\n' >"$C2_CONFIG_FILE"
c2_conf_load
if c2_enabled; then
	echo "accepted a non-absolute storage root" >&2
	exit 1
fi

# 清理
C2_CONF_LOADED="false"
C2_ENABLED="false"
C2_STORAGE_ROOT=""
c2_conf_clear
if c2_enabled; then
	echo "C2 mode still enabled after clearing the config" >&2
	exit 1
fi

# ---------------------------------------------------------------- 挂载点检测
# 根挂载点在所有 POSIX 环境下都应被识别为挂载点
c2_is_mounted /
if c2_is_mounted "$test_root/does-not-exist"; then
	echo "reported a missing path as mounted" >&2
	exit 1
fi

# ---------------------------------------------------------------- 软链接
mkdir -p "$test_root/target"
c2_symlink "$test_root/link" "$test_root/target"
[ -L "$test_root/link" ]
c2_symlink_points_to "$test_root/link" "$test_root/target"

# 重复执行不应改变既有链接
c2_symlink "$test_root/link" "$test_root/target"
[ -L "$test_root/link" ]
c2_symlink_points_to "$test_root/link" "$test_root/target"

# 指向新目标时应重新指向
mkdir -p "$test_root/target2"
c2_symlink "$test_root/link" "$test_root/target2"
[ -L "$test_root/link" ]
c2_symlink_points_to "$test_root/link" "$test_root/target2"
if c2_symlink_points_to "$test_root/link" "$test_root/target"; then
	echo "symlink still reported pointing at the old target" >&2
	exit 1
fi

# ---------------------------------------------------------------- 数据迁移
mkdir -p "$test_root/src/sub"
printf 'payload\n' >"$test_root/src/file.txt"
printf 'nested\n' >"$test_root/src/sub/nested.txt"
mkdir -p "$test_root/dst"
c2_migrate_dir "$test_root/src" "$test_root/dst"
[ -f "$test_root/dst/file.txt" ]
[ -f "$test_root/dst/sub/nested.txt" ]
[ ! -e "$test_root/src" ]

# 已经是同一目标的软链接时不做任何改动
c2_symlink "$test_root/src" "$test_root/dst"
c2_migrate_dir "$test_root/src" "$test_root/dst"
[ -L "$test_root/src" ]
[ -f "$test_root/dst/file.txt" ]

# 隐藏文件也应被迁移
mkdir -p "$test_root/src3"
printf 'hidden\n' >"$test_root/src3/.hidden"
mkdir -p "$test_root/dst3"
c2_migrate_dir "$test_root/src3" "$test_root/dst3"
[ -f "$test_root/dst3/.hidden" ]

# 源目录迁移后应被移除，为软链接让出路径
[ ! -e "$test_root/src3" ]

# 空目录迁移后也应被移除，随后可建立软链接
mkdir -p "$test_root/src4" "$test_root/dst4"
c2_migrate_dir "$test_root/src4" "$test_root/dst4"
[ ! -e "$test_root/src4" ]
c2_symlink "$test_root/src4" "$test_root/dst4"
[ -L "$test_root/src4" ]
c2_symlink_points_to "$test_root/src4" "$test_root/dst4"

# 路径被空目录占用时应能正常建立软链接
mkdir -p "$test_root/busy" "$test_root/busy_target"
c2_symlink "$test_root/busy" "$test_root/busy_target"
[ -L "$test_root/busy" ]
c2_symlink_points_to "$test_root/busy" "$test_root/busy_target"

# ---------------------------------------------------------------- 备份根目录
# 未启用 C2 模式时回落到 /tmp
C2_CONF_LOADED="false"
C2_ENABLED="false"
C2_STORAGE_ROOT=""
[ "$(c2_backup_root)" = "/tmp" ]

# 启用后指向 SSD 下的备份目录
c2_conf_save "$test_root/ssd"
C2_CONF_LOADED="false"
c2_conf_load
backup_root=$(c2_backup_root)
[ "$backup_root" = "$test_root/ssd/backup" ]
[ -d "$backup_root" ]

# ---------------------------------------------------------------- 变量遮蔽回归
# c2_root 既是函数名也可能被当作局部变量使用，
# 若出现 c2_root=$(c2_root) 这类自我调用会导致无限递归
if grep -Eq '^[[:space:]]*local[[:space:]]+c2_root\b' "$script_path"; then
	echo "a local variable shadows the c2_root function" >&2
	exit 1
fi
if grep -Eq '^[[:space:]]*c2_root=\$\(c2_root\)' "$script_path"; then
	echo "c2_root calls itself recursively" >&2
	exit 1
fi

echo "c2_storage_smoke=pass"

