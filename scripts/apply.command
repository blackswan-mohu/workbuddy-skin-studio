#!/bin/bash
# Doubao Skin Studio — 自动识别豆包客户端，按需重启并注入皮肤。
#
# 关键设计：本 skill 会分发给用户，由豆包或豆包工作客户端里的 agent 调用。
# 一旦关闭发起调用的客户端，agent 及其 shell 会被一起终止，所以真正的
# 「关闭客户端→带端口重启→注入」必须放进一个脱离当前 session 的
# 独立后台进程（perl fork+setsid 守护化），launcher 派生它后立刻返回。
# 这样即便杀豆包连累了 agent，worker 仍在独立 session 里把皮肤装回来。

set -e

# 绝对路径，保证 worker 再次 exec 自己时不受 cwd 影响
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SELF="$SCRIPT_DIR/apply.command"
source "$SCRIPT_DIR/client-config.command"

WORKER_MODE=0
if [ "$1" = "--worker" ]; then
  WORKER_MODE=1
  shift
  CLIENT="$1"
  shift
else
  CLIENT="$(detect_doubao_client "$ROOT" "$@")"
fi
configure_doubao_client "$CLIENT"

PORT="$DOUBAO_CDP_PORT"
APP="$DOUBAO_APP"
BIN="$DOUBAO_BIN"
LOG="${DOUBAO_SKIN_LOG:-/tmp/doubao-skin-apply-${DOUBAO_CLIENT_ID}.log}"
CDP_LOG="${DOUBAO_SKIN_CDP_LOG:-/tmp/doubao-skin-cdp-${DOUBAO_CLIENT_ID}.log}"

