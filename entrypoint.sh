#!/bin/sh
# Start script for MCP Memory Service on Dockhold.
#
# Dockhold hands this app a port (PORT), its own public address
# (DOCKHOLD_APP_URL) and, when App storage is turned on, a folder that
# survives restarts (DATA_DIR). The API key comes from Dockhold's Secrets as
# MCP_API_KEY. This script checks those, prepares the folders and the OAuth
# signing key, and then hands over to upstream's own entrypoint in
# Streamable HTTP mode. It never prints a secret value.
#
# Every check below fails with one line and exit code 1. Dockhold shows that
# line on the app page, so the line is the whole error message.
set -eu

# 1. App storage.
#
# The memories, the OAuth clients and tokens, and the signing key all live in
# one folder. Without App storage that folder would be gone after the next
# restart, so the app refuses to start instead of starting empty.
storage_missing() {
  echo "This app keeps its data on App storage. Turn on App storage in the Size tab; the app restarts on its own." >&2
  exit 1
}
[ -n "${DATA_DIR:-}" ] || storage_missing
case "$DATA_DIR" in /*) ;; *) storage_missing ;; esac
[ -d "$DATA_DIR" ] || storage_missing
[ -w "$DATA_DIR" ] || storage_missing
# Permission bits can say "writable" on a folder that is mounted read-only.
# Creating and removing a file is the only check that cannot be fooled.
probe="$DATA_DIR/.dockhold-write-check.$$"
( : > "$probe" ) 2>/dev/null || storage_missing
rm -f "$probe"

# 2. The API key.
#
# It is the password on the OAuth login page, and clients may also send it
# directly as a bearer token, so it is a full credential. Upstream refuses
# every login while it is unset; this script refuses to start instead, so the
# problem is visible on the app page and not only as a failed login.
if [ -z "${MCP_API_KEY:-}" ]; then
  echo "MCP_API_KEY is missing or empty. Add it as a secret on this app's Variables tab and restart." >&2
  exit 1
fi
if [ "${#MCP_API_KEY}" -lt 32 ]; then
  echo "MCP_API_KEY is shorter than 32 characters. Generate a longer one (openssl rand -hex 32), update the secret under Settings > Secrets and restart." >&2
  exit 1
fi

# 3. The public address.
#
# OAuth clients are sent to the issuer URL to log in, so it must be the
# address they can reach. Dockhold always sets DOCKHOLD_APP_URL.
: "${MCP_OAUTH_ISSUER:=${DOCKHOLD_APP_URL:-}}"
if [ -z "$MCP_OAUTH_ISSUER" ]; then
  echo "DOCKHOLD_APP_URL is not set. Outside Dockhold, set MCP_OAUTH_ISSUER to the public https:// address of this app." >&2
  exit 1
fi

# 4. Folders.
#
# umask 007: every file is readable and writable by the storage folder's
# group as well as by its owner. SQLite creates a new database as 0644 and
# gives its -wal and -shm files the same mode, so both databases are created
# here first, empty, and SQLite fills them in.
umask 007
STATE="$DATA_DIR/mcp-memory"
mkdir -p "$STATE/oauth" "$STATE/backups" "$DATA_DIR/.dockhold/home"
chmod 0700 "$DATA_DIR/.dockhold"
touch "$STATE/memory.db" "$STATE/oauth/oauth.db"

# HOME on App storage, so anything upstream keeps under HOME survives a
# restart. The embedding model stays in the image, read-only, and is linked
# in where upstream looks for it.
export HOME="$DATA_DIR/.dockhold/home"
model_dir=$(cat /opt/mcp-memory-home/model-cache-dir)
mkdir -p "$HOME/$(dirname "$model_dir")"
ln -sfn "/opt/mcp-memory-home/$model_dir" "$HOME/$model_dir"

# 5. Sign every client out when the API key changes.
#
# A hash of the key is kept next to the OAuth data. When the key in
# Dockhold's Secrets no longer matches it, the OAuth clients, the refresh
# tokens and the signing key are removed, so every connected client has to
# log in again with the new key. Memories are not touched. The hash is
# computed through a pipe, so the key never appears in a process list.
key_hash=$(printf '%s' "$MCP_API_KEY" | sha256sum | cut -d' ' -f1)
if [ -s "$STATE/oauth/api-key.sha256" ] && [ "$(cat "$STATE/oauth/api-key.sha256")" != "$key_hash" ]; then
  echo "MCP_API_KEY changed: signing every client out."
  rm -f "$STATE/oauth/oauth.db" "$STATE/oauth/oauth.db-wal" "$STATE/oauth/oauth.db-shm" \
    "$STATE/oauth/private.pem" "$STATE/oauth/public.pem"
  touch "$STATE/oauth/oauth.db"
fi
printf '%s\n' "$key_hash" > "$STATE/oauth/api-key.sha256.tmp"
mv "$STATE/oauth/api-key.sha256.tmp" "$STATE/oauth/api-key.sha256"

# 6. The OAuth signing key.
#
# Upstream makes a new key on every start unless it is given one, which logs
# every client out on each restart and deploy. This script makes one on the
# first start and keeps it on App storage. To bring your own, set both
# MCP_OAUTH_PRIVATE_KEY and MCP_OAUTH_PUBLIC_KEY as secrets. Upstream quietly
# ignores half a pair, so half a pair is refused here.
own_priv=${MCP_OAUTH_PRIVATE_KEY:-${MCP_OAUTH_PRIVATE_KEY_PATH:-}}
own_pub=${MCP_OAUTH_PUBLIC_KEY:-${MCP_OAUTH_PUBLIC_KEY_PATH:-}}
if { [ -n "$own_priv" ] && [ -z "$own_pub" ]; } || { [ -z "$own_priv" ] && [ -n "$own_pub" ]; }; then
  echo "Only half of the OAuth key pair is set. Set both MCP_OAUTH_PRIVATE_KEY and MCP_OAUTH_PUBLIC_KEY as secrets, or neither, and restart." >&2
  exit 1
fi
if [ -z "$own_priv" ]; then
  if [ ! -s "$STATE/oauth/private.pem" ] || [ ! -s "$STATE/oauth/public.pem" ]; then
    echo "Creating the OAuth signing key on App storage."
    python - "$STATE/oauth" <<'EOF'
import os, sys
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
d = sys.argv[1]
k = rsa.generate_private_key(public_exponent=65537, key_size=2048)
priv = k.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
pub = k.public_key().public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo)
# Public first, private last: a start interrupted in between leaves no
# private.pem, so the next start makes a fresh pair.
for name, data in (("public.pem", pub), ("private.pem", priv)):
    tmp = os.path.join(d, name + ".tmp")
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, os.path.join(d, name))
EOF
  fi
  export MCP_OAUTH_PRIVATE_KEY_PATH="$STATE/oauth/private.pem"
  export MCP_OAUTH_PUBLIC_KEY_PATH="$STATE/oauth/public.pem"
fi

# 7. Established-install marker.
#
# Written only after every check above passed. It says which template and
# upstream version last ran on this storage, for support and upgrades.
# Nothing in this script ever wipes or re-seeds the memories.
printf 'mcp-memory-service-starter %s\n' "$(cat /opt/mcp-memory-home/upstream-version)" > "$DATA_DIR/.dockhold/template"

# 8. Hand over to upstream.
#
# MCP_MEMORY_ALLOW_HASH_EMBEDDINGS=0: when the embedding model cannot load,
# upstream would fill an empty database with hash pseudo-vectors, which look
# like working semantic search and silently are not. Refuse that, so a
# missing model is an error on the first request instead.
#
# X-Forwarded-For: Dockhold's edge sets it to the real client address and
# replaces whatever the client sent, so the login rate limit counts each
# visitor on its own. Behind a proxy that does not replace it, a client could
# pick its own address; unset it there.
export MCP_OAUTH_ISSUER
export MCP_OAUTH_ENABLED=true
export MCP_OAUTH_STORAGE_BACKEND=sqlite
export MCP_OAUTH_SQLITE_PATH="$STATE/oauth/oauth.db"
export MCP_OAUTH_TRUST_PROXY_HEADER=X-Forwarded-For
export MCP_MEMORY_BASE_DIR="$STATE"
export MCP_MEMORY_SQLITE_PATH="$STATE/memory.db"
export MCP_MEMORY_BACKUPS_PATH="$STATE/backups"
export MCP_MEMORY_ONNX_ALLOW_DOWNLOAD=0
export MCP_MEMORY_ALLOW_HASH_EMBEDDINGS=0
export MCP_SSE_HOST=0.0.0.0
export MCP_SSE_PORT="${PORT:-8765}"
export MCP_MODE=streamable-http

exec /usr/local/bin/docker-entrypoint-unified.sh "$@"
