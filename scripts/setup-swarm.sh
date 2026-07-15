#!/bin/bash

set -euo pipefail

# Parse arguments
PROMPT_PARTS=()
MODE="normal"
MAX_ITERATIONS=20
COMPLETION_PROMISE=""

session_id=${CLAUDE_CODE_SESSION_ID:-}
STATE_FILE=".claude/.swarm/state-$session_id.local.md"

# Parse options and positional arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      cat << 'HELP_EOF'
Output the following content completely, without modification or summary.

Swarm Research: Arrange multiple agents to advance the mission in parallel.

USAGE:
  /swarm:swarm [PROMPT...] [OPTIONS]

ARGUMENTS:
  PROMPT...    Initial prompt to start the loop (can be multiple words without quotes)

OPTIONS:
  --mode <normal|goal|loop>      mode selection, goal: work until the goal is achieved, loop: optimizes until no further optimization is possible, normal: single-round session(default)
  --max-iterations <n>             Maximum iterations before auto-stop (default: 20; 0 represents infinity)
  --completion-promise '<text>'    Promise phrase (USE QUOTES for multi-word)
  -h, --help                       Show this help message

DESCRIPTION:
  Starts a Swarm Research in your CURRENT session. It orchestrates multiple agents to advance the mission in parallel. When the mode is goal or loop, The stop hook prevents exit and feeds your output back as input until completion or iteration limit.

  Use this for:
  - Complex or multi-step tasks
  - Time-consuming tasks that require multiple trials
  - Tasks requiring multiple characters or perspectives to complete

EXAMPLES:
  /swarm:swarm Give me an innovative idea of time series forecasting
  /swarm:swarm Give me an innovative idea of time series forecasting --mode goal
  /swarm:swarm Give me an innovative idea of time series forecasting --mode loop --max-iterations 20
  /swarm:swarm Give me an innovative idea of time series forecasting --mode goal --completion-promise 'SWARM GOAL ACHIEVED'

STOPPING:
  reaching --max-iterations or detecting --completion-promise
  run `/swarm:swarm-cancel`

MONITORING:
  head -10 .claude/swarm-state.local.md
HELP_EOF
      exit 0
      ;;
    --mode)
      if [[ -z "${2:-}" ]]; then
        echo "❌ Error: --mode requires one of the following: normal, goal, or loop" >&2
        echo "" >&2
        echo "   Valid examples:" >&2
        echo "     --mode normal" >&2
        echo "     --mode goal" >&2
        echo "     --mode loop" >&2
        echo "" >&2
        echo "   You provided: --max-iterations (with no one of normal, goal, or loop)" >&2
        exit 1
      fi
      if ! [[ "$2" =~ ^(normal|loop|goal)$ ]]; then
        echo "❌ Error: --mode requires one of the following: normal, goal, or loop" >&2
        echo "" >&2
        echo "   Valid examples:" >&2
        echo "     --mode normal" >&2
        echo "     --mode goal" >&2
        echo "     --mode loop" >&2
        echo "" >&2
        echo "   You provided: --max-iterations (with no one of normal, goal, or loop)" >&2
        exit 1
      fi
      MODE="$2"
      shift 2
      ;;
    --max-iterations)
      if [[ -z "${2:-}" ]]; then
        echo "❌ Error: --max-iterations requires a number argument" >&2
        echo "" >&2
        echo "   Valid examples:" >&2
        echo "     --max-iterations 10" >&2
        echo "     --max-iterations 50" >&2
        echo "     --max-iterations 0  (unlimited)" >&2
        echo "" >&2
        echo "   You provided: --max-iterations (with no number)" >&2
        exit 1
      fi
      if ! [[ "$2" =~ ^[0-9]+$ ]]; then
        echo "❌ Error: --max-iterations must be a positive integer or 0, got: $2" >&2
        echo "" >&2
        echo "   Valid examples:" >&2
        echo "     --max-iterations 10" >&2
        echo "     --max-iterations 50" >&2
        echo "     --max-iterations 0  (unlimited)" >&2
        echo "" >&2
        echo "   Invalid: decimals (10.5), negative numbers (-5), text" >&2
        exit 1
      fi
      MAX_ITERATIONS="$2"
      shift 2
      ;;
    --completion-promise)
      if [[ -z "${2:-}" ]]; then
        echo "❌ Error: --completion-promise requires a text argument" >&2
        echo "" >&2
        echo "   Valid examples:" >&2
        echo "     --completion-promise 'DONE'" >&2
        echo "     --completion-promise 'TASK COMPLETE'" >&2
        echo "     --completion-promise 'SWARM GOAL ACHIEVED'" >&2
        echo "" >&2
        echo "   You provided: --completion-promise (with no text)" >&2
        echo "" >&2
        echo "   Note: Multi-word promises must be quoted!" >&2
        exit 1
      fi
      COMPLETION_PROMISE="$2"
      shift 2
      ;;
    *)
      # Non-option argument - collect all as prompt parts
      PROMPT_PARTS+=("$1")
      shift
      ;;
  esac
done

PROMPT="${PROMPT_PARTS[*]:-}"

