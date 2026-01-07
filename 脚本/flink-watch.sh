#!/usr/bin/env bash
# flink-watch.sh - Simple watchdog for Flink (health check, restart, logging)
#
# Purpose:
#   1) 定期对 Flink 服务做健康检查（HTTP 或进程存在性）。
#   2) 在连续多次健康检查失败时，自动尝试重启服务并记录日志。
#   3) 提供手动 start/stop/status 操作以便运维调用或与 launchd/systemd 集成。
#
# Safety notes:
# - 请编辑顶部配置区域（START_CMD, RUN_AS, HEALTH_URL, LOG_FILE...）以适配你的环境。
# - 启动命令应是幂等或具有良好重启行为。若需要优雅停止，请在 STOP 操作或 stop script 中实现。
# - 脚本可通过 launchd/systemd 以循环模式（--loop）或周期运行，建议将其作为守护进程由系统管理。
#
# Examples:
#   ./flink-watch.sh --loop
#   ./flink-watch.sh --once
#   ./flink-watch.sh start|stop|status
#
# Notes:
# - START_CMD should be the command used to (re)start Flink (e.g. /opt/flink/bin/start-cluster.sh)
# - If RUN_AS is set, the script will attempt to run START_CMD as that user using sudo -u
# - HEALTH_URL can be a JobManager REST/overview URL (e.g. http://localhost:8081/overview). If unset, the script falls back to checking the pid file / process existence.
# - LOG_FILE defaults to ~/logs/flink-watch.log

set -o pipefail
set -e

# -------------------- CONFIG (modify as needed) --------------------
# START_CMD: command or script to start Flink (must be idempotent / safe to call repeatedly)
#   e.g. "/opt/flink/bin/start-cluster.sh" or "/usr/local/bin/start-flink.sh"
# RUN_AS:  user to run the START_CMD as; if empty, uses current user (will attempt sudo -u if set)
# HEALTH_URL: URL to check for service health (HTTP 200 expected). If empty, script falls back to process check.
#   Example: http://localhost:8081/overview
# HEALTH_TIMEOUT: timeout (seconds) for health HTTP checks
# HEALTH_RETRY_THRESHOLD: consecutive failed health checks before triggering restart
# RESTART_INTERVAL: wait time (seconds) after a restart before next health check
# MAX_RESTARTS: 0 for unlimited, otherwise maximum restart attempts before exiting
# LOG_FILE: path where script writes logs
# PIDFILE: optional pid file for bookkeeping; to write to /var/run may require sudo
# LOOP_SLEEP: seconds to sleep between checks when running in loop mode
START_CMD=""                 # e.g. "/opt/flink/bin/start-cluster.sh"
RUN_AS=""                    # e.g. flink (empty = current user)
HEALTH_URL=""                # e.g. http://localhost:8081/overview
HEALTH_TIMEOUT=5
HEALTH_RETRY_THRESHOLD=3
RESTART_INTERVAL=30
MAX_RESTARTS=0
LOG_FILE="${HOME}/logs/flink-watch.log"
PIDFILE="/var/run/flink-watch.pid"
LOOP_SLEEP=30

# -------------------- helpers --------------------
log() {
  local msg="$*"
  mkdir -p "$(dirname "$LOG_FILE")" || true
  echo "[$(date '+%F %T')] $msg" >> "$LOG_FILE"
}

get_pid() {
  # 首先优先使用 PIDFILE（如果存在且对应进程仍然在运行，则返回该 PID）
  if [ -f "$PIDFILE" ]; then
    local p
    p=$(cat "$PIDFILE" 2>/dev/null || true)
    if [ -n "$p" ] && ps -p "$p" >/dev/null 2>&1; then
      echo "$p"
      return 0
    fi
  fi
  # 然后作为回退，尝试根据 Flink 的 Java 主类查找进程（更通用）
  # 注意：pgrep 可能匹配到多个进程，这里只取第一个。
  p=$(pgrep -f "org.apache.flink.runtime" | head -n1 || true)
  if [ -n "$p" ]; then
    echo "$p"
    return 0
  fi
  return 1
}

is_healthy() {
  # 健康检查策略：优先 HTTP 检查（若配置 HEALTH_URL），若不可用则退回到进程存在性检查
  if [ -n "$HEALTH_URL" ]; then
    if command -v curl >/dev/null 2>&1; then
      local code
      # 使用 curl 获取 HTTP 状态码，200 视为健康
      code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$HEALTH_TIMEOUT" "$HEALTH_URL" || echo "000")
      [ "$code" = "200" ] && return 0 || return 1
    else
      # 若系统没有 curl，尝试使用 nc 做简单 TCP 端口探测（需要解析 URL）
      if command -v nc >/dev/null 2>&1; then
        nc -z -w $HEALTH_TIMEOUT $(echo "$HEALTH_URL" | sed -E 's#^[a-z]+://([^:/]+):?([0-9]*).*#\1 \2#' ) >/dev/null 2>&1 && return 0 || return 1
      fi
      # 无法执行有效 HTTP 或 TCP 检查，则认为不健康
      return 1
    fi
  else
    # fallback to process check: 只要主进程在运行则视为健康
    get_pid >/dev/null 2>&1 || return 1
    return 0
  fi
}

