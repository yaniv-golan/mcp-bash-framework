# Notification Architecture Fix Plan

## Problem Statement

The MCP server emits spurious `notifications/*/list_changed` notifications on fresh sessions, even when the registry content hasn't actually changed between requests.

### Evidence

Testing with a fresh workspace shows excessive notifications:

```bash
# Fresh session test
rm -rf /tmp/mcp-test && mkdir -p /tmp/mcp-test/{tools,resources,prompts,server.d}
MCPBASH_PROJECT_ROOT=/tmp/mcp-test ./bin/mcp-bash << 'EOF' | grep -c "list_changed"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"l1","method":"tools/list"}
{"jsonrpc":"2.0","id":"l2","method":"tools/list"}
EOF
# Result: 9-21 notifications instead of expected 3 (one initial triplet)
```

With cached session (re-running same test):
```bash
# Result: 0 notifications (correct behavior after partial fix)
```

### Root Cause Analysis

The current notification system uses boolean `*_CHANGED` flags:

```bash
# In lib/tools.sh, lib/resources.sh, lib/prompts.sh
MCP_TOOLS_CHANGED=false  # Global flag

# Set to true when hash differs
if [ "${previous_hash}" != "${MCP_TOOLS_REGISTRY_HASH}" ]; then
    MCP_TOOLS_CHANGED=true
fi

# Consumed and reset
mcp_tools_consume_notification() {
    if [ "${MCP_TOOLS_CHANGED}" = true ]; then
        MCP_TOOLS_CHANGED=false
        printf '{"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{}}'
    fi
}
```

**The Problem Flow:**

1. Request 1 (`initialized`): 
   - Poll runs, `previous_hash=""`, scan produces `hash="abc"`, `CHANGED=true`
   - Notification emitted, `CHANGED=false`

2. Request 2 (`tools/list`, ~1 second later):
   - Poll runs (different second, so `mcp_core_poll_registries_once` allows it)
   - `mcp_tools_poll()` TTL check: `now - LAST_SCAN < 5` → NO refresh (correct)
   - But `mcp_resources_poll()` or `mcp_prompts_poll()` might trigger refresh
   - Or fastpath check fails → rescan → `CHANGED=true` again

3. The partial fix (commit 08053e4) addresses this by loading `previous_hash` from cache:
   ```bash
   if [ -z "${previous_hash}" ] && [ -f "${MCP_TOOLS_REGISTRY_PATH}" ]; then
       previous_hash="$("${MCPBASH_JSON_TOOL_BIN}" -r '.hash // empty' ...)
   fi
   ```

4. **Remaining issue**: On fresh sessions, multiple poll cycles can occur before state stabilizes, each potentially triggering notifications.

## Proposed Solution

### Architecture Change: Hash-Based Notification Tracking

Instead of boolean flags, track the **last notified hash** for each registry:

```bash
# New approach
MCP_TOOLS_LAST_NOTIFIED_HASH=""  # Hash that was last notified

mcp_tools_consume_notification() {
    local current_hash="${MCP_TOOLS_REGISTRY_HASH}"
    
    # Only emit if hash changed AND we haven't notified for this hash
    if [ -n "${current_hash}" ] && [ "${current_hash}" != "${MCP_TOOLS_LAST_NOTIFIED_HASH}" ]; then
        MCP_TOOLS_LAST_NOTIFIED_HASH="${current_hash}"
        printf '{"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{}}'
    else
        printf ''
    fi
}
```

### Benefits

1. **Idempotent**: Multiple consume calls for the same hash produce only ONE notification
2. **No race conditions**: Even if multiple poll cycles run, notification only fires once per unique hash
3. **Simpler logic**: No need to track `*_CHANGED` flags in refresh functions
4. **Self-healing**: If state gets corrupted, the next unique hash triggers notification

### Implementation Plan

#### Phase 1: Add Last-Notified Hash Variables

**Files to modify:**
- `lib/tools.sh`
- `lib/resources.sh`
- `lib/prompts.sh`

**Changes:**

```bash
# Add new variable (near existing MCP_TOOLS_CHANGED)
MCP_TOOLS_LAST_NOTIFIED_HASH=""
```

#### Phase 2: Modify consume_notification Functions

