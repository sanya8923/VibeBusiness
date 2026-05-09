# research-buy

A Claude Code skill that researches equipment for a specific use case and binds it to actual purchase in a specific city. Generates a self-contained HTML guide on localhost, then stays in expert mode for follow-up questions and inline expansions.

**What you get:** a single `index.html` page with a brief, TL;DR, 3-5 budget setups (with localStorage checklist), full component catalog, shopping table with direct product URLs in shops in your city, and 5-10 source videos embedded.

**Designed for:** physical equipment with multiple components, where buying locally matters (microphones, cameras, lighting, audio interfaces, bicycles, kitchen gear, etc.). Not for: digital goods, courses, services, real estate.

---

## Requirements

- **Claude Code** (or any harness that supports SKILL.md skills)
- **`uv`** for the YouTube research phase. Install once via:
  - `curl -LsSf https://astral.sh/uv/install.sh | sh` (Linux/Mac, no admin)
  - `brew install uv` (Mac with Homebrew)
  - `pip install uv` (any platform with Python)
- **`python3`** (for the local HTTP server and JSON parsing)
- **`ffmpeg`** — optional, only if you want frame grabs from YouTube source videos

If `uv` / `uvx` is missing the skill skips the YouTube phase with a warning and continues with the rest of the pipeline.

---

## Install

Copy the `research-buy/` folder into your skills directory:

```bash
# Claude Code (default location):
cp -R research-buy ~/.claude/skills/

# Or wherever your harness loads skills from
```

The skill's own files (`template.html`, `extract.sh.template`) are addressed via `<skill_dir>` in `SKILL.md`. The skill resolves that to the directory where `SKILL.md` sits.

---

## Quick start

```
/research-buy microphone for podcasting, Batumi Georgia, up to $100, only headphones, self-read
```

Or just give it the topic and answer 4 questions in chat:

```
/research-buy microphone for podcasting
```

After ~5-10 minutes you get:

```
✅ Done. Artefact: http://localhost:8765/

Topic: microphone for podcasting
Location: Batumi, Georgia
Slug: microphone-podcast-batumi
Setups: 3 | Shops: 6 | Sources: 7

I'm staying in this topic. Ask now or come back later:
- compare setups / pick the optimal one
- what to upgrade once budget grows
- accessories for the chosen setup
- ...
```

The page contains everything self-contained — open it in a browser, walk through the setups, tick off purchases (state persists in localStorage).

---

## Pipeline overview

| Phase | What happens | Where |
|---|---|---|
| 0 | Parse arguments, create `<out_dir>/`, set up todo list | Claude main |
| 1 | Brief (skipped if all args parsed) | Chat |
| 2 | YouTube research — 5-10 quality videos with quotes & timestamps | Subagent (`uvx yt-dlp`) |
| 3 | Component catalog — slots, brands, price ranges, compatibility | Claude main |
| 4 | 3-5 budget setups | Claude main |
| 5 | Local shopping research with delivery tags (🟢/🔵/🟡/🟣) | Subagent |
| 6 | Render HTML | Claude main |
| 7 | Localhost server, CHANGELOG, optional memory updates | Claude main |

After Phase 7 the skill stays in **consultation mode** — answer follow-up questions, inline-expand sections, optionally spawn child research with `parent_slug`.

---

## Files

```
research-buy/
├── SKILL.md                # the skill itself
├── template.html           # HTML page template with {{...}} placeholders
├── extract.sh.template     # bash helper for YouTube metadata + frame extraction
└── README.md               # this file
```

---

## Configuration knobs

- `out_dir` — defaults to `./research/<slug>/`. Override if you keep research artefacts elsewhere.
- `consume` — `self-read` / `share` / `compare`. Adjusts tone and density of the output.
- `parent_slug` — link this research to an earlier one (e.g. accessories for a previous setup).

---

## Privacy & publishing

The artefact is **localhost-only** by default. The HTML has `<meta name="robots" content="noindex, nofollow">`. The skill does not push anywhere. If you want to publish — that's a separate step you do manually.

---

## License

MIT — see `LICENSE` in the repo root.
