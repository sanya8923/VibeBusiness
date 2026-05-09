---
name: research-buy
description: Researches equipment for a specific task and helps the user actually buy it in a specific city. Pipeline — brief → YouTube research → component catalog → budget setups → local shopping with direct URLs → standalone HTML guide on localhost. After generation stays in consultation mode for follow-up questions and inline expansion. Triggers — "find me X to buy in Y", "research-buy X in Y", "what equipment do I need for X in city Z", "/research-buy".
---

# research-buy

Automates equipment research for a specific use case and binds it to purchase in a specific city. Generates a self-contained HTML guide on localhost, then stays in expert mode for follow-up.

---

## Arguments

| Arg | Required | Default | Description |
|---|---|---|---|
| `topic` | yes | — | Free-form topic ("microphone for podcasting", "lighting for streaming", "city bicycle") |
| `location` | yes | — | Country + city. If only country given — ask for city |
| `budget` | no | — | Range or null. If null — ask in brief |
| `has` | no | — | What user already owns / has tried |
| `consume` | no | `self-read` | `self-read` / `share` / `compare` — sets tone of the page |
| `out_dir` | no | `./research/<slug>/` | Where to write the artefact. Override if you keep research in a different place |
| `parent_slug` | no | — | If this research extends an existing one — slug of the parent |

### Call formats

The skill accepts arguments three ways — pick whichever is more convenient.

**Format A — single comma-separated line (preferred for tests / repeats):**

```
/research-buy <topic>, <location>, <budget>, <has>, <consume>
```

Example:
```
/research-buy microphone for podcasting, Batumi Georgia, up to $100, only headphones, self-read
```

**Format B — topic only, rest collected in chat:**

```
/research-buy <topic>
```

The skill asks 4 questions (location, budget, what you already own, consumption format).

**Format C — labelled, when explicitness helps:**

```
/research-buy microphone for podcasting
location: Batumi, Georgia
budget: up to $100
has: only headphones
consume: self-read
```

### Parsing free-form arguments (Format A)

When parameters arrive as a single comma-separated line, recognize them like this:

- **First chunk** before the first comma → `topic`
- Chunk containing a city/country name (any city/country) or a clear `<city>, <country>` / `<country> <city>` pattern → `location`. If only country — ask for city as a single follow-up; do not re-ask the rest.
- Chunk containing currency markers (`$`, `USD`, `EUR`, `GEL`, `₽`, `RUB`, `руб`, etc.) or a number with words like "up to", "from", "budget", "range" → `budget`
- Chunk with words "have", "tried", "none", "only X", "from scratch", "I own" → `has`
- Chunk with words "for myself", "share", "compare", "for a friend" → `consume`

If a parameter is recognized with low confidence — ask one short follow-up about that parameter only. "clarify budget" beats "let's start over with 5 questions".

If all required parameters are recognized — **skip Phase 1**, generate `brief.md` from parsed values, jump to Phase 2.

---

## Pipeline (autonomous after the brief)

### Phase 0 — Setup

1. Parse arguments per "Call formats":
   - Format A (commas) — recognize each parameter per parsing rules
   - Format C (labels) — take explicit values
   - Format B (topic only) — leave the rest empty, go to Phase 1
2. `slug = kebab(topic)-kebab(location-city)` — e.g. `microphone-podcast-batumi`
3. `out_dir = <user-provided>` or default `./research/<slug>/`
4. `mkdir -p <out_dir>/screenshots`
5. Use TaskCreate / TodoWrite to track 7 phases of progress

### Phase 1 — Brief (chat dialog)

**Skip entirely if** all required (`topic`, `location`) and optional (`budget`, `has`, `consume`) are extracted in Phase 0. Generate `brief.md` from parsed values and jump to Phase 2.

**Run if** only `topic` is known (Format B) — ask 4 questions in one message:

```
1. Location: <country>, which city?
2. Budget: what range? (write "no limit" if there's none)
3. What do you already own / what have you tried that didn't work?
4. Consumption format: read it yourself / share with a friend / compare against an alternative?
```

