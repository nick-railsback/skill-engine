# Agents

The `Agent` protocol is a narrower, more versatile sibling of `Solver`. An agent is an `async def execute(state: AgentState) -> AgentState` wrapped by `@agent`. The same agent instance can play four roles: (1) top-level `Solver` on a `Task`, (2) standalone callable via `run()`, (3) sub-agent in a multi-agent system, and (4) a `Tool` exposed to a model via `as_tool()`.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/agents.qmd#L26-L38

```python
from inspect_ai.agent import Agent, AgentState, agent
from inspect_ai.model import ChatMessageSystem, get_model
from inspect_ai.tool import web_search

@agent
def web_surfer() -> Agent:
    async def execute(state: AgentState) -> AgentState:
        """Web research assistant."""
        state.messages.append(
            ChatMessageSystem(content="You are an expert at using a web browser.")
        )
        messages, output = await get_model().generate_loop(
            state.messages, tools=[web_search()]
        )
        state.output = output
        state.messages.extend(messages)
        return state
    return execute
```

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/agents.qmd#L44-L75

`AgentState` carries `messages` (conversation history) and `output` (last `ModelOutput`). It is defined at `src/inspect_ai/agent/_agent.py`; the class starts at line 34 and the `Agent` protocol at line 92.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/src/inspect_ai/agent/_agent.py#L34-L95

## Using agents

Agents can be passed directly as the `solver=` argument to `Task` or `eval()`. For interfaces that are not agent-aware, `as_solver()` converts an agent to a `Solver`. For programmatic workflows, `run(agent, state)` invokes an agent and returns the updated state — `run()` makes a copy of the input state so parallel invocations are safe.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/agents.qmd#L96-L155

## Built-in agents

| Agent | Use when |
|---|---|
| `react()` | Standard ReAct loop. The workhorse for most agentic evals. Configurable system prompt, max iterations, tool set, scorer-integrated stopping criterion. ACP intervention out of the box. |
| `deepagent()` | Long-horizon work needing subagent delegation, planning, and persistent memory. Implemented under `src/inspect_ai/agent/_deepagent/`. ACP intervention out of the box. |
| `human_cli` | Replaces the model with a human operator — useful for human baselines on computing/CTF tasks. Surfaces a CLI prompt for each tool call decision. |

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/agents.qmd#L8-L24

Plus two non-Inspect-native bridges: **Agent Bridge** (`agent_bridge`) wraps an external agent framework (OpenAI, Anthropic, Google, LangGraph, etc.) so it can run inside an Inspect task. **Inspect SWE** is a separate package at `meridianlabs-ai/inspect_swe` that runs Claude Code / Codex CLI / Gemini CLI as agents inside Inspect evaluations.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/agent-bridge.qmd#L7-L35

## ReAct agent — the default

```python
from inspect_ai.agent import react
from inspect_ai.tool import bash, python

solver = react(
    tools=[bash(), python()],
    max_iterations=20,
)
```

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/react-agent.qmd#L6-L46

ReAct iterates: model generates → tool calls executed → results appended → model generates again. It runs until the model calls the special `submit()` tool, until `max_iterations` hits, or until limits trip. If the model stops calling tools without submitting, it is prompted to continue or call `submit()`.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/react-agent.qmd#L8-L18

Configurable: `prompt` (system message or `AgentPrompt` instance), `tools`, `max_iterations`, `score` (a scorer that can terminate early on success), `attempts` (retry policy when the scorer says fail). Pass `AgentPrompt` with parts set to `None` to suppress default prompts entirely.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/react-agent.qmd#L64-L123

`attempts` controls how many submissions are allowed. Internally resolved to an `AgentAttempts` instance; you can pass one directly to set a custom incorrect message or scoring scale.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/src/inspect_ai/agent/_react.py#L51-L95

## Deep Agent

`deepagent()` adds four things over ReAct: (1) a `task()` delegation tool that lets the agent spawn isolated subagents (`research()`, `plan()`, `general()`); (2) a `memory()` tool with persistent notes across iterations and context compaction; (3) a `todo_write()` planning tool for explicit task decomposition; and (4) an opinionated system prompt that teaches the model when to use each. It targets tasks that take dozens to hundreds of model turns — e.g., software engineering, deep research, multi-stage CTF.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/deepagent.qmd#L6-L46

Subagents run in isolated context by default: each gets a fresh message history with only the task prompt, and only its summary returns to the parent. All subagents inherit the parent's model. For cost-sensitive workloads, override `research()` with a cheaper model (e.g. `research(model="anthropic/claude-haiku-4-5")`) since read-only gathering is the highest-volume subagent task.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/deepagent.qmd#L58-L82

