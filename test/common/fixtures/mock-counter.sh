#!/usr/bin/env bash
# Mock CLI that emits counter progress to stderr
# Usage: mock-counter.sh [--fast] [--total N]
#   --fast: emit progress quickly (no sleep)
#   --total: total count (default: 10)

set -euo pipefail

fast=false
total=10

while [[ $# -gt 0 ]]; do
	case "$1" in
	--fast)
		fast=true
		shift
		;;
	--total)
		total="$2"
		shift 2
		;;
	*) shift ;;
	esac
done

sleep_time=0.1
if [[ "$fast" == "true" ]]; then
	sleep_time=0
fi

for ((i = 1; i <= total; i++)); do
	echo "[${i}/${total}] Processing item ${i}" >&2
	if [[ "$sleep_time" != "0" ]]; then
		sleep "$sleep_time"
	fi
done

echo "Processed ${total} items"
