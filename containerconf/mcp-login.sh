#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# --- Remote MCP sign-in -----------------------------------------------------
# OAuth sign-in for a remote MCP server reached through mcp-remote (e.g. one
# copied from a Claude Desktop config). Run once, and again whenever the
# server's refresh token expires.
#
#   ./mcp-login.sh NAME     NAME = a key under "mcpServers" in
#                           $XPAL_HOST_AUTH/mcp/servers.json
#
# Starts a throwaway container that publishes ONLY the server's OAuth callback
# port, on host loopback, so the browser's post-login redirect reaches
# mcp-remote inside the container (via a relay — see mcp-login-container.sh).
# Tokens land in $XPAL_HOST_AUTH/mcp-remote, which the day-to-day containers
# mount as well, so they use the tokens without being recreated.
#
# Why not sign in from the day-to-day container: its ports are fixed at
# creation, and keeping the callback port published there would stop other
# apps on this machine (e.g. Claude Desktop's own mcp-remote) from binding it
# when they need to sign in.

NAME="${1:-}"
if [ -z "$NAME" ]; then
  echo "Usage: $0 NAME   (a server name from \$XPAL_HOST_AUTH/mcp/servers.json)" >&2
  exit 2
fi

if [ ! -f "$XPAL_HOST_AUTH/mcp/servers.json" ]; then
  echo "No $XPAL_HOST_AUTH/mcp/servers.json yet." >&2
  echo "Create it from containerconf/mcp-servers.example.json — same shape as the" >&2
  echo "\"mcpServers\" block of a Claude Desktop config." >&2
  exit 1
fi

AUTH_MOUNT=( -v "$XPAL_HOST_AUTH":/xpal-auth:Z )

# Ask the image for this server's callback port. The parsing lives in the
# in-container helper, so the host needs nothing beyond the container runtime.
PORT="$("$XPAL_RUNTIME" run --rm --userns=keep-id "${AUTH_MOUNT[@]}" \
  "$XPAL_IMAGE" mcp-login --print-callback-port "$NAME")" || PORT=""
case "$PORT" in
  ''|*[!0-9]*)
    echo "Could not read the callback port for '$NAME' (see error above)." >&2
    echo "If the error is 'mcp-login: not found', rebuild the image: ./build.sh" >&2
    exit 1
    ;;
esac
RELAY_PORT=$((PORT + 1))

# The callback port must be free on the host for the length of the sign-in.
if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
  echo "Port $PORT is already in use on this machine." >&2
  echo "Another mcp-remote (e.g. Claude Desktop's) may be mid sign-in — finish or" >&2
  echo "quit it, then retry." >&2
  exit 1
fi

# Allocate a TTY only when there is one (works from scripts and agents too;
# the in-container helper keeps stdin open itself when it has no terminal).
TTY_ARGS=( -i )
if [ -t 0 ] && [ -t 1 ]; then
  TTY_ARGS=( -it )
fi

echo "Publishing host 127.0.0.1:$PORT -> container relay :$RELAY_PORT for the sign-in."
exec "$XPAL_RUNTIME" run "${TTY_ARGS[@]}" --rm \
  --userns=keep-id \
  -p "127.0.0.1:$PORT:$RELAY_PORT" \
  -e "MCP_LOGIN_RELAY_PORT=$RELAY_PORT" \
  "${AUTH_MOUNT[@]}" \
  "$XPAL_IMAGE" mcp-login "$NAME"