**Before:**
```bash
mcp_tools_consume_notification() {
    if [ "${MCP_TOOLS_CHANGED}" = true ]; then
        MCP_TOOLS_CHANGED=false
        printf '{"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{}}'
    else
        printf ''
    fi
}
```

**After:**
```bash
mcp_tools_consume_notification() {
    local current_hash="${MCP_TOOLS_REGISTRY_HASH}"
    
    # Skip if no hash yet (not initialized)
    if [ -z "${current_hash}" ]; then
        printf ''
        return 0
    fi
    
    # Skip if already notified for this hash
    if [ "${current_hash}" = "${MCP_TOOLS_LAST_NOTIFIED_HASH}" ]; then
        printf ''
        return 0
    fi
    
    # Emit notification and record hash
    MCP_TOOLS_LAST_NOTIFIED_HASH="${current_hash}"
    printf '{"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{}}'
}
```

#### Phase 3: Remove *_CHANGED Flag Logic

Remove from refresh functions:
```bash
# REMOVE these lines from mcp_tools_refresh_registry, etc:
if [ "${previous_hash}" != "${MCP_TOOLS_REGISTRY_HASH}" ]; then
    MCP_TOOLS_CHANGED=true
fi
```

Also remove:
- `MCP_TOOLS_CHANGED=false` variable declarations
- Any references to `MCP_TOOLS_CHANGED` in tests

#### Phase 4: Handle Initial State

On first poll, `MCP_TOOLS_LAST_NOTIFIED_HASH=""` and `MCP_TOOLS_REGISTRY_HASH` will be set to actual hash. This correctly triggers ONE notification.

On subsequent polls (same hash), notification is suppressed.

#### Phase 5: Update Tests

Tests that explicitly check for `list_changed` notifications may need adjustment:
- `test/integration/test_registry_refresh.sh` - verify single notification per change
- Any tests counting notifications

### Edge Cases

1. **Server restart**: `LAST_NOTIFIED_HASH` resets to empty, causing one notification on reconnect. This is **correct behavior** per MCP spec.

2. **Actual content change**: New scan produces new hash → notification fires. Correct.

3. **Multiple rapid rescans (same content)**: All produce same hash → only first notifies. Correct.

4. **Cache file corruption**: Hash changes → notification fires. Self-healing.

### Rollback Plan

If issues arise, the old `*_CHANGED` flag approach can be restored by:
1. Reverting the consume_notification changes
2. Re-adding the `*_CHANGED=true` logic in refresh functions
3. Keeping the partial fix (loading from cache) as a safety net

### Testing Strategy

1. **Fresh session test**: Should see exactly 3 notifications (one triplet) on init
2. **Repeated requests**: Should see 0 additional notifications
3. **Actual change test**: Modify registry, should see exactly 3 new notifications
4. **Reconnection test**: New session should see 3 notifications (correct)

### Timeline

- Phase 1-3: ~1 hour implementation
- Phase 4: ~30 min edge case handling  
- Phase 5: ~1 hour test updates
- Total: ~2.5 hours

### Files Affected

| File | Changes |
|------|---------|
| `lib/tools.sh` | Add `LAST_NOTIFIED_HASH`, modify `consume_notification`, remove `CHANGED` logic |
| `lib/resources.sh` | Same as above |
| `lib/prompts.sh` | Same as above |
| `test/integration/test_registry_refresh.sh` | Verify notification counts |

### Success Criteria

1. Fresh session: exactly 3 `list_changed` notifications (one per registry type)
2. Subsequent requests in same session: 0 spurious notifications
3. All existing tests pass
4. MCP Inspector shows stable notification behavior

---

## Review Feedback & Revisions (2024-11-28)

### Issue 1: Protocol Guard Breaks Hash Tracking

**Reviewer observation**: Hash-based consume logic doesn't consider the protocol guard in `mcp_core_emit_registry_notifications`. When `listChanged` is suppressed for protocol 2025-03-26, the plan would still advance `*_LAST_NOTIFIED_HASH` when notifications are dropped.

