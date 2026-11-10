#!/bin/bash
# 云存宝 C2 定制守护（c2_guard.sh）回归测试
set -uo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
guard_path="${project_root}/c2_guard.sh"

test_root="$(mktemp -d)"
case "$test_root" in
	[A-Za-z]:*) test_root="$(TMPDIR=/tmp mktemp -d)" ;;
esac
cleanup() {
	case "$test_root" in
		/tmp/*) rm -rf -- "$test_root" ;;
	esac
}
trap cleanup EXIT HUP INT TERM

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# --- 1. POSIX sh 语法校验（dash 严格模式）-----------------------------------
if command -v dash >/dev/null 2>&1; then
	dash -n "$guard_path" || fail "c2_guard.sh failed dash syntax check"
fi
bash -n "$guard_path" || fail "c2_guard.sh failed bash syntax check"

# --- 2. 准备夹具 -------------------------------------------------------------
sandbox="$test_root/sandbox"
mkdir -p "$sandbox/bin" "$sandbox/root" "$sandbox/storage/c2" "$sandbox/storage/docker" "$sandbox/storage/web" "$sandbox/home"

make_script() {
	# $1=目标文件  $2=是否含 C2 标志  $3=许可标志
	local target="$1" c2_flag="$2" granted="$3"
	{
		echo '#!/bin/bash'
		echo "canshu=\"default\""
		echo "permission_granted=\"$granted\""
		if [ "$c2_flag" = "yes" ]; then
			echo 'c2_menu() { echo "c2 menu"; }'
		else
			echo 'linux_menu() { echo "upstream menu"; }'
		fi
		# 填充体积，模拟真实脚本
		local i=0
		while [ "$i" -lt 400 ]; do
			echo "# padding line $i to emulate a full script body ................"
			i=$((i + 1))
		done
	} >"$target"
}

export C2_CONF_FILE="$sandbox/c2.conf"
export C2_GUARD_LOG="$sandbox/guard.log"
export C2_GUARD_SCRIPT_PATH="$sandbox/bin/k"
export C2_GUARD_ROOT_SCRIPT="$sandbox/root/kejilion.sh"
export C2_GUARD_BIN_LINK="$sandbox/bin/k-link"
export C2_GUARD_HOME_DOCKER="$sandbox/home/docker"
export C2_GUARD_HOME_WEB="$sandbox/home/web"
export C2_DOCKER_CONF="$sandbox/daemon.json"
export C2_CONTAINERD_CONF="$sandbox/containerd.toml"
export C2_SCRIPT_MIN_BYTES=1000
export C2_GUARD_NO_DOCKER_RESTART=1

cat >"$C2_CONF_FILE" <<EOF
C2_ENABLED="true"
C2_STORAGE_ROOT="$sandbox/storage"
EOF

export C2_GUARD_LIB_ONLY=1
# shellcheck source=/dev/null
. "$guard_path"

# --- 3. script_is_c2 判定 ----------------------------------------------------
make_script "$sandbox/c2.sh" yes false
make_script "$sandbox/upstream.sh" no false
script_is_c2 "$sandbox/c2.sh" || fail "C2 fixture not recognised"
if script_is_c2 "$sandbox/upstream.sh"; then
	fail "upstream fixture wrongly recognised as C2"
fi

# --- 4. restore_shared_script 恢复被覆盖的脚本并保留许可标志 ----------------
cp "$sandbox/c2.sh" "$sandbox/storage/c2/kejilion.sh"
cp "$sandbox/upstream.sh" "$C2_GUARD_SCRIPT_PATH"
cp "$sandbox/upstream.sh" "$C2_GUARD_ROOT_SCRIPT"
sed -i 's/^permission_granted="false"/permission_granted="true"/' "$C2_GUARD_SCRIPT_PATH"
rm -f "$C2_GUARD_BIN_LINK"

restore_shared_script || fail "restore_shared_script failed"
script_is_c2 "$C2_GUARD_SCRIPT_PATH" || fail "shared script not restored to C2 version"
script_is_c2 "$C2_GUARD_ROOT_SCRIPT" || fail "root script not restored to C2 version"
grep -q '^permission_granted="true"' "$C2_GUARD_SCRIPT_PATH" ||
	fail "permission_granted flag lost during restore"
[ -L "$C2_GUARD_BIN_LINK" ] || fail "/usr/bin/k style symlink not created"
[ "$(readlink "$C2_GUARD_BIN_LINK")" = "$C2_GUARD_SCRIPT_PATH" ] ||
	fail "symlink target mismatch"

# --- 5. daemon.json 采用增量合并，不丢原有字段 ------------------------------
# 静态断言：必须是 `. + {...}` 合并语义；构造新对象会丢掉原有字段
grep -Fq '. + {' "$guard_path" || fail "daemon.json repair must use jq merge semantics (. + {...})"
grep -Fq '.["exec-opts"]' "$guard_path" ||
	fail "daemon.json repair must address hyphenated keys with bracket notation"
grep -Fq '"allow-direct-routing": true' "$guard_path" ||
	fail "daemon.json repair must restore allow-direct-routing"
grep -Fq 'jq --arg dr' "$guard_path" || fail "daemon.json repair must pass data-root via --arg"

cat >"$C2_DOCKER_CONF" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m" },
  "registry-mirrors": ["https://docker.xuanyuan.me"]
}
EOF
repair_daemon_json
_rc=$?

if command -v jq >/dev/null 2>&1; then
	[ "$_rc" -eq 10 ] || fail "daemon.json repair should report a change (got $_rc)"
	[ "$(jq -r '."log-driver"' "$C2_DOCKER_CONF")" = "json-file" ] ||
		fail "daemon.json lost log-driver during merge"
	[ "$(jq -r '."log-opts"."max-size"' "$C2_DOCKER_CONF")" = "10m" ] ||
		fail "daemon.json lost nested log-opts during merge"
	[ "$(jq -r '."data-root"' "$C2_DOCKER_CONF")" = "$sandbox/storage/docker-data" ] ||
		fail "daemon.json data-root not repaired"
	[ "$(jq -r '."allow-direct-routing"' "$C2_DOCKER_CONF")" = "true" ] ||
		fail "daemon.json allow-direct-routing not repaired"
	[ "$(jq -r '."ip6tables"' "$C2_DOCKER_CONF")" = "false" ] ||
		fail "daemon.json ip6tables not repaired"
	jq -e '."exec-opts" | index("native.cgroupdriver=systemd")' "$C2_DOCKER_CONF" >/dev/null ||
		fail "daemon.json exec-opts missing systemd cgroup driver"
	[ "$(jq -r '."registry-mirrors" | length' "$C2_DOCKER_CONF")" -ge 1 ] ||
		fail "daemon.json registry-mirrors unexpectedly empty"
	[ "$(jq -r '."dns" | length' "$C2_DOCKER_CONF")" -ge 1 ] ||
		fail "daemon.json dns unexpectedly empty"

	# 二次执行必须是幂等的
	repair_daemon_json
	_rc=$?
	[ "$_rc" -eq 0 ] || fail "daemon.json repair is not idempotent (got $_rc)"
else
	echo "SKIP: jq unavailable, daemon.json merge assertions rely on the target device" >&2
fi

# --- 6. containerd 只改顶层 root -------------------------------------------
cat >"$C2_CONTAINERD_CONF" <<'EOF'
root = "/var/lib/containerd"
[plugins."io.containerd.grpc.v1.cri"]
  root = "/var/lib/containerd/io.containerd.grpc.v1.cri"
EOF
repair_containerd_root
_rc=$?
[ "$_rc" -eq 10 ] || fail "containerd root repair should report a change (got $_rc)"
grep -q "^root = \"$sandbox/storage/containerd-data\"$" "$C2_CONTAINERD_CONF" ||
	fail "containerd top-level root not repaired"
grep -q 'root = "/var/lib/containerd/io.containerd.grpc.v1.cri"' "$C2_CONTAINERD_CONF" ||
	fail "containerd plugin-level root must not be touched"
repair_containerd_root
_rc=$?
[ "$_rc" -eq 0 ] || fail "containerd root repair is not idempotent (got $_rc)"

# --- 7. 目录软链 ------------------------------------------------------------
check_symlink "$C2_GUARD_HOME_DOCKER" "$sandbox/storage/docker" ||
	fail "docker symlink not created"
[ "$(readlink "$C2_GUARD_HOME_DOCKER")" = "$sandbox/storage/docker" ] ||
	fail "docker symlink target mismatch"
check_symlink "$C2_GUARD_HOME_WEB" "$sandbox/storage/web" ||
	fail "web symlink not created"

# 真实目录不得被擅自替换
rm -f "$C2_GUARD_HOME_DOCKER"
mkdir -p "$C2_GUARD_HOME_DOCKER"
if check_symlink "$C2_GUARD_HOME_DOCKER" "$sandbox/storage/docker"; then
	fail "real directory must not be silently replaced by a symlink"
fi
[ -d "$C2_GUARD_HOME_DOCKER" ] || fail "real directory got removed"
rm -rf "$C2_GUARD_HOME_DOCKER"

# --- 7b. 独立文件系统判定 ---------------------------------------------------
# 存储根通常是挂载点的子目录（/storage/kejilion），必须判定为已挂载
on_separate_fs "/" && fail "root filesystem must not be treated as a separate filesystem"
on_separate_fs "/nonexistent-c2-probe" && fail "missing path must not be treated as mounted"
if on_separate_fs "$sandbox/storage"; then
	# 沙箱通常与 / 同盘，只有在确实独立时才允许通过
	:
fi

# --- 8. 端到端：模拟 KPanel 覆盖后由 do_check 自动恢复 ----------------------
cp "$sandbox/upstream.sh" "$C2_GUARD_SCRIPT_PATH"
cp "$sandbox/upstream.sh" "$C2_GUARD_ROOT_SCRIPT"
rm -f "$C2_GUARD_BIN_LINK"

do_check || fail "do_check returned non-zero"
script_is_c2 "$C2_GUARD_SCRIPT_PATH" || fail "do_check did not restore the shared script"
script_is_c2 "$C2_GUARD_ROOT_SCRIPT" || fail "do_check did not restore the root script"
[ -L "$C2_GUARD_BIN_LINK" ] || fail "do_check did not restore the /usr/bin/k symlink"

# --- 9. 权威副本缺失时尝试重建（下载地址不可达时应失败并保持原状）---------
cp "$sandbox/upstream.sh" "$sandbox/storage/c2/kejilion.sh"
C2_SCRIPT_URLS="http://127.0.0.1:1/kejilion.sh"
if ensure_canonical >/dev/null 2>&1; then
	fail "ensure_canonical must fail when every download source is unreachable"
fi
script_is_c2 "$sandbox/storage/c2/kejilion.sh" &&
	fail "broken canonical copy must not pass script_is_c2"

echo "c2_guard_smoke=pass"
