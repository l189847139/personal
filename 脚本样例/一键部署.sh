#!/bin/bash
set -euo pipefail  # 任何命令失败立即终止脚本

# 一键部署脚本（支持本地与多主机部署）
#  - 本地部署：将本地 tar.gz 解压到指定目录并创建/更新软链接；
#  - 远程部署：通过 scp 将压缩包传到远端并在远端完成解压与软链更新；
#  - 提供安全删除选项、可配置 SSH 用户/密钥/端口；
# 兼容性注意：
#  - 依赖 tar 支持 -tzf（用于读取压缩包内顶级目录），并依赖标准的 ssh/scp 命令。
# 执行时只需要执行 + 压缩包名 ，第一次执行时需验证有无免密认证
# 配置变量（可通过命令行覆盖）：
TARGET_DIR="/data/dcp-application"      # 部署到的目标目录（远端和本地均使用）
LINK_NAME="/data/dcp/deploy"            # 指向已部署版本的软链接
ENABLE_DELETE=true                      # 部署后是否删除压缩包（true/false）
SSH_USER="dcp"                          # SSH 登录用户名（默认使用当前用户名或 -u 指定）
IDENTITY_FILE=""                        # SSH 私钥路径（如果需要免密登录）
DEFAULT_PORT=22                         # SSH 默认端口
SERVERS="dcp@10.68.133.41:22"           # 要部署的主机列表（逗号或空格分隔），格式：[user@]host[:port]
ENSURE_SSH_SETUP=true                   # 部署前是否尝试安装公钥以实现免密（可通过 --no-setup-ssh 关闭）

# show_usage: 打印脚本使用说明并退出（用于参数错误或用户请求帮助时）
show_usage() {
  cat <<EOF
用法: $0 <压缩包> | $0 -f <压缩包> [-s <servers>] [选项]

说明:
  本脚本用于将程序部署到 Linux 主机（远端需为 Linux 系统）。
  直接传入压缩包文件名（路径或文件名）即可执行本地部署，例如：
    $0 myapp.tar.gz
  或使用 -f 指定压缩包，并可通过 -s 指定多台服务器进行远程部署。

必选（仅当使用长格式时）:
  -f, --file <file>            本地压缩包文件（.tar.gz）

可选:
  -s, --servers <list>         目标服务器列表，逗号或空格分隔，格式示例：
                               host1,host2
                               user@host1,host2:2222
  -u, --user <ssh_user>        SSH 登录用户（若服务器项未指定用户则使用此项）
  -i, --identity <id_file>     SSH 私钥文件路径
  -r, --target <target_dir>    远程或本地目标目录（默认: $TARGET_DIR）
  -l, --link <link_name>       要创建的软链接路径（默认: $LINK_NAME）
  --no-delete                  不删除压缩包（默认会删除）
  --no-setup-ssh               不在部署前尝试安装公钥（禁用自动免密安装）
  -h, --help                   显示帮助

示例:
  本地部署（简写）: $0 myapp.tar.gz
  本地部署（长格式）: $0 -f myapp.tar.gz
  多台服务器部署: $0 -f myapp.tar.gz -s "server1,deploy@server2:2222" -u deploy -i ~/.ssh/id_rsa
EOF
  exit 1
}  

# 简单日志函数：
# - log: 输出带时间戳的一般信息（写到 stdout）
# - error: 输出带时间戳的错误信息到 stderr
log() { echo "["]> /dev/null; echo "[$(date '+%F %T')] $*"; }
error() { echo "[$(date '+%F %T')] [错误] $*" >&2; }

