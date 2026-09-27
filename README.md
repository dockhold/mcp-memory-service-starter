# MCP Memory Service on Dockhold

[MCP Memory Service](https://github.com/doobidoo/mcp-memory-service) gives
your AI assistants one long-term memory. Store a decision, a fact or a note
in one conversation and find it again by meaning in the next, from
claude.ai, ChatGPT, Claude Code or any MCP client. This template runs the
maintainer's published slim image (version 11.14.0) on
[Dockhold](https://dockhold.eu) as a remote MCP server with OAuth login, and
adds a start script that wires it to Dockhold's port, App storage, public
address and your API key. Nothing upstream is changed. Deploy it as it is, or
use it as the starting point for your own memory server.

This template is not affiliated with MCP Memory Service.

[![Deploy to Dockhold](https://img.shields.io/badge/Deploy%20to-Dockhold-2563eb?style=for-the-badge)](https://app.dockhold.eu/new?repo=https://github.com/dockhold/mcp-memory-service-starter&name=agent-memory&ref=template-mcp-memory-service)

## Deploy

1. Open the [Deploy link](https://app.dockhold.eu/new?repo=https://github.com/dockhold/mcp-memory-service-starter&name=agent-memory&ref=template-mcp-memory-service)
   and sign in if asked.
2. Under **App size**, keep **256 MB**. Under **App storage**, turn it on
   and pick **10 GB**. The free plan is enough.
3. Under **Environment**, in the **Secrets** list, click **New secret**,
   tick it, and set its **Env var name** to `MCP_API_KEY`. Give the entry a
   name that belongs to this app, for example `mcp-memory-api-key`, because
   secrets are shared across your apps by name.

   | Secret (your name) | Env var name | Value |
   | --- | --- | --- |
   | `mcp-memory-api-key` | `MCP_API_KEY` | 32 or more random characters, for example the output of `openssl rand -hex 32` |

4. Click **Deploy** and wait until the app shows as running.
5. Open `https://<your app>/health`. It answers `{"status":"ok"}`.

If the app refuses to start, its page shows one line saying what is missing.
App storage is on the app's **Size** tab; secrets are attached on its
**Variables** tab. Fix it and click **Restart**.

## Connect your assistant

The MCP address is `https://<your app>/mcp`. Each client logs in once: it
opens the login page of your app, you paste the API key, and the client
keeps the session from then on.

* **claude.ai:** Settings > Connectors, add a custom connector with the MCP
  address.
* **Claude Code:** `claude mcp add --transport http memory https://<your app>/mcp`,
  then run `/mcp` in Claude Code and log in.
* **ChatGPT:** turn on Developer Mode and add a connector with the MCP
  address.
* **Clients without OAuth** can send the API key itself, as
  `Authorization: Bearer <key>` or `X-API-Key: <key>`.

Try it: in one conversation, ask your assistant to remember something. In a
new conversation, ask what it remembers about it.

## Two ways to use it

**Run it.** Deploy this repository as it is. You get a hosted memory server
and nothing to maintain. Your app stays on the version it was built with;
**Restart** does not pull new code. This is the way to try it.

**Develop it (recommended for daily use).** Click **Use this template** on
GitHub to make your own copy, connect that repository in Dockhold, and deploy
it. From then on every push redeploys the app, and an upgrade is a one-line
change you merge (see "Upgrading" below). MCP Memory Service ships security
fixes in its latest release only, so a server you keep should be on this
path. The repository's own checks (`.github/workflows/check.yml`) run on
every push to your copy.

Only the second path gives you push-to-deploy. The first path never reads
your GitHub account.

## Your API key

The key is the password on the login page, and a client may also send it
directly as a bearer token. Treat it as the key to every memory in the app.

| What you do | What happens |
| --- | --- |
| Change `MCP_API_KEY` in Dockhold (Settings > Secrets), then **Restart** | Every connected client is signed out and logs in again with the new key. The memories stay. |
| **Restart** or deploy with the key unchanged | Nothing. Clients stay logged in. |
| Remove the secret, or set one shorter than 32 characters | The app refuses to start and its page says why. |

**Sessions.** A login gives the client an access token for 60 minutes and a
refresh token for 30 days (upstream's defaults). The client renews both by
itself. The key that signs the tokens is created on the first start and kept
on App storage, which is why restarts and deploys do not sign anyone out.

## Settings

* `MCP_OAUTH_PRIVATE_KEY` and `MCP_OAUTH_PUBLIC_KEY` (optional, both or
  neither, as secrets). Your own PEM key pair for signing tokens instead of
  the generated one. With your own pair, changing the API key still signs
  every client out, but tokens already issued keep working until they expire
  (at most 60 minutes) unless you change the pair too.
* **Login attempts are rate limited per visitor** with upstream's defaults:
  60 requests per minute to the login endpoints. The visitor address comes
  from Dockhold's edge; the template is tuned for it.
* **Other upstream settings** can be added as variables on the Variables tab;
  see upstream's
  [configuration docs](https://github.com/doobidoo/mcp-memory-service/tree/v11.14.0/docs).
  The start script always sets these, so do not add them: `MCP_MODE`,
  `MCP_SSE_HOST`, `MCP_SSE_PORT`, `MCP_OAUTH_ENABLED`,
  `MCP_OAUTH_STORAGE_BACKEND`, `MCP_OAUTH_SQLITE_PATH`,
  `MCP_OAUTH_TRUST_PROXY_HEADER`, `MCP_MEMORY_BASE_DIR`,
  `MCP_MEMORY_SQLITE_PATH`, `MCP_MEMORY_BACKUPS_PATH`,
  `MCP_MEMORY_ONNX_ALLOW_DOWNLOAD`, `MCP_MEMORY_ALLOW_HASH_EMBEDDINGS`.

Dockhold sets `PORT`, `DATA_DIR` and `DOCKHOLD_APP_URL` itself. Do not add
them.

## Backups, upgrading, restoring

**Your data** is the `mcp-memory` folder on App storage (the memories and
the OAuth logins) plus the API key secret. App storage is not a backup of
itself, and upstream's scheduled backups belong to its web dashboard, which
this template does not run. To keep your own copy of the memories, ask a
connected assistant to page through them with the `memory_list` tool and
save the result.

**Upgrading.** Upgrades happen on the Develop path. A daily check in this
repository opens an issue when upstream releases a new version, with the
new tag and digest. Change the `FROM` line in the `Dockerfile` to it and
push, or merge this repository's `main` into your copy; the
[CHANGELOG](CHANGELOG.md) entry says whether the upgrade changes your data.
Read upstream's release notes too. An app deployed on the Run path keeps the
version it was built with.

If the app comes back on the previous version after an upgrade (Dockhold
rolls a deploy back when the new version does not become healthy), check the
app's log before you retry. A newer version may already have changed the
database.

## Limitations

* One running copy while App storage is attached. The memories are in a
  SQLite file, so this is also what upstream expects.
* Only the MCP endpoint runs. Upstream's web dashboard and REST API are a
  separate server that this template does not start.
* Tools that read files on the server (upstream calls them local-only) are
  turned off by upstream on remote connections.
* Every start logs upstream warnings that `torch`, `sentence-transformers`,
  `transformers` and `pymilvus` are not installed, and a "first run"
  timeout note. The slim image runs without them on purpose; the lines are
  harmless.

## Security notes

* TLS ends at Dockhold's edge. Your memories and your API key reach the app
  over that connection.
* Client registration is open, because claude.ai and ChatGPT register
  themselves. A registered client still needs the API key to log in.
* The embedding model is downloaded when the image is built and checked
  against the sha256 that upstream pins. The running app has downloads
  turned off, and the smoke test runs it with no outbound network at all.
* Report problems with MCP Memory Service itself through
  [upstream's security policy](https://github.com/doobidoo/mcp-memory-service/security/policy).
  Report problems with this template here.

## License

MCP Memory Service is Apache-2.0 licensed
([upstream LICENSE](https://github.com/doobidoo/mcp-memory-service/blob/v11.14.0/LICENSE)).
This template's glue (Dockerfile, start script, workflows, tests, README) is
MIT, see [LICENSE](LICENSE).

## More

[Remote MCP setup](https://github.com/doobidoo/mcp-memory-service/blob/v11.14.0/docs/remote-mcp-setup.md)
in upstream's docs: how the server, OAuth and the clients work.
