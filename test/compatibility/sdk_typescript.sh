#!/usr/bin/env bash
# Compatibility: verify handshake using a minimal TypeScript (ts-node) client.
# Skips gracefully when Node/npx/ts-node are unavailable.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

if [ "${MCPBASH_RUN_SDK_TYPESCRIPT:-0}" != "1" ]; then
	printf 'SKIP: sdk_typescript (set MCPBASH_RUN_SDK_TYPESCRIPT=1 to enable)\n'
	exit 0
fi

if ! command -v node >/dev/null 2>&1; then
	printf 'SKIP: sdk_typescript (node missing)\n'
	exit 0
fi

if ! command -v npx >/dev/null 2>&1; then
	printf 'SKIP: sdk_typescript (npx missing)\n'
	exit 0
fi

if ! npx -y ts-node --version >/dev/null 2>&1; then
	printf 'SKIP: sdk_typescript (ts-node unavailable)\n'
	exit 0
fi

test_create_tmpdir
WORKSPACE="${TEST_TMPDIR}/workspace"
test_stage_workspace "${WORKSPACE}"

TS_SCRIPT="${WORKSPACE}/client.ts"
cat >"${TS_SCRIPT}" <<'TS'
import { createInterface } from 'readline';
import { spawn } from 'child_process';

function send(proc: ReturnType<typeof spawn>, msg: object) {
	proc.stdin.write(JSON.stringify(msg) + '\n');
}

async function readUntil(rl: ReturnType<typeof createInterface>, predicate: (msg: any) => boolean, timeoutMs = 5000) {
	return new Promise<any>((resolve, reject) => {
		const timer = setTimeout(() => reject(new Error('timeout waiting for message')), timeoutMs);
		rl.on('line', (line) => {
			let parsed: any;
			try {
				parsed = JSON.parse(line);
			} catch (err) {
				clearTimeout(timer);
				reject(new Error(`invalid JSON from server: ${line}`));
				return;
			}
			if (predicate(parsed)) {
				clearTimeout(timer);
				resolve(parsed);
			}
		});
	});
}

async function main() {
	const server = spawn('./bin/mcp-bash', {
		env: {
			...process.env,
			MCPBASH_PROJECT_ROOT: process.env.MCPBASH_PROJECT_ROOT || process.cwd(),
		},
		stdio: ['pipe', 'pipe', 'inherit'],
	});

	const rl = createInterface({ input: server.stdout });

	send(server, { jsonrpc: '2.0', id: 'init', method: 'initialize', params: {} });
	const init = await readUntil(rl, (m) => m.id === 'init');
	if (!init.result || init.result.protocolVersion !== '2025-11-25') {
		throw new Error(`unexpected init response: ${JSON.stringify(init)}`);
	}

	send(server, { jsonrpc: '2.0', method: 'notifications/initialized' });
	send(server, { jsonrpc: '2.0', id: 'shutdown', method: 'shutdown' });
	const shutdown = await readUntil(rl, (m) => m.id === 'shutdown');
	if (!shutdown.result) {
		throw new Error(`missing shutdown result: ${JSON.stringify(shutdown)}`);
	}
	send(server, { jsonrpc: '2.0', id: 'exit', method: 'exit' });

	await new Promise<void>((resolve) => {
		server.on('exit', () => resolve());
	});
}

main().catch((err) => {
	console.error(err);
	process.exit(1);
});
TS

(
	cd "${WORKSPACE}"
	TS_NODE_TRANSPILE_ONLY=1 TS_NODE_COMPILER_OPTIONS='{"module":"CommonJS","moduleResolution":"node"}' \
		MCPBASH_PROJECT_ROOT="${WORKSPACE}" npx -y ts-node "${TS_SCRIPT}"
)

printf '✅ sdk_typescript\n'