# 确保本地存在可用的公钥（返回公钥路径）
# 优先使用 -i 指定的私钥对应的 .pub；如无则尝试现有 id_ed25519/id_rsa，否则生成新的 ed25519 密钥
ensure_local_pubkey() {
  local pub priv
  if [ -n "$IDENTITY_FILE" ]; then
    priv="$IDENTITY_FILE"
    pub="${IDENTITY_FILE}.pub"
  else
    if [ -f "$HOME/.ssh/id_ed25519" ]; then
      priv="$HOME/.ssh/id_ed25519"; pub="$HOME/.ssh/id_ed25519.pub"
    elif [ -f "$HOME/.ssh/id_rsa" ]; then
      priv="$HOME/.ssh/id_rsa"; pub="$HOME/.ssh/id_rsa.pub"
    else
      priv="$HOME/.ssh/id_ed25519"; pub="$HOME/.ssh/id_ed25519.pub"
      log "未找到本地 SSH 密钥，生成新的无密码 ed25519 密钥对: $priv"
      ssh-keygen -t ed25519 -f "$priv" -N "" -q || { error "生成 SSH 密钥失败"; return 1; }
    fi
  fi

  # 如 pub 不存在但私钥存在，尝试从私钥生成公钥
  if [ ! -f "$pub" ]; then
    if [ -f "$priv" ]; then
      ssh-keygen -y -f "$priv" > "$pub" || { error "从私钥生成公钥失败: $priv"; return 1; }
    else
      error "找不到可用的私钥或公钥"; return 1
    fi
  fi
  echo "$pub"
}

# 尝试在远端安装公钥以实现免密（优先使用 ssh-copy-id，其次 scp+远端追加）
try_setup_ssh_on_host() {
  local user="$1" host="$2" port="$3"
  log "尝试在 $user@$host:$port 安装公钥以实现免密登录（将提示远端密码）"
  local pub
  pub=$(ensure_local_pubkey) || return 1

  # 优先使用 ssh-copy-id（更健壮），若不可用则回退到 scp + 远端追加
  if command -v ssh-copy-id >/dev/null 2>&1; then
    ssh-copy-id -i "$pub" -p "$port" "${user}@${host}" || return 1
    return 0
  fi

  local tmp_remote="/tmp/$(basename "$pub").$$"
  scp -P "$port" "$pub" "${user}@${host}:$tmp_remote" || return 1
  ssh -p "$port" "${user}@${host}" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && grep -qxF \"\$(cat $tmp_remote)\" ~/.ssh/authorized_keys || cat $tmp_remote >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && rm -f $tmp_remote" || return 1
  return 0
}

# 检查是否已能免密登录（尝试批处理模式 SSH）
check_ssh_auth() {
  local user="$1" host="$2" port="$3"
  ssh -o BatchMode=yes -o ConnectTimeout=5 -p "$port" "${user}@${host}" 'echo SSH_OK' >/dev/null 2>&1
}

# resolve_path: 兼容的绝对路径解析函数，优先 realpath -> readlink -f -> cd + pwd
resolve_path() {
  local p="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$p"
  elif command -v readlink >/dev/null 2>&1; then
    readlink -f "$p"
  else
    (cd "$p" && pwd -P)
  fi
}

# 检查运行所需命令（tar/ssh/scp），以及在启用自动安装公钥时检查 ssh-keygen
check_commands() {
  local cmds=(tar ssh scp)
  for c in "${cmds[@]}"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      error "需要的命令不存在：$c，请在目标 Linux 主机或本机安装后重试"
      exit 2
    fi
  done
  if [ "${ENSURE_SSH_SETUP:-true}" = true ]; then
    if ! command -v ssh-keygen >/dev/null 2>&1; then
      error "ssh-keygen 未找到，但 ENSURE_SSH_SETUP=true，无法生成或处理密钥，请安装 openssh-client 或相应包"
      exit 2
    fi
  fi
}

