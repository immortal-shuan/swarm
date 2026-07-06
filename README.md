# swarm

多视角研究蜂群（Claude Code 插件）。按 `.claude/rules/roles.md` 启动一支由理论研究者、实践工程师、关联领域研究者、泛领域研究者组成的子代理蜂群，从多个视角研究一个任务，综合发现后**落地实现**。

## 三种模式

| 模式 | 行为 |
|------|------|
| `normal`（默认） | 跑一遍蜂群 → 综合 → 落地实现；不武装 hook |
| `goal` | **arm 脚本武装 + Stop hook 跨回合驱动**：开局陈述**核心目标与可检验成功标准**，每轮用 `swarm-verifier` **校验达成**；未达成 hook 带入下一轮补做，**达成即停**（或达上限）|
| `loop` | goal 的超集：达成后继续由 hook 驱动，持续应用"超出目标的优化"，直到**收敛**或达上限 |

## 安装 / 加载

本地开发加载（无需 marketplace）：

```bash
claude --plugin-dir ./swarm
```

校验格式：

```bash
claude plugin validate ./swarm
```

修改文件后在会话内热重载：`/reload-plugins`

## 用法

插件命令带命名空间前缀 `swarm:`（交互模式下输入 `/swarm` 会自动补全）：

```
/swarm:swarm <任务描述>                                  # normal
/swarm:swarm <任务描述> --mode goal                      # goal
/swarm:swarm <任务描述> --mode loop                      # loop
/swarm:swarm <任务描述> --mode loop --max-iterations 2   # 限定循环轮次
/swarm:swarm-cancel                                      # 终止 loop
/swarm:swarm-help                                        # 帮助
```

参数（goal / loop 通用）：

- `--max-iterations N` — 最大轮次，默认 `20`，`0` = 无限（危险）
- `--completion-promise TEXT` — 达成 / 收敛承诺短语，默认 goal=`SWARM GOAL ACHIEVED`、loop=`SWARM CONVERGED`

## 组成

```
swarm/
├── .claude-plugin/plugin.json        # manifest
├── commands/
│   ├── swarm.md                      # /swarm 入口，解析 --mode，编排三模式
│   ├── swarm-cancel.md               # /swarm-cancel 终止 goal/loop
│   └── swarm-help.md                 # /swarm-help
├── skills/swarm-agent/SKILL.md       # 蜂群引擎（与模式无关）：读 roles→拆角度→并行启代理→综合→落地
├── agents/
│   ├── swarm-theorist.md             # 理论研究者（5-10）
│   ├── swarm-engineer.md             # 实践工程师（3-8）
│   ├── swarm-adjacent.md             # 关联/可迁移领域研究者（3-6）
│   ├── swarm-scout.md                # 泛领域搜索研究者（2-3）
│   └── swarm-verifier.md             # 目标校验员（goal/loop）
├── scripts/
│   └── swarm-arm.sh                  # goal/loop 启动脚本：任务经 stdin 读入，写出状态文件
├── hooks/
│   ├── hooks.json                    # 注册 Stop hook
│   └── swarm-loop-stop-hook.sh       # goal/loop：拦截退出、判断达成/收敛、重注入迭代 prompt
└── (goal/loop 状态文件运行时生成于项目的 .claude/swarm-loop.local.md)
```

数据流：`/swarm:swarm` → 命令正文由模型解析出 mode/任务（不经 shell，任务文本含特殊字符也安全）→ normal 直接跑蜂群；**goal/loop 则由模型调 `scripts/swarm-arm.sh`（任务经 stdin 传入，仍不经 shell 分词）写出 `.claude/swarm-loop.local.md`，再由 Stop hook 跨回合驱动**——每回合判断达成/收敛，未达成就重注入迭代 prompt 续跑 → 每轮 `swarm:swarm-agent` skill 跑蜂群（用 `Task` 工具并行启 `swarm:swarm-*` 子代理）配合 `swarm-verifier` 校验 → 主会话综合并落地。

## 自定义角色

蜂群读取项目根的 `.claude/rules/roles.md`（存在则以它为准）来决定四类角色的数量区间；不存在时用 skill 内置默认。要调整规模/角色，直接编辑该文件即可，无需改插件。

## ⚠️ 成本与安全

- 子代理**继承当前会话模型**（如 Opus）。一遍蜂群启 **13-27 个子代理**，token 成本高。
- **goal / loop 逐轮叠加**成本：默认 `--max-iterations 20`；loop 优化轮用轻量小蜂群；主要靠输出承诺提前结束。
- **goal 与 loop 武装后正常结束都会被拦截**——只能用 `/swarm:swarm-cancel`、达成/收敛承诺或达最大轮次停止。
- 研究子代理只读，统一由主会话落地写文件，避免并发写冲突。
- `commands/swarm.md` 默认授予较宽的 `Bash`（为落地实现/自测，并用于调 arm 脚本）。如需收紧，可改其 `allowed-tools`。
- 与 `ralph-loop` 的 Stop hook 互不干扰（各用各的状态文件）。
