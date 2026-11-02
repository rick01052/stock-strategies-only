#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# stock-strategies-only — Termux Optimized Startup v2
# ============================================================
# Usage:
#   ./start.sh doctor       # 驗證環境 (預設指令)
#   ./start.sh backend      # 啟動 FastAPI  (port 8000, foreground)
#   ./start.sh backend-bg    # 啟動 FastAPI (背景, gateway 用, 不需 redirect)
#   ./start.sh frontend     # 啟動 Next.js  (port 3000)
#   ./start.sh both         # 雙服務：背景 backend + 前景 frontend
#   ./start.sh build        # 前端量產建置 (web/.next/)
#   ./start.sh test         # 後端 + 前端測試
#   ./start.sh stop         # 停止所有服務
#   ./start.sh smoke        # 端到端冒煙測試
#   ./start.sh setup         # 確保目錄存在 (gateway 用)
#
# 覆寫埠號：BACKEND_PORT=8080 FRONTEND_PORT=3080 ./start.sh both
# ============================================================

# Create log directory FIRST — before set -e, so tee pipelines never fail
LOG_DIR="${HOME}/.hermes/cache/scratch/sso-logs"
mkdir -p "${LOG_DIR}" 2>/dev/null || true

set -euo pipefail

SSO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PY="/data/data/com.termux/files/usr/lib/hermes-agent/venv/bin/python"
SYS_SITE="/data/data/com.termux/files/usr/lib/python3.14/site-packages"
HERMES_ENV="$HOME/.hermes/.env"
BACKEND_PORT="${BACKEND_PORT:-8000}"
FRONTEND_PORT="${FRONTEND_PORT:-3000}"

export PYTHONPATH="${SYS_SITE}:${SSO_DIR}:${PYTHONPATH:-}"
cd "$SSO_DIR"

# ---------- Env loading (with mapping from Hermes .env) ----------
load_env() {
  # Prefer .env in repo
  if [[ -f "$SSO_DIR/.env" ]]; then
    set -a
    source "$SSO_DIR/.env"
    set +a
  fi

  # Fallback: pull from Hermes .env for missing values (with name mapping)
  if [[ -f "$HERMES_ENV" ]]; then
    _fill() {
      local name="$1" src_key="$2"
      if [[ -z "${!name:-}" ]]; then
        local val
        val=$(grep -E "^${src_key}=" "$HERMES_ENV" | head -1 | cut -d= -f2- || true)
        if [[ -n "${val:-}" ]]; then
          export "$name=$val"
        fi
      fi
    }
    _fill FINMIND_TOKEN     FINMIND_API_TOKEN
    _fill TELEGRAM_BOT_TOKEN TELEGRAM_BOT_TOKEN
    _fill TELEGRAM_CHAT_ID  TELEGRAM_HOME_CHANNEL
    _fill GOOGLE_SHEET_ID   GOOGLE_SHEET_ID
    _fill GEMINI_API_KEY    GEMINI_API_KEY
    _fill GOOGLE_CREDS_JSON GOOGLE_CREDS_JSON
  fi

  # Force a modern Gemini model to avoid "no longer available to new users"
  export GEMINI_MODEL="${GEMINI_MODEL:-gemini-3.8-flash}"

  # Only export non-empty vars (GOOGLE_CREDS_JSON may be absent)
  local _out=""
  for _v in FINMIND_TOKEN TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID GOOGLE_SHEET_ID GEMINI_API_KEY; do
    [[ -n "${!_v:-}" ]] && _out+="$_v "
  done
  [[ -n "${GOOGLE_CREDS_JSON:-}" ]] && _out+="GOOGLE_CREDS_JSON"
  export $_out GEMINI_MODEL
}

