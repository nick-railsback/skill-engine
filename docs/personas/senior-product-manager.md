# The Senior Product Manager

> Technical-adjacent, not a coder. Pressure-tests roadmap features against
> the platform's actual constraints before championing them upward.

## The scenario

The senior PM at a mid-sized B2B SaaS owns a product surface that touches
three engineering teams. She's been in product six years, four of them at
this company. She doesn't code, but she's fluent enough in architecture to
read a sequence diagram and ask the right follow-up questions. She uses
Claude Desktop daily — for research, customer interviews synthesis, and
sharpening her own writing.

## The moment

She has championed a roadmap feature for two quarters. Engineering said
yes. The scoping doc is blessed. Four days before the sprint kicks off,
a staff engineer pulls her aside in the hallway: *"I don't think this
will work the way you've described it. The platform doesn't do that the
way you're assuming."*

She had been advocating, for two quarters, for a feature the architecture
structurally cannot support in the shape she's been promising. She didn't
know. She couldn't have known. She doesn't have the technical fluency to
interrogate the platform directly, and she has always depended on engineers
to translate.

## The intervention

The staff engineer apologizes for not catching it sooner — and then hands
her a `.zip` file: their team's skill-engine contextualizer, a snapshot of
the platform's current architecture, exported for use in her Claude Desktop.
He shows her how to load it. *"Next time you have a feature idea, ask the
platform what it can actually do, before you go champion it."*

## The result

The next roadmap item she champions, she pressure-tests it in Claude
Desktop with the contextualizer loaded: *"Given this feature spec, what
constraints in our platform would make it harder or impossible to
implement as described?"* Claude — reading the contextualizer — flags two
real constraints she'd missed and confirms one she suspected. She revises
the scoping doc before engineering review, not after. The staff engineer
later messages her: *"This is the cleanest scoping doc I've gotten from
product in a year."* When engineering pushes a contextualizer update,
she can see the proposed diff before accepting — same reviewer-in-the-loop
discipline that protected the original artifact.

## Why it works

- **[Skill-engine produces a hand-off-able artifact](../../CAPABILITIES.md#how-its-distributed)** — a `.zip` of the
  contextualizer drops cleanly into Claude Desktop with no engineering
  setup on her side.
- **[Reviewer-in-the-loop](../../CAPABILITIES.md#how-human-review-fits)** applies to consumers, not just creators —
  when the platform team updates the contextualizer, she can review the
  diff before accepting it on her end.
- **The architecture in her hands** lets her have constraint-aware
  conversations with engineering, not just hope-driven ones.

[← Back to all personas](./README.md)
