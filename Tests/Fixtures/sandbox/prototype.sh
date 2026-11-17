#!/bin/bash
# A throwaway session box, built by hand with unshare(1), for measuring what the session sandbox must give (the session
# sandbox plan's SB0, docs/superpowers/plans/2026-11-17-v2-session-sandbox.md). Nothing in the product runs it; the
# product's box is the shim's (`Platform.Sandbox`).
#
#   prototype.sh HOME WORKTREE CONFIG [options] -- COMMAND...
#
# HOME is the box's home: a scratch folder of the run's, bound read-write at its own path. WORKTREE is bound
# read-write and is where COMMAND starts. CONFIG is a Claude Code config folder, or `-` for none: the box's config
# folder is HOME/.claude, the session's own, and each entry of CONFIG on the read-only list below is bound read-only
# into it (the plan's "The agent itself" table); `.credentials.json` too, read-only, never copied. Whatever else
# Claude Code writes there stays in HOME.
#
# Options:
#   --ro PATH          PATH read-only, at its own path (a file or a folder), with the mounts below it
#   --rw PATH          PATH read-write, at its own path
#   --private PATH     PATH read through an overlay: writes go to a layer in memory, thrown away with the box
#   --net shared|none  the host's network (the default: slice 1's worker) or a namespace with loopback alone
#   --sys              /sys, read-only (the kernel allows sysfs only in a network namespace of the box's own)
#   --nproc N          RLIMIT_NPROC, set before the user namespace is made
#   --env NAME=VALUE   an environment entry for COMMAND, besides the allow-list
#   --path FOLDER      a folder put first on COMMAND's PATH
#
# The box: a tmpfs root; /usr, /etc and /opt read-only (every mount under them too), with /bin, /lib, /lib64 and /sbin
# as links; its own /proc, /dev (null, zero, full, random, urandom, tty, a devpts of its own, shm), /tmp and /var/tmp;
# the user's own uid (mapped to itself), no capability in any set, no_new_privs; every mount nosuid and nodev but
# the device nodes. Nothing else of the machine is there: not the rest of the home, /run, /mnt, /init, /sys (unless
# asked), the node's sockets. COMMAND is pid 1 of a pid namespace of its own, so when it ends every process of the box
# does. The terminal it was given keeps working, and has no name inside.
#
# Exit status: COMMAND's; 64 for a bad call, which makes nothing, or a HOME that is, or holds, the account's own home;
# 70 when a step of building the box failed (named on stderr).
set -euo pipefail

# The config folder's entries bound read-only (the plan's `ClaudeFiles.readOnlyEntries`, and the login).
readonly CLAUDE_READ_ONLY=(settings.json settings.local.json CLAUDE.md skills agents commands plugins keybindings.json
                           statusline.sh policy-limits.json remote-settings.json .credentials.json)

say() { printf 'prototype.sh: %s\n' "$*" >&2; }

