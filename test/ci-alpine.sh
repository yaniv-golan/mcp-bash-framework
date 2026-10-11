#!/bin/sh
# Run the unit and integration suites on Alpine Linux, where ps, stat, find,
# tar, date and the other system tools are BusyBox. Runs inside an Alpine
# container with the repository (including node_modules) mounted at /src:
#
#   npm ci
#   docker run --rm -v "$PWD:/src:ro" alpine:3.20 sh /src/test/ci-alpine.sh
#
# The tests run as an unprivileged user on a copy inside the container: as
# root, permission checks pass that would fail for a real user, and a bind
# mount from macOS can report execute permission that the kernel refuses.
set -eu

apk add --no-cache bash jq git perl bats ncurses curl zip file python3 >/dev/null

mkdir -p /work
cp -a /src/. /work/
adduser -D tester >/dev/null 2>&1 || true
chown -R tester /work
su tester -c 'git config --global --add safe.directory /work'

status=0
su tester -c 'cd /work && CI=1 bash test/unit/run.sh' || status=1
su tester -c 'cd /work && MCPBASH_CI_MODE=1 bash test/integration/run.sh' || status=1
exit "${status}"
