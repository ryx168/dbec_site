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
# Keep filebrowser's own database OUT of the checkout: its default location is
# the current directory, where the auto-push's `git add -A` would commit it
# (and Cloudflare Pages would then publish it, bcrypt password hash included).
FB_DB=/tmp/filebrowser.db
filebrowser config init -d "$FB_DB" --root "$GITHUB_WORKSPACE" >/tmp/fb-init.log 2>&1
filebrowser users add -d "$FB_DB" "$FB_USER" "$FB_PASS" --perm.admin >/tmp/fb-user.log 2>&1
filebrowser -d "$FB_DB" -a 127.0.0.1 -p 8080 --root "$GITHUB_WORKSPACE" >/tmp/filebrowser.log 2>&1 &
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
echo "::endgroup::"

# SFTP (optional, best-effort): a second sshd on 127.0.0.1:2222 restricted to
# SFTP-only for user conan, exposed through bore.pub (a zero-account public TCP
# relay) so FileZilla etc. can connect at bore.pub:<random port>. SSH does its
# own end-to-end encryption, so the shared relay never sees plaintext. If any
# of this fails the web editor above still works - SFTP just isn't advertised.
echo "::group::Start SFTP (bore.pub)"
SFTP_HOST=""; SFTP_PORT=""; BORE_PID=""
sudo apt-get install -y -qq openssh-server acl >/dev/null 2>&1 || true
ssh-keygen -q -t ed25519 -f /tmp/ssh_host_ed25519_key -N "" >/dev/null 2>&1 || true
# conan's home IS the checkout, so an SFTP session starts there and uploads land
# in the repo (and thus get auto-committed), not in a throwaway home dir.
id conan >/dev/null 2>&1 || sudo useradd -M -d "$GITHUB_WORKSPACE" -s /bin/bash conan
sudo usermod -d "$GITHUB_WORKSPACE" conan 2>/dev/null || true
echo "conan:$FB_PASS" | sudo chpasswd
# let conan read+write the checkout now and for files it creates later
sudo setfacl -R  -m u:conan:rwX "$GITHUB_WORKSPACE" 2>/dev/null || true
sudo setfacl -R -d -m u:conan:rwX "$GITHUB_WORKSPACE" 2>/dev/null || true
# ensure every dir on the way to the checkout is searchable by conan
d="$GITHUB_WORKSPACE"; while [ "$d" != "/" ]; do sudo chmod o+x "$d" 2>/dev/null || true; d=$(dirname "$d"); done
sudo tee /tmp/sshd_config >/dev/null <<EOF
Port 2222
ListenAddress 127.0.0.1
HostKey /tmp/ssh_host_ed25519_key
PidFile /tmp/sshd.pid
LogLevel VERBOSE
PasswordAuthentication yes
UsePAM yes
PermitRootLogin no
AllowUsers conan
Subsystem sftp internal-sftp
Match User conan
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
    PermitTunnel no
EOF
sudo /usr/sbin/sshd -f /tmp/sshd_config -E /tmp/sshd.log && echo "  sshd (sftp-only) on 127.0.0.1:2222" || echo "  sshd failed to start"
curl -fsSL -o /tmp/bore.tgz https://github.com/ekzhang/bore/releases/download/v0.5.1/bore-v0.5.1-x86_64-unknown-linux-musl.tar.gz 2>/dev/null \
  && tar xzf /tmp/bore.tgz -C /tmp 2>/dev/null
if [ -x /tmp/bore ]; then
  /tmp/bore local 2222 --to bore.pub >/tmp/bore.log 2>&1 &
  BORE_PID=$!
  for i in $(seq 1 15); do
    sleep 2
    SFTP_PORT=$(grep -oE 'bore\.pub:[0-9]+' /tmp/bore.log | head -1 | cut -d: -f2 || true)
    [ -n "$SFTP_PORT" ] && { SFTP_HOST="bore.pub"; break; }
  done
fi
if [ -n "$SFTP_PORT" ]; then
  echo "  SFTP ready: bore.pub:$SFTP_PORT  (user conan)"
else
  echo "  SFTP unavailable this session (web editor still works):"; tail -5 /tmp/bore.log 2>/dev/null || true
fi
echo "::endgroup::"

echo ""
echo "=========================================================="
echo "  EDIT SESSION READY"
echo "  Web editor: $TUNNEL_URL   (user $FB_USER)"
[ -n "$SFTP_PORT" ] && echo "  SFTP:       bore.pub port $SFTP_PORT   (user conan)"
echo "  password:   (the editor password set as the FB_PASS secret)"
echo "=========================================================="
echo ""
echo "::group::Publish session for the launcher"
# Publish this session's URL on a side branch ("session": one JSON file) so the
# launcher at www.diamondbarevergreen.com/edit (functions/edit.js in this repo)
# can send visitors straight here. Plumbing commands only - nothing touches the
# working tree that the auto-push stages, and main is never involved.
publish_session() {
  local url="$1" shost="$2" sport="$3" json blob tree commit
  if [ -n "$sport" ]; then
    json=$(printf '{"url":"%s","sftp_host":"%s","sftp_port":"%s","since":"%s"}\n' "$url" "$shost" "$sport" "$(date -u +%FT%TZ)")
  else
    json=$(printf '{"url":"%s","since":"%s"}\n' "$url" "$(date -u +%FT%TZ)")
  fi
  blob=$(printf '%s' "$json" | git hash-object -w --stdin)
  tree=$(printf '100644 blob %s\tedit-session.json\n' "$blob" | git mktree)
  commit=$(git -c user.email=superesolutions@gmail.com -c user.name="dbec on-demand editor" commit-tree "$tree" -m "edit session $(date -u +%FT%TZ)")
  git push -q -f origin "$commit:refs/heads/session" && echo "  session published for the launcher" \
    || echo "  (launcher publish failed - session still usable via this log)"
}
publish_session "$TUNNEL_URL" "$SFTP_HOST" "$SFTP_PORT"
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
  # SFTP activity has no HTTP log - treat any content-file write since the last
  # active moment as activity (exclude .git, which the push loop churns itself).
  if find "$GITHUB_WORKSPACE" -type f -newermt "@$last_active" ! -path '*/.git/*' -print -quit 2>/dev/null | grep -q .; then
    last_active=$now
  fi
  if [ $(( now - last_push )) -ge $PUSH_EVERY ]; then push_changes; last_push=$now; fi
  idle=$(( now - last_active ))
  if [ $idle -ge $idle_limit ]; then echo "idle ${idle}s >= ${idle_limit}s - stopping"; break; fi
  [ $(( now - start )) -ge $MAX ] && { echo "max session time - stopping"; break; }
done

echo "::group::Final push"
push_changes
echo "::endgroup::"
git push -q origin --delete session 2>/dev/null || true
[ -n "${BORE_PID:-}" ] && kill "$BORE_PID" 2>/dev/null || true
sudo kill "$(cat /tmp/sshd.pid 2>/dev/null)" 2>/dev/null || true
echo "session ended"