**Evidence** (from `lib/core.sh` lines 909-947):
```bash
mcp_core_emit_registry_notifications() {
    local allow_list_changed="true"
    case "${MCPBASH_NEGOTIATED_PROTOCOL_VERSION:-${MCPBASH_PROTOCOL_VERSION}}" in
    2025-03-26)
        allow_list_changed="false"
        ;;
    esac
    # ...
    if [ "${allow_list_changed}" = true ]; then
        note="$(mcp_tools_consume_notification)"
        # emit...
    else
        mcp_tools_consume_notification >/dev/null  # ← Still calls consume!
    fi
}
```

**Impact**: A client negotiating 2025-03-26 would "consume" the hash without actually receiving the notification. If the same process later serves a client that allows `listChanged`, it would never receive the initial triplet.

**Fix**: Modify `consume_notification` to accept a parameter indicating whether to actually update state:

```bash
# Updated signature
mcp_tools_consume_notification() {
    local actually_emit="${1:-true}"
    local current_hash="${MCP_TOOLS_REGISTRY_HASH}"
    
    if [ -z "${current_hash}" ]; then
        printf ''
        return 0
    fi
    
    if [ "${current_hash}" = "${MCP_TOOLS_LAST_NOTIFIED_HASH}" ]; then
        printf ''
        return 0
    fi
    
    # Only update state if we're actually emitting
    if [ "${actually_emit}" = "true" ]; then
        MCP_TOOLS_LAST_NOTIFIED_HASH="${current_hash}"
        printf '{"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{}}'
    else
        printf ''  # Notification would fire, but suppressed by protocol
    fi
}
```

And update `mcp_core_emit_registry_notifications`:
```bash
if [ "${allow_list_changed}" = true ]; then
    note="$(mcp_tools_consume_notification true)"
    # emit...
else
    # Don't consume, just skip - leave state for future clients
    :
fi
```

### Issue 2: Double-Refresh Path Causes Redundant Work

**Reviewer observation**: The plan only dedupes emissions; it doesn't address the double-refresh path. List handlers directly call refresh, then the poll runs again after dispatch.

**Evidence** (from `lib/tools.sh` line 633-643):
```bash
mcp_tools_list() {
    local limit="$1"
    local cursor="$2"
    # ...
    mcp_tools_refresh_registry || {  # ← Direct refresh in handler
```

And from `lib/core.sh` (dispatch loop):
```bash
# After handler completes:
mcp_core_emit_registry_notifications  # ← Triggers poll → potentially another refresh
```

**Impact**: 
- `register.sh` may execute twice per request (once in handler, once in poll)
- Non-deterministic scripts can churn hashes and emit spurious notifications
- Wasted CPU/IO on redundant scans

**Fix Option A - Share TTL Guard** (REJECTED):

```bash
# Would skip refresh_registry entirely if TTL not expired
if (( now - MCP_TOOLS_LAST_SCAN >= MCP_TOOLS_TTL )); then
    mcp_tools_refresh_registry || { ... }
fi
```

⚠️ **Problem**: This skips the entire `refresh_registry` call, which also skips `register.sh` execution. But `register.sh` has its **own separate TTL** (`MCPBASH_REGISTER_TTL`, default 5s) checked inside `mcp_registry_register_apply`. Gating the outer call would break users who:
- Set a shorter `MCPBASH_REGISTER_TTL` than `MCP_TOOLS_TTL`
- Rely on per-request `register.sh` execution for dynamic registrations

**Fix Option B - Reuse Polled State** (REJECTED):

```bash
# Would only refresh if cache file missing
if [ ! -f "${MCP_TOOLS_REGISTRY_PATH}" ]; then
    mcp_tools_refresh_registry || { ... }
fi
```

⚠️ **Problem**: Same issue - skips `register.sh` execution after initial cache is created.

**Fix Option C - Dedupe at Notification Level Only** (RECOMMENDED):

Instead of preventing double-refresh at the call site, accept that both paths may run `refresh_registry`, but ensure the **notification deduplication** (via `LAST_NOTIFIED_HASH`) prevents spurious emissions. The hash-based tracking already handles this:

```bash
# Both handler and poll may call refresh_registry
# But only ONE notification fires per unique hash
mcp_tools_consume_notification() {
    if [ "${current_hash}" = "${MCP_TOOLS_LAST_NOTIFIED_HASH}" ]; then
        printf ''  # Already notified for this hash
        return 0
    fi
    # ...
}
```