Memory survives context compaction (enabled by default). The system prompt instructs the model to checkpoint important state to memory before compaction. The `memory()` tool is based on Anthropic's native memory tool and binds to it natively on Anthropic models; only the top-level agent has memory by default — subagents communicate findings through their return value.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/deepagent.qmd#L74-L82

The default system prompt is goal-oriented rather than procedurally prescriptive: act rather than narrate intent; keep going until fully resolved; batch independent tool calls in a single response; use reasonable defaults rather than pausing to ask clarifying questions. For shorter but still difficult benchmarks (e.g. Cybench, Terminal Bench 2.0) there is no observed performance difference between `react()`, `deepagent()`, and `claude_code()` — only reach for `deepagent()` when confident the task will benefit, and always measure against a `react()` baseline.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/deepagent.qmd#L50-L107

## Multi-agent architectures

Multi-agent architecture often does **not** out-perform a well-tuned simple `react()` agent. The recommended methodology: (1) establish a `react()` baseline, (2) optimize environment / tool selection / prompts, (3) only then experiment with multi-agent designs and benchmark against the baseline.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/multi-agent.qmd#L6-L32

Two composition patterns:

- **Handoff** — `handoff(agent_b)` becomes a tool on agent_a's tool set. The conversation history (minus system messages) is forwarded to the sub-agent; the sub-agent can append to it. Presented to the model as `transfer_to_<name>` tool calls. Use for back-and-forth collaboration where history sharing matters.
- **As-tool wrapping** — `as_tool(agent_b)` gives a simple string-in / string-out interface; agent_b runs to completion and returns its last assistant message. Use for one-shot discrete task delegation.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/multi-agent.qmd#L80-L155

**Handoff filters** — by default `handoff()` applies `content_only()` as an `output_filter`, stripping system messages, reasoning traces, and converting tool calls to text so the parent model is not confused by content it doesn't understand the origin of. Use `input_filter=remove_tools` to strip tool calls from the history presented to the sub-agent. Both `input_filter` and `output_filter` accept arbitrary async callables.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/multi-agent.qmd#L157-L189

Implementation: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/src/inspect_ai/agent/_handoff.py#L19-L65

## Agent vs. solver — when to choose which

Solvers are appropriate when the elicitation strategy is task-specific and won't be reused. Agents are appropriate when the same scaffold should plug into multiple tasks or be composed with other agents. Passing `react(...)` directly as `Task(solver=...)` works and is simpler than wrapping in `as_solver(react(...))`.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/src/inspect_ai/agent/_as_solver.py#L1-L93

## Limits inside agents

`message_limit`, `token_limit`, `time_limit`, and `working_limit` apply to agents the same way they apply to solvers. Limits can be set at the sample level, via a context manager, or passed to `run()`.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/agent-custom.qmd#L282-L289

## Human Agent

`human_cli` replaces the model with a human operator running in a Linux sandbox. The human baseliner accesses the container (e.g. VS Code Terminal link), uses CLI commands to view instructions, submit answers, pause work, and enable intermediate scoring. Terminal sessions are recorded by default. Requirements: the task must be solvable using Linux tools; a sandbox must be configured; the dataset must supply instructions the human can read.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/human-agent.qmd#L6-L64

## Agent Bridge

`agent_bridge()` redirects Python-based external agents (OpenAI Completions, OpenAI Responses, Anthropic, Google) to the current Inspect model provider by running them inside the context manager. `sandbox_agent_bridge()` does the same for agents running inside a sandbox (any language) and supports bridging Inspect tools into the external agent via `BridgedToolsSpec`.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/agent-bridge.qmd#L29-L170

## Agent Intervention (ACP)

Agent intervention is **bidirectional**: it supports creating evaluations with a human in the loop from either side. Human operators can connect to running sessions, interrupt agents, and redirect them with follow-up messages. Agents can also initiate intervention by asking questions and sending notifications. Every intervention is recorded in the transcript. `react()` and `deepagent()` support intervention out of the box; custom agents opt in with a small change to their turn loop.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/intervention.qmd#L6-L14

### Enabling and attaching

Start the eval with `--acp-server`, then attach from a second terminal:

```bash
inspect eval terminal_bench_2 --acp-server
inspect acp
```

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/intervention.qmd#L16-L49

`inspect acp` shows the running sessions, lets you pick one, and exposes intervention keybindings:

