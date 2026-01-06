#!/usr/bin/env bash
# Mock CLI that emits NDJSON progress to stderr
# Usage: mock-progress.sh [--fast] [--fail]
#   --fast: emit progress quickly (no sleep)
#   --fail: exit with non-zero status after emitting progress

set -euo pipefail

fast=false
fail=false

while [[ $# -gt 0 ]]; do
	case "$1" in
	--fast)
		fast=true
		shift
		;;
	--fail)
		fail=true
		shift
		;;
	*) shift ;;
	esac
done

sleep_time=0.1
if [[ "$fast" == "true" ]]; then
	sleep_time=0
fi

for pct in 0 25 50 75 100; do
	echo "{\"progress\":${pct},\"message\":\"Step ${pct}%\"}" >&2
	if [[ "$sleep_time" != "0" ]]; then
		sleep "$sleep_time"
	fi
done

# Output result to stdout
echo '{"result":"success"}'

if [[ "$fail" == "true" ]]; then
	exit 1
fi
