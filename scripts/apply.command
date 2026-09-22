#!/bin/bash
# Doubao Skin Studio — 自动识别豆包客户端，按需重启并注入皮肤。
#
# 关键设计：本 skill 会分发给用户，由豆包或豆包工作客户端里的 agent 调用。
# 「关闭客户端→带调试端口重启→注入」放进一个后台 worker，launcher 派生它后立刻返回。
#
# 为什么 worker 不脱离会话（不用 setsid）：macOS 的 GUI app 必须在用户会话（Aqua）
# 上下文里才能被 `open` 正常拉起。若把 worker setsid 到独立 session，`open -na` 会
# 「返回 0 但豆包实际不启动」（直接执行二进制在独立 session 里同样起不来 renderer）。
# 所以 worker 留在会话内，用 `open -na` 启动带调试端口的豆包——豆包由 launchd 托管，
# 一旦拉起就独立于 worker，worker 即便被连累退出，豆包与已注入皮肤都不受影响。

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
    #    启动方式用 `open -na`（走 LaunchServices），而非直接执行二进制：实测前者
    #    ~2s 就能初始化出可注入的 GUI renderer，后者要 ~9s 且更易在竞争窗口里超时。
    #    注意：`open -na` 有单实例拦截——必须先彻底退出豆包（上面已 quit+pkill）才生效。
    PORT=""
    for cand in $CANDIDATE_PORTS; do
      echo "带调试端口重启$DOUBAO_CLIENT_NAME（尝试端口 $cand）..."
      open -na "$APP" --args --remote-debugging-address=127.0.0.1 --remote-debugging-port="$cand" \
        >"$CDP_LOG" 2>&1 || true
      echo "等待端口 $cand 出现 renderer..."
      for i in $(seq 1 25); do
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

# 通过独立 Terminal 派生 worker，launcher 立即返回。
# 为什么用 Terminal 而不是 nohup/setsid：换肤要同时满足两个约束——
#   (1) worker 必须存活：关豆包会连累发起命令的 agent 及其子进程；
#   (2) worker 必须能启动 GUI 豆包：macOS 下 `open` 只在用户会话（Aqua）上下文里有效。
# nohup 的子进程仍在 agent 进程树内（关豆包被连累）；setsid 脱离了会话（GUI 起不来）——
# 两者互斥。而 Terminal.app 既不在 agent 进程树内、本身又是有完整会话上下文的 GUI 应用，
# 一举满足两个约束：worker 在 Terminal 里独立存活，且能正常 `open` 拉起带调试端口的豆包。
# 注：首次会弹一次「豆包想控制 Terminal」的自动化授权，允许一次即可。
BOOT="/tmp/doubao-skin-boot-${DOUBAO_CLIENT_ID}.sh"
{
  echo '#!/bin/bash'
  echo "export DOUBAO_RESTART_DELAY=${DOUBAO_RESTART_DELAY:-3}"
  # 用 %q 逐个转义参数，安全承载 worker 命令与透传的 --theme 等参数
  printf 'bash %q --worker %q' "$SELF" "$DOUBAO_CLIENT_ID"
  for arg in "$@"; do printf ' %q' "$arg"; done
  printf ' >%q 2>&1\n' "$LOG"
  # 跑完自动关掉这个临时 Terminal 窗口，不打扰用户
  echo 'osascript -e "tell application \"Terminal\" to close (every window whose name contains \"doubao-skin-boot\")" >/dev/null 2>&1 || true'
} > "$BOOT"
chmod +x "$BOOT"

if osascript -e "tell application \"Terminal\" to do script \"bash '$BOOT'\"" >/dev/null 2>&1; then
  : # 已在独立 Terminal 中启动 worker
else
  # 极端兜底：Terminal 不可用（如无 GUI）时退回 nohup（可能遇到上述约束冲突，仅作最后手段）
  echo "（Terminal 不可用，退回后台方式）" >&2
  DOUBAO_RESTART_DELAY="${DOUBAO_RESTART_DELAY:-3}" \
    nohup bash "$SELF" --worker "$DOUBAO_CLIENT_ID" "$@" >"$LOG" 2>&1 </dev/null &
  disown
fi

echo "已在后台开始换肤。$DOUBAO_CLIENT_NAME重启后右上角会出现 🎨 按钮。"
echo "如需排查，请查看 $LOG。"
exit 0