**Run partially** — ask only about missing parameters. Don't re-ask known ones.

Save the answer as `<out_dir>/brief.md`:

```markdown
# Research brief

- **Topic:** ...
- **Location:** ...
- **Budget:** ...
- **Already owns:** ...
- **Consumption:** ...
- **Started:** YYYY-MM-DD

## Context from dialog
<any extra details surfaced during the brief>
```

### Phase 2 — YouTube research (subagent)

Launch via `Agent` tool, `subagent_type: general-purpose`. Prompt:

```
You are a YouTube researcher for an equipment guide.

Topic: <topic>
Location (for context): <location>
Budget: <budget>
User context: <has>

Find 5-10 quality videos in English or in the user's brief language.
Filter: subscribers >10k, views >50k, published <3 years ago.
Source priorities:
- niche channels (reviews/tutorials on the topic)
- large creators with topical expertise
- educational channels

For each video collect:
- youtube id and url
- channel name and subscribers count
- title, duration, publish date
- language
- 3-5 key timestamps with a short label of what's shown (useful for frame extraction)
- 5-10 key quotes / takeaways from the video (use description + auto-subtitles)

Use `uvx yt-dlp` (no install) for parsing:
- `uvx yt-dlp --skip-download --write-info-json --write-auto-subs --sub-lang en,<user-lang> <url>` — metadata + subs
- Parse VTT via python regex to extract takeaways

Output: `<out_dir>/videos.json` with shape:

[
  {
    "id": "...",
    "url": "...",
    "channel": "...",
    "subscribers": 250000,
    "title": "...",
    "duration_sec": 540,
    "lang": "en",
    "published": "2024-08-15",
    "frames": [{"sec": 30, "label": "key shot"}, ...],
    "key_quotes": ["...", "..."]
  }
]

OPTIONAL (if frames are clearly needed for the guide):
- Use <out_dir>/extract.sh (copy of <skill_dir>/extract.sh.template)
- Download partial sections (--download-sections) and pull frames via ffmpeg
- Save to <out_dir>/screenshots/<video_id>_<sec>.jpg

Don't fabricate. If no quotes found in subs — leave key_quotes empty.
Cap at 10 videos — quality over quantity.

If yt-dlp fails (YouTube changed something / blocked region / uvx missing) — skip the YouTube phase, write empty array to videos.json, return a warning in your final summary.

Final message: path to videos.json, count of videos, 50-word summary.
```

### Phase 3 — Component catalog (Claude main)

Read all materials from Phase 2 and extract:

1. **List of slots** (components of the task). E.g. for podcast microphone: microphone, pop filter, stand / pop-shockmount, cable, audio interface, monitor headphones, room acoustics, recorder.
2. **For each slot:** 3-7 recommended brands/models with price ranges in local currency + USD/EUR in parentheses
3. **Compatibility map** — what works with what (XLR vs USB microphone → different interface requirements)

Output: `<out_dir>/components.md` with sections per slot, comparison tables, compatibility notes.

### Phase 4 — Budget setups (Claude main)

3-5 ready-made setups:

- **Starter** (minimum that works) — lower price ceiling
- **Comfort** — recommended middle
- **Studio** — premium for serious work
- **Pro** — top tier (optional)

If the user gave a budget — at least one setup must fit within it.

Each setup = a table: component → model → price → total.

Output: `<out_dir>/setups.md` (rendered into the HTML page).

### Phase 5 — Local shopping (subagent)

Launch via `Agent` tool, `subagent_type: general-purpose`. Prompt:

```
You are a shop researcher for buying equipment in the given location.

Location: <location>
Components and models: <out_dir>/components.md
Setups: <out_dir>/setups.md

STEPS:

1. Read <out_dir>/components.md and <out_dir>/setups.md.

2. Check for a memory cache for this location (path is project-specific):
   ~/.claude/.../reference_<location-kebab>_stores.md (or your equivalent memory store)
   If present — start with its shops, refresh, add new ones.
   If absent — collect from scratch.
   If your environment doesn't use such a memory file — skip this step.

3. Find shops via WebSearch + WebFetch:
   - Local domains of the country (.ge, .ru, .uz, etc)
   - Large marketplaces (mymarket, ebg, ozon, wildberries — pick by country)
   - Niche shops for the category
   - International intermediaries (ubuy.ge, onex.ge, etc) for brands not stocked locally

4. Tag each shop with a delivery category:
   - 🟢 physical store IN THE CITY
   - 🔵 online with CONFIRMED delivery to the city
   - 🟡 online but pickup-only / no delivery (needs a third-party courier)
   - 🟣 international (Aliexpress / B&H via intermediary)

5. For EACH model from components.md and setups.md:
   - Find a direct product URL on at least one shop
   - Quote the price in local currency
   - If sold out — tag "🟡 sold out, check"
   - If the shop renders prices via JS (e.g. Zoommer.ge) and WebFetch returns 403/empty — tag "price not retrieved via web, ask the shop"

6. Output:
   - <out_dir>/shopping.md — main file with shops and items
   - If memory store is in use — refresh ~/.claude/.../reference_<location-kebab>_stores.md (cumulative across sessions)

shopping.md structure:

# Shopping in <location>

## Shops (legend: 🟢 local store / 🔵 delivery / 🟡 pickup-only / 🟣 international)

| Shop | URL | Category | Contacts | Stocks |
|---|---|---|---|---|
| ... | ... | 🟢 / 🔵 / 🟡 / 🟣 | ... | ... |

## Components with direct links

### Microphone
- Model A: <URL>, <shop>, <price>, <status>
- Model B: ...

### Pop filter
...

## Courier services (if intermediaries are needed)
...

## Main selection rules (1-2 lines)
...

Don't fabricate URLs. If no direct page found — write "(no direct URL, search the shop's catalogue)".
Cap at 10 shops in the table.

Final message: path to shopping.md, shop count, models with URLs found, 50-word summary.
```

### Phase 6 — HTML rendering (Claude main)

1. Copy `<skill_dir>/template.html` → `<out_dir>/index.html`
2. Replace content placeholders:
   - `{{TITLE}}` — page title ("<topic> in <location-city>")
   - `{{TOPIC}}` — topic
   - `{{LOCATION}}` — location
   - `{{DATE}}` — current date (YYYY-MM-DD)
   - `{{SLUG}}` — slug
   - `{{LANG}}` — `en` / `ru` / etc., the brief's language
   - `{{BRIEF_HTML}}` — brief.md as HTML
   - `{{TLDR_HTML}}` — 5-7 main takeaways across all materials
   - `{{SETUPS_HTML}}` — setups.md → setup cards
   - `{{COMPONENTS_HTML}}` — components.md → slot tables
   - `{{SHOPPING_HTML}}` — shopping.md → shop tables
   - `{{VIDEOS_HTML}}` — videos.json → embed iframes (youtube-nocookie) + quotes
   - `{{SOURCES_HTML}}` — list of all sources
