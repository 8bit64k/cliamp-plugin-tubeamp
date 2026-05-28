# CHECKPOINT — cliamp-plugin-tubeamp

**Status:** Shipped. v1.2.0 public. Announced on X 2026-05-28.

---

## What this project is

A Lua visualizer plugin for [cliamp](https://github.com/bjarneo/cliamp) — renders the 10-band EQ as glowing vacuum tubes with amber-to-white-hot filaments, red overdrive flare, phosphor afterglow, peak markers, VU needles, and a chrome chassis with frequency labels.

Single-file Lua, ANSI 256-color, ~480 lines.

---

## Where things are

| | |
|---|---|
| Repo | https://github.com/8bit64k/cliamp-plugin-tubeamp (public) |
| Default branch | `master` |
| Latest tag | `v1.2.0` |
| Release | https://github.com/8bit64k/cliamp-plugin-tubeamp/releases/tag/v1.2.0 |
| Install path (Nick's machines) | `~/.config/cliamp/plugins/tubeamp.lua` |
| Authoritative design doc | `docs/DESIGN.md` (32 KB, 15 sections, agent-handoff-ready) |
| Demo GIF | `assets/cliamp-tubeamp-01.gif` (4 MB after `gifsicle -O3 --colors 256 --lossy=80`) |

---

## Release history

| Version | Tag | What landed |
|---------|-----|------------|
| 1.0.0 | (no tag) | Initial implementation. 10 tubes, glow ramp, overdrive, peaks, VU, labels. |
| 1.1.0 | (no tag) | Responsive width: stretches gaps then centers. Tier-down to COMPACT/MINI/HIDDEN. No more wrapping. |
| 1.2.0 | `v1.2.0` | Row-budget priority (filaments > envelopes > VU > labels). Cliamp's default 5-row pane now gets a proper 3-filament tube instead of a chrome sandwich. First public release. |

---

## Verification performed

- Lua syntax check (clean parse)
- Standalone render harness across 5 brightness scenes (idle, quiet bass, rock mix, overdrive, max)
- Layout sweep across 15 size combinations (200 cols → 18 cols, 22 rows → 2 rows) — no overflow at any size, all tiers transition cleanly
- Real-cliamp smoke test on macOS (Nick) — install/uninstall/play cycle clean, `~/.config/cliamp/plugins.log` empty
- Tier-transition test: state preserved across resize sequence `100 → 40 → 25 → 18 (HIDDEN) → 100` — no cold-tube flicker on resume

---

## Known limitations (documented in DESIGN.md §13)

1. No truecolor mode (ANSI 256 only). v2 idea — read `COLORTERM` from env, switch to 24-bit ramp if available.
2. No fractional Unicode block fill — uses `░▒▓█` shading instead. Intentional: shades read as glowing density, partial blocks read as discrete bar tips.
3. Smoothing is not dt-aware. Fine in practice because cliamp's tick rate is stable and music visibility is low during slow ticks.
4. Wide-terminal cap at ~165 cols (deliberate to avoid sparse-fence look). Could expose as config in v2.

---

## v2 ideas (parking lot — DESIGN.md §13)

- Truecolor amber gradient behind `color_mode = "truecolor"` toggle
- Glass reflection highlight on tube upper-left
- Subtle frame-driven filament flicker
- Heater preamp glow (always-on warm row at bottom)
- Per-band custom labels
- Themes: military green phosphor, nixie orange, cathode cyan-green

---

## Related parking lot

A sibling project at `~/builds/cliamp-plugin-ascii-eq/` holds the brainstorm for a future cliamp visualizer that animates user-supplied ASCII art from the EQ feed. Paused pending Nick's decisions on:
- Combo choice (recommended: column-bob + glow illumination)
- Test ASCII art file
- Final plugin name

See `~/builds/cliamp-plugin-ascii-eq/BRAINSTORM.md` for the full design space (8 approaches with pros/cons) when work resumes.

---

## Notes for the next agent

- The repo uses MIT license, attributed to `8bit64k` (per builds/AGENTS.md — never `Nick`).
- Cliamp's plugin manager strips the `cliamp-plugin-` prefix on install, so the user-visible name is `tubeamp`.
- The entry file `tubeamp.lua` MUST stay at repo root — moving it breaks `cliamp plugins install`.
- DESIGN.md §15 has the full pre-PR / pre-release checklist.

---

*Checkpoint written 2026-05-28 at session close. Project parked in shipped state.*