# 参数解析
# 支持：-f/--file 指定文件；-s/--servers 指定主机列表；也可直接把压缩包作为第一个位置参数（示例: ./一键部署.sh myapp.tar.gz）
if [ $# -eq 0 ]; then
  show_usage
fi

COMPRESS_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file) COMPRESS_FILE="$2"; shift 2 ;; # 指定压缩包路径
    -s|--servers) SERVERS="$2"; shift 2 ;;     # 服务器列表
    -u|--user) SSH_USER="$2"; shift 2 ;;       # SSH 用户
    -i|--identity) IDENTITY_FILE="$2"; shift 2 ;; # SSH 私钥
    -r|--target) TARGET_DIR="$2"; shift 2 ;;   # 覆盖目标目录
    -l|--link) LINK_NAME="$2"; shift 2 ;;      # 覆盖软链路径
    --no-delete) ENABLE_DELETE=false; shift ;;  # 部署后不删除压缩包
    --no-setup-ssh) ENSURE_SSH_SETUP=false; shift ;;  # 禁用自动安装公钥
    -h|--help) show_usage ;;                   # 显示帮助
    *)
      if [ -z "$COMPRESS_FILE" ]; then
        COMPRESS_FILE="$1"; shift                # 位置参数作为压缩包路径
      else
        error "未知参数: $1"; show_usage
      fi
      ;;
  esac
done

# 基本校验
# - 检查是否提供了压缩包名或路径
# - 如果给的是相对文件名且当前工作目录找不到，则尝试在脚本所在目录查找（便于从项目根运行脚本时只传包名）
if [ -z "$COMPRESS_FILE" ]; then
  error "未指定压缩包文件"; show_usage
fi

