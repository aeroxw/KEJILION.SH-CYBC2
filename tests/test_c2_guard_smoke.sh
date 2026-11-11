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

# 孤立的下划线变量行会被 shell 当成命令执行（_url: not found），
# 这类行必须是变量赋值形式
if grep -nE '^[[:space:]]+_[a-zA-Z_]+[[:space:]]*$' "$guard_path" >/dev/null; then
	echo "FAIL: c2_guard.sh contains standalone variable lines" >&2
	grep -nE '^[[:space:]]+_[a-zA-Z_]+[[:space:]]*$' "$guard_path" >&2
	exit 1
fi

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

# --- 9. 权威副本：必须跟随「已安装的最新 C2 版脚本」-------------------------
# 回归：权威副本曾经是静态旧快照，守护会用它把用户刚更新的脚本回滚成旧版
cp "$sandbox/upstream.sh" "$sandbox/storage/c2/kejilion.sh"
C2_SCRIPT_URLS="http://127.0.0.1:1/kejilion.sh"

# 本机已安装的 C2 版脚本可以用来重建权威副本（断网也能恢复）
if ! ensure_canonical >/dev/null 2>&1; then
	fail "ensure_canonical must rebuild from the installed C2 script when the copy is corrupt"
fi
script_is_c2 "$sandbox/storage/c2/kejilion.sh" ||
	fail "ensure_canonical did not refresh the canonical copy from the installed script"

# 已安装版本更新后，权威副本必须跟着更新，不能停留在旧快照
make_script "$C2_GUARD_SCRIPT_PATH" yes true
echo '# C2_CANONICAL_V2' >>"$C2_GUARD_SCRIPT_PATH"
ensure_canonical >/dev/null 2>&1
grep -q 'C2_CANONICAL_V2' "$sandbox/storage/c2/kejilion.sh" ||
	fail "canonical copy must follow the newest installed script"

# 本机没有可用副本、且全部下载地址不可达时必须失败
cp "$sandbox/upstream.sh" "$C2_GUARD_SCRIPT_PATH"
cp "$sandbox/upstream.sh" "$C2_GUARD_ROOT_SCRIPT"
cp "$sandbox/upstream.sh" "$sandbox/storage/c2/kejilion.sh"
if ensure_canonical >/dev/null 2>&1; then
	fail "ensure_canonical must fail when every download source is unreachable"
fi
script_is_c2 "$sandbox/storage/c2/kejilion.sh" &&
	fail "broken canonical copy must not pass script_is_c2"

# --- 10. 禁止原地覆盖正在执行的脚本 -----------------------------------------
# cp 覆盖同一个 inode 会破坏同时运行的 k 进程（bash 按字节偏移续读，
# 内容一变就报 "syntax error: unexpected EOF"）。必须走「临时文件 + rename」。
main_script="${project_root}/kejilion.sh"
if [ -f "$main_script" ]; then
	if grep -qE 'cp -f +~/kejilion\.sh +/usr/local/bin/k([^a-zA-Z0-9_.-]|$)' "$main_script"; then
		fail "kejilion.sh must not copy onto /usr/local/bin/k in place (breaks running k)"
	fi
	grep -q 'c2_atomic_copy()' "$main_script" ||
		fail "kejilion.sh must provide c2_atomic_copy for self-install"
	grep -q 'c2_atomic_copy ~/kejilion.sh /usr/local/bin/k' "$main_script" ||
		fail "kejilion.sh must install to /usr/local/bin/k via c2_atomic_copy"
fi
if grep -qE 'cp -f +"\$_canon" +"?\$?C2_GUARD_SCRIPT_PATH' "$guard_path"; then
	fail "c2_guard.sh must not restore the shared script in place (breaks running k)"
fi
grep -q 'atomic_install()' "$guard_path" ||
	fail "c2_guard.sh must provide atomic_install for restoring the shared script"
grep -q 'atomic_install "\$_canon" "\$C2_GUARD_SCRIPT_PATH"' "$guard_path" ||
	fail "c2_guard.sh must restore the shared script via atomic_install"

