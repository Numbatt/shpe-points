# SHPE Points

Officer-facing points system for Rice SHPE. Full architecture and rationale:
[`docs/DESIGN.md`](docs/DESIGN.md). Read it before changing anything structural.

## Hard constraints

- **`dashboard/index.html` stays a single dependency-free file.** No npm, no build step,
  no framework, no CDN, inline CSS only. This is a deliberate handoff decision, not an
  oversight: the next VP is not necessarily technical, and a file with no dependencies has
  nothing to rot. See "Why the dashboard is a single dependency-free HTML file" in DESIGN.md.
- **`member_totals_all_time` must keep its name and its `first_name,last_name,total_points`
  columns.** The live shpe.rice.edu leaderboard queries it. Superset the columns, never rename.
- **The system must never rank or recommend who to sponsor.** Sponsorship depends on
  constraints points can't see. The dashboard slices data and stops there.

## Skill routing

When the user's request matches an available skill, ALWAYS invoke it using the Skill
tool as your FIRST action. Do NOT answer directly, do NOT use other tools first.
The skill has specialized workflows that produce better results than ad-hoc answers.

Key routing rules:
- Product ideas, "is this worth building", brainstorming → invoke office-hours
- Bugs, errors, "why is this broken", 500 errors → invoke investigate
- Ship, deploy, push, create PR → invoke ship
- QA, test the site, find bugs → invoke qa
- Code review, check my diff → invoke review
- Update docs after shipping → invoke document-release
- Weekly retro → invoke retro
- Design system, brand → invoke design-consultation
- Visual audit, design polish → invoke design-review
- Architecture review → invoke plan-eng-review
- Save progress, save state, save my work → invoke context-save
- Resume, where was I, pick up where I left off → invoke context-restore
- Code quality, health check → invoke health
