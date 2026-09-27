#!/usr/bin/env bash
# Smoke test for the mcp-memory-service-starter image, run the way Dockhold
# runs it: user 1001, every capability dropped, no privilege escalation,
# 256 MB of memory and no swap, App storage mounted at /data owned root:1001
# with mode 2770, a fixed PORT and a generated API key. Two restrictions go
# further than Dockhold does. There is no outbound network, which proves the
# app never downloads anything at runtime. The root filesystem is read-only,
# which proves nothing is written outside /data and /tmp. Every client step
# runs tests/flow.py inside the image itself, on the same isolated network.
# Nothing upstream is mocked.
#
# Usage: tests/smoke.sh <image>
# Needs: docker, bash 4 or newer. Exits non-zero if any case fails.
# Prints one PASS or FAIL line per case, INFO lines for measurements, and the
# container log after a failure.
set -euo pipefail

IMAGE=${1:?usage: tests/smoke.sh <image>}
RUN="mmsmoke-$$-$RANDOM"
NET="$RUN-net"
APP="$RUN-app"
VOL="$RUN-data"
PORT=8080
URL="http://app:$PORT"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mmsmoke.XXXXXX")
STORAGE_LINE="This app keeps its data on App storage. Turn on App storage in the Size tab; the app restarts on its own."

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() {
  echo "FAIL  $1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "----- container log ($APP) -----"
  docker logs "$APP" 2>&1 | tail -n 40 || true
  echo "-------------------------------"
}
report() { if [ "$2" = true ]; then pass "$1"; else fail "$1"; fi; }
info() { echo "INFO  $1"; }

cleanup() {
  docker rm -f "$APP" "$RUN-refuse" "$RUN-flow" >/dev/null 2>&1 || true
  docker volume rm -f "$VOL" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

rand_hex() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }

KEY=$(rand_hex 32)
printf '%s\n' "$KEY" > "$WORK/key"
chmod 0644 "$WORK/key"

# --internal: the containers can reach each other and nothing else.
docker network create --internal "$NET" >/dev/null
docker volume create "$VOL" >/dev/null
# Shape the volume like Dockhold's App storage mount.
docker run --rm --user 0 --network none --entrypoint sh -v "$VOL:/data" "$IMAGE" \
  -c 'chown root:1001 /data && chmod 2770 /data'

PLATFORM=(--user 1001:1001 --cap-drop ALL --security-opt no-new-privileges
  --memory 256m --memory-swap 256m --read-only --tmpfs /tmp:mode=1777
  --network "$NET" -e PORT="$PORT")
APP_ENV=(-e DOCKHOLD_APP_URL="$URL" -v "$VOL:/data" -e DATA_DIR=/data)

# Client steps run from the image's own Python, as the calling user, with the
# key and token files in a bind-mounted work folder.
flow() {
  docker run --rm --name "$RUN-flow" --network "$NET" --user "$(id -u):$(id -g)" --cap-drop ALL \
    --entrypoint python -v "$PWD/tests/flow.py:/flow.py:ro" -v "$WORK:/work" \
    "$IMAGE" /flow.py "$URL" /work/key "/work/$1" "${@:2}"
}

# A refusal only counts with its own message, and an exit. A server that
# starts never exits, so the timeout exit code (124) means it did not refuse.
must_refuse() {
  local name=$1 want=$2 rc=0 out
  shift 2
  out=$(timeout 60 docker run --rm --name "$RUN-refuse" "${PLATFORM[@]}" "$@" "$IMAGE" 2>&1) || rc=$?
  docker rm -f "$RUN-refuse" >/dev/null 2>&1 || true
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 124 ]; then fail "$name: the app started"; return; fi
  case $out in *"$want"*) pass "$name" ;; *) fail "$name: refused for another reason: $out" ;; esac
}