3. Replace **label placeholders** (UI strings) per the brief's language. English defaults:

   | Placeholder | EN | RU |
   |---|---|---|
   | `{{L_TOPIC}}` | Topic | Тема |
   | `{{L_LOCATION}}` | Location | Локация |
   | `{{L_DATE}}` | Date | Дата сборки |
   | `{{L_BRIEF}}` | Brief | Бриф |
   | `{{L_SETUPS}}` | Setups | Сетапы |
   | `{{L_COMPONENTS}}` | Components | Компоненты |
   | `{{L_SHOPPING}}` | Shopping | Шопинг |
   | `{{L_VIDEOS}}` | Videos | Видео |
   | `{{L_SOURCES}}` | Sources | Источники |
   | `{{L_SETUPS_FULL}}` | Setups by budget | Сетапы по бюджетам |
   | `{{L_COMPONENTS_FULL}}` | Components and alternatives | Компоненты и альтернативы |
   | `{{L_SHOPPING_FULL}}` | Shopping in the location | Шопинг в локации |
   | `{{L_VIDEOS_FULL}}` | Video sources | Источники-видео |
   | `{{L_SOURCES_FULL}}` | All sources | Все источники |
   | `{{L_LEGEND_LOCAL}}` | local store | локальная точка |
   | `{{L_LEGEND_DELIVERY}}` | delivery | доставка |
   | `{{L_LEGEND_PICKUP}}` | pickup-only / needs intermediary | pickup-only / нужен посредник |
   | `{{L_LEGEND_INTERNATIONAL}}` | international | международный |
   | `{{L_FOOTER_GENERATED}}` | Generated by | Сгенерировано |
   | `{{L_FOOTER_LOCAL}}` | Local artefact, not for publication | Локальный артефакт, не для публикации |

