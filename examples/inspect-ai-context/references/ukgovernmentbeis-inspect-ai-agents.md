---
name: Agents — ReAct, Deep Agent, multi-agent, custom, bridge, human, intervention (ACP)
source_id: ukgovernmentbeis-inspect-ai
---

# Agents

The `Agent` protocol is a narrower, more versatile sibling of `Solver`. An agent is an `async def execute(state: AgentState) -> AgentState` wrapped by `@agent`. The same agent instance can play four roles:

1. Top-level `Solver` on a `Task` (via `as_solver`).
2. Standalone callable in a workflow (call `await agent.execute(state)`).
3. Sub-agent in a multi-agent system (delegated to by another agent).
4. A `Tool` exposed to a model (via `as_tool`) — the model "calls" the agent like any other tool.

```python
from inspect_ai.agent import Agent, AgentState, agent
from inspect_ai.model import ChatMessageSystem
from inspect_ai.tool import web_search

@agent
def web_surfer() -> Agent:
    async def execute(state: AgentState) -> AgentState:
        state.messages.append(
            ChatMessageSystem(content="You are an expert at using a web browser.")
        )
        # run tool loop with web_search bound
        ...
        return state
    return execute
```

`AgentState` carries `messages`, `output`, `store`, and the bound tool set — same shape as `TaskState` minus the task-level fields.

## Built-in agents

| Agent | Use when |
|---|---|
| `react()` | Standard ReAct loop. The workhorse for most agentic evals. Configurable system prompt, max iterations, tool set, scorer-integrated stopping criterion. ACP intervention out of the box. |
| `deep_agent()` | Long-horizon work needing subagent delegation, planning, and persistent memory. Implemented under `src/inspect_ai/agent/_deepagent/`. ACP intervention out of the box. |
| `human_agent()` | Replaces the model with a human operator — useful for human baselines on computing/CTF tasks. Surfaces a CLI prompt for each tool call decision. |

Plus two non-Inspect-native bridges:

- **Agent Bridge** (`agent_bridge`) — wraps an external agent framework (LangGraph, etc.) so it can run inside an Inspect task.
- **Inspect SWE** — separate package at `meridianlabs-ai/inspect_swe` that runs Claude Code / Codex CLI / Gemini CLI as agents inside Inspect evaluations.

## ReAct agent — the default

```python
from inspect_ai.agent import react
from inspect_ai.tool import bash, python

solver = react(
    tools=[bash(), python()],
    max_iterations=20,
)
```

ReAct iterates: model generates → tool calls executed → results appended → model generates again. Stops when the model returns a non-tool-call response, when `max_iterations` hits, or when limits trip. The agent's "final answer" is the model's last non-tool message.

Configurable: `prompt` (system message), `tools`, `max_iterations`, `score` (a scorer that can terminate early on success), `attempts` (retry policy when the scorer says fail).

## Deep Agent

`deep_agent()` adds three things over ReAct: a planning tool that lets the agent emit and refine a plan, a memory tool with persistent notes across iterations, and a subagent-delegation tool so the main agent can spawn a sub-task with its own scope. It targets tasks that take dozens to hundreds of model turns — e.g., software engineering, deep research, multi-stage CTF.

## Multi-agent architectures

Two composition patterns:

- **Handoff** — `handoff(agent_b)` becomes a tool on agent_a's tool set. Agent_a calls it; the conversation hands off to agent_b for a turn, then control returns. Use for specialist consultations.
- **As-tool wrapping** — `as_tool(agent_b)` turns agent_b into a sub-call that runs to completion and returns a single result. Use for delegating discrete tasks to specialists.

Pick handoff for back-and-forth collaboration, as_tool for one-shot delegation.

## Agent vs. solver — when to choose which

Solvers are good when the elicitation strategy is task-specific and won't be reused. Agents are good when the same scaffold should plug into multiple tasks or be composed with other agents. If you find yourself writing `as_solver(react(...))` you're at the boundary — using `react()` directly as the `Task(solver=...)` works and is simpler.

## Limits inside agents

`message_limit`, `token_limit`, `time_limit`, `working_limit` apply to agents the same way they apply to solvers. The `suspend_token_limit()` context manager lets you exempt a region of the agent's execution from token accounting — useful when calling a strong grader model that shouldn't count against the agent-under-test's budget.

## Agent Intervention (ACP)