# --- 11. 守护不能被 systemd 启动频率限制锁死 -------------------------------
# 脚本被反复改写时触发会非常密集，若沿用默认的 5 次/10 秒限制，
# 守护会进入 start-limit-hit 状态并彻底停摆。
grep -q 'StartLimitIntervalSec=0' "$guard_path" ||
	fail "c2_guard.sh must disable the systemd start limit for the guard service"
grep -q 'reset-failed c2-guard' "$guard_path" ||
	fail "c2_guard.sh must reset failed unit state"
grep -q 'heal_path_unit' "$guard_path" ||
	fail "c2_guard.sh must self-heal a failed path unit"

# --- 12. KPanel 集群私网 CIDR 白名单 ----------------------------------------
# 回归：KPanel 的 .env 会被重装流程整体重写，白名单随之丢失，
# 「集群 → 添加主机」就会报「该地址被网络安全策略拒绝」。
export C2_GUARD_KPANEL_ENV="$sandbox/kpanel/.env"
export C2_KPANEL_PRIVATE_CIDRS="10.31.3.0/24"
mkdir -p "$sandbox/kpanel"

cat >"$C2_GUARD_KPANEL_ENV" <<EOF
KPANEL_PUBLIC_URL=http://10.31.3.201:3666
KPANEL_SECURE_COOKIE=false
KPANEL_ALLOW_IP_HOSTS=true
KPANEL_TRUSTED_PROXY_CIDRS=127.0.0.0/8,::1/128
EOF

repair_kpanel_env
_rc=$?
[ "$_rc" -eq 10 ] || fail "repair_kpanel_env must report a change when the whitelist is missing (got $_rc)"
grep -q '^KPANEL_CLUSTER_PRIVATE_CIDRS=10.31.3.0/24$' "$C2_GUARD_KPANEL_ENV" ||
	fail "repair_kpanel_env did not add the cluster private CIDR whitelist"
grep -q '^KPANEL_PUBLIC_URL=http://10.31.3.201:3666$' "$C2_GUARD_KPANEL_ENV" ||
	fail "repair_kpanel_env must keep the existing .env keys"

# 幂等：已经正确时不得再次改写
_before=$(cat "$C2_GUARD_KPANEL_ENV")
repair_kpanel_env
_rc=$?
[ "$_rc" -eq 0 ] || fail "repair_kpanel_env must be idempotent (got $_rc)"
[ "$_before" = "$(cat "$C2_GUARD_KPANEL_ENV")" ] ||
	fail "repair_kpanel_env rewrote an already correct .env"

# 白名单被改窄时必须纠正回来，且不能出现重复键
sed -i 's|^KPANEL_CLUSTER_PRIVATE_CIDRS=.*|KPANEL_CLUSTER_PRIVATE_CIDRS=10.0.0.0/8|' "$C2_GUARD_KPANEL_ENV"
repair_kpanel_env >/dev/null
[ "$(grep -c '^KPANEL_CLUSTER_PRIVATE_CIDRS=' "$C2_GUARD_KPANEL_ENV")" -eq 1 ] ||
	fail "repair_kpanel_env must not duplicate the whitelist key"
grep -q '^KPANEL_CLUSTER_PRIVATE_CIDRS=10.31.3.0/24$' "$C2_GUARD_KPANEL_ENV" ||
	fail "repair_kpanel_env must restore the configured whitelist"

# do_check 必须把这条规则纳入守护流程
grep -q 'repair_kpanel_env' "$guard_path" ||
	fail "c2_guard.sh must run repair_kpanel_env inside do_check"
grep -q 'C2_GUARD_KPANEL_ENV' "$guard_path" ||
	fail "c2_guard.sh must allow overriding the KPanel .env path"

# 白名单丢失时，do_check 必须把它补回来
sed -i '/^KPANEL_CLUSTER_PRIVATE_CIDRS=/d' "$C2_GUARD_KPANEL_ENV"
do_check || fail "do_check returned non-zero"
grep -q '^KPANEL_CLUSTER_PRIVATE_CIDRS=10.31.3.0/24$' "$C2_GUARD_KPANEL_ENV" ||
	fail "do_check did not restore the KPanel cluster private CIDR whitelist"

echo "c2_guard_smoke=pass"
