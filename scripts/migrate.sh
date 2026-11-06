#!/usr/bin/env bash
#
# 统一迁移入口：本地开发与 CI 共用同一条代码路径。
#
# 用法：
#   ./scripts/migrate.sh                 # 等价于 flyway migrate
#   ./scripts/migrate.sh info            # 查看已执行 / 待执行版本
#   ./scripts/migrate.sh validate        # 校验已执行脚本的 checksum
#   ./scripts/migrate.sh repair          # 修复 checksum 不一致（谨慎使用）
#   ./scripts/migrate.sh -target=2 info  # 透传任意 flyway 参数
#
# 它做了什么：
#   1. 解析 flyway.conf 里的 flyway.url，拿到主机 / 端口 / 库名
#      （flyway.conf 是连接信息的唯一来源，这里不再重复配置，避免两处漂移）
#   2. 探测 RDS 是否直连可达；不可达（RDS 在私有子网，通常如此）就通过
#      跳板机建立 SSM 端口转发，把远端 3306 映射到本地 127.0.0.1:3307
#   3. 跳板机 ASG 若为 0 则临时拉到 1，结束时按记录的初始值还原
#   4. 从 AWS Secrets Manager 取出数据库口令，以 FLYWAY_PASSWORD 注入
#   5. 执行 flyway，无论成败都回收端口转发会话与 ASG 容量
#
# 安全：
#   * 口令只存在于进程环境变量中，不落盘、不回显、不进 git
#   * 在 GitHub Actions 里会自动调用 ::add-mask::，避免泄漏到日志
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 配置（全部可用环境变量覆盖；这里没有任何密钥）
# ---------------------------------------------------------------------------
: "${REPO_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${CONFIG_FILE:=${REPO_ROOT}/flyway.conf}"
: "${AWS_REGION:=ap-northeast-1}"
: "${AWS_DEFAULT_REGION:=${AWS_REGION}}"

: "${TUNNEL:=auto}"                 # auto | on | off
: "${TUNNEL_LOCAL_PORT:=3307}"
: "${TUNNEL_WAIT_SECONDS:=120}"
: "${TUNNEL_CONNECT_TIMEOUT:=3}"

: "${ASG_NAME:=platform-dev-bastion}"
: "${BASTION_WAIT_SECONDS:=300}"
: "${AUTO_SCALE_BASTION:=1}"        # 1=ASG 为 0 时自动拉起
: "${RESTORE_BASTION:=1}"           # 1=结束时还原为进入时的 desired capacity

: "${SSM_DOCUMENT:=AWS-StartPortForwardingSessionToRemoteHost}"
: "${FLYWAY_BIN:=flyway}"

export AWS_REGION AWS_DEFAULT_REGION