# 任务描述prompt不能为空
if [[ -z "$PROMPT" ]]; then
  echo "❌ Error: No prompt provided" >&2
  echo "" >&2
  echo "   Swarm needs a task description to work on." >&2
  echo "" >&2
  echo "   Examples:" >&2
  echo "     /swarm:swarm Give me an innovative idea of time series forecasting" >&2
  echo "     /swarm:swarm Give me an innovative idea of time series forecasting --mode goal" >&2
  echo "     /swarm:swarm Give me an innovative idea of time series forecasting --mode loop --completion-promise 'SWARM LOOP ACHIEVED'" >&2
  echo "" >&2
  echo "   For all options: /swarm:swarm --help" >&2
  exit 1
fi

# 给completion-promise添加默认字段
if [[ -z "$COMPLETION_PROMISE" ]]; then
  if [[ "$MODE" == "goal" ]]; then
    COMPLETION_PROMISE="SWARM GOAL ACHIEVED"
  else
    COMPLETION_PROMISE="SWARM CONVERGED"
  fi
fi

# 如果是normal模式，则正常退出
if [[ "$MODE" == "normal" ]]; then
  echo "✅ In normal mode, `swarm:swarm-agent` is directly invoked to perform the task: $PROMPT"
  exit 0
fi

# 判定当前项目是否已有活跃循环,若有，则拒绝
if [[ -f "$STATE_FILE" ]]; then
  echo "⚠️  You cannot run multiple swarm goal or loop modes within the same project." >&2
  echo "⚠️  The current project has an active swarm (goal/loop mode)." >&2
  echo "⚠️  Please run `/swarm:swarm-cancel` before attempting to start a new one." >&2
  exit 1
fi

# 进行loop或goal模式的持续运行prompt
if [[ "$MODE" == "goal" ]]; then
  BODY_TEMPLATE=$(cat <<'TEMPLATE_EOF'
# 每一轮迭代请这样做

1. **确立/回顾核心目标与成功标准**：
   - 首轮：用 1-3 句话陈述本任务的**核心目标**，并列出 3-7 条**可检验的成功标准**（明确、可判定），讲给用户听。
   - 后续轮：查看工作区/对话里已有的产出，**对照上一轮 `swarm:swarm-verifier` 指出的缺口**回顾目标与标准。
2. **落地实现**：调用 `swarm:swarm-agent` skill 处理任务——首轮组完整蜂群（拆角度 → 并行启子代理 → 综合 → 落地实现）；后续轮**聚焦缺口**做增量实现。
3. **独立校验**：用 `Task` 工具启动 `swarm:swarm-verifier` 子代理，把「核心目标 + 成功标准 + 已产出的成果/文件」交给它，让它独立判定 PASS / FAIL、逐条给证据并指出缺口。
4. **判定与收敛**：
   - 若 verifier 判 **PASS**（核心目标达成、成功标准全部满足）→ 逐条核对成功标准（✓/✗ + 简要证据）后，在你的**最终输出**里写出 `<promise>@@PROMISE@@</promise>`（**仅在真实 PASS 时**，不得为退出而谎报），结束。
   - 若 verifier 判 **FAIL** → 本轮**不要**输出该标签；简要总结缺口即可，Stop hook 会自动带你进入下一轮继续补做。

> 重要：`<promise>...</promise>` 标签只在**真正达标**时于最终输出写出；举例/解释时**不要**照抄该标签，否则会被 Stop hook 误判为达成而提前结束。
TEMPLATE_EOF
)
else
  BODY_TEMPLATE=$(cat <<'TEMPLATE_EOF'
# 每一轮迭代请这样做

1. 确立/回顾**核心目标**与可检验的**成功标准**（首轮必须明确写出并讲给用户；后续轮对照已有成果回顾）。
2. 自检：成功标准是否**全部满足**（查看你之前在文件/工作区里的成果）？
   - 若**尚未全满足** → 本轮调用 `swarm:swarm-agent` skill 聚焦达成并落地实现，再用 `swarm:swarm-verifier` 子代理校验。
   - 若**已全满足** → 本轮调用一个**轻量** `swarm:swarm-agent`（角色数量取 roles.md 区间低端），寻找并实现一组"超出目标的优化"（性能/健壮性/边界/可读性/可维护性/测试）。
3. 收敛判定：当**核心目标已达成、且确实再无值得投入的优化**时，输出 `<promise>@@PROMISE@@</promise>`（仅在真实成立时，不得为退出而谎报）。

> 重要：`<promise>...</promise>` 标签只在**真正收敛**时于最终输出写出；举例/解释时**不要**照抄该标签，否则会被 Stop hook 误判为收敛而提前结束循环。
TEMPLATE_EOF
)
fi

# 填入实际承诺语
BODY="${BODY_TEMPLATE//@@PROMISE@@/$COMPLETION_PROMISE}"


# 写入状态文件
cat > "$STATE_FILE" <<EOF
---
active: true
mode: $MODE
iteration: 1
phase: decomposition
phase_state: executing
subagents: 0
tools: 0
max_iterations: $MAX_ITERATIONS
completion_promise: $COMPLETION_PROMISE
session_id: ${CLAUDE_CODE_SESSION_ID:-}
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---

$PROMPT
EOF

# 第一轮swarm工作的prompt
cat <<EOF
Task：$PROMPT

该阶段的任务要求是：使用/swarm:swarm-agent 来完成任务
EOF