if [ ! -f "$COMPRESS_FILE" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # 如果在脚本目录中存在同名文件，则使用该路径
  if [ -f "$SCRIPT_DIR/$COMPRESS_FILE" ]; then
    COMPRESS_FILE="$SCRIPT_DIR/$COMPRESS_FILE"
  else
    error "压缩包不存在: $COMPRESS_FILE"; exit 2
  fi
fi

BASENAME=$(basename -- "$COMPRESS_FILE")

# 运行前检测必需命令与环境（针对 Linux 目标和本地环境）
check_commands

# 本地部署函数（deploy_local）
# 步骤说明：
#  1) 确保目标目录存在并 cd 进入
#  2) 读取压缩包中第一个条目以确定顶级目录名（不实际解压，以便知道解压后目录名）
#  3) 若存在同名目录则清理（注意：此操作将删除旧目录）
#  4) 解压、校验、创建/更新软链接，最后根据配置选择是否删除压缩包
deploy_local() {
  log "开始本地部署：$BASENAME 到 $TARGET_DIR"
  echo "正在进入目录: $TARGET_DIR"
  mkdir -p "$TARGET_DIR"
  cd "$TARGET_DIR" || { error "无法进入目录：$TARGET_DIR"; return 1; }

  # 从压缩包中读取第一个条目以获取顶级目录的名字（不实际解压）
  echo "正在解压: $BASENAME"
  TOP_DIR=$(tar -tzf "$BASENAME" | head -1 | cut -f1 -d"/")
  if [ -z "$TOP_DIR" ]; then
    error "压缩包内没有顶级目录"
    return 2
  fi

  # 如果已经存在同名目录，则认为是旧版本并清理（注意：破坏性操作）
  if [ -d "$TOP_DIR" ]; then
    echo "检测到已存在目录 $TOP_DIR，执行清理..."
    rm -rf "$TOP_DIR"
  fi

  # 执行解压并设置解压后目录变量以便后续验证
  tar -xzf "$BASENAME"
  UNPACKED_DIR="$TOP_DIR"

  # 验证解压是否成功
  if [ ! -d "$UNPACKED_DIR" ]; then
    error "解压目录验证失败：$UNPACKED_DIR"; ls -l; return 3
  fi

  # 创建或更新符号链接，ln -sfn 用于原子更新
  echo "创建软链接: $LINK_NAME → $UNPACKED_DIR"
  ABS_DIR=$(resolve_path "$UNPACKED_DIR")
  ln -sfn "$ABS_DIR" "$LINK_NAME"

  # 可选地删除上传的压缩包以释放空间
  if [ "$ENABLE_DELETE" = true ]; then
    echo "正在安全清理压缩包..."
    if [ -f "$BASENAME" ]; then
      rm -v -- "$BASENAME"
      echo "[成功] 压缩包已删除"
    else
      echo "[警告] 压缩包不存在：$BASENAME"
    fi
  fi

  echo "本地部署完成：链接指向：$(ls -l $LINK_NAME)"
} 

# 远程部署函数（在远端机器上执行）
# 参数 entry 格式： [user@]host[:port]
# 流程：
#  1) 解析 user/host/port（优先使用 entry 中指定的 user/port，否则回退到 -u 指定或默认）
#  2) 构建 ssh/scp 参数（包括 -i 指定私钥和 accept-new 主机密钥策略）
#  3) 确保远端目标目录存在 -> scp 上传压缩包 -> 在远端执行与本地相同的解压+软链更新逻辑
deploy_remote() {
  local entry="$1"
  # 解析 entry 格式: [user@]host[:port]
  local user host port
  user=""
  port=""

  # 提取 user@host:port
  if [[ "$entry" =~ @ ]]; then
    user_part="${entry%%@*}"
    rest="${entry#*@}"
    user="$user_part"
  else
    rest="$entry"
  fi

  if [[ "$rest" =~ : ]]; then
    host="${rest%%:*}"
    port="${rest#*:}"
  else
    host="$rest"
  fi

  # 如果 entry 没有指定 user，则使用 -u 提供的 SSH_USER，或 fallback 到当前 $USER
  if [ -z "$user" ]; then
    if [ -n "$SSH_USER" ]; then
      user="$SSH_USER"
    else
      user="$USER"
    fi
  fi
  # 端口默认 fallback
  if [ -z "$port" ]; then
    port=$DEFAULT_PORT
  fi

  log "开始在 $user@$host:$port 上部署"

  # SSH 与 SCP 命令选项：设置 Accept-new 主机密钥以便首次连接自动接受
  SSH_OPTS=( -o StrictHostKeyChecking=accept-new -p "$port" )
  if [ -n "$IDENTITY_FILE" ]; then
    SSH_OPTS+=( -i "$IDENTITY_FILE" )
  fi

  # scp 选项，和 ssh 类似；scp_cmd 数组方便后续调用
  scp_cmd=( scp -P "$port" )
  if [ -n "$IDENTITY_FILE" ]; then
    scp_cmd+=( -i "$IDENTITY_FILE" )
  fi

  # 在传输之前，检查是否已经能免密登录；若不能且允许自动安装公钥，则尝试安装
  if ! check_ssh_auth "$user" "$host" "$port"; then
    log "$user@$host 不支持免密登录"
    if [ "${ENSURE_SSH_SETUP:-true}" = true ]; then
      log "尝试为 $user@$host 安装公钥..."
      try_setup_ssh_on_host "$user" "$host" "$port" || { error "为 $host 安装公钥失败"; return 6; }
      # 再次验证免密是否生效
      if ! check_ssh_auth "$user" "$host" "$port"; then
        error "$host 仍未设置免密登录"; return 7
      fi
      log "免密登录安装完成并可用"
    else
      error "$host 未启用免密且脚本未允许自动安装"; return 6
    fi
  else
    log "$user@$host 已支持免密登录，继续部署"
  fi

  # 先确保目标目录存在
  ssh "${user}@${host}" "${SSH_OPTS[@]}" "mkdir -p '$TARGET_DIR'" || { error "无法在 $host 创建目录 $TARGET_DIR"; return 4; }

  # 传输压缩包
  "${scp_cmd[@]}" "$COMPRESS_FILE" "${user}@${host}:$TARGET_DIR/" || { error "向 $host 传输文件失败"; return 5; }

  # 在远端执行解压与链接操作
  # 远端脚本说明：
  #  1) 切换到目标目录并读取压缩包中的顶级目录名称
  #  2) 若存在同名目录则清理（此为破坏性操作）
  #  3) 解压、校验、更新软链，并可选删除压缩包
# 在远端执行解压与链接操作（修复后的代码）
ssh "${user}@${host}" "${SSH_OPTS[@]}" bash -s <<EOF
set -e
cd '$TARGET_DIR' || { echo '[错误] 无法进入目录：$TARGET_DIR'; exit 1; }
BASENAME='$BASENAME'
LINK_NAME='$LINK_NAME'
ENABLE_DELETE='$ENABLE_DELETE'

# 远端解压流程说明：
# 1) 先检查压缩包是否存在
if [ ! -f "\$BASENAME" ]; then
  echo "[远程:$host][错误] 压缩包不存在：\$BASENAME"; exit 2
fi

# 2) 使用 tar -tzf 读取压缩包中第一个条目以获得顶级目录名（修复转义）
echo "[远程:$host] 正在解析压缩包顶级目录..."
TOP_DIR=\$(tar -tzf "\$BASENAME" | head -1 | cut -f1 -d"/")
if [ -z "\$TOP_DIR" ]; then
  echo "[远程:$host][错误] 压缩包内无有效顶级目录"; exit 3
fi

# 3) 清理旧目录（若存在）
if [ -d "\$TOP_DIR" ]; then
  echo "[远程:$host] 检测到已存在目录 \$TOP_DIR，执行清理..."
  rm -rf "\$TOP_DIR"
fi

# 4) 解压并校验
echo "[远程:$host] 正在解压: \$BASENAME"
tar -xzf "\$BASENAME"
UNPACKED_DIR="\$TOP_DIR"

if [ ! -d "\$UNPACKED_DIR" ]; then
  echo "[远程:$host][错误] 解压目录验证失败：\$UNPACKED_DIR"; ls -l; exit 4
fi

# 5) 创建/更新软链接（修复绝对路径转义）
echo "[远程:$host] 创建软链接: $LINK_NAME → \$UNPACKED_DIR"
if command -v realpath >/dev/null 2>&1; then
  ABS_DIR=\$(realpath "\$UNPACKED_DIR")
elif command -v readlink >/dev/null 2>&1; then
  ABS_DIR=\$(readlink -f "\$UNPACKED_DIR")
else
  ABS_DIR=\$(cd "\$UNPACKED_DIR" && pwd -P)
fi
ln -sfn "\$ABS_DIR" "\$LINK_NAME"

# 6) 可选删除压缩包
if [ "\$ENABLE_DELETE" = true ]; then
  echo "[远程:$host] 正在安全清理压缩包..."
  if [ -f "\$BASENAME" ]; then
    rm -v -- "\$BASENAME"
    echo "[远程:$host][成功] 压缩包已删除"
  else
    echo "[远程:$host][警告] 压缩包不存在：\$BASENAME"
  fi
fi

echo "[远程:$host] 部署完成，链接指向：\$(ls -l "\$LINK_NAME")"
EOF

  rc=$?
  if [ $rc -ne 0 ]; then
    error "远程部署到 $host 失败（退出码 $rc）"
    return $rc
  fi

  log "$host 部署成功"
}

# 主流程：如果未指定服务器则做本地部署，否则遍历服务器做远程部署
# 本地部署：将压缩包复制到目标目录（使部署逻辑与远端一致），然后在目标目录内执行 deploy_local
if [ -z "$SERVERS" ]; then
  log "未指定服务器列表，执行本地部署"
  # 将压缩包复制到目标目录然后调用本地部署逻辑
  mkdir -p "$TARGET_DIR"
  cp -v -- "$COMPRESS_FILE" "$TARGET_DIR/"
  (cd "$TARGET_DIR" && deploy_local)
  exit 0
fi

# 解析服务器列表（支持逗号或空格分隔）
# 先把逗号替换为空格，再用数组（支持: host, user@host:port 等多种格式）
SERVERS_CLEAN=$(echo "$SERVERS" | tr ',' ' ')
read -ra HOSTS <<< "$SERVERS_CLEAN"

# 传输并部署到每台机器（当前为顺序执行，失败会计数）
failed=0
for host in "${HOSTS[@]}"; do
  host_trimmed=$(echo "$host" | xargs)
  if [ -z "$host_trimmed" ]; then
    continue
  fi
  # deploy_remote 会在失败时返回非 0，循环会记录失败数量
  deploy_remote "$host_trimmed" || failed=$((failed+1))
done

if [ $failed -ne 0 ]; then
  error "存在 $failed 台主机部署失败"
  exit 10
fi

log "全部主机部署成功！"
exit 0