Agent intervention lets a human operator observe a running agent, interrupt it mid-turn, and redirect it with follow-up messages — all faithfully recorded in the transcript. It is built on the [Agent Client Protocol](https://agentclientprotocol.com), so any ACP-speaking client (Inspect's CLI, Zed, a custom client) can attach to a running eval. `react()` and `deep_agent()` support intervention out of the box; custom agents opt in with a small change to their turn loop.

### Enabling and attaching

Start the eval with `--acp-server`, then attach from a second terminal:

```bash
inspect eval terminal_bench_2 --acp-server
inspect acp
```

`inspect acp` shows the running sessions, lets you pick one, and exposes intervention keybindings:

- **Esc** — interrupt the current generation or tool call. Records an `InterruptEvent`.
- **Ctrl+P** — show the active plan and its status.
- **Ctrl+L** — cancel the running tool call only (turn continues).
- **Ctrl+N** — cancel the sample (choose score or error). Records a `SampleLimitEvent` with `type="operator"`.
- **Ctrl+S** — switch to another running sample.

Messages you type land at the start of the agent's next turn as `ChatMessageUser` with `source="operator"`. Everything — interrupt, operator messages, sample cancels — is captured in the Inspect log.

### Remote evals

`inspect acp` defaults to local. For remote, bind a loopback port on the eval host and forward over SSH (the ACP server has no built-in auth, so don't expose the port directly):

```bash
# on the eval host
inspect eval terminal_bench_2 --acp-server 4545
# from local
ssh -L 4545:localhost:4545 user@eval-host
inspect acp --server 127.0.0.1:4545
```

`--acp-server 0.0.0.0:4545` binds non-loopback — trusted networks only.

### Adding ACP to a custom agent

Wrap the turn loop in `agent_channel()` and use `ch.turn_scope()` as the cancel boundary. `AgentInterrupted` signals operator-driven cancel (distinct from hard sample cancels, which propagate as `CancelledError`):

```python
from inspect_ai.agent import AgentState, agent_channel, AgentInterrupted
from inspect_ai.model import execute_tools, get_model

async def execute(state: AgentState) -> AgentState:
    async with agent_channel() as ch:
        while True:
            state.messages.extend(await ch.before_turn(state.messages))
            try:
                with ch.turn_scope():
                    state.output = await get_model().generate(state.messages, tools=tools)
                    state.messages.append(state.output.message)
                    if state.output.message.tool_calls:
                        messages, _ = await execute_tools(state.messages, tools)
                        state.messages.extend(messages)
                    else:
                        break  # agent is done
            except AgentInterrupted:
                state.messages.extend(await ch.after_cancel(state.messages))
                continue
    return state
```

`ch.before_turn()` drains queued operator messages (blocks for an initial user message on turn 1 if `state.messages` is empty). `ch.after_cancel()` synthesizes a cancelled `ChatMessageTool` for any in-flight tool calls so the next turn sees a clean tool_call / tool_result pair, then appends the operator's follow-up. Custom agents without this code still run normally; they just don't appear in the `inspect acp` picker. Sub-agents reached via `handoff()`, `as_tool()`, or `deep_agent()` open their own channel but are not bound to the ACP transport — only the outermost agent in a sample is operator-controllable, and sub-agent activity collapses to a single tool call in the operator's view.

### Other ACP clients

Editors with ACP support (e.g. Zed) launch the agent as a subprocess and exchange JSON-RPC over stdio. `inspect acp --stdio` is the bridge — it forwards between the editor's stdio and a running eval's ACP socket, auto-discovering the most recently started local `--acp-server` eval (override with `--eval-id` or `--socket`). Custom clients can speak ACP directly over the eval's socket: standard methods (`initialize`, `session/new`, `session/load`, `session/prompt`, `session/cancel`, `session/update`, `session/request_permission`) work unchanged, and Inspect adds `inspect/*` extension methods for session enumeration, direct attach, terminal sample cancel, single-tool-call cancel, raw transcript event streams, and end-of-sample notification.

## See also

- `ukgovernmentbeis-inspect-ai-tools.md` — tool definitions that agents consume.
- `ukgovernmentbeis-inspect-ai-sandboxing.md` — sandbox environments for code-running agents.
- `ukgovernmentbeis-inspect-ai-solvers.md` — solver protocol that agents sometimes wrap.

## Source

- `docs/agents.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/agents.qmd
- `docs/react-agent.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/react-agent.qmd
- `docs/deepagent.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/deepagent.qmd
- `docs/multi-agent.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/multi-agent.qmd
- `docs/agent-custom.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/agent-custom.qmd
- `docs/agent-bridge.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/agent-bridge.qmd
- `docs/human-agent.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/human-agent.qmd
- `docs/intervention.qmd` (NEW) — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/intervention.qmd
- `src/inspect_ai/agent/` — implementation: https://github.com/UKGovernmentBEIS/inspect_ai/tree/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/agent
- `src/inspect_ai/agent/_acp/` — ACP server/transport: https://github.com/UKGovernmentBEIS/inspect_ai/tree/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/agent/_acp
- `src/inspect_ai/agent/_channel/` — `agent_channel()` implementation: https://github.com/UKGovernmentBEIS/inspect_ai/tree/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/agent/_channel
- Repo SHA: `033745ddbc05431c38b015a4b8f2236e956ee9ea` (as of 2026-05-26)
