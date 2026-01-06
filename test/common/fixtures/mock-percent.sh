#!/usr/bin/env bash
# Mock CLI that emits percentage progress to stderr
# Usage: mock-percent.sh [--fast]
#   --fast: emit progress quickly (no sleep)

set -euo pipefail

fast=false

while [[ $# -gt 0 ]]; do
	case "$1" in
	--fast)
		fast=true
		shift
		;;
	*) shift ;;
	esac
done

sleep_time=0.1
if [[ "$fast" == "true" ]]; then
	sleep_time=0
fi

for pct in 10 30 50 70 90 100; do
	echo "Downloading... ${pct}%" >&2
	if [[ "$sleep_time" != "0" ]]; then
		sleep "$sleep_time"
	fi
done

echo "Done"