# ---------------------------------------------------------------------------
# 日志
# ---------------------------------------------------------------------------
log()  { printf '\033[1;34m[migrate]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[migrate]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[migrate]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 状态（供 cleanup 使用）
# ---------------------------------------------------------------------------
session_pid=""
session_id=""
session_log=""
bastion_scaled_by_us=0
initial_desired=""
tunnel_started=0

cleanup() {
  local rc=$?
  set +e

  if [[ "$tunnel_started" == "1" ]]; then
    log "回收 SSM 端口转发会话"
    if [[ -n "$session_pid" ]]; then
      kill "$session_pid" 2>/dev/null
      wait "$session_pid" 2>/dev/null
    fi
    if [[ -n "$session_id" ]]; then
      aws ssm terminate-session --session-id "$session_id" >/dev/null 2>&1
    fi
  fi
  [[ -n "$session_log" && -f "$session_log" ]] && rm -f "$session_log"

  if [[ "$bastion_scaled_by_us" == "1" && "$RESTORE_BASTION" == "1" ]]; then
    log "把跳板机 ASG 的 desired capacity 还原为 ${initial_desired}"
    aws autoscaling update-auto-scaling-group \
      --auto-scaling-group-names "$ASG_NAME" \
      --desired-capacity "$initial_desired" \
      --region "$AWS_REGION" >/dev/null 2>&1
  elif [[ "$bastion_scaled_by_us" == "1" ]]; then
    warn "RESTORE_BASTION=0，跳板机保持在 desired=1（记得手动改回 0）"
  fi

  exit "$rc"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------------
require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "缺少命令：$c"
  done
}

# TCP 连通性探测。优先用 nc（有超时），退回到 bash 的 /dev/tcp。
tcp_reachable() {
  local host=$1 port=$2
  if command -v nc >/dev/null 2>&1; then
    nc -z -w "$TUNNEL_CONNECT_TIMEOUT" "$host" "$port" >/dev/null 2>&1
    return $?
  fi
  (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null
}

# ---------------------------------------------------------------------------
# 1. 解析 flyway.conf 中的连接信息
# ---------------------------------------------------------------------------
parse_connection() {
  [[ -f "$CONFIG_FILE" ]] || die "找不到配置文件：$CONFIG_FILE"

  flyway_url=$(sed -n 's/^flyway\.url=//p' "$CONFIG_FILE" | tail -n 1)
  [[ -n "$flyway_url" ]] || die "${CONFIG_FILE} 里没有 flyway.url"

  case "$flyway_url" in
    jdbc:mysql://*) ;;
    *) die "flyway.url 不是 jdbc:mysql:// 开头：$flyway_url" ;;
  esac

  local rest without_query hostport
  rest=${flyway_url#jdbc:mysql://}
  without_query=${rest%%\?*}                 # host:port/dbname
  hostport=${without_query%%/*}              # host:port
  db_name=${without_query#*/}                # dbname
  query_part=""
  case "$flyway_url" in
    *\?) query_part="?${flyway_url#*\?}" ;;
  esac

  if [[ "$hostport" == *:* ]]; then
    db_host=${hostport%%:*}
    db_port=${hostport##*:}
  else
    db_host=$hostport
    db_port=3306
  fi

  [[ -n "$db_host" ]] || die "无法从 flyway.url 解析出主机名"
  [[ -n "$db_name" ]] || die "flyway.url 里缺少数据库名（/dbname）"

  log "目标数据库：${db_host}:${db_port}/${db_name}"
}

# ---------------------------------------------------------------------------
# 2. 解析 Secrets Manager 中的主账号密钥
# ---------------------------------------------------------------------------
resolve_secret_arn() {
  if [[ -n "${MIGRATE_SECRET_ARN:-}" ]]; then
    printf '%s' "$MIGRATE_SECRET_ARN"
    return 0
  fi

  # 不写死 ARN：按端点地址反查实例，拿到 RDS 自动托管的主账号密钥。
  # 注意 DescribeDBInstances 没有 endpoint-address 过滤器，只能在 JMESPath 里比对。
  local arn
  arn=$(aws rds describe-db-instances \
    --query "DBInstances[?Endpoint.Address=='${db_host}'].MasterUserSecret.SecretArn | [0]" \
    --output text 2>/dev/null || true)

  [[ -n "$arn" && "$arn" != "None" ]] || \
    die "按端点 ${db_host} 没查到 RDS 主账号密钥，请检查权限或显式设置 MIGRATE_SECRET_ARN"
  printf '%s' "$arn"
}

# 从密钥中取出 username / password，绝不回显 password。
# 注意：这里必须用 `python3 -c` 而不是 heredoc，否则 heredoc 会抢走 stdin，
# 密钥 JSON 就读不到了。
fetch_credentials() {
  local secret_arn=$1 json
  json=$(aws secretsmanager get-secret-value \
    --secret-id "$secret_arn" \
    --region "$AWS_REGION" \
    --query SecretString --output text)

  command -v python3 >/dev/null 2>&1 || die "缺少 python3，用于解析 Secrets Manager 返回的 JSON"

  # 输出两行：第一行 username，第二行 password（仅 stdout，由调用方读取）
  printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception as exc:
    sys.exit("Secrets Manager 返回的不是合法 JSON: %s" % exc)
if "password" not in data:
    sys.exit("密钥里没有 password 字段")
sys.stdout.write(str(data.get("username") or ""))
sys.stdout.write("\n")
sys.stdout.write(str(data["password"]))
'
}

# ---------------------------------------------------------------------------
# 3. 跳板机：确保有实例且 SSM Online
# ---------------------------------------------------------------------------
bastion_instance_id() {
  # shellcheck disable=SC2016  # 反引号是 JMESPath 字面量，不能被 shell 展开
  aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --region "$AWS_REGION" \
    --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
    --output text 2>/dev/null | awk 'NR==1 && $1!="None" {print $1}'
}

wait_for_bastion_online() {
  local deadline=$((SECONDS + BASTION_WAIT_SECONDS)) iid ping
  while (( SECONDS < deadline )); do
    iid=$(bastion_instance_id)
    if [[ -n "$iid" ]]; then
      ping=$(aws ssm describe-instance-information \
        --filters "Key=InstanceIds,Values=${iid}" \
        --region "$AWS_REGION" \
        --query 'InstanceInformationList[0].PingStatus' \
        --output text 2>/dev/null || true)
      if [[ "$ping" == "Online" ]]; then
        printf '%s' "$iid"
        return 0
      fi
    fi
    sleep 5
  done
  return 1
}

ensure_bastion() {
  local iid
  iid=$(bastion_instance_id)

  if [[ -z "$iid" && "$AUTO_SCALE_BASTION" == "1" ]]; then
    initial_desired=$(aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names "$ASG_NAME" \
      --region "$AWS_REGION" \
      --query 'AutoScalingGroups[0].DesiredCapacity' --output text)

    if [[ "$initial_desired" == "0" ]]; then
      log "跳板机 ASG 当前 desired=0，临时拉起到 1（结束后还原）"
      aws autoscaling update-auto-scaling-group \
        --auto-scaling-group-names "$ASG_NAME" \
        --desired-capacity 1 \
        --region "$AWS_REGION" >/dev/null
      bastion_scaled_by_us=1
    fi
  elif [[ -z "$iid" && "$AUTO_SCALE_BASTION" != "1" ]]; then
    die "跳板机没有运行中的实例。先执行：aws autoscaling update-auto-scaling-group --auto-scaling-group-names ${ASG_NAME} --desired-capacity 1"
  fi

  log "等待跳板机 SSM 上线（最长 ${BASTION_WAIT_SECONDS}s）"
  iid=$(wait_for_bastion_online) || \
    die "跳板机 SSM 未在 ${BASTION_WAIT_SECONDS}s 内上线，检查实例角色是否挂了 AmazonSSMManagedInstanceCore"
  printf '%s' "$iid"
}

# ---------------------------------------------------------------------------
# 4. SSM 端口转发
# ---------------------------------------------------------------------------
start_tunnel() {
  local iid=$1 deadline
  session_log=$(mktemp "${TMPDIR:-/tmp}/flyway-tunnel.XXXXXX")

  log "建立端口转发：127.0.0.1:${TUNNEL_LOCAL_PORT} -> ${db_host}:${db_port}（经 ${iid}）"
  aws ssm start-session \
    --target "$iid" \
    --document-name "$SSM_DOCUMENT" \
    --region "$AWS_REGION" \
    --parameters "{\"host\":[\"${db_host}\"],\"portNumber\":[\"${db_port}\"],\"localPortNumber\":[\"${TUNNEL_LOCAL_PORT}\"]}" \
    >"$session_log" 2>&1 &
  session_pid=$!
  tunnel_started=1

  deadline=$((SECONDS + TUNNEL_WAIT_SECONDS))
  while (( SECONDS < deadline )); do
    if tcp_reachable 127.0.0.1 "$TUNNEL_LOCAL_PORT"; then
      session_id=$(sed -n 's/.*SessionId: \([^[:space:]]*\).*/\1/p' "$session_log" | head -n 1)
      log "端口转发已就绪"
      return 0
    fi
    if ! kill -0 "$session_pid" 2>/dev/null; then
      warn "端口转发进程已退出，输出如下："
      cat "$session_log" >&2
      die "SSM 端口转发失败"
    fi
    sleep 2
  done

  warn "端口转发超时，输出如下："
  cat "$session_log" >&2
  die "等待 127.0.0.1:${TUNNEL_LOCAL_PORT} 就绪超时（${TUNNEL_WAIT_SECONDS}s）"
}

# ---------------------------------------------------------------------------
# 5. 组装 flyway 调用
# ---------------------------------------------------------------------------
run_flyway() {
  local -a args=("$@")
  (( ${#args[@]} )) || args=(migrate)

  # Flyway 13 的参数名是 configFiles（复数）；-configFile 会被当成配置项而报错
  local -a cmd=("$FLYWAY_BIN" "-configFiles=${CONFIG_FILE}")

  if [[ "$need_tunnel" == "1" ]]; then
    # 用同一份 flyway.url，只把 host:port 换成本地转发端口，避免重复配置
    export FLYWAY_URL="jdbc:mysql://127.0.0.1:${TUNNEL_LOCAL_PORT}/${db_name}${query_part}"
    log "使用隧道连接：127.0.0.1:${TUNNEL_LOCAL_PORT}/${db_name}"
  fi

  if [[ -n "${FLYWAY_USER:-}" ]]; then
    export FLYWAY_USER
  fi
  if [[ -n "${FLYWAY_PASSWORD:-}" ]]; then
    export FLYWAY_PASSWORD
  fi

  log "执行：flyway ${args[*]}"
  (cd "$REPO_ROOT" && "${cmd[@]}" "${args[@]}")
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  require_cmd aws sed mktemp
  command -v "$FLYWAY_BIN" >/dev/null 2>&1 || die "找不到 flyway（可用 brew install flyway 安装）"

  parse_connection

  # --- 决定是否需要走隧道 ---
  need_tunnel=0
  case "$TUNNEL" in
    on)  need_tunnel=1 ;;
    off) need_tunnel=0 ;;
    auto)
      if tcp_reachable "$db_host" "$db_port"; then
        log "RDS 直连可达，不建立隧道"
      else
        need_tunnel=1
      fi
      ;;
    *) die "TUNNEL 只能是 auto / on / off，当前：$TUNNEL" ;;
  esac

  # --- 取密钥（无论是否隧道都需要，因为口令永远来自 Secrets Manager）---
  local secret_arn creds
  secret_arn=$(resolve_secret_arn)
  log "读取密钥：${secret_arn}"
  creds=$(fetch_credentials "$secret_arn")

  FLYWAY_USER=$(printf '%s\n' "$creds" | sed -n '1p')
  FLYWAY_PASSWORD=$(printf '%s\n' "$creds" | sed -n '2p')
  [[ -n "$FLYWAY_PASSWORD" ]] || die "取到的口令为空"

  # GitHub Actions 不会自动屏蔽 Secrets Manager 的值，这里手动屏蔽口令。
  # 用户名不屏蔽：它本来就写在 flyway.conf 里，屏蔽了反而会把日志里的
  # 所有 "admin" 都替换成 ***，干扰排错。
  if [[ "${GITHUB_ACTIONS:-}" == "true" && -n "$FLYWAY_PASSWORD" ]]; then
    printf '::add-mask::%s\n' "$FLYWAY_PASSWORD"
  fi
  export FLYWAY_USER FLYWAY_PASSWORD

  # --- 建隧道 ---
  if [[ "$need_tunnel" == "1" ]]; then
    local iid
    iid=$(ensure_bastion)
    log "跳板机实例：${iid}"
    start_tunnel "$iid"
  fi

  run_flyway "$@"
}

main "$@"
