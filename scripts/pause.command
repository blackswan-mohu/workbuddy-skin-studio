#!/bin/bash
# Doubao Skin Studio — 暂停皮肤，恢复原生界面（不重启客户端）
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/client-config.command"

CLIENT="$(detect_doubao_client "$ROOT" "$@")"
configure_doubao_client "$CLIENT"
PORT="$DOUBAO_CDP_PORT"

NODE=""
if command -v node >/dev/null 2>&1; then
  NODE="$(command -v node)"
else
  for candidate in "$HOME"/.nvm/versions/node/*/bin/node; do
    if [ -x "$candidate" ]; then NODE="$candidate"; break; fi
  done
fi
[ -z "$NODE" ] && { echo "未找到 node，请先安装 Node.js 18+" >&2; exit 1; }

# 皮肤可能被注入在非默认端口（新版 aha-runtime 占用 9333/9334 时 apply 会自动换端口）。
# 这里遍历候选端口，挑一个真正暴露 renderer 的端口来还原；找不到就退回默认端口。
if [ "$DOUBAO_CLIENT_ID" = "work" ]; then
  CANDIDATE_PORTS="${DOUBAO_CDP_PORTS:-9334 9344 9345 9346 9347}"
else
  CANDIDATE_PORTS="${DOUBAO_CDP_PORTS:-9333 9335 9336 9337 9338}"
fi
for cand in $CANDIDATE_PORTS; do
  if curl -s --max-time 1 "http://127.0.0.1:$cand/json/list" 2>/dev/null |
       "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const a=JSON.parse(s);const h=process.argv[1];process.exit(Array.isArray(a)&&a.some(t=>t&&t.type==="page"&&typeof t.url==="string"&&t.url.includes(h))?0:1)}catch(e){process.exit(1)}})' "$DOUBAO_RENDERER_HINT" 2>/dev/null; then
    PORT="$cand"; break
  fi
done

echo "已识别调用客户端：$DOUBAO_CLIENT_NAME"
exec "$NODE" "$ROOT/src/cli.mjs" pause --client "$DOUBAO_CLIENT_ID" --port "$PORT" "$@"