- **Esc** — interrupt the current generation or tool call. Records an `InterruptEvent`.
- **Ctrl+P** — show the active plan and its status.
- **Ctrl+L** — cancel the running tool call only (turn continues).
- **Ctrl+N** — cancel the sample (choose score or error). Records a `SampleLimitEvent` with `type="operator"`.
- **Ctrl+S** — switch to another running sample.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/intervention.qmd#L16-L49

Messages you type land at the start of the agent's next turn as `ChatMessageUser` with `source="operator"`. Everything — interrupt, operator messages, sample cancels — is captured in the Inspect log.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/intervention.qmd#L51-L60

### Intervention Clients

All intervention features work with the standard Inspect full task display too, not only the ACP client. Each `eval()` call establishes which client it uses via the `--acp-server` option: `inspect eval <task> --acp-server` uses the ACP client; omitting it uses the standard task display. The ACP client is recommended because it is more feature-rich, works with `--display plain` and other non-interactive modes, and can be remoted over HTTP.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/intervention.qmd#L79-L92

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

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/intervention.qmd#L62-L78

### Questions and Notifications

Agents can initiate intervention by asking questions and sending notifications, making the intervention model fully bidirectional. This is done by providing agents with the `ask_user()` and/or `notify_user()` tools (both documented in full in the tools reference).

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/intervention.qmd#L93-L120

**Ask User Tool** — `ask_user()` requests structured information from users via [ACP Elicitation](https://agentclientprotocol.com/rfds/elicitation), which supports text, boolean, enum, and other field types. Add it to any agent's tool list (e.g. `tools=[bash(), text_editor(), ask_user()]`). The sample parks until an ACP client that declares the `elicitation.form` capability answers; there is no silent fallback to a console prompt.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/intervention.qmd#L97-L120

**Notify User Tool** — `notify_user()` sends fire-and-forget status messages to the operator. Notifications are routed via [Apprise](https://appriseit.com) and fire whenever a human-in-the-loop interaction is posted (including `ask_user()` calls and tool-approval prompts). Configure the notification target via the `INSPECT_EVAL_NOTIFICATION` environment variable or by passing an Apprise config file path. Enable per eval with `--notification` on the CLI or `notification=True` in `eval()`.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/intervention.qmd#L174-L200

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

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/intervention.qmd#L202-L254

`ch.before_turn()` drains queued operator messages (blocks for an initial user message on turn 1 if `state.messages` is empty). `ch.after_cancel()` synthesizes a cancelled `ChatMessageTool` for any in-flight tool calls so the next turn sees a clean tool_call / tool_result pair, then appends the operator's follow-up. Custom agents without this code still run normally; they just don't appear in the `inspect acp` picker.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/intervention.qmd#L249-L254

### Writing an ACP client

Any ACP-speaking client (Inspect's CLI, Zed, a custom client) can attach to a running eval. Inspect implements the full standard ACP surface plus `inspect/*` extension methods for session enumeration, direct attach, terminal sample cancel, single-tool-call cancel, raw transcript event streams, and end-of-sample notification. Clients that declare `elicitation.form` capability receive `ask_user` prompts as structured `elicitation/create` requests. The full extension surface is defined in `inspect_ext.py`.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/intervention.qmd#L256-L305

Implementation: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/src/inspect_ai/agent/_acp/inspect_ext.py

## See also

- `ukgovernmentbeis-inspect-ai-tools.md` — tool definitions that agents consume, including `ask_user()` and `notify_user()`.
- `ukgovernmentbeis-inspect-ai-sandboxing.md` — sandbox environments for code-running agents.
- `ukgovernmentbeis-inspect-ai-solvers.md` — solver protocol that agents sometimes wrap.

## Source

- `docs/agents.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/agents.qmd
- `docs/react-agent.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/react-agent.qmd
- `docs/deepagent.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/deepagent.qmd
- `docs/multi-agent.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/multi-agent.qmd
- `docs/agent-custom.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/agent-custom.qmd
- `docs/agent-bridge.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/agent-bridge.qmd
- `docs/human-agent.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/human-agent.qmd
- `docs/intervention.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/intervention.qmd
- `src/inspect_ai/agent/` — implementation: https://github.com/UKGovernmentBEIS/inspect_ai/tree/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/src/inspect_ai/agent
- `src/inspect_ai/agent/_acp/` — ACP server/transport: https://github.com/UKGovernmentBEIS/inspect_ai/tree/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/src/inspect_ai/agent/_acp
- `src/inspect_ai/agent/_channel/` — `agent_channel()` implementation: https://github.com/UKGovernmentBEIS/inspect_ai/tree/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/src/inspect_ai/agent/_channel
- Repo SHA / as of: `6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40 (as of 2026-05-27)`
