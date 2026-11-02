#!/data/data/com.termux/files/usr/bin/bash
# Stop all backend/frontend
pkill -TERM -f 'uvicorn api.main:app' 2>/dev/null || true
pkill -TERM -f 'node.*next dev' 2>/dev/null || true
pkill -TERM -f 'node.*next-server' 2>/dev/null || true
pkill -TERM -f 'node.*telemetry/detached-flush' 2>/dev/null || true
sleep 2
# Force kill any leftovers
pkill -KILL -f 'uvicorn api.main:app' 2>/dev/null || true
pkill -KILL -f 'node.*next' 2>/dev/null || true
echo "✅ stopped"