# 定位 node（优先 PATH，其次常见 nvm 目录），取绝对路径给独立 worker 用
find_node() {
  if command -v node >/dev/null 2>&1; then command -v node; return; fi
  for candidate in "$HOME"/.nvm/versions/node/*/bin/node; do
    [ -x "$candidate" ] && { echo "$candidate"; return; }
  done
}
NODE="$(find_node)"

# 候选调试端口：新版豆包的 aha-runtime(承载 Agent 的 node 运行时)会抢占 9333/9334，
# 在这些端口上只暴露 [node] 端点、没有 [page] renderer，导致注入拿不到 target。
# 这里准备一组候选端口，逐个尝试；client 各自偏移，避免两端串用同一端口。
if [ "$DOUBAO_CLIENT_ID" = "work" ]; then
  CANDIDATE_PORTS="${DOUBAO_CDP_PORTS:-9334 9344 9345 9346 9347}"
else
  CANDIDATE_PORTS="${DOUBAO_CDP_PORTS:-9333 9335 9336 9337 9338}"
fi

# 校验某端口上是否有「真正的 renderer page target」（不是 aha-runtime 的 node 端点）。
# 关键：必须同时满足 type=page 且 url 含客户端专属 hint，才算可注入。
port_has_renderer() {
  local p="$1"
  curl -s --max-time 1 "http://127.0.0.1:$p/json/list" 2>/dev/null |
    "$NODE" -e '
      let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
        try{
          const a=JSON.parse(s);
          const hint=process.argv[1];
          const ok=Array.isArray(a)&&a.some(t=>t&&t.type==="page"&&typeof t.url==="string"&&t.url.includes(hint));
          process.exit(ok?0:1);
        }catch(e){process.exit(1);}
      });
    ' "$DOUBAO_RENDERER_HINT" 2>/dev/null
}

cdp_ready() {
  port_has_renderer "$PORT"
}

# ============ worker：真正干活的独立进程 ============
if [ "$WORKER_MODE" = "1" ]; then
  DELAY="${DOUBAO_RESTART_DELAY:-3}"
  echo "[$(date '+%H:%M:%S')] worker 启动，目标：$DOUBAO_CLIENT_NAME，${DELAY}s 后开始换肤"
  sleep "$DELAY"

  # 1) 免重启快速路径：若任一候选端口已暴露 renderer，直接用它注入
  READY_PORT=""
  for cand in $CANDIDATE_PORTS; do
    if port_has_renderer "$cand"; then READY_PORT="$cand"; break; fi
  done

  if [ -n "$READY_PORT" ]; then
    PORT="$READY_PORT"
    echo "CDP 已就绪（端口 $PORT），直接注入，无需重启"
  else
    echo "关闭$DOUBAO_CLIENT_NAME..."
    osascript -e "tell application id \"$DOUBAO_BUNDLE_ID\" to quit" 2>/dev/null || true
    for _ in $(seq 1 10); do pgrep -f "$BIN" >/dev/null 2>&1 || break; sleep 1; done
    pkill -f "$BIN" 2>/dev/null || true
    sleep 2

    # 2) 逐个候选端口尝试：带该端口重启→等出现真正的 page renderer→锁定
    #    新版 aha-runtime 会占用 9333/9334 只暴露 node 端点，遇到就换下一个干净端口。
    PORT=""
    for cand in $CANDIDATE_PORTS; do
      echo "带调试端口重启$DOUBAO_CLIENT_NAME（尝试端口 $cand）..."
      nohup "$BIN" --remote-debugging-address=127.0.0.1 --remote-debugging-port="$cand" \
        >"$CDP_LOG" 2>&1 </dev/null &
      disown
      echo "等待端口 $cand 出现 renderer..."
      for i in $(seq 1 20); do
        if port_has_renderer "$cand"; then PORT="$cand"; break; fi
        sleep 1
      done
      if [ -n "$PORT" ]; then
        echo "renderer 就绪（端口 $PORT）"
        break
      fi
      echo "端口 $cand 未出现 renderer（可能被 aha-runtime 占用），换下一个..."
      pkill -f "$BIN" 2>/dev/null || true
      sleep 2
    done

    if [ -z "$PORT" ]; then
      echo "[$(date '+%H:%M:%S')] 所有候选端口均未拿到 renderer，换肤失败。候选：$CANDIDATE_PORTS" >&2
      exit 1
    fi
  fi

  echo "注入皮肤..."
  "$NODE" "$ROOT/src/cli.mjs" apply --client "$DOUBAO_CLIENT_ID" --port "$PORT" "$@"
  echo "[$(date '+%H:%M:%S')] 换肤完成"
  exit 0
fi

# ============ launcher：派生独立 worker 后立刻返回 ============
[ -d "$APP" ] || { echo "未找到$DOUBAO_CLIENT_NAME（应在 $APP）" >&2; exit 1; }
[ -x "$BIN" ] || { echo "未找到$DOUBAO_CLIENT_NAME主程序：$BIN" >&2; exit 1; }
[ -n "$NODE" ] || { echo "未找到 node，请先安装 Node.js 18+" >&2; exit 1; }

echo "已识别调用客户端：$DOUBAO_CLIENT_NAME"
echo "即将自动重启$DOUBAO_CLIENT_NAME并加载皮肤，约几秒后完成（应用会短暂关闭再打开）。"
echo "请先保存$DOUBAO_CLIENT_NAME里未保存的内容。"

# perl fork+setsid：把 worker 送进全新 session，脱离当前 agent/shell 的进程组，
# 这样稍后 kill 豆包连累了 agent 也波及不到 worker。macOS 无 setsid 命令，用 perl。
DOUBAO_RESTART_DELAY="${DOUBAO_RESTART_DELAY:-3}" \
  nohup perl -e 'use POSIX qw(setsid); exit if fork; setsid; exec @ARGV;' \
    bash "$SELF" --worker "$DOUBAO_CLIENT_ID" "$@" >"$LOG" 2>&1 </dev/null &
disown

echo "已在后台开始换肤。$DOUBAO_CLIENT_NAME重启后右上角会出现 🎨 按钮。"
echo "如需排查，请查看 $LOG。"
exit 0
