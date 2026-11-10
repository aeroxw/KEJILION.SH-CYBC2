#!/bin/bash
set -euo pipefail

script_path=${1:-"$(cd "$(dirname "$0")/.." && pwd)/kejilion.sh"}
helper_body=$(
	awk '
		/^(c2_apps_git_remotes|refresh_apps_catalog)\(\) \{/ { capture=1 }
		capture { print }
		capture && /^\}$/ { capture=0 }
	' "$script_path"
)
[ -n "$helper_body" ]
eval "$helper_body"

test_root=$(mktemp -d)
# MSYS(Windows) 下 mktemp 会返回带盘符的路径，后续 rm 会被安全删除钩子拒绝，
# 统一改用 /tmp 下的 POSIX 路径。
case "$test_root" in
	[A-Za-z]:*) test_root="$(TMPDIR=/tmp mktemp -d)" ;;
esac
cleanup() {
	case "$test_root" in
		/tmp/*) rm -rf -- "$test_root" ;;
	esac
}
trap cleanup EXIT HUP INT TERM

export HOME="$test_root/home"
mkdir -p "$HOME"
git_log="$test_root/git.log"
: >"$git_log"
gh_proxy=
gl_hong=
gl_bai=
gl_kjlan=

install() {
	[ "$1" = git ]
}

# 真实实现里克隆/拉取分别有 120s / 60s 上限，测试只需要去掉超时包装
timeout() {
	shift
	"$@"
}

c2_enabled() {
	[ "${C2_TEST_ENABLED:-0}" = 1 ]
}

git() {
	printf '%s\n' "$*" >>"$git_log"
	case "$1" in
		clone)
			destination=${4:?missing clone destination}
			if [ -n "${GIT_CLONE_FAIL_REMOTE:-}" ] && [ "$3" = "$GIT_CLONE_FAIL_REMOTE" ]; then
				mkdir -p "$destination"
				return 1
			fi
			mkdir -p "$destination/.git"
			;;
		-C)
			[ "${GIT_PULL_FAIL:-0}" != 1 ]
			;;
		*)
			return 1
			;;
	esac
}

# --- 1. 首选源可用时直接克隆 -------------------------------------------------
refresh_apps_catalog
test -d "$HOME/apps/.git"
grep -Fx 'clone --depth=1 github.com/kejilion/apps.git '"$HOME"'/apps' "$git_log" >/dev/null

# --- 2. 首选源失败时自动回退到下一个镜像 ------------------------------------
: >"$git_log"
rm -rf -- "$HOME/apps"
GIT_CLONE_FAIL_REMOTE="github.com/kejilion/apps.git" refresh_apps_catalog
test -d "$HOME/apps/.git"
grep -Fx 'clone --depth=1 https://ghproxy.net/https://github.com/kejilion/apps.git '"$HOME"'/apps' "$git_log" >/dev/null
grep -c '^clone ' "$git_log" | grep -Fx '2' >/dev/null

# --- 3. 已有仓库时走拉取 ----------------------------------------------------
: >"$git_log"
refresh_apps_catalog
grep -Fx -- '-C '"$HOME"'/apps pull --ff-only github.com/kejilion/apps.git main' "$git_log" >/dev/null

# --- 4. 非 C2 模式下拉取失败必须报错 ----------------------------------------
if GIT_PULL_FAIL=1 refresh_apps_catalog >"$test_root/pull-failure.out" 2>&1; then
	echo "catalog refresh accepted a failed fast-forward pull" >&2
	exit 1
fi
grep -F '拒绝继续使用可能过期的配置' "$test_root/pull-failure.out" >/dev/null

# --- 5. C2 模式下拉取失败降级为使用本地列表 ---------------------------------
if ! C2_TEST_ENABLED=1 GIT_PULL_FAIL=1 refresh_apps_catalog >"$test_root/pull-degraded.out" 2>&1; then
	echo "C2 catalog refresh should fall back to the local catalog" >&2
	exit 1
fi
grep -F '继续使用本地已有列表' "$test_root/pull-degraded.out" >/dev/null

# --- 6. 已存在但不是 Git 仓库的目录必须拒绝 ---------------------------------
rm -rf -- "$HOME/apps"
mkdir -p "$HOME/apps"
if refresh_apps_catalog >"$test_root/non-git.out" 2>&1; then
	echo "catalog refresh accepted an existing non-Git directory" >&2
	exit 1
fi
grep -F '已存在但不是应用市场 Git 仓库' "$test_root/non-git.out" >/dev/null

# --- 7. 候选镜像顺序固定，且首选源优先 --------------------------------------
mapfile -t remotes < <(c2_apps_git_remotes)
[ "${#remotes[@]}" -ge 3 ]
[ "${remotes[0]}" = "github.com/kejilion/apps.git" ]
[ "${remotes[1]}" = "https://ghproxy.net/https://github.com/kejilion/apps.git" ]

echo "app_catalog_refresh_smoke=pass"