**Rationale**: The core issue is spurious *notifications*, not redundant *refreshes*. While double-refresh is wasteful, it's not incorrect. Changing refresh behavior risks breaking existing `register.sh` workflows. The hash-based dedup solves the notification problem without changing refresh semantics.

**Future optimization**: If profiling shows double-refresh is a performance issue, add a `MCP_TOOLS_LAST_REFRESH_REQUEST_ID` check that skips refresh if same request already triggered it. This is orthogonal to the notification fix.

### Issue 3: Testing Plan Gaps

**Reviewer observation**: Testing plan misses the reported repro and the protocol-2025-03-26 case.

**Current test coverage** (grep for 2025-03-26):
```bash
test/integration/test_minimal_mode.sh:19:...protocolVersion":"2025-03-26"
test/integration/test_minimal_mode.sh:38:assert_eq "2025-03-26" ...
```
Only verifies negotiation, not notification suppression.

**Missing tests to add**:

1. **Fast sequence repro** (`test/integration/test_registry_refresh.sh`):
```bash
test_fast_sequence_notification_count() {
    # The exact repro from the bug report
    # Set up a workspace with at least one tool to ensure registries exist
    local test_dir
    test_dir="$(mktemp -d)"
    mkdir -p "${test_dir}/tools"
    cat > "${test_dir}/tools/test_tool.sh" << 'TOOL'
#!/usr/bin/env bash
# @describe A test tool
echo "ok"
TOOL
    chmod +x "${test_dir}/tools/test_tool.sh"
    
    local count
    count=$(MCPBASH_PROJECT_ROOT="${test_dir}" ./bin/mcp-bash << 'EOF' 2>/dev/null | grep -c "list_changed"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"l1","method":"tools/list"}
{"jsonrpc":"2.0","id":"l2","method":"tools/list"}
EOF
    )
    
    rm -rf "${test_dir}"
    
    # With registries present, expect exactly 3 notifications (one triplet)
    # NOT 0 (that would mean notifications are broken)
    # NOT >3 (that would mean spurious notifications)
    assert_eq 3 "${count}" "Fast sequence should produce exactly one triplet of notifications"
}
```

2. **Protocol 2025-03-26 suppression** (`test/integration/test_minimal_mode.sh`):
```bash
test_old_protocol_suppresses_list_changed() {
    # Set up workspace with tools to ensure notifications WOULD fire on newer protocol
    local test_dir
    test_dir="$(mktemp -d)"
    mkdir -p "${test_dir}/tools"
    cat > "${test_dir}/tools/test_tool.sh" << 'TOOL'
#!/usr/bin/env bash
# @describe A test tool
echo "ok"
TOOL
    chmod +x "${test_dir}/tools/test_tool.sh"
    
    local count
    count=$(MCPBASH_PROJECT_ROOT="${test_dir}" ./bin/mcp-bash << 'EOF' 2>/dev/null | grep -c "list_changed"
{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-03-26"}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":"l1","method":"tools/list"}
EOF
    )
    
    rm -rf "${test_dir}"
    
    assert_eq 0 "${count}" "Protocol 2025-03-26 should suppress list_changed notifications"
}
```

3. **Protocol suppression doesn't call consume** (`test/unit/notification.bats`):

> ⚠️ **Architectural note**: Success criterion #4 from the original plan ("hash state preserved when suppressed") is **not testable across processes** because `*_LAST_NOTIFIED_HASH` is in-memory only. However, in stdio mode, each `./bin/mcp-bash` process handles exactly ONE client session (reads stdin until EOF, then exits). There is no scenario where the same process serves multiple protocol versions. Therefore, criterion #4 is architecturally satisfied by the single-session constraint.
>
> If HTTP/SSE multi-session support is added in the future, this would need revisiting with either:
> - Persisted notification state, or
> - Same-process multi-connection testing

The unit test verifies the core invariant: `consume_notification` with `actually_emit=false` returns empty and does NOT update state:

```bash
@test "consume_notification with actually_emit=false does not update state" {
    source lib/tools.sh
    
    # Simulate a registry with a hash
    MCP_TOOLS_REGISTRY_HASH="abc123"
    MCP_TOOLS_LAST_NOTIFIED_HASH=""
    
    # Consume with emit=false (protocol suppression)
    result="$(mcp_tools_consume_notification false)"
    
    # Should return empty (no notification)
    [ -z "${result}" ]
    
    # State should NOT be updated
    [ "${MCP_TOOLS_LAST_NOTIFIED_HASH}" = "" ]
    
    # Now consume with emit=true
    result="$(mcp_tools_consume_notification true)"
    
    # Should return notification JSON
    [[ "${result}" == *"list_changed"* ]]
    
    # State SHOULD be updated
    [ "${MCP_TOOLS_LAST_NOTIFIED_HASH}" = "abc123" ]
}
```

---

## Revised Implementation Plan

### Phase 1: Protocol-Aware Consume (1 hour)

Modify `consume_notification` to accept `actually_emit` parameter:
- `lib/tools.sh` - `mcp_tools_consume_notification()`
- `lib/resources.sh` - `mcp_resources_consume_notification()`
- `lib/prompts.sh` - `mcp_prompts_consume_notification()`

Update `lib/core.sh` `mcp_core_emit_registry_notifications()` to:
- Pass `true` when `allow_list_changed=true`
- Skip consume entirely when `allow_list_changed=false`

### Phase 2: Hash-Based Tracking (1 hour)

Replace `*_CHANGED` flags with `*_LAST_NOTIFIED_HASH`:
- Add new variables
- Implement hash comparison in consume functions
- Remove `*_CHANGED` flag logic from refresh functions

### Phase 3: Testing (1.5 hours)

Add new tests:
1. Fast sequence notification count (exact repro with workspace setup) — integration test
2. Protocol 2025-03-26 suppresses `list_changed` — integration test
3. `consume_notification(false)` does not update state — unit test (`test/unit/notification.bats`)

**Review existing tests**: Two files reference `list_changed` notifications:
- `test/integration/test_tools_schema.sh` — asserts `list_changed` fires after tool modification (≥1)
- `test/integration/test_prompts.sh` — asserts `list_changed` fires after prompt modification

These tests verify notifications fire when content *actually changes*, which the fix preserves. They should continue to pass without modification. Verify during implementation.

**Note on double-refresh**: The fix does NOT prevent redundant `refresh_registry` calls (handler path + poll path). This is intentional:
- The core issue is spurious *notifications*, not redundant *refreshes*
- Hash-based dedup at notification layer solves the observed bug
- Changing refresh call patterns would alter `register.sh` execution semantics
- **Accepted risk**: If `register.sh` has side effects beyond registry content (logging, external calls, state mutations), those side effects will execute redundantly. This matches current behavior and is preserved intentionally—no mitigation is attempted or planned for this fix.

### Revised Timeline

| Phase | Time | Description |
|-------|------|-------------|
| 1 | 1 hour | Protocol-aware consume |
| 2 | 1 hour | Hash-based tracking |
| 3 | 1.5 hours | Testing |
| **Total** | **3.5 hours** | |

### Revised Files Affected

| File | Changes |
|------|---------|
| `lib/tools.sh` | `LAST_NOTIFIED_HASH`, consume param |
| `lib/resources.sh` | Same as above |
| `lib/prompts.sh` | Same as above |
| `lib/core.sh` | Skip consume when protocol suppresses |
| `test/integration/test_registry_refresh.sh` | Fast sequence test |
| `test/integration/test_minimal_mode.sh` | Append new protocol suppression test; existing negotiation assertions remain unchanged |
| `test/unit/notification.bats` | Unit test for consume_notification behavior (new file) |

### Revised Success Criteria

1. Fresh session: exactly 3 `list_changed` notifications (one per registry type)
2. Subsequent requests in same session: 0 spurious notifications
3. Protocol 2025-03-26: 0 `list_changed` notifications
4. `consume_notification(false)` does not update `LAST_NOTIFIED_HASH` (unit test)
5. All existing tests pass
6. MCP Inspector shows stable notification behavior

**Architectural constraint**: Criterion #4 ("hash state preserved when suppressed across sessions") is not applicable in stdio mode because each process handles exactly one client session. The single-session constraint inherently satisfies this requirement. The unit test verifies the function-level invariant.

**Explicitly NOT in scope** (deferred):
- Double-refresh optimization (would change `register.sh` execution semantics)
- Persistent notification state (only needed if multi-session HTTP/SSE support is added)

