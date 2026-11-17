#!/usr/bin/env bash
# mcp-login — sign in to a remote OAuth MCP server from INSIDE the container,
# then register it with Claude Code. Installed at /usr/local/bin/mcp-login.
#
# Normally launched from the host by containerconf/mcp-login.sh, which starts a
# throwaway container with the OAuth callback port published. See
# containerconf/README.md -> "Remote MCP servers".
#
#   mcp-login NAME                        sign in if needed, list tools, register
#   mcp-login --print-callback-port NAME  print NAME's callback port and exit
#
# Server definitions live in /xpal-auth/mcp/servers.json (host:
# $XPAL_HOST_AUTH/mcp/servers.json), in the same {"mcpServers": {...}} shape a
# Claude Desktop config uses, so an entry can be pasted across unchanged.
# Entries must run mcp-remote, and the form decides where it comes from:
#   "command": "mcp-remote"                    the copy baked into the image
#   "command": "npx", args "-y mcp-remote@X"   fetched by npx at runtime
# (A host path to npx, e.g. ~/node/bin/npx, counts as npx.) The second
# mcp-remote argument must be the callback port.
#
# Why a relay: mcp-remote's OAuth callback server listens on 127.0.0.1 only
# (hard-coded in mcp-remote, no flag to change it). A published container port
# delivers traffic to the container's network interface, not its loopback, so
# the browser's post-login redirect would never arrive. socat listens on all
# interfaces at RELAY_PORT and forwards to 127.0.0.1:CALLBACK_PORT; the host
# publishes CALLBACK_PORT -> RELAY_PORT. The redirect URI the OAuth server has
# registered (http://localhost:<callback port>/<path>) therefore stays the same
# as on a desktop install.

set -euo pipefail

SERVERS_FILE="${MCP_SERVERS_FILE:-/xpal-auth/mcp/servers.json}"

usage() {
  echo "Usage: mcp-login NAME" >&2
  echo "       mcp-login --print-callback-port NAME" >&2
  echo "NAME is a key under \"mcpServers\" in $SERVERS_FILE." >&2
}

