<!-- SPDX-License-Identifier: Apache-2.0 -->

# Named systems — registry and matching

Every EARS criterion names exactly one system (the actor that performs the response). To stay consistent across specs and tasks, this project keeps a project-level registry of named systems. This file explains how to consult and grow that registry from a skill. Systems Registry exists here at `<cwd>/.x-plan/_data_systems.yaml`.

## What an entry looks like

Systems Registry is a YAML file, and each entry in it has three fields:

- `name` — the free-text human label rendered in EARS criteria as `the <name>`. Use natural capitalization and spacing. Examples: `"Checkout Service"`, `"Kanban Board UI"`, `"Spec Sync Engine"`.
- `id` — the URL-safe key derived from `name`. Lowercase letters/digits/hyphens only. Never write the slug into criterion text.
- `brief` — one short sentence describing what the system does and the boundary it owns.

A typical `<cwd>/.x-plan/_data_systems.yaml` should read:

```
systems:
  - id: dashed-slug1
    name: Human Readable Service Name
    brief: A summary of the service.
  - id: dashed-slug2
    name: Human Friendly Name
    brief: A summary of the service.

```

## Naming rules (you must enforce)

1. **Allowed characters**: letters, digits, spaces, and hyphens only. Underscores, commas, and other punctuation are rejected. Underscores are SQL `LIKE` wildcards (the reference-count query would mismatch); commas conflict with EARS clause separators (a name with a comma would make `When X, the Y, Z shall …` ambiguous).
2. **Must contain at least one letter**. Names made up of only digits, spaces, or hyphens (e.g. `"123"`, `"42-09"`) aren't legible system names. `"v2 Gateway"` is fine because it has `v`/`G`/etc; `"42"` alone is not.
3. **No leading "the"**: the name must not start with the word `the` (case-insensitive). EARS already prepends `the <name>` to every criterion, so a name like `"The Service"` would render as `"the The Service shall …"` — refused at validation time.
4. **Length cap**: 60 characters. Long enough for "iOS Push Notification Client" but not for a paragraph.
5. **Slug uniqueness**: two display names that slugify to the same key (e.g. `"Checkout Service"` and `"Checkout  Service"` with extra spaces) collide. The user must rename one before both can coexist.
6. **Brief**: 1–240 characters, single sentence preferred.

## How other skills consult the registry

Other skills read `<cwd>/.x-plan/_data_systems.yaml` directly and update it as needed. 

For each spec or task the skills intend to write, they:
   1. identify the actor — the specific component, service, or device that performs the response.
   2. Try to match it against an existing entry by name AND `brief`.
   3. If matched: use the existing entry's `name` verbatim in the EARS criterion text (e.g., "the Checkout Service shall …") AND its `id` verbatim in the plan's frontmatter `systems:` array (e.g., `systems: [checkout-service]`). These two are always taken from the same registry entry.
   4. If not matched: STOP. Propose a new system to the user (id + name + one-sentence brief). On approval, add that to `<cwd>/.x-plan/_data_systems.yaml`. Then continue.

## Source of truth

A system's current contract is the set of `[x]` EARS criteria across plans whose frontmatter is `status: valid` AND whose `systems:` array includes the system's id. Use `x-x plan list --status valid --system <id> --order=asc` (the kebab id from `<cwd>/.x-plan/_data_systems.yaml`, not the display name) to enumerate them in chronological order, then read each plan's `## Tasks` for `[x]` criteria naming the system. Plans with `status: superseded` or `status: deprecated` are history and must never be read for current truth.

## When the registry is empty

A fresh project may have an empty `systems` YAML. Do not try to write criteria with bare `the system` because the registry is empty — propose a real system to the user instead.

## When more than one entry is plausible

Pick the most specific match. If two entries genuinely apply (e.g. a frontend component and a backend service both behave on the same trigger), split the criterion into two: one per system. EARS forbids more than one named system per criterion.

## When you propose a new system

Use natural English. Briefs should answer "what does this system do, and what's its boundary?" in 10–25 words. 

Try to be one level more granular when choosing a system name, for example, if you choose the root API project as the system, most of the plans/tasks will be around that. But if you choose a module inside of the API project, you could generate more specific plans/tasks specifically targeted to that module. You can still use the API project, but choose it for more umbrella-level activities, logging, configuration, compliance, etc.

A few do-and-don't examples:

| ✅ Good | ❌ Bad | Why |
|---------|--------|-----|
| `"Checkout Service"` | `"checkout_service"` | Underscores aren't allowed; use natural spaces. |
| `"Kanban Board UI"` | `"kanban-board-ui"` | Present the human label, not the slug. |
| `"Order Audit Log"` | `"The Order Audit Log"` | Names must not start with "the". |
| `"iOS Push Client"` | `"iOS Push! Client"` | `!` isn't an allowed character. |
| `"Order Auth Service"` | `"Order, Auth Service"` | Commas conflict with EARS clause separators. |
| `"v2 Gateway"` | `"123"` or `"42-09"` | Name must contain at least one letter. |

## What the AI must never do

- Never invent a system name on the fly that's not in the registry. Either match an entry or propose one and wait for approval.
- Never write `the system shall …`, `it shall …`, `the application shall …`, `the service shall …`, `the platform shall …`. Those are banned per EARS.
- Never write the slug/id into EARS criterion text. EARS uses the display name (`"the Checkout Service shall …"`); the id is for the plan's frontmatter `systems:` array and `--system <id>` lookups only.