start_service() {
  # 启动服务：以指定用户（如果配置）或当前用户运行 START_CMD
  if [ -z "$START_CMD" ]; then
    log "START_CMD is empty; cannot start service"
    return 1
  fi

  log "Starting Flink service (cmd: $START_CMD)"
  # Run as specific user if requested
  if [ -n "$RUN_AS" ]; then
    if command -v sudo >/dev/null 2>&1; then
      # 使用 sudo -u 以目标用户身份执行，后台运行并记录 PID
      sudo -u "$RUN_AS" nohup bash -lc "$START_CMD" >> "$LOG_FILE" 2>&1 &
      echo $! > "$PIDFILE" 2>/dev/null || true
    else
      log "sudo not found; attempting to run as current user"
      nohup bash -lc "$START_CMD" >> "$LOG_FILE" 2>&1 &
      echo $! > "$PIDFILE" 2>/dev/null || true
    fi
  else
    nohup bash -lc "$START_CMD" >> "$LOG_FILE" 2>&1 &
    echo $! > "$PIDFILE" 2>/dev/null || true
  fi

  # 等待短暂时间以便进程出生并可被 get_pid 检测到
  sleep 2
  local p
  p=$(get_pid || true)
  log "Start invoked, pid: ${p:-unknown}"
  return 0
}

stop_service() {
  local p
  p=$(cat "$PIDFILE" 2>/dev/null || true)
  if [ -n "$p" ] && ps -p "$p" >/dev/null 2>&1; then
    log "Stopping service pid $p"
    kill "$p" || true
    sleep 2
    if ps -p "$p" >/dev/null 2>&1; then
      log "PID $p did not exit, sending SIGKILL"
      kill -9 "$p" || true
    fi
    rm -f "$PIDFILE" || true
    return 0
  fi
  # fallback: try pgrep for flink
  p=$(pgrep -f "org.apache.flink.runtime" | xargs || true)
  if [ -n "$p" ]; then
    log "Stopping flink processes: $p"
    kill $p || true
    sleep 2
    return 0
  fi
  log "No running Flink process found"
  return 1
}

status_service() {
  local p
  p=$(get_pid 2>/dev/null || true)
  if [ -n "$p" ]; then
    echo "Flink seems running (pid: $p)"
    return 0
  fi
  echo "Flink is not running"
  return 1
}

watch_once() {
  if is_healthy; then
    log "Health check OK"
    return 0
  fi
  log "Health check FAILED"
  start_service
  sleep $RESTART_INTERVAL
}

watch_loop() {
  # 循环监控逻辑：统计连续失败次数，达到阈值则触发重启并计数重启次数。
  # 重要变量说明：
  #  - HEALTH_RETRY_THRESHOLD: 连续健康检查失败达到该值触发重启
  #  - RESTART_INTERVAL: 重启后等待的间隔时间（秒）
  #  - MAX_RESTARTS: 最大重启次数（0 表示无限制）
  local failures=0
  local restarts=0
  log "Entering watch loop (interval ${LOOP_SLEEP}s)"
  while true; do
    if is_healthy; then
      if [ "$failures" -gt 0 ]; then
        log "Health recovered"
      fi
      failures=0
    else
      failures=$((failures+1))
      log "Health check failed (consecutive=$failures)"
    fi

    if [ "$failures" -ge "$HEALTH_RETRY_THRESHOLD" ]; then
      log "Threshold reached ($HEALTH_RETRY_THRESHOLD), restarting service"
      # 尝试优雅停止并重新启动
      stop_service || true
      start_service || true
      restarts=$((restarts+1))
      log "Restarted (count=$restarts)"
      # 重置失败计数
      failures=0
      # 如果达到最大重启次数则退出循环（可用于防止疯狂重启）
      if [ "$MAX_RESTARTS" -gt 0 ] && [ "$restarts" -ge "$MAX_RESTARTS" ]; then
        log "Max restarts reached ($MAX_RESTARTS), exiting"
        break
      fi
      # 重启后等待一段时间再继续检查
      sleep $RESTART_INTERVAL
    fi
    sleep $LOOP_SLEEP
  done
}

print_help() {
  cat <<EOF
Usage: $0 [--once|--loop|start|stop|status|--help]
  --once    : run one health check and restart if needed
  --loop    : run continuously (recommended via launchd/systemd)
  start     : start service via START_CMD
  stop      : stop service (by pidfile or pgrep)
  status    : print status
  --help    : show this help

Configuration: edit variables at top of this script (START_CMD, RUN_AS, HEALTH_URL, LOG_FILE...)
EOF
}

# -------------------- CLI --------------------
case "$1" in
  --once)
    watch_once
    ;;
  --loop)
    watch_loop
    ;;
  start)
    start_service
    ;;
  stop)
    stop_service
    ;;
  status)
    status_service
    ;;
  --help|help|-h|"")
    print_help
    ;;
  *)
    print_help
    exit 2
    ;;
esac

exit 0
