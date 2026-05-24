<!-- SPDX-License-Identifier: Apache-2.0 -->

# EARS — acceptance criteria language

Every `## Tasks` checkbox is an EARS criterion. Follow these rules without exception.

## The 5 patterns

| # | Pattern | When to use | Template |
|---|---------|-------------|----------|
| 1 | Ubiquitous | Always true | `The <system> shall <response>.` |
| 2 | State-driven | A state must hold | `While <precondition>, the <system> shall <response>.` |
| 3 | Event-driven | A discrete event triggers it | `When <trigger>, the <system> shall <response>.` |
| 4 | Optional feature | Only in certain configurations | `Where <feature is included>, the <system> shall <response>.` |
| 5 | Unwanted behavior | A failure or misuse case | `If <unwanted trigger>, then the <system> shall <response>.` |

Complex requirements stack `While` with `When` OR `If ... then` (not both), in fixed order. `Where` is standalone — never stacks.

Example of a stacked complex requirement:
`While the aircraft is on ground, when reverse thrust is commanded, the engine control system shall enable reverse thrust.`

## Hard rules

1. **Exactly one named system per criterion.** The system is a concrete subsystem, service, or component from the registry (`<cwd>/.x-plan/_data_systems.yaml`) — never bare `the system`, `it`, `the app`, `the service`, `the application`, `the platform`. See `../_x-x_shared/_systems.md` for registry consultation and propose-new-system rules.
2. **Use `shall`** for the response. Never `should`, `may`, `might`, `will`, `can`, `must`.
3. **One requirement per sentence.** Split bundled inputs.
4. **`When` and `If` are mutually exclusive** in one sentence — `When` is expected, `If ... then` is unwanted.
5. **Use exact keywords** (`While`, `When`, `If ... then`, `Where`, `shall`) in the fixed slot order: `[While ...,] [When ..., | If ..., then] the <system> shall <response>.`
6. **Response must be concrete and observable.** No "feel premium", "look modern", etc. If non-functional without a measurable target, refuse and ask.

If you can't satisfy these, refuse and ask one direct question per gap. No padding, no hedging.

## Output format

Each criterion is a checkbox in `## Tasks`. `[ ]` is open, `[x]` is done — `/x-x` flips them as it executes.

```
- [ ] The Checkout Service shall <response>.
- [ ] When the Kanban Board UI receives a drop event, the Kanban Board UI shall <response>.
```

If clarifying questions are needed, ask them as a numbered list and stop. Do not produce partial requirements.
