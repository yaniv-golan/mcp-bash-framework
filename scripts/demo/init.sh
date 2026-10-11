# Container setup for scripts/demo/demo.tape: bash, jq and mcp-bash on PATH.
# shellcheck shell=sh
apk add -q bash jq >/dev/null
ln -s /opt/mcp-bash/bin/mcp-bash /usr/local/bin/mcp-bash
cd /home || exit 1
PS1='$ ' exec bash --norc