# ---------- Commands ----------
cmd_doctor() {
  load_env
  echo "═══════════════════════════════════════════════════"
  echo "  ENVIRONMENT DOCTOR — stock-strategies-only"
  echo "═══════════════════════════════════════════════════"

  echo -e "\n[1/8] Python runtime"
  "$VENV_PY" --version
  echo "  PYTHONPATH: $PYTHONPATH"

  echo -e "\n[2/8] Env vars"
  for k in FINMIND_TOKEN TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID GOOGLE_SHEET_ID GOOGLE_CREDS_JSON GEMINI_API_KEY; do
    v="${!k:-}"
    if [[ -n "$v" ]]; then
      printf "  ✅ %-22s (len=%d)\n" "$k" "${#v}"
    else
      printf "  ⚠️  %-22s (empty — Google Sheet 功能停用)\n" "$k"
    fi
  done

  echo -e "\n[3/8] Python deps"
  "$VENV_PY" -c "
import numpy, pandas, pyarrow, fastapi, uvicorn, pydantic, requests
import gspread, google.auth, httpx
for m in (numpy, pandas, pyarrow, fastapi, uvicorn, pydantic, requests, gspread, google.auth, httpx):
    print(f'  ✅ {m.__name__:22s} {m.__version__}')
"

  echo -e "\n[4/8] Node runtime"
  node --version
  echo "  node_modules: $([[ -d web/node_modules ]] && echo ✅ || echo ❌)"

  echo -e "\n[5/8] Core modules"
  "$VENV_PY" -c "
import sys; sys.path.insert(0, '$SSO_DIR')
from stock_strategies import indicators, evaluate, data, backtest, datasources, config, cache, sheet, notify
print('  ✅ all 9 modules importable')
from api.main import app
print(f'  ✅ FastAPI app: {len([r for r in app.routes if hasattr(r, \"methods\")])} routes')
"

  echo -e "\n[6/8] GitHub Actions (if GITHUB_TOKEN available)"
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    "$VENV_PY" -c "
import urllib.request, json, os
req = urllib.request.Request(
    'https://api.github.com/repos/rick01052/stock-strategies-only/actions/runs?per_page=4',
    headers={'Authorization': 'Bearer ' + os.environ['GITHUB_TOKEN']})
with urllib.request.urlopen(req, timeout=10) as r:
    data = json.loads(r.read())
for run in data.get('workflow_runs', []):
    icon = '✅' if run['conclusion'] == 'success' else '❌'
    print(f'  {icon} {run[\"name\"]:30s} {run[\"conclusion\"]}')
" || echo "  ⚠️ GitHub API call failed (token may lack Actions permission)"
  fi

  echo -e "\n[7/8] Tests (backend only — 5s)"
  "$VENV_PY" -m pytest tests/ -q --tb=line 2>&1 | tail -3 | sed 's/^/  /'

  echo -e "\n[8/8] Summary"
  echo "  Backend:  $VENV_PY -m uvicorn api.main:app --host 0.0.0.0 --port 8000"
  echo "  Frontend: node web/node_modules/.bin/next dev"
  echo "═══════════════════════════════════════════════════"
}

cmd_backend() {
  load_env
  echo "→ FastAPI on http://127.0.0.1:${BACKEND_PORT}  (docs: /docs)"
  exec "$VENV_PY" -m uvicorn api.main:app --host 127.0.0.1 --port "$BACKEND_PORT"
}

cmd_backend_bg() {
  # Background mode for gateway: handles logging internally, no shell redirect needed
  load_env
  local BE_LOG="${LOG_DIR}/backend.log"
  echo "→ FastAPI (bg) on http://127.0.0.1:${BACKEND_PORT}  log: $BE_LOG"
  "$VENV_PY" -m uvicorn api.main:app --host 127.0.0.1 --port "$BACKEND_PORT" \
    >"$BE_LOG" 2>&1 &
  local BE_PID=$!
  echo "  Backend PID: $BE_PID"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    sleep 1
    if curl -sf --max-time 2 "http://127.0.0.1:${BACKEND_PORT}/api/health" >/dev/null 2>&1; then
      echo "  ✅ backend ready"
      break
    fi
    if ! kill -0 "$BE_PID" 2>/dev/null; then
      echo "  ❌ backend crashed. Log:"
      tail -20 "$BE_LOG"
      exit 1
    fi
  done
}

cmd_frontend() {
  load_env
  echo "→ Next.js on http://127.0.0.1:${FRONTEND_PORT}"
  echo "  (bypass npm symlink issue: node node_modules/.bin/next)"
  cd web
  NEXT_PUBLIC_API_BASE="http://127.0.0.1:${BACKEND_PORT}" \
    exec node node_modules/.bin/next dev -p "$FRONTEND_PORT"
}

cmd_frontend_bg() {
  # Background mode for gateway: handles logging internally
  load_env
  local FE_LOG="${LOG_DIR}/frontend.log"
  echo "→ Next.js (bg) on http://127.0.0.1:${FRONTEND_PORT}  log: $FE_LOG"
  cd web
  NEXT_PUBLIC_API_BASE="http://127.0.0.1:${BACKEND_PORT}" \
    node node_modules/.bin/next dev -p "$FRONTEND_PORT" >"$FE_LOG" 2>&1 &
  local FE_PID=$!
  echo "  Frontend PID: $FE_PID"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    sleep 1
    if curl -sf --max-time 2 "http://127.0.0.1:${FRONTEND_PORT}/" >/dev/null 2>&1; then
      echo "  ✅ frontend ready"
      break
    fi
    if ! kill -0 "$FE_PID" 2>/dev/null; then
      echo "  ❌ frontend crashed. Log:"
      tail -20 "$FE_LOG"
      exit 1
    fi
  done
}

