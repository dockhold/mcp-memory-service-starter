"""Client-side steps for tests/smoke.sh: OAuth and MCP, the way a real client does it.

Usage: flow.py <base-url> <api-key-file> <token-file> <step>...

Steps run in order and print one PASS or FAIL line each; the first FAIL exits 1.
  probe      unauthenticated and garbage-token calls are refused, a wrong key is refused
  login      dynamic client registration, PKCE authorization with the API key,
             token exchange; saves the access token to the token file
  store      stores one memory through /mcp
  search     finds that memory with semantic search
  revoked    the saved token is refused
  ratelimit  one visitor (by X-Forwarded-For) hits the login rate limit,
             another visitor is not affected

Standard library only, so it runs inside the app image itself.
"""
import base64
import hashlib
import html
import json
import re
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request

BASE, KEY_FILE, TOK_FILE, STEPS = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
KEY = open(KEY_FILE).read().strip()
REDIRECT = "http://localhost:6274/oauth/callback"
MEMORY = "The deploy target for project nightjar is Dockhold."
ACCEPT = "application/json, text/event-stream"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


OPENER = urllib.request.build_opener(NoRedirect)


def req(method, path, body=None, headers=None, form=False):
    h = dict(headers or {})
    data = None
    if body is not None:
        if form:
            data = urllib.parse.urlencode(body).encode()
            h["Content-Type"] = "application/x-www-form-urlencoded"
        else:
            data = json.dumps(body).encode()
            h["Content-Type"] = "application/json"
    r = urllib.request.Request(BASE + path, data=data, method=method, headers=h)
    try:
        resp = OPENER.open(r, timeout=120)
        return resp.status, dict(resp.headers), resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read().decode()


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name + (f"  [{detail}]" if detail else ""))
    if not cond:
        sys.exit(1)


def rpc_result(body):
    # Streamable HTTP may answer as an SSE stream; the JSON-RPC reply is the last data: line.
    if body.lstrip().startswith("{"):
        return json.loads(body)
    lines = [line[5:].strip() for line in body.splitlines() if line.startswith("data:")]
    return json.loads(lines[-1]) if lines else {}


def session(token):
    """initialize, then notifications/initialized, on one session. Returns (status, session id)."""
    h = {"Accept": ACCEPT, "Authorization": f"Bearer {token}"}
    s, hd, _ = req("POST", "/mcp", {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "0"}}}, h)
    if s != 200:
        return s, None
    sid = hd.get("Mcp-Session-Id") or hd.get("mcp-session-id")
    if sid:
        h["Mcp-Session-Id"] = sid
    s2, _, _ = req("POST", "/mcp", {"jsonrpc": "2.0", "method": "notifications/initialized"}, h)
    check("notifications/initialized", s2 in (200, 202), s2)
    return s, sid


def call(token, sid, name, arguments):
    h = {"Accept": ACCEPT, "Authorization": f"Bearer {token}"}
    if sid:
        h["Mcp-Session-Id"] = sid
    s, _, b = req("POST", "/mcp", {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                   "params": {"name": name, "arguments": arguments}}, h)
    return s, rpc_result(b) if s == 200 else {}


def authorize_query(cid, challenge):
    return urllib.parse.urlencode({"response_type": "code", "client_id": cid, "redirect_uri": REDIRECT,
                                   "state": "smoke", "code_challenge": challenge,
                                   "code_challenge_method": "S256", "scope": "read write"})


def register():
    s, _, b = req("POST", "/oauth/register", {"client_name": "smoke", "redirect_uris": [REDIRECT],
                  "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
                  "token_endpoint_auth_method": "none"})
    check("client registration", s in (200, 201), s)
    return json.loads(b)


def step_probe():
    tools = {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}
    s, _, _ = req("POST", "/mcp", tools, {"Accept": ACCEPT})
    check("/mcp without a token is refused (401)", s == 401, s)
    s, _, _ = req("POST", "/mcp", tools, {"Accept": ACCEPT, "Authorization": "Bearer not-a-token"})
    check("/mcp with a made-up token is refused (401)", s == 401, s)
    s, _, b = req("GET", "/.well-known/oauth-authorization-server")
    issuer = json.loads(b).get("issuer", "") if s == 200 else ""
    check("OAuth issuer is the app's public address", issuer.rstrip("/") == BASE, issuer)
    cid = register()["client_id"]
    q = authorize_query(cid, "x" * 43)
    s, _, _ = req("POST", "/oauth/authorize?" + q, {"api_key": "wrong-" + "0" * 40}, form=True)
    check("login with a wrong API key is refused (403)", s == 403, s)


def step_login():
    client = register()
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    q = authorize_query(client["client_id"], challenge)
    s, _, b = req("POST", "/oauth/authorize?" + q, {"api_key": KEY}, form=True)
    # Upstream answers a good login with a page that redirects the browser
    # (meta refresh), not with a 302, for popup-based clients such as claude.ai.
    m = re.search(r'url=([^"]+)"', b)
    loc = html.unescape(m.group(1)) if m else ""
    check("login with the API key returns an authorization code", s == 200 and loc.startswith(REDIRECT) and "code=" in loc, s)
    code = urllib.parse.parse_qs(urllib.parse.urlparse(loc).query)["code"][0]
    body = {"grant_type": "authorization_code", "code": code, "redirect_uri": REDIRECT,
            "client_id": client["client_id"], "code_verifier": verifier}
    if client.get("client_secret"):
        body["client_secret"] = client["client_secret"]
    s, _, b = req("POST", "/oauth/token", body, form=True)
    check("code exchanged for an access token", s == 200, s)
    open(TOK_FILE, "w").write(json.loads(b)["access_token"])


def token():
    return open(TOK_FILE).read().strip()


def step_store():
    s, sid = session(token())
    check("MCP session with the access token", s == 200, s)
    s, r = call(token(), sid, "memory_store", {"content": MEMORY, "tags": ["smoke"]})
    # Upstream reports a failed store with isError false and the error in the
    # text, so the success text is what counts.
    text = json.dumps(r)
    check("memory_store", s == 200 and "Memory stored successfully" in text, text[:200])


def step_search():
    s, sid = session(token())
    check("MCP session with the access token", s == 200, s)
    s, r = call(token(), sid, "memory_search", {"query": "where does nightjar deploy?"})
    text = json.dumps(r)
    check("memory_search finds the memory", s == 200 and "nightjar" in text, text[:200])
    # Upstream reports "mode: semantic" even when it runs on hash pseudo-vectors,
    # so this line alone does not prove the model loaded. The start script turns
    # that fallback off, which makes a missing model fail the store step instead.
    check("search ran in semantic mode (the bundled model loaded)", "mode: semantic" in text, text[:200])


def step_revoked():
    s, _ = session(token())
    check("the old access token is refused (401)", s == 401, s)


def step_ratelimit():
    q = "/oauth/authorize?" + authorize_query("smoke-no-such-client", "x" * 43)
    codes = [req("GET", q, headers={"X-Forwarded-For": "198.51.100.7"})[0] for _ in range(70)]
    check("one visitor sending 70 login requests is rate limited (429)", 429 in codes, sorted(set(codes)))
    s = req("GET", q, headers={"X-Forwarded-For": "203.0.113.9"})[0]
    check("a second visitor is not affected by the first one's limit", s != 429, s)


for step in STEPS:
    globals()["step_" + step]()
