#!/usr/bin/env bash
# Spec §11: pagination cursor helpers.

set -euo pipefail

mcp_paginate_python() {
	if command -v python3 >/dev/null 2>&1; then
		printf 'python3'
		return 0
	fi
	if command -v python >/dev/null 2>&1; then
		printf 'python'
		return 0
	fi
	return 1
}

mcp_paginate_encode() {
	local collection="$1"
	local offset="$2"
	local hash="$3"
	local timestamp="${4:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
	local py

	if ! py="$(mcp_paginate_python)"; then
		return 1
	fi

	COLLECTION="${collection}" OFFSET="${offset}" HASH_VALUE="${hash}" TIMESTAMP="${timestamp}" "${py}" <<'PY'
import json, base64, os
collection = os.environ["COLLECTION"]
offset = int(os.environ["OFFSET"])
hash_value = os.environ["HASH_VALUE"]
timestamp = os.environ.get("TIMESTAMP")
payload = json.dumps({"ver": 1, "collection": collection, "offset": offset, "hash": hash_value, "timestamp": timestamp}, separators=(',',':'))
encoded = base64.urlsafe_b64encode(payload.encode('utf-8')).decode('utf-8').rstrip('=')
print(encoded)
PY
}

mcp_paginate_decode() {
	local cursor="$1"
	local expected_collection="$2"
	local expected_hash="$3"
	local py

	if ! py="$(mcp_paginate_python)"; then
		return 1
	fi

	local result
	if ! result="$(
		CURSOR="${cursor}" EXPECTED_COLLECTION="${expected_collection}" EXPECTED_HASH="${expected_hash}" "${py}" <<'PY'
import json, base64, os, sys
cursor = os.environ["CURSOR"]
expected_collection = os.environ["EXPECTED_COLLECTION"]
expected_hash = os.environ["EXPECTED_HASH"]
padding = '=' * (-len(cursor) % 4)
try:
    payload = json.loads(base64.urlsafe_b64decode(cursor + padding).decode('utf-8'))
except Exception:
    sys.exit(1)
if payload.get('ver') != 1 or payload.get('collection') != expected_collection:
    sys.exit(1)
if expected_hash and payload.get('hash') != expected_hash:
    sys.exit(2)
offset = payload.get('offset', 0)
print(offset)
PY
	)"; then
		return 1
	fi

	printf '%s' "${result}"
}
