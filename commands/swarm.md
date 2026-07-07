---
description: "Start Swarm Research in current session"
argument-hint: "PROMPT [--mode normal|goal|loop] [--max-iterations N] [--completion-promise TEXT]"
allowed-tools: ["*"]
---
# Swarm Command

Execute the setup script to initialize the Swarm Research:

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-swarm.sh" $ARGUMENTS
```

调用 `swarm:swarm-agent` skill处理任务

⚠️ 明确告诉用户：**一旦启用goal 和 loop模式 ，正常结束都会被拦截**；中途停止请运行 `/swarm:swarm-cancel`。
