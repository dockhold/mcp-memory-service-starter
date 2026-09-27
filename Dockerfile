# MCP Memory Service on Dockhold.
#
# MCP Memory Service is Apache-2.0 licensed (see README). This image is the
# maintainer's published slim image (SQLite with sqlite-vec, ONNX embeddings,
# no PyTorch) plus a start script that wires it to Dockhold's port, App
# storage, public address and your API key. Nothing upstream is rebuilt or
# patched.
#
# The published image leaves the embedding model out and downloads it on the
# first start. Here it is downloaded once, at build time, and checked against
# the sha256 that the upstream code pins. The running app has model downloads
# turned off, so it never fetches code or data.
#
# Upgrading: change the tag and the digest on the FROM line together. The
# daily Upstream release check opens an issue with both. A wrong digest fails
# the build. That is the point.

FROM docker.io/doobidoo/mcp-memory-service:11.14.0-slim@sha256:004b9278023db02414726a128d93bccfce03b1cea2a2bef22d488f86d6ecd23f

# The model's address, sha256 and cache path are read from the upstream
# class, so they follow the pinned version. The sha256 is checked before the
# archive is unpacked. The start script links the cache folder into HOME
# (model-cache-dir says which one), and the upstream version goes into the
# install marker. Everything here is root-owned and read-only at runtime.
RUN set -euf; \
    home=/opt/mcp-memory-home; \
    set -- $(HOME="$home" python -c 'from mcp_memory_service.embeddings.onnx_embeddings import ONNXEmbeddingModel as M; print(M.MODEL_DOWNLOAD_URL, M._MODEL_SHA256, M.DOWNLOAD_PATH, M.EXTRACTED_FOLDER_NAME)'); \
    [ "$#" -eq 4 ]; url=$1; sha=$2; dir=$3; sub=$4; \
    case "$dir" in "$home"/*) ;; *) echo "unexpected model path: $dir"; exit 1 ;; esac; \
    mkdir -p "$dir"; \
    curl -fsSL --proto '=https' --retry 3 -o /tmp/model.tar.gz "$url"; \
    echo "$sha  /tmp/model.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/model.tar.gz -C "$dir" --no-same-owner --no-same-permissions; \
    rm /tmp/model.tar.gz; \
    test -f "$dir/$sub/model.onnx"; \
    rel=${dir#"$home"/}; echo "${rel%/*}" > "$home/model-cache-dir"; \
    python -c 'from mcp_memory_service._version import __version__; print(__version__)' > "$home/upstream-version"; \
    chmod -R a+rX,go-w "$home"

COPY entrypoint.sh /app/dockhold-entrypoint.sh
RUN chmod 0755 /app/dockhold-entrypoint.sh
USER 1001:1001
# The start script execs upstream's entrypoint, which execs the server, so the
# server is the main process and receives the stop signal directly.
ENTRYPOINT ["/app/dockhold-entrypoint.sh"]
