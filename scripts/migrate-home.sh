#!/usr/bin/env bash
# 在 Linux Docker 宿主机以 root 执行；只导出旧容器层 HOME，不输出凭据内容。
set -euo pipefail
fatal() { printf 'dsh-home-migrate: %s\n' "$*" >&2; exit 1; }
preserve_exports() {
    local saved
    for saved in "${export_dir:-}" "${staging:-}"; do
        if [[ -n "$saved" && -d "$saved" ]]; then
            printf '迁移暂存保留在 %s；未删除源容器。\n' "$saved" >&2
        fi
    done
}
[[ $# == 3 ]] || fatal 'usage: sudo bash scripts/migrate-home.sh OLD_CONTAINER HOST_APP_DIR SOURCE_HOME'
container="${1#/}"
[[ "$container" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || fatal '容器名称不合法。'
# 源目录由操作者显式提供；拒绝会改变 docker cp 链接语义或绕过挂载比较的路径。
source_home="$3"
[[ "$source_home" == /* && "$source_home" != / && "$source_home" != *[[:cntrl:]]* \
    && "$source_home/" != *'//'* && "$source_home/" != *'/./'* && "$source_home/" != *'/../'* ]] \
    || fatal 'SOURCE_HOME 必须是非根目录的规范绝对路径，不含控制字符、重复分隔符、点路径段或末尾斜杠。'
[[ -d "$2" ]] || fatal '宿主挂载目录不存在。'
app_dir="$(cd -- "$2" && pwd -P)"
[[ "$app_dir" != / ]] || fatal '不能把宿主根目录用作 APP 挂载目录。'
target="$app_dir/.home"
[[ ! -e "$target" && ! -L "$target" ]] || fatal "目标已存在，未覆盖：$target"
if [[ -z "${DOCKER_CONTEXT:-}" && -n "${DOCKER_HOST:-}" && "$DOCKER_HOST" != unix://* ]]; then
    fatal '拒绝远程 Docker endpoint；请在 daemon 所在宿主机使用 Unix socket。'
fi
[[ "$(uname -s)" == Linux ]] || fatal '请在 Linux Docker 宿主机运行迁移。'
(( EUID == 0 )) || fatal '需要宿主 root 权限完成私有目录的原子移动；请使用 sudo bash。'
command -v docker >/dev/null || fatal '找不到 Docker CLI。'
if [[ -n "${DOCKER_HOST:-}" && -z "${DOCKER_CONTEXT:-}" ]]; then
    endpoint="$DOCKER_HOST"
else
    endpoint="$(docker context inspect "${DOCKER_CONTEXT:-$(docker context show)}" --format '{{.Endpoints.docker.Host}}')"
fi
[[ "$endpoint" == unix://* ]] || fatal '拒绝远程 Docker endpoint；请在 daemon 所在宿主机使用 Unix socket。'
[[ "$(docker inspect --format '{{.State.Running}}' "$container")" == false ]] \
    || fatal '源容器仍在运行；请先 docker stop，避免复制正在变化的登录配置。'
[[ "$(docker inspect --format '{{.HostConfig.Privileged}}' "$container")" == false ]] \
    || fatal '不自动迁移 privileged 容器；其内部挂载无法可靠判断。'
while IFS= read -r capability; do
    [[ "${capability#CAP_}" != SYS_ADMIN && "$capability" != ALL ]] \
        || fatal '不自动迁移带 SYS_ADMIN 的容器；请先人工确认内部挂载。'
done <<< "$(docker inspect --format '{{range .HostConfig.CapAdd}}{{println .}}{{end}}' "$container")"

# 只支持原先没有挂载的容器层 HOME。覆盖 HOME 或其子目录的挂载需单独迁移，
# 否则把 staging 建在源 HOME 内可能导致递归自复制。这里只读挂载元数据。
while IFS= read -r destination; do
    [[ -n "$destination" ]] || continue
    destination="${destination%/}/"
    if [[ "$source_home/" == "$destination"* || "$destination" == "$source_home/"* ]]; then
        fatal '源 HOME 存在挂载；请直接备份其宿主数据，本脚本不做重叠导出。'
    fi
done <<< "$(docker inspect --format '{{range .Mounts}}{{println .Destination}}{{end}}' "$container")"
# 父目录链接可能把词法路径重定向到挂载内；复制前按容器视图逐级检查。
bash "$(dirname -- "${BASH_SOURCE[0]}")/verify-home-path.sh" "${endpoint#unix://}" "$container" "$source_home"
docker_root="$(docker info --format '{{.DockerRootDir}}')"
if [[ -d "$docker_root" ]]; then docker_root="$(cd -- "$docker_root" && pwd -P)"; fi
[[ -n "$docker_root" && "$app_dir" != "$docker_root" && "$app_dir" != "$docker_root/"* ]] \
    || fatal 'APP 目录不能位于 Docker 内部数据目录，避免导出与目标重叠。'
image="$(docker inspect --format '{{.Image}}' "$container")"

# 先导出到源容器不可见的私有临时目录，避免根 HOME 链接指向 APP 时，
# 在确认它是链接之前就往源树里创建 staging。TMPDIR 可指定足够大的临时文件系统。
export_parent="${TMPDIR:-/tmp}"
[[ -d "$export_parent" ]] || fatal '临时目录不存在。'
export_parent="$(cd -- "$export_parent" && pwd -P)"
[[ "$export_parent" != "$docker_root" && "$export_parent" != "$docker_root/"* ]] \
    || fatal '临时目录不能位于 Docker 内部数据目录。'
while IFS= read -r source; do
    [[ -n "$source" ]] || continue
    source="$(readlink -f -- "$source")"
    if [[ "$export_parent" == "$source" || "$export_parent" == "${source%/}/"* ]]; then
        fatal '临时目录位于源容器挂载范围内；请指定不重叠的 TMPDIR。'
    fi
done <<< "$(docker inspect --format '{{range .Mounts}}{{println .Source}}{{end}}' "$container")"
staging=''
export_dir="$(mktemp -d "$export_parent/dsh-home-export.XXXXXX")"
trap preserve_exports EXIT
# 不加 -L 或尾随 /.，仅复制根链接本身并拒绝，不跟随到另一棵数据树。
docker cp "$container:$source_home" "$export_dir/agent"
[[ -d "$export_dir/agent" && ! -L "$export_dir/agent" ]] \
    || fatal '源 HOME 不是实际目录或已是链接；未发布，请直接迁移其已有持久化数据。'
# 已完成安全导出，再放到目标同一文件系统，保证最后的发布可以原子 rename。
staging="$(mktemp -d "$app_dir/.home-import.XXXXXX")"
mv -T -- "$export_dir/agent" "$staging/agent"
rmdir -- "$export_dir"
export_dir=''

# 一次性元数据修复：APP 只读，仅导出副本可写；不写工程文件，不用 DAC_OVERRIDE。
# shellcheck disable=SC2016 # 程序中的变量在 helper 容器内展开。
docker run --rm --network none --read-only --user 0:0 \
    --cap-drop ALL --cap-add CHOWN --cap-add DAC_READ_SEARCH \
    --security-opt no-new-privileges:true --entrypoint /bin/bash \
    --mount "type=bind,source=$app_dir,target=/workspace,readonly" \
    --mount "type=bind,source=$staging,target=/migration" \
    -e "AGENT_UID=${AGENT_UID:-}" -e "AGENT_GID=${AGENT_GID:-}" \
    "$image" -euc '
        uid="${AGENT_UID:-$(stat -c %u /workspace)}"
        gid="${AGENT_GID:-$(stat -c %g /workspace)}"
        if [[ "$uid" == 0 ]]; then uid="$(id -u agent)"; fi
        if [[ "$gid" == 0 ]]; then gid="$(id -g agent)"; fi
        [[ "$uid" =~ ^[1-9][0-9]{0,9}$ && "$gid" =~ ^[1-9][0-9]{0,9}$ ]]
        ((10#$uid < 4294967295 && 10#$gid < 4294967295))
        test -d /migration/agent
        test ! -L /migration/agent
        chown -h 0:0 /migration/agent
        chmod 0700 /migration/agent
        chown -hR "$uid:$gid" /migration/agent
        printf "HOME ownership prepared: %s:%s\n" "$uid" "$gid"
    '

# 需宿主 root：目录改为目标 UID/0700 后，普通调用者可能无权更新其 .. 条目。
# staging 与目标在同一文件系统；-T + no-clobber 保证既不合并也不覆盖新出现的目标。
mv -T --no-clobber -- "$staging/agent" "$target"
[[ ! -e "$staging/agent" && ! -L "$staging/agent" ]] || fatal "迁移期间目标已出现，未覆盖；请保留并检查 $staging"
rmdir -- "$staging"
trap - EXIT
printf 'HOME 已迁移到 %s；源容器仍保留。现在可创建新版容器。\n' "$target"
