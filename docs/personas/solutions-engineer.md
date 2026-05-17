# The Solutions Engineer

> Evaluates five competing agentic-payments protocols by spinning up one
> contextualizer per protocol and composing them against his business
> context.

## The scenario

The solutions engineer at an online retail company is tasked with
researching how to integrate an agentic payments system — so the company's
products can be found and purchased by customers' AI agents. This is new
territory for him. The company's catalog spans single-dollar items to a few
hundred dollars per order.

He's heard of A2A, x402, and AP2, though he quickly discovers more. All
the protocols are open source and/or have comprehensive documentation sites. The protocol landscape is
moving fast, and the specs themselves release on different cadences. He's
already contextualized his company's full domain with skill-engine — a
`retail-business-context` skill that he uses every day.

## The moment

His director wants a recommendation in two weeks. The protocol layer is
genuinely confusing: A2A is for agent communication, AP2 handles trust,
ACP (Stripe + OpenAI) handles checkout, MPP (Stripe + Tempo) handles
machine settlement, x402 (Coinbase) handles stablecoin settlement. Some
are layered; some compete. He can't keep them straight in his head, and
the specs change weekly.

## The intervention

He scaffolds one contextualizer per protocol:

```
.claude/skills/
├── retail-business-context/      ← already exists
├── ap2-protocol-context/
├── acp-protocol-context/
├── x402-protocol-context/
├── mpp-protocol-context/
└── a2a-protocol-context/
```

For each protocol contextualizer, `research/source-paths.json` registers
the spec repository (`kind: git-managed`) and the protocol's marketing
site (`kind: external-doc`). He runs `/skill-engine:engine-bootstrap` once
per protocol, then `/skill-engine:discover`. Because the navigator
descriptions follow the WHEN-not-WHAT discipline, each one fires only on
questions about its specific protocol — not on every payment question.

## The result

When he asks Claude *"given our catalog and order flow, would AP2 mandates
plus ACP checkout cover the $5–$300 purchase range, or do we need MPP for
anything?"* — his retail-business contextualizer activates (his catalog is
in scope), the AP2 navigator activates (mandates are mentioned), the ACP
navigator activates (checkout is mentioned). Claude reasons across all
three and produces a comparison grounded in his actual business context
plus the live protocol specs. When he later decides MPP is out of scope,
he just stops loading that contextualizer — no shared config to edit.

## Why it works

- **[Multi-contextualizer composition](../../CAPABILITIES.md#how-it-composes)** lets him reason about cross-protocol
  fit without merging everything into one mega-contextualizer.
- **[source-paths.json kind discriminators](../../CAPABILITIES.md#how-it-gets-built)** (`git-managed` for spec repos,
  `external-doc` for marketing pages) cover the heterogeneous sources each
  protocol publishes.
- **[REFRESH per contextualizer](../../CAPABILITIES.md#how-it-stays-accurate)** lets each protocol's contextualizer track
  its own release cadence independently — important when one protocol
  updates monthly and another quarterly.

[← Back to all personas](./README.md)
