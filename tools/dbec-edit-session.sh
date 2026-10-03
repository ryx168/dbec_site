#!/bin/bash
# Self-contained editing session for diamondbarevergreen.com - no VPS, no
# tunnel key to install anywhere. filebrowser serves the cloned site content
# with a web UI (upload, inline edit, delete - the same kind of interface as
# the old aaPanel File Manager); cloudflared's quick-tunnel mode (--url, no
# account/zone needed) publishes it at a random *.trycloudflare.com URL that
# this script prints to the run log. Edits are auto-committed and pushed back
# to this repo on a timer and at session end, which Cloudflare Pages then
# deploys automatically once this repo is connected to the Pages project.
set -uo pipefail
cd "${GITHUB_WORKSPACE:-$PWD}"

echo "::group::Install filebrowser + cloudflared"
curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash
curl -fsSL -o /tmp/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x /tmp/cloudflared
if ! command -v filebrowser >/dev/null 2>&1; then
  echo "  filebrowser installer did not put it on PATH - checking common locations"
  for p in /usr/local/bin/filebrowser ./filebrowser "$HOME/filebrowser"; do
    if [ -x "$p" ]; then echo "  found at $p"; sudo ln -sf "$(realpath "$p")" /usr/local/bin/filebrowser; break; fi
  done
fi
command -v filebrowser || { echo "  FATAL: filebrowser still not found after install"; exit 1; }
echo "::endgroup::"

echo "::group::Start filebrowser"
filebrowser config init --root "$GITHUB_WORKSPACE" >/tmp/fb-init.log 2>&1
filebrowser users add "$FB_USER" "$FB_PASS" --perm.admin >/tmp/fb-user.log 2>&1
filebrowser -a 127.0.0.1 -p 8080 --root "$GITHUB_WORKSPACE" >/tmp/filebrowser.log 2>&1 &
FB_PID=$!
sleep 2
if kill -0 "$FB_PID" 2>/dev/null; then
  echo "  filebrowser started (pid $FB_PID), listening on 127.0.0.1:8080"
else
  echo "  FAILED TO START - dumping log:"; cat /tmp/filebrowser.log
  exit 1
fi
echo "::endgroup::"

echo "::group::Start Cloudflare quick tunnel"
/tmp/cloudflared tunnel --url http://127.0.0.1:8080 --no-autoupdate >/tmp/cloudflared.log 2>&1 &
TUNNEL_PID=$!
TUNNEL_URL=""
for i in $(seq 1 20); do
  sleep 2
  TUNNEL_URL=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' /tmp/cloudflared.log | head -1 || true)
  [ -n "$TUNNEL_URL" ] && break
  echo "  [${i}] waiting for tunnel URL..."
done
if [ -z "$TUNNEL_URL" ]; then
  echo "  FAILED TO GET TUNNEL URL - dumping log:"; cat /tmp/cloudflared.log
  exit 1
fi
echo ""
echo "=========================================================="
echo "  EDIT SESSION READY"
echo "  URL:      $TUNNEL_URL"
echo "  username: $FB_USER"
echo "  password: (the one you set when triggering this run)"
echo "=========================================================="
echo ""
echo "::endgroup::"

git config user.email "superesolutions@gmail.com"
git config user.name "dbec on-demand editor"

push_changes() {
  if ! git diff --quiet || [ -n "$(git status --porcelain)" ]; then
    git add -A
    git commit -m "Edit session: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >/tmp/git-commit.log 2>&1 || return 0
    git push origin HEAD:main >/tmp/git-push.log 2>&1 && echo "  [$(date -u +%H:%M:%S)] pushed changes" || {
      echo "  [$(date -u +%H:%M:%S)] push failed:"; cat /tmp/git-push.log
    }
  fi
}

IDLE_MIN="${IDLE_MINUTES:-15}"
idle_limit=$(( IDLE_MIN * 60 ))
activity_count() { grep -cE "\" (GET|POST|PUT|DELETE) " /tmp/filebrowser.log 2>/dev/null || echo 0; }
last_count=$(activity_count); last_active=$(date +%s)
last_push=$(date +%s)
PUSH_EVERY=120
MAX=$(( 340 * 60 )); start=$(date +%s)
echo "watching for idle (${IDLE_MIN} min)"
while true; do
  sleep 15
  now=$(date +%s)
  if ! kill -0 "$FB_PID" 2>/dev/null; then echo "filebrowser died - stopping"; break; fi
  if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then echo "tunnel died - stopping"; break; fi
  c=$(activity_count)
  if [ "$c" != "$last_count" ]; then last_count=$c; last_active=$now; fi
  if [ $(( now - last_push )) -ge $PUSH_EVERY ]; then push_changes; last_push=$now; fi
  idle=$(( now - last_active ))
  if [ $idle -ge $idle_limit ]; then echo "idle ${idle}s >= ${idle_limit}s - stopping"; break; fi
  [ $(( now - start )) -ge $MAX ] && { echo "max session time - stopping"; break; }
done

echo "::group::Final push"
push_changes
echo "::endgroup::"
echo "session ended"
