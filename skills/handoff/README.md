# handoff

Lightweight Claude Code skill that captures the state of the current work session into a handoff file and updates persistent memory, so the **next** session resumes without context loss.

## What you get

- A timestamped, versioned handoff file at `<workspace>/docs/plans/YYYY-MM-DD-session-handoff-<slug>-vN.md` containing TL;DR, decisions, open questions, suggested next steps, and rules learned this session.
- An updated project memory file at `<memory_store>/project_<slug>_active.md` so Claude Code auto-loads the project's current state into every new session.
- An updated index in `<memory_store>/MEMORY.md` with a one-line pointer to the freshest handoff — that's how the next session "knows" where to look.
- (Optional) A feedback memory file when a clear new rule emerged in the session ("don't do X", "always do Y").

The magic: because Claude Code auto-injects `MEMORY.md` into the system prompt of every new session of the same workspace, you start the next session and the assistant already knows where you left off — no manual `/load` or copy-paste.

## Designed for

- Solo developers / power users running multi-session projects in Claude Code.
- Sessions that are about to hit context limits / compaction and need a clean checkpoint.
- Handing work off across machines / between LLMs without losing the thread.

## Requirements

- **Claude Code** with auto-memory enabled (default in CC ≥ 2.x).
- A workspace with a `docs/plans/` directory (or one that can be created).
- The standard CC memory path layout: `~/.claude/projects/<encoded-workspace>/memory/` where `<encoded-workspace>` is the absolute workspace path with `/` replaced by `-` and a leading `-`. Example: `/Users/alice/code/myproject` → `~/.claude/projects/-Users-alice-code-myproject/memory/`.

If your environment is **not** Claude Code, this skill won't deliver its full value — the auto-resume relies on CC's specific memory injection. Use a different workflow there.

## Install

```bash
# Clone or download this folder, then:
cp -R handoff ~/.claude/skills/
```

(Or place the folder anywhere on your skills search path used by your Claude Code setup.)

## Quick start

End of session, ready to step away:

```
/handoff
```

The skill will:
1. Detect a project slug from session context (or ask).
2. Compute the next version number from existing handoffs.
3. Generate a fully-templated handoff markdown.
4. Update `project_<slug>_active.md` and `MEMORY.md`.
5. Optionally write a `feedback_<slug>_<topic>.md` if a new rule emerged.
6. Report the produced paths back in chat.

You can also pass an explicit slug:

```
/handoff my-project
```

## Companion skill

Often paired with a heavier `session-debrief` skill (not included here) that does end-of-stage finalization: knowledge atoms, full documentation, git commit. `handoff` is the light version for the in-between checkpoints.

## Configuration knobs

Inline in `SKILL.md`:
- The handoff file template — adjust sections to your taste (TL;DR, decisions, open questions, suggested next steps).
- The project memory body convention.
- The `MEMORY.md` index format (one line per project, ≤ 200 chars).
- Project slug auto-detection rules (the skill makes generic assumptions; tune them to your workspace conventions).

## License

See `LICENSE` in the repo root.
