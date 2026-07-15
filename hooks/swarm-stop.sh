#!/bin/bash

set -euo pipefail

HOOK_INPUT=$(cat)

session_id=${CLAUDE_CODE_SESSION_ID:-}
STATE_FILE=".claude/.swarm/state-$session_id.local.md"

# 没有活跃的swarm，允许退出
if [[ -z "$SWARM_STATE_FILE" ]]; then
  exit 0
fi

# 提取两个"---"之间的内容
FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$SWARM_STATE_FILE")

# 提取文件状态参数
SUBAGENTS=$(echo "$FRONTMATTER" | grep '^subagents:' | sed 's/subagents: *//')
ITERATION=$(echo "$FRONTMATTER" | grep '^iteration:' | sed 's/iteration: *//')
MAX_ITERATIONS=$(echo "$FRONTMATTER" | grep '^max_iterations:' | sed 's/max_iterations: *//')
COMPLETION_PROMISE=$(echo "$FRONTMATTER" | grep '^completion_promise:' | sed 's/completion_promise: *//' | sed 's/^"\(.*\)"$/\1/')
MODE=$(echo "$FRONTMATTER" | grep '^mode:' | sed 's/mode: *//')


# 判定允许临时的条件
if [ "$SUBAGENTS" -gt 0 ]; then
  SYSTEM_MSG="存在subagents在运行，允许临时stop"
  jq -n \
    --arg msg "$SYSTEM_MSG" \
    '{
      "decision": "approve",
      "systemMessage": $msg
    }'
  exit 0
fi

# 判定ITERATION和MAX_ITERATIONS是否正确
if [[ ! "$ITERATION" =~ ^[0-9]+$ ]]; then
  echo "⚠️  Swarm state file corrupted, iteration is not numeric: '$ITERATION'" >&2
  rm "$SWARM_STATE_FILE"
  exit 0
fi
if [[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
  echo "⚠️  Swarm state file corrupted, max iteration is not numeric: '$MAX_ITERATIONS'" >&2
  rm "$SWARM_STATE_FILE"
  exit 0
fi

# 判定全局停止的条件
# 判断是否达到了最大迭代次数
if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $ITERATION -ge $MAX_ITERATIONS ]]; then
  echo "🛑 Swarm $MODE: max iteration($MAX_ITERATIONS) has been reached"
  rm "$SWARM_STATE_FILE"
  exit 0
fi

# 判断transcript文件，这一块我看不懂，测试下来对流程无影响，保留
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path')
if [[ ! -f "$TRANSCRIPT_PATH" ]]; then
  echo "⚠️  Swarm: Transcript file not found" >&2
  rm "$SWARM_STATE_FILE"
  exit 0
fi
if ! grep -q '"role":"assistant"' "$TRANSCRIPT_PATH"; then
  echo "⚠️  Swarm: No assistant messages found in transcript" >&2
  rm "$SWARM_STATE_FILE"
  exit 0
fi

LAST_LINES=$(grep '"role":"assistant"' "$TRANSCRIPT_PATH" | tail -n 100)
if [[ -z "$LAST_LINES" ]]; then
  echo "⚠️  Swarm: Failed to extract assistant messages" >&2
  rm "$SWARM_STATE_FILE"
  exit 0
fi

set +e
LAST_OUTPUT=$(echo "$LAST_LINES" | jq -rs '
  map(.message.content[]? | select(.type == "text") | .text) | last // ""
' 2>&1)
JQ_EXIT=$?
set -e
if [[ $JQ_EXIT -ne 0 ]]; then
  echo "⚠️  Swarm: Failed to parse assistant message JSON" >&2
  rm "$SWARM_STATE_FILE"
  exit 0
fi

# 检测Completion promise，检测到直接结束，这一段先保留，我不确定后续swarm流程的优化往什么方向走
if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
  PROMISE_TEXT=$(echo "$LAST_OUTPUT" | perl -0777 -pe 's/.*?<promise>(.*?)<\/promise>.*/$1/s; s/^\s+|\s+$//g; s/\s+/ /g' 2>/dev/null || echo "")
  if [[ -n "$PROMISE_TEXT" ]] && [[ "$PROMISE_TEXT" = "$COMPLETION_PROMISE" ]]; then
    if [[ "$MODE" = "goal" ]]; then
      echo "✅ Swarm goal: 检测到 <promise>$COMPLETION_PROMISE</promise>，核心目标达成，结束。"
    else
      echo "✅ Swarm loop: 检测到 <promise>$COMPLETION_PROMISE</promise>，循环收敛结束。"
    fi
    rm "$SWARM_STATE_FILE"
    exit 0
  fi
fi

# Not converged -> continue with the SAME per-iteration prompt
NEXT_ITERATION=$((ITERATION + 1))

# 原始prompt获得
PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$SWARM_STATE_FILE")
if [[ -z "$PROMPT_TEXT" ]]; then
  echo "⚠️  Swarm: State file corrupted or incomplete" >&2
  echo "  File: $SWARM_STATE_FILE" >&2
  echo "  Problem: No prompt text found" >&2
  echo "" >&2
  echo "  This usually means:" >&2
  echo "    • State file was manually edited" >&2
  echo "    • File was corrupted during writing" >&2
  rm "$SWARM_STATE_FILE"
  exit 0
fi

# 更新iteration的值
TEMP_FILE="${SWARM_STATE_FILE}.tmp.$$"
sed "s/^iteration: .*/iteration: $NEXT_ITERATION/" "$SWARM_STATE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$SWARM_STATE_FILE"

if [[ "$MODE" = "goal" ]]; then
  SYSTEM_MSG=$(cat <<EOF
当前阶段的的任务流程是：
检测是否存在正在运行的subagents和后台程序，若存在，提示并未结束
若不存在，使用 /swarm:swarm-verifier 子代理来校验任务的完成情况；
如果校验通过，则直接输出`<promise>$COMPLETION_PROMISE</promise>`，任务结束
校验不通过使用 /swarm:swarm-agent 继续推进并完善
EOF
)
else
  SYSTEM_MSG=$(cat <<EOF
当前阶段的的任务流程是：
使用 /swarm:swarm-verifier 子代理来校验任务的完成情况；
如果校验通过，则直接输出`<promise>$COMPLETION_PROMISE</promise>`，任务结束
校验不通过使用 /swarm:swarm-agent skill继续推进并优化
EOF
)
fi

jq -n \
  --arg prompt "$PROMPT_TEXT" \
  --arg msg "$SYSTEM_MSG" \
  '{
    "decision": "block",
    "reason": $prompt,
    "systemMessage": $msg
  }'

exit 0