cmd_both() {
  load_env
  local BE_LOG="$LOG_DIR/backend.log" FE_LOG="$LOG_DIR/frontend.log"
  echo "→ Backend (bg) :$BACKEND_PORT  log: $BE_LOG"
  "$VENV_PY" -m uvicorn api.main:app --host 127.0.0.1 --port "$BACKEND_PORT" \
    >"$BE_LOG" 2>&1 &
  local BE_PID=$!
  echo "  Backend PID: $BE_PID"
  local ready=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    sleep 1
    if curl -sf --max-time 2 "http://127.0.0.1:$BACKEND_PORT/api/health" >/dev/null 2>&1; then
      ready=1; break
    fi
    if ! kill -0 "$BE_PID" 2>/dev/null; then break; fi
  done
  if [[ "$ready" != 1 ]]; then
    echo "  ❌ backend not ready. last log lines:"; tail -30 "$BE_LOG"
    kill "$BE_PID" 2>/dev/null || true; exit 1
  fi
  echo "  ✅ backend ready: $(curl -s --max-time 3 http://127.0.0.1:$BACKEND_PORT/api/health)"
  echo "→ Frontend (fg) :$FRONTEND_PORT  log: $FE_LOG"
  echo "  open http://127.0.0.1:$FRONTEND_PORT  (Ctrl+C stops both)"
  cd web
  NEXT_PUBLIC_API_BASE="http://127.0.0.1:$BACKEND_PORT" \
    node node_modules/.bin/next dev -p "$FRONTEND_PORT" 2>&1 | tee "$FE_LOG" &
  local FE_PID=$!
  trap 'echo; echo "→ stopping both"; kill '"$BE_PID"' $FE_PID 2>/dev/null || true; pkill -f "uvicorn api.main:app" 2>/dev/null || true; pkill -f "next dev" 2>/dev/null || true' EXIT INT TERM
  wait "$FE_PID"
}

cmd_stop() {
  pkill -TERM -f "uvicorn api.main:app" 2>/dev/null || true
  pkill -TERM -f "node node_modules/.bin/next dev" 2>/dev/null || true
  pkill -TERM -f "next-server" 2>/dev/null || true
  pkill -TERM -f "detached-flush" 2>/dev/null || true
  sleep 2
  pkill -KILL -f "uvicorn api.main:app" 2>/dev/null || true
  pkill -KILL -f "node node_modules/.bin/next" 2>/dev/null || true
  pkill -KILL -f "next-server" 2>/dev/null || true
  echo "✅ stopped"
  pgrep -af "uvicorn api.main|next dev" || true
}

cmd_smoke() {
  load_env
  local B="http://127.0.0.1:$BACKEND_PORT" F="http://127.0.0.1:$FRONTEND_PORT"
  echo "═══ E2E smoke — backend :$BACKEND_PORT  frontend :$FRONTEND_PORT ═══"
  _probe() {
    local label="$1" url="$2"
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$url" 2>/dev/null || echo ERR)
    printf "  %s  %-30s %s\n" "$([[ "$code" == 2* ]] && echo ✅ || echo ❌)" "$label" "HTTP $code"
  }
  _probe "backend /api/health"     "$B/api/health"
  _probe "proxy  /api/health"      "$F/api/health"
  _probe "backend /api/strategies" "$B/api/strategies"
  _probe "dynamic /strategies/default" "$F/strategies/default"
  _probe "dynamic /strategies/conservative" "$F/strategies/conservative"
  echo -n "  📊 FinMind market: "
  curl -s --max-time 30 "$B/api/market" | head -c 120; echo
  echo -n "  🧠 Gemini ($GEMINI_MODEL): "
  curl -s --max-time 90 -X POST "$B/api/strategies/generate" \
    -H 'Content-Type: application/json' \
    -d '{"prompt":"動量突破：均線上且量能放大"}' | head -c 120; echo
}

cmd_build() {
  load_env
  echo "→ Production build of frontend"
  cd web
  node node_modules/.bin/next build
  echo "✅ Build output: web/.next/"
}

cmd_test() {
  load_env
  echo "→ Backend tests (pytest)"
  "$VENV_PY" -m pytest tests/ -q --tb=line 2>&1 | tail -5
  echo
  echo "→ Frontend tests (vitest)"
  cd web
  node node_modules/.bin/vitest run 2>&1 | tail -8
}


cmd_setup() {
  echo "→ Ensuring log directory exists"
  mkdir -p "$LOG_DIR"
  echo "  ✅ $LOG_DIR"
  echo "→ Ensuring scratch dir exists"
  mkdir -p "$HOME/.hermes/cache/scratch"
  echo "  ✅ scratch ready"
  echo "→ Ensuring web/node_modules exists"
  if [[ ! -d web/node_modules ]]; then
    echo "  ⚠️ web/node_modules missing — run 'start.sh build' first"
  else
    echo "  ✅ web/node_modules present"
  fi
}

# ---------- Dispatch ----------
case "${1:-doctor}" in
  doctor)     cmd_doctor ;;
  backend)    cmd_backend ;;
  backend-bg) cmd_backend_bg ;;
  frontend)   cmd_frontend ;;
  frontend-bg) cmd_frontend_bg ;;
  both)       cmd_both ;;
  build)      cmd_build ;;
  test)       cmd_test ;;
  stop)       cmd_stop ;;
  smoke)      cmd_smoke ;;
  setup)      cmd_setup ;;
  *)          echo "Usage: $0 {doctor|backend|backend-bg|frontend|both|build|test|stop|smoke|setup}"; exit 1 ;;
esac