if [[ "${VIBE_PROTOTYPE_STAGE:-}" != inside ]]; then
    if [[ $# -lt 5 ]]; then
        say "usage: prototype.sh HOME WORKTREE CONFIG [options] -- COMMAND..."
        exit 64
    fi
    home=$1 worktree=$2
    for folder in "$home" "$worktree"; do
        [[ "$folder" == /* && -d "$folder" ]] || { say "$folder: not an absolute path to a folder"; exit 64; }
    done
    account=$(getent passwd "$(id -u)" | cut -d: -f6)
    real_home=$(realpath -e "$home")
    real_account=$(realpath -e "$account")
    case "$real_account/" in
        "$real_home"/*) say "refusing $home: it is, or holds, the account's own home ($account)"; exit 64 ;;
    esac
    net=shared nproc=
    rest=("${@:4}")
    index=0
    while [[ $index -lt ${#rest[@]} && "${rest[$index]}" != -- ]]; do
        case "${rest[$index]}" in
            --net) net=${rest[$((index + 1))]:-}; index=$((index + 2)) ;;
            --nproc) nproc=${rest[$((index + 1))]:-}; index=$((index + 2)) ;;
            --ro|--rw|--private|--env|--path) index=$((index + 2)) ;;
            --sys) index=$((index + 1)) ;;
            *) say "unknown option ${rest[$index]}"; exit 64 ;;
        esac
    done
    [[ $((index + 1)) -lt ${#rest[@]} ]] || { say "no COMMAND after --"; exit 64; }
    [[ "$net" == shared || "$net" == none ]] || { say "--net is shared or none"; exit 64; }
    root=$(mktemp -d "${TMPDIR:-/tmp}/box-root.XXXXXX")
    trap 'rmdir "$root" 2>/dev/null || true' EXIT
    namespaces=(--user --map-current-user --keep-caps --mount --pid --fork --kill-child --ipc --uts --cgroup)
    [[ "$net" == none ]] && namespaces+=(--net)
    [[ -n "$nproc" ]] && ulimit -u "$nproc"
    status=0
    VIBE_PROTOTYPE_STAGE=inside VIBE_PROTOTYPE_ROOT=$root \
        VIBE_PROTOTYPE_USER=$(id -un) VIBE_PROTOTYPE_TERM=${TERM:-dumb} VIBE_PROTOTYPE_LANG=${LANG:-C.UTF-8} \
        /usr/bin/unshare "${namespaces[@]}" -- /bin/bash "$0" "$@" || status=$?
    exit $status
fi

# Inside: the user's own uid, holding every capability of a user namespace of its own (kept across exec as ambient
# ones, `--keep-caps`), pid 1 of a pid namespace, pid 1 of a pid namespace, in a mount namespace of its own. Everything
# below changes only this namespace's view; nothing outside it moves.
fail() { say "the box couldn't be built: $*"; exit 70; }
R=$VIBE_PROTOTYPE_ROOT
home=$1 worktree=$2 config=$3
shift 3
mounts=() extra_env=() extra_path=() sys=0 net=shared
while [[ "$1" != -- ]]; do
    case "$1" in
        --ro|--rw|--private) mounts+=("${1#--}:$2"); shift 2 ;;
        --env) extra_env+=("$2"); shift 2 ;;
        --path) extra_path+=("$2"); shift 2 ;;
        --net) net=$2; shift 2 ;;
        --nproc) shift 2 ;;
        --sys) sys=1; shift ;;
    esac
done
shift

# A mount point for `source` at `R/target`: a folder, or an empty file for a file.
point() {
    if [[ -d "$1" ]]; then mkdir -p "$R$2"; else mkdir -p "$(dirname "$R$2")"; [[ -e "$R$2" ]] || : >"$R$2"; fi
}

# Every mount at or under `R/target` made read-only, nosuid and nodev, keeping the atime and noexec flags each has
# (the kernel refuses a remount that would clear a flag the mount's owner locked).
read_only_below() {
    local top="$R$1" point options atime noexec
    while read -r point options; do
        atime=relatime noexec=
        case ",$options," in *,noatime,*) atime=noatime ;; *,nodiratime,*) atime=nodiratime ;; esac
        case ",$options," in *,noexec,*) noexec=,noexec ;; esac
        mount -o "remount,bind,ro,nosuid,nodev,$atime$noexec" "$point" || fail "read-only remount of $point"
    done < <(awk -v t="$top" '$5 == t || index($5, t "/") == 1 { print $5, $6 }' /proc/self/mountinfo)
}

bind_ro() { point "$1" "${2:-$1}"; mount --rbind "$1" "$R${2:-$1}" || fail "bind of $1"; read_only_below "${2:-$1}"; }
bind_rw() { point "$1" "${2:-$1}"; mount --rbind -o nosuid,nodev "$1" "$R${2:-$1}" || fail "bind of $1"; }

mount --make-rprivate / || fail "private mount tree"
mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs "$R" || fail "the root"

for folder in /usr /etc /opt; do [[ -d "$folder" ]] && bind_ro "$folder"; done
for link in bin lib lib64 sbin; do ln -s "usr/$link" "$R/$link"; done
mkdir -p "$R/proc" && mount -t proc -o nosuid,nodev,noexec proc "$R/proc" || fail "/proc"
mkdir -p "$R/dev" && mount -t tmpfs -o mode=0755,nosuid tmpfs "$R/dev" || fail "/dev"
for node in null zero full random urandom tty; do
    : >"$R/dev/$node" && mount --bind "/dev/$node" "$R/dev/$node" || fail "/dev/$node"
done
mkdir "$R/dev/pts" && mount -t devpts -o newinstance,ptmxmode=0666,mode=0620,nosuid,noexec devpts "$R/dev/pts" || fail "devpts"
ln -s pts/ptmx "$R/dev/ptmx"
mkdir "$R/dev/shm" && mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs "$R/dev/shm" || fail "/dev/shm"
ln -s /proc/self/fd "$R/dev/fd"
ln -s /proc/self/fd/0 "$R/dev/stdin"; ln -s /proc/self/fd/1 "$R/dev/stdout"; ln -s /proc/self/fd/2 "$R/dev/stderr"
for folder in /tmp /var/tmp; do
    mkdir -p "$R$folder" && mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs "$R$folder" || fail "$folder"
done
if [[ $sys == 1 ]]; then
    mkdir -p "$R/sys" && mount -t sysfs -o ro,nosuid,nodev,noexec sysfs "$R/sys" || fail "/sys"
fi

bind_rw "$home"
bind_rw "$worktree"
# The options' mounts, in the order given: a folder bound read-write under one bound read-only comes after it.
layers=0
for mount in "${mounts[@]}"; do
    kind=${mount%%:*} path=${mount#*:}
    case "$kind" in
        ro) bind_ro "$path" ;;
        rw) bind_rw "$path" ;;
        private)
            if [[ $layers == 0 ]]; then
                mkdir -p "$R/.layers" && mount -t tmpfs -o mode=0700 tmpfs "$R/.layers" || fail "the layers"
            fi
            mkdir -p "$R/.layers/$layers/upper" "$R/.layers/$layers/work" "$R$path"
            mount -t overlay overlay -o "lowerdir=$path,upperdir=$R/.layers/$layers/upper,workdir=$R/.layers/$layers/work,nosuid,nodev" \
                "$R$path" || fail "overlay of $path"
            layers=$((layers + 1))
            ;;
    esac
done

# The config folder: the session's own, with the named entries read-only.
if [[ "$config" != - ]]; then
    mkdir -p "$R$home/.claude"
    for entry in "${CLAUDE_READ_ONLY[@]}"; do
        [[ -e "$config/$entry" ]] && bind_ro "$config/$entry" "$home/.claude/$entry"
    done
fi

hostname box
cd "$R"
mkdir .old
pivot_root . .old || fail "pivot_root"
cd /
umount -l /.old || fail "detaching the old root"
rmdir /.old
if [[ -d /.layers ]]; then umount -l /.layers && rmdir /.layers; fi
mount -o remount,bind,ro,nosuid,nodev / || fail "the root read-only"
if [[ "$net" == none ]]; then ip link set lo up || fail "loopback"; fi

path=/usr/local/bin:/usr/bin:/bin
for folder in "${extra_path[@]}"; do path=$folder:$path; done
environment=(HOME="$home" USER="$VIBE_PROTOTYPE_USER" LOGNAME="$VIBE_PROTOTYPE_USER" SHELL=/bin/bash PATH="$path"
             LANG="$VIBE_PROTOTYPE_LANG" TERM="$VIBE_PROTOTYPE_TERM" TMPDIR=/tmp)
[[ "$config" != - ]] && environment+=(CLAUDE_CONFIG_DIR="$home/.claude")
cd "$worktree"
exec setpriv --no-new-privs --inh-caps=-all --ambient-caps=-all --bounding-set=-all -- env -i "${environment[@]}" "${extra_env[@]}" "$@"