# Reads one server entry and prints, by mode:
#   port   — the callback port (2nd mcp-remote arg)
#   client — the command that runs mcp-remote-client with the entry's args,
#            NUL-separated (npx -p <pkg> ... for npx entries)
#   claude — the entry normalized for `claude mcp add-json`: same launcher
#            (bare `npx`, not a host path), any PATH override dropped — in a
#            desktop config it points at host paths.
# node is always present here (mcp-remote needs it), so it does the JSON work.
PARSER='
const [file, name, mode] = process.argv.slice(1);
const fail = (msg) => { process.stderr.write(`mcp-login: ${msg}\n`); process.exit(2); };
let doc;
try { doc = JSON.parse(require("fs").readFileSync(file, "utf8")); }
catch (e) { fail(`cannot read ${file}: ${e.message}`); }
const servers = (doc && doc.mcpServers) || {};
const def = servers[name];
if (!def) fail(`no server "${name}" in ${file} (found: ${Object.keys(servers).join(", ") || "none"})`);
const cmd = String(def.command || "").split("/").pop();
const args = (def.args || []).map(String);
// via "npx":       fetch mcp-remote at runtime, like a Claude Desktop config
// via "installed": use the copy baked into the image (any other launcher too)
let rest, via = "installed", pkg = "";
if (cmd === "mcp-remote") {
  rest = args;
} else {
  const i = args.findIndex((a) => /^mcp-remote(@.+)?$/.test(a));
  if (i === -1) fail(`"${name}" does not run mcp-remote; mcp-login only handles mcp-remote servers`);
  rest = args.slice(i + 1);
  if (cmd === "npx") { via = "npx"; pkg = args[i]; }
}
if (!/^https?:\/\//.test(rest[0] || "")) fail(`"${name}": the first mcp-remote argument must be the server URL`);
const port = /^[0-9]+$/.test(rest[1] || "") ? rest[1] : "";
const nul = (list) => list.map((a) => `${a}\0`).join("");
switch (mode) {
  case "port":
    if (!port) fail(`"${name}" has no callback port; add one as the second mcp-remote argument`);
    process.stdout.write(`${port}\n`);
    break;
  case "client":
    // The full command that runs mcp-remote-client with the same arguments.
    if (via === "npx" && !/^mcp-remote@\d/.test(pkg))
      process.stderr.write(`mcp-login: warning: "${name}" runs ${pkg} unpinned; pin it (mcp-remote@<version>) so the version cannot change under you\n`);
    process.stdout.write(nul(via === "npx"
      ? ["npx", "-y", "-p", pkg, "mcp-remote-client", ...rest]
      : ["mcp-remote-client", ...rest]));
    break;
  case "claude": {
    const env = { ...(def.env || {}) };
    delete env.PATH;
    const out = via === "npx"
      ? { type: "stdio", command: "npx", args: ["-y", pkg, ...rest] }
      : { type: "stdio", command: "mcp-remote", args: rest };
    if (Object.keys(env).length > 0) out.env = env;
    process.stdout.write(`${JSON.stringify(out)}\n`);
    break;
  }
  default:
    fail(`internal: unknown mode ${mode}`);
}
'

PRINT_PORT=0
if [ "${1:-}" = "--print-callback-port" ]; then
  PRINT_PORT=1
  shift
fi
NAME="${1:-}"
if [ -z "$NAME" ] || [ "${NAME#-}" != "$NAME" ]; then
  usage
  exit 2
fi

if [ ! -f "$SERVERS_FILE" ]; then
  echo "mcp-login: $SERVERS_FILE not found." >&2
  echo "Create it on the host at \$XPAL_HOST_AUTH/mcp/servers.json" >&2
  echo "(shape: containerconf/mcp-servers.example.json)." >&2
  exit 1
fi

parse() { node -e "$PARSER" "$SERVERS_FILE" "$NAME" "$1"; }

CALLBACK_PORT="$(parse port)"
if [ "$PRINT_PORT" = "1" ]; then
  echo "$CALLBACK_PORT"
  exit 0
fi

mapfile -d '' -t CLIENT_CMD < <(parse client)
CLAUDE_JSON="$(parse claude)"

# --- Callback relay (see header) -------------------------------------------
RELAY_PORT="${MCP_LOGIN_RELAY_PORT:-$((CALLBACK_PORT + 1))}"
socat "TCP-LISTEN:${RELAY_PORT},fork,reuseaddr" "TCP:127.0.0.1:${CALLBACK_PORT}" &
RELAY_PID=$!
trap 'kill "$RELAY_PID" 2>/dev/null || true' EXIT
sleep 0.3
if ! kill -0 "$RELAY_PID" 2>/dev/null; then
  echo "mcp-login: could not start the callback relay on port $RELAY_PORT." >&2
  exit 1
fi

cat <<EOF
== Signing in to "$NAME" ==
mcp-remote prints an authorization URL below. Open it in a browser on your
host and sign in. The OAuth server then redirects the browser to
http://localhost:${CALLBACK_PORT}/... on the host, which mcp-login.sh published
into this container. Tokens are stored under ${MCP_REMOTE_CONFIG_DIR:-~/.mcp-auth}.
If valid tokens already exist, no URL appears — it just connects and lists tools.
("Could not open a browser automatically" is expected in a container.)

EOF

# mcp-remote-client shuts down (exit 0) the moment stdin closes — before it
# has listed the tools — so hold stdin open when run without a terminal.
run_client() {
  if [ -t 0 ]; then
    "${CLIENT_CMD[@]}"
  else
    "${CLIENT_CMD[@]}" < <(sleep infinity)
  fi
}
if ! run_client; then
  echo "mcp-login: sign-in or connection to \"$NAME\" failed (see output above)." >&2
  exit 1
fi

# --- Register with Claude Code (user scope -> $CLAUDE_CONFIG_DIR, persisted) --
echo
if ! command -v claude >/dev/null 2>&1; then
  echo "claude is not on PATH; skipped Claude Code registration."
  exit 0
fi
if claude mcp add-json --scope user "$NAME" "$CLAUDE_JSON"; then
  echo "Registered \"$NAME\" with Claude Code (user scope)."
else
  echo "Claude Code registration skipped — most likely \"$NAME\" is already registered."
  echo "To re-register from servers.json:  claude mcp remove --scope user \"$NAME\" && mcp-login \"$NAME\""
fi
echo "Done. In the day-to-day container, start a new claude session (or /mcp -> reconnect)."
