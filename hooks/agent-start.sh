#!/bin/bash

set -euo pipefail

session_id=${CLAUDE_CODE_SESSION_ID:-}
STATE_FILE=".claude/.swarm/state-$session_id.local.md"

# 当前session的状态文件损坏
if [[ -z "$SWARM_STATE_FILE" ]]; then
  echo "⚠️  Swarm state file corrupted, '$STATE_FILE' not found" >&2
  exit 0
fi

# 提取两个"---"之间的内容，及需要的subagents参数值
FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$SWARM_STATE_FILE")
SUBAGENTS=$(echo "$FRONTMATTER" | grep '^subagents:' | sed 's/subagents: *//')

# Not converged -> continue with the SAME per-iteration prompt
TEMP_SUBAGENTS=$((SUBAGENTS + 1))

# 更新iteration的值
TEMP_FILE="${SWARM_STATE_FILE}.tmp.$$"
sed "s/^subagents: .*/subagents: $TEMP_SUBAGENTS/" "$SWARM_STATE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$SWARM_STATE_FILE"

exit 0