4. Use `https://www.youtube-nocookie.com/embed/<id>` for video embeds
5. One channel — one embed (don't duplicate)
6. Setup-card checkboxes persist in localStorage with key `research-<slug>-checklist`

### Phase 7 — Finalize

1. **Start an HTTP server** in the background:
   ```bash
   cd <out_dir> && python3 -m http.server 8765 > /dev/null 2>&1 &
   ```
   If port 8765 is busy — try 8766, 8767, … up to 8775. Record the chosen port.
   Artefact URL: `http://localhost:<port>/`

2. **Verify availability** — `curl -s -o /dev/null -w "%{http_code}" <URL>` should return 200.

3. **Create CHANGELOG.md** with a first entry:
   ```markdown
   # Changelog research <slug>

   ## YYYY-MM-DD — Initial generation
   - Videos: N
   - Setups: M
   - Shops: K
   - Components with URLs found: P / total
   ```

4. **(Optional) Memory updates** — only if your Claude Code setup uses a persistent memory store (e.g. superpowers / a custom MEMORY.md):
   - Add a `project_research_<slug>.md` entry with `status=active`
   - Refresh / create `reference_<location-kebab>_stores.md` for cumulative shop knowledge
   - Index it in your top-level MEMORY.md

   If your environment doesn't use such a store — skip this step. The artefact in `<out_dir>` is fully self-contained.

5. **Final chat message:**

```
✅ Done. Artefact: http://localhost:<port>/

**Topic:** <topic>
**Location:** <location>
**Slug:** <slug>
**Setups:** N | **Shops:** M | **Sources:** V

I'm staying in this topic. Ask now or come back later:
- compare setups / pick the optimal one
- what to upgrade once budget grows
- accessories for the chosen setup
- refresh prices / availability
- expand into an adjacent topic (e.g. acoustics, post-processing)
```

---

## Adjacent topic expansion (consultation mode)

After Phase 7 the assistant stays in "topic expert" mode.

### Inline expansion (1-2 sections on the page)

When the user asks about an accessory / minor adjacent question that fits in 1-2 sections:

1. Mini WebSearch + WebFetch (≤15 sources)
2. Add a new section to `<out_dir>/index.html` (e.g. `#accessories-recommended`)
3. Append to `<out_dir>/CHANGELOG.md`:
   ```markdown
   ## YYYY-MM-DD — Inline expansion: <topic>
   - Added section #<anchor>
   - Sources: N
   ```
4. (Optional) Refresh memory entry for this research with new "open questions" / "what was bought".

### Big expansion (its own 5+ components)

When the question turns into its own research:

1. Offer the user: "this is a separate topic now. Run /research-buy with imported location, budget and a link to this research?"
2. On agreement — start a new run with `parent_slug=<current>`
3. Same pipeline; in Phase 0 import parameters from the parent.

### Boundary inline vs new research

Subjective — the assistant decides:

- 1-2 sections, ≤15 sources, no full setup tables → inline
- 5+ slots, own budget structure, own shop set → new research

When in doubt — ask the user.

---

## Resuming in a new session

If a future session says "let's continue with <topic>" / "more on shopping in <location>" / "add to that research about X":

1. Search your memory store / `MEMORY.md` for an active record by slug/topic/location
2. If 1 match — open it, read `<out_dir>/index.html` + memory, confirm "continue with <slug>?"
3. If 2+ — ask "you have several active, which one?"
4. If 0 — fallback: "no active research found, want to start a new /research-buy?"

If your environment has no persistent memory — the artefact directory itself is the source of truth: search by `<out_dir>/CHANGELOG.md` files.

---

## Principles (strict)

1. **Autonomous after the brief.** Phases 2-7 run without confirmation gates.
2. **Local artefact only.** No publishing to the internet. No git push, no third-party CMS, no chat broadcasting.
3. **Don't fabricate "sold out" / outdated state.** Tag honestly: `🟡 sold out, check with shop`.
4. **Languages.** UI of the page = brief language. Sources = whichever is relevant (mix EN with local language as needed).
5. **`yt-dlp` via `uvx`.** No `brew install` / `pip install` baked into the pipeline. If `uvx` is missing, install once via `curl -LsSf https://astral.sh/uv/install.sh | sh` (Linux/Mac), `brew install uv` (Mac), or `pip install uv`. If install is not possible — skip the YouTube phase with a warning, do not block the rest of the pipeline.
6. **Shops with JS-rendered prices.** Tag "price not retrieved via web", do not hallucinate a number.
7. **Memory cache for shops.** Cumulative across sessions when the environment supports it. If `reference_<location>_stores.md` exists — start from it, refresh, add. Optional: skip if no memory store.
8. **Concurrency.** Phase 5 (shopping) depends on Phase 3 (catalog), so they run sequentially. Within Phase 5 the subagent may parallelise WebFetches across shops. The YouTube subagent (Phase 2) and the catalog work (Phase 3) may overlap if you have spare budget — but Claude main blocks on Phase 2 results before Phase 3 conclusions.
9. **Output dir.** Default `./research/<slug>/`. Override via `out_dir`. Don't write outside `<out_dir>` except the optional memory updates in Phase 7.4.
10. **Privacy of personal context.** If sources surface real names of people in non-public contexts — anonymize before writing into the artefact.

---

## What this skill does NOT do

- **Doesn't work for non-equipment topics** (cafes, courses, travel itineraries, real estate) — fail-fast with "this topic doesn't fit equipment-research-pattern, use brainstorming or a different skill".
- **Doesn't call shops** — adds "needs a phone call" to the user's checklist.
- **Doesn't perform checkout** — no purchase operations.
- **Doesn't write opinionated brand-vs-brand reviews as if it's an expert** — that's a reviewer's job. It states the spec differences and leaves the choice to the user.
- **Doesn't write anything but research artefacts** into `<out_dir>` — no draft articles, tasks, or unrelated docs.
- **Doesn't publish to the internet without explicit request.** If the user says "publish" — that's a separate operation, not part of the skill.

---

## Pre-completion checklist

- [ ] `<out_dir>/` exists and is non-empty
- [ ] `index.html` rendered, all `{{...}}` placeholders replaced
- [ ] localhost server is running on a free port
- [ ] `curl http://localhost:<port>/` returns 200
- [ ] All components from `components.md` are present in `shopping.md` (or explicitly tagged "not found")
- [ ] `CHANGELOG.md` created with the first entry
- [ ] (Optional) memory entries created/updated, indexed
- [ ] Final chat message sent with an explicit invitation to keep talking
- [ ] Consultation mode availability is signalled

---

## Skill files

- `<skill_dir>/template.html` — HTML page template with `{{...}}` placeholders
- `<skill_dir>/extract.sh.template` — bash template for collecting YouTube metadata + frames via `uvx yt-dlp` and `ffmpeg`

`<skill_dir>` is the directory where this SKILL.md sits — typically `~/.claude/skills/research-buy/` (Claude Code) or wherever your harness loads skills from.