start() {
  docker run -d --name "$APP" --network-alias app "${PLATFORM[@]}" "${APP_ENV[@]}" \
    -e MCP_API_KEY="$1" "$IMAGE" >/dev/null
  local i=0 t0
  t0=$(date +%s)
  until docker run --rm --network "$NET" --cap-drop ALL --entrypoint python "$IMAGE" \
      -c "import urllib.request; urllib.request.urlopen('$URL/health', timeout=2)" >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge 90 ] || [ "$(docker inspect -f '{{.State.Running}}' "$APP")" != true ]; then
      fail "the app becomes healthy"; exit 1
    fi
    sleep 1
  done
  info "healthy $(( $(date +%s) - t0 )) s after start"
}

stop() {
  local t0 code oom
  t0=$(date +%s)
  docker stop -t 60 "$APP" >/dev/null
  code=$(docker inspect -f '{{.State.ExitCode}}' "$APP")
  oom=$(docker inspect -f '{{.State.OOMKilled}}' "$APP")
  report "stops cleanly on SIGTERM ($(( $(date +%s) - t0 )) s, exit $code)" "$([ "$code" = 0 ] && [ "$oom" = false ] && echo true || echo false)"
  docker logs "$APP" >> "$WORK/all.log" 2>&1
  docker rm "$APP" >/dev/null
}

memory() { info "memory in use: $(docker stats --no-stream --format '{{.MemUsage}}' "$APP")"; }

# 1. Refusals, each with its own message.
must_refuse "refuses to start without App storage" "$STORAGE_LINE" -e DOCKHOLD_APP_URL="$URL" -e MCP_API_KEY="$KEY"
must_refuse "refuses to start without the API key" "MCP_API_KEY is missing or empty" "${APP_ENV[@]}"
must_refuse "refuses to start with a short API key" "MCP_API_KEY is shorter than 32" "${APP_ENV[@]}" -e MCP_API_KEY=short
must_refuse "refuses to start without a public address" "DOCKHOLD_APP_URL is not set" -v "$VOL:/data" -e DATA_DIR=/data -e MCP_API_KEY="$KEY"
must_refuse "refuses to start with half an OAuth key pair" "Only half of the OAuth key pair" "${APP_ENV[@]}" -e MCP_API_KEY="$KEY" -e MCP_OAUTH_PRIVATE_KEY=x

# 2. First start: auth, login, store, search.
start "$KEY"
if flow tok1 probe login store search ratelimit; then pass "client flow on the first start"; else fail "client flow on the first start"; fi
memory
stop

# 3. Restart: the same token and the same memory still work.
start "$KEY"
if flow tok1 search; then pass "token and memory survive a restart"; else fail "token and memory survive a restart"; fi
stop

# 4. New API key: every client is signed out, the memories stay.
NEW_KEY=$(rand_hex 32)
printf '%s\n' "$NEW_KEY" > "$WORK/key"
start "$NEW_KEY"
if flow tok1 revoked; then pass "changing the API key signs old clients out"; else fail "changing the API key signs old clients out"; fi
if flow tok2 login search; then pass "the new key logs in and the memories are still there"; else fail "the new key logs in and the memories are still there"; fi
stop

# 5. Log hygiene, over every start above.
if grep -qF "MCP_API_KEY changed: signing every client out." "$WORK/all.log"; then pass "the key change is logged"; else fail "the key change is logged"; fi
if grep -qF -e "$KEY" -e "$NEW_KEY" "$WORK/all.log"; then fail "no API key value in the logs"; else pass "no API key value in the logs"; fi
bad=$(grep -E -i "traceback|error|readonly database|permission denied|failed to persist" "$WORK/all.log" \
  | grep -v -F "Authorization denied: invalid API key" || true)
if [ -n "$bad" ]; then fail "no errors in the logs: $bad"; else pass "no errors in the logs"; fi
while IFS= read -r line; do info "log warning: $line"; done < <(grep -i "warn" "$WORK/all.log" | sort -u)

# 6. What ended up on App storage.
docker run --rm --user 0 --network none --entrypoint sh -v "$VOL:/data" "$IMAGE" -c \
  'find /data -maxdepth 3 \( -type f -o -type l \) -exec stat -c "%A %u:%g %n" {} \;' \
  | while IFS= read -r line; do info "storage: $line"; done

echo "$PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
