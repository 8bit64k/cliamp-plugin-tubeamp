# DESIGN.md — cliamp-plugin-tubeamp

> Vintage vacuum-tube amplifier visualizer for [cliamp](https://github.com/bjarneo/cliamp).
> This document is the authoritative reference for the plugin's design, constraints, and integration points.
> An agent dropping into this project should be able to read this file and modify the plugin confidently without reading the upstream cliamp source first.

---

## Table of contents

1. [What this plugin is](#1-what-this-plugin-is)
2. [Upstream project (cliamp) — what you need to know](#2-upstream-project-cliamp--what-you-need-to-know)
3. [The cliamp plugin system, condensed](#3-the-cliamp-plugin-system-condensed)
4. [Visualizer plugin API contract](#4-visualizer-plugin-api-contract)
5. [Design goals & visual brief](#5-design-goals--visual-brief)
6. [Implementation walkthrough](#6-implementation-walkthrough)
7. [Color system](#7-color-system)
8. [State & per-frame timing](#8-state--per-frame-timing)
9. [Configuration surface](#9-configuration-surface)
10. [Constraints & sandbox boundaries](#10-constraints--sandbox-boundaries)
11. [Testing & local verification](#11-testing--local-verification)
12. [Installation & distribution](#12-installation--distribution)
13. [Known limitations & ideas for v2](#13-known-limitations--ideas-for-v2)
14. [File map](#14-file-map)
15. [Agent handoff checklist](#15-agent-handoff-checklist)

---

## 1. What this plugin is

`tubeamp` is a custom visualizer plugin for cliamp that renders the player's 10-band EQ spectrum as a row of glowing vacuum tubes. It is written in Lua, runs inside cliamp's sandboxed `gopher-lua` VM, and uses ANSI 256-color escape sequences to draw amber-through-white-hot filaments with a red overdrive flare on peaks.

It is **not** a fork of cliamp. It is a self-contained Lua plugin shipped in its own repo. cliamp loads it at startup from `~/.config/cliamp/plugins/`.

**Repo:** `8bit64k/cliamp-plugin-tubeamp` (private during QA)
**Install path:** `~/.config/cliamp/plugins/tubeamp.lua`
**cliamp visualizer name:** `tubeamp` (cycle to it with `v` in the player)

---

## 2. Upstream project (cliamp) — what you need to know

### What cliamp is

cliamp is a Bubbletea-based terminal music player inspired by Winamp. Written in Go. Plays local files, HTTP streams, podcasts, and content from many providers (YouTube, YouTube Music, SoundCloud, Bilibili, Spotify, Xiaoyuzhou, Navidrome, Plex, Jellyfin, NetEase Cloud Music, Radio Browser).

**Repo:** https://github.com/bjarneo/cliamp
**Site:** https://cliamp.stream
**Go version:** 1.26 (pinned via `mise.toml`)
**Built with:** Bubbletea (TUI), Lip Gloss (styling), Beep (audio), gopher-lua (plugin VM)

### Local checkout

The upstream is cloned at `~/builds/cliamp/` for reference. Read the following files when you need ground truth:

| Path | What's in it |
|------|--------------|
| `~/builds/cliamp/docs/plugins.md` | User-facing plugin API reference — **the authoritative spec** |
| `~/builds/cliamp/luaplugin/visualizer.go` | Go-side visualizer plugin host — defines the render contract |
| `~/builds/cliamp/luaplugin/luaplugin.go` | Plugin manager: registration, lifecycle, VM-per-plugin isolation |
| `~/builds/cliamp/luaplugin/sandbox.go` | What's removed/restricted in the Lua sandbox |
| `~/builds/cliamp/ui/visualizer.go` | The Visualizer driver that calls into Lua via `RenderVis` |
| `~/builds/cliamp/ui/vis_*.go` | 30+ first-party visualizers — reference implementations for shape and idiom |
| `~/builds/cliamp/ui/tick.go` | Frame cadence constants (`TickFast = 50ms`, `TickSlow = 200ms`) |
| `~/builds/cliamp/plugins/` | First-party bundled Lua plugins (`now-playing.lua`, `auto-eq.lua`, `webhook.lua`, `status-messages.lua`) — reference examples |

### The 10-band EQ

cliamp ships a 10-band parametric EQ with these center frequencies, in order:

| Index (Lua 1-based) | Frequency |
|---------------------|-----------|
| 1 | 32 Hz |
| 2 | 64 Hz |
| 3 | 125 Hz |
| 4 | 250 Hz |
| 5 | 500 Hz |
| 6 | 1 kHz |
| 7 | 2 kHz |
| 8 | 4 kHz |
| 9 | 8 kHz |
| 10 | 16 kHz |

The same band layout is used for the spectrum visualizer feed — the `bands` table passed to `p:render(...)` is normalized FFT energy in those 10 buckets, range 0.0 to 1.0 each.

### Audio analysis pipeline (relevant facts)

- An audio tap (`player/tap.go`) snapshots the post-DSP audio stream into a ring buffer for FFT.
- The visualizer driver (`ui/visualizer.go`) runs FFT (default size 2048), bins into bands, applies a per-mode smoothing/analysis spec, and produces a `[]float64` of 10 normalized values.
- For Lua visualizers, the Go side packages this into a `[10]float64` and passes it through `RenderVis(name, bands, rows, cols, frame)`.
- Bands are already log-magnitude scaled (`(10*log10(sum) + 10) / 50`, clamped 0..1) — the plugin sees a perceptually reasonable spectrum, not raw power.
- Per-frame, frame counter `frame` is monotonic across the visualizer's lifetime.

You do **not** need to do dB conversion, smoothing, or FFT in the plugin. Cliamp's driver has already done the analysis. The plugin's only job is to render.

---

## 3. The cliamp plugin system, condensed

### Plugin types

cliamp has two plugin types: `hook` and `visualizer`. Tubeamp is the latter.

- **hook** — subscribes to events (`track.change`, `playback.state`, `app.start`, `app.quit`, `track.scrobble`) and runs in response. Async, 5s timeout per callback.
- **visualizer** — registers a render callback that cliamp calls every animation frame. Synchronous, 10 ms budget per frame.

### Loading

- Plugins live at `~/.config/cliamp/plugins/`.
- Each `.lua` file (or directory with `init.lua`) is loaded into its own `gopher-lua` VM at startup.
- A plugin is recognized only if it calls `plugin.register({...})`. Files that don't register are silently skipped.
- VMs are isolated — a crash in one plugin cannot affect another or the player. Render errors fall back to the previous frame.

### Registration shape

```lua
local p = plugin.register({
    name        = "tubeamp",         -- required, becomes the visualizer's cycle name
    type        = "visualizer",      -- required for visualizer plugins
    version     = "1.0.0",           -- optional, informational
    description = "...",             -- optional
})
```

The returned object `p` is also where the plugin attaches its callbacks:

- `p.render = function(self, bands, frame, rows, cols) ... end` — required
- `p.init   = function(self, rows, cols) ... end`               — optional, called once on selection
- `p.destroy= function(self) ... end`                            — optional, called on deselection

Note the upstream resolves these by reading the named keys (`render`, `init`, `destroy`) off the registered table after the plugin file finishes executing. The Lua-idiomatic `function p:render(...) end` desugars to `p.render = function(self, ...) end`, which is exactly what we want.

### How render gets called

From `luaplugin/visualizer.go`, function `RenderVis`:

1. Build a 1-indexed Lua table from `[10]float64`.
2. Acquire the plugin's mutex (one render at a time per plugin).
3. Call `p.render(self, bands, frame, rows, cols)` with `Protect: true`.
4. If the call errors, return the last successful frame instead.
5. The render function must return a string. Non-string returns are treated as "use last frame."

### Frame cadence

- `TickFast = 50ms` (20 FPS) when audio is playing and the visualizer pane is foreground.
- `TickSlow = 200ms` (5 FPS) when paused, overlay open, or visualizer hidden.
- Render is allowed up to 10 ms wall time per call. Over budget = previous frame reused.

Per-band level `bands[i]` is updated every analysis tick; FFT cadence is decoupled from render cadence by the audio tap and driver. The plugin should assume render may be called many times in a row without the bands array changing — animations should advance off `frame`, not real-time clocks.

---

## 4. Visualizer plugin API contract

```lua
function p:render(bands, frame, rows, cols)
    --   bands : table { [1]=0.0..1.0, ..., [10]=0.0..1.0 } — 10-band normalized spectrum
    --   frame : monotonic counter, advances each render call
    --   rows  : terminal rows available to the visualizer
    --   cols  : terminal columns available to the visualizer
    -- returns: multi-line string (newline-separated). ANSI escape codes are
    --         passed through Bubbletea unchanged.
end
```

### Inputs

- `bands` is a 1-indexed table. `bands[1]` is 32 Hz, `bands[10]` is 16 kHz.
- Values are floats in [0.0, 1.0]. They may exceed the bounds briefly on transients in some configurations — the plugin clamps defensively.
- `rows` and `cols` reflect the current visualizer pane size. In fullscreen mode, they grow significantly. The plugin must adapt layout (tube width, inner row count) to them.
- `frame` resets to 0 every time the visualizer is selected (after `init`).

### Outputs

- A single multi-line string. cliamp expects `\n`-separated lines.
- ANSI escape sequences (`\x1b[...]m`) are honored — Bubbletea's renderer passes them through.
- Returning fewer lines than `rows` leaves blank space below; returning more is clipped.
- Returning anything that isn't a Lua string (including `nil` or accidental return values from short-circuit `or`) causes cliamp to reuse the previous frame.

### Sandbox restrictions you'll bump into

- No `os.execute`, no `io.*`, no `dofile`, no `loadfile`.
- Network access only via `cliamp.http` (5s timeout, 1MB cap).
- File writes restricted to `/tmp/`, `~/.config/cliamp/`, `~/.local/share/cliamp/`, `~/Music/cliamp/`.
- `cliamp.timer.after/every` and `cliamp.sleep` are available but not used here — visualizers are driven by render calls, not timers.

---

## 5. Design goals & visual brief

### Brief (from user)

> "Build me a custom visualizer plugin that visualizes the eq like old tube amps."

Translation into concrete design goals:

1. **Each EQ band is a tube** — the bank-of-vacuum-tubes aesthetic of a Marshall, Mesa, or Fender amp. 10 bands → 10 tubes.
2. **Warm amber glow** — not Winamp green, not bare grayscale. The signature tube look is amber/orange filament with white-hot peaks.
3. **Overdrive** — tubes pushed past a threshold should visibly flare red. This conveys "running hot" the way an analog amp does, and it's expressive on loud transients.
4. **Phosphor afterglow** — tubes don't snap off when the signal drops. They cool down gradually, like a heated filament losing energy. This is also why tubes never go fully dark.
5. **Chrome chassis & legible frequency labels** — frame the tube bank with rails and engrave Hz labels so the visualization doubles as a legible spectrum reference.
6. **VU needle row** — pay homage to the analog needle meters that sit on real amp faceplates. Use them as instantaneous level under each tube.
7. **Peak hold markers** — a dot floats at the recent maximum and slowly decays. Standard spectrum-analyzer feature; reads well on screens with motion.

### Non-goals

- 3D perspective, ray-marching, or per-pixel lighting. This is a TUI plugin running 20 FPS through a Lua VM with a 10 ms budget. Keep it cheap.
- Procedural tube damage / glow flicker beyond what the audio drives. We're not simulating a real tube — we're stylizing.
- Multi-line track-info overlay. cliamp draws track info elsewhere. The visualizer renders the spectrum and nothing else.

### Visual hierarchy

```
   chrome rail │ tube envelopes (10 across)                  │ chrome rail
   ────────────┼──────────────────────────────────────────────┼────────────
   glass top   │ ╭──╮                                         │  glass top
   filaments   │ │██│  glow fills bottom-up                   │  filaments
               │ │██│  amber → gold → white → red overdrive   │
               │ │░░│  peak ● floats inside the column        │
   glass base  │ ╰──╯                                         │  glass base
   VU needle   │ [▬▬▬··]   per-band instantaneous level       │  VU needle
   chassis lbl │   125     centered frequency label           │  chassis lbl
```

---

## 6. Implementation walkthrough

Everything lives in **`tubeamp.lua`** (single file, ~330 lines). The implementation is intentionally flat — no modules, no requires, no helper files. This avoids the dance with cliamp's `init.lua` directory convention and keeps the plugin trivial to audit.

### Top of file: registration

```lua
local p = plugin.register({
    name        = "tubeamp",
    type        = "visualizer",
    version     = "1.0.0",
    description = "Vintage vacuum-tube amplifier — warm amber glow per EQ band",
})
```

This is the only side effect at load time. Everything else is function definitions and the per-instance state table.

### Configuration pull

```lua
local cfg_gain        = tonumber(p:config("gain")) or 1.0
local cfg_smooth_up   = tonumber(p:config("attack")) or 0.55
local cfg_smooth_down = tonumber(p:config("release")) or 0.18
local cfg_overdrive   = tonumber(p:config("overdrive")) or 0.78
```

`p:config(key)` reads from `[plugins.tubeamp]` in `~/.config/cliamp/config.toml`. All four are optional; all defaults are tuned for "musical."

### ANSI helpers

```lua
local ESC = string.char(27)
local function fg256(n)  return ESC .. "[38;5;" .. n .. "m" end
local function bg256(n)  return ESC .. "[48;5;" .. n .. "m" end
local function bold()    return ESC .. "[1m"  end
local function reset()   return ESC .. "[0m"  end
```

256-color ANSI only. No 24-bit truecolor — the Hermes ecosystem (and most TUI users) sit on terminals where 256 is the universal safe choice, and Lip Gloss/Bubbletea on the cliamp side uses ANSI color types throughout.

### Color ramps

Two ramps, picked from the ANSI 256 palette:

- **Glow ramp** (cold → hot): 11 stops from near-black (232) through deep red-brown, amber, orange, gold, to pure yellow (226). These are the filament colors at increasing temperature.
- **Overdrive ramp**: 4 stops from red (160) through bright red (196) to magenta-pink (198). Triggered above the configurable threshold.

```lua
local function glow_color(level, hot)
    if hot then
        local idx = clamp(floor(level * (#overdrive_ramp - 1)) + 1, 1, #overdrive_ramp)
        return overdrive_ramp[idx]
    end
    local idx = clamp(floor(level * (#glow_ramp - 1)) + 1, 1, #glow_ramp)
    return glow_ramp[idx]
end
```

Plus three chrome shades (`CHROME_DIM=240`, `CHROME=250`, `CHROME_LO=236`) and a label gray (`LABEL=244`).

### Per-instance state

```lua
local smoothed = {0,0,0,0,0,0,0,0,0,0}
local peaks    = {0,0,0,0,0,0,0,0,0,0}
local peak_age = {0,0,0,0,0,0,0,0,0,0}

function p:init(rows, cols)
    for i = 1, 10 do
        smoothed[i] = 0
        peaks[i]    = 0
        peak_age[i] = 0
    end
end
```

`init` resets the smoothing on visualizer selection so we don't carry over stale state from a previous activation. The state is module-local (not on `p`) because each plugin lives in its own VM — there is no contention.

### Layout

Layout adapts to terminal size in four tiers via `pick_layout(rows, cols)`:

| Tier | Min cols | Min rows | Width-fixed | Components |
|------|----------|----------|-------------|-----------|
| **FULL**    | 53 (`4 + 10×4 + 9×1`) | 4 | tubes 4–9 + gaps 1–5 + rails | rails + envelopes + filaments + (VU at ≥6 rows) + (labels at ≥9 rows) |
| **COMPACT** | 39 (`10×3 + 9×1`)     | 4 | tubes=3 gaps=1                | envelopes + filaments + (VU at ≥6 rows) + (labels at ≥9 rows) |
| **MINI**    | 19 (`10×1 + 9×1`)     | 3 | tubes=1 gaps=1                | 1-char glow columns + thin VU; no envelopes |
| **HIDDEN**  | otherwise             | otherwise | n/a                       | returns `""` |

**Row-budget priority (high → low):** **filaments > envelopes > VU > labels.**

Cliamp's default normal-mode visualizer pane is **5 rows** (constant `DefaultVisRows` in `ui/visualizer.go`). The visualizer pane only grows beyond that when the user toggles full-vis mode with shift+V (`m.height-10)*4/5` in `ui/model/keys.go`). The previous (v1.1.0) layout consumed 4 of those 5 rows for chrome (top envelope + bottom envelope + VU + label), leaving a 1-row filament that didn't read as a tube at all.

v1.2.0 rebalances this. The `alloc_with_envelopes(rows)` helper applies the priority:

```lua
local function alloc_with_envelopes(rows)
    if rows < 4 then return nil end       -- need at least envelopes + 2 filament rows
    local show_vu     = rows >= 6
    local show_labels = rows >= 9
    local fixed = 2 + (show_vu and 1 or 0) + (show_labels and 1 or 0)
    local inner = rows - fixed
    if inner < 2 then inner = 2 end
    if inner > 14 then inner = 14 end
    return inner, show_vu, show_labels
end
```

Empirical row → component breakdown at any FULL/COMPACT width:

| Pane rows | Lines | Components                              | Filament rows |
|-----------|-------|-----------------------------------------|--------------|
| 4         | 4     | envelopes + filaments                   | 2 |
| **5** (cliamp default) | 5 | **envelopes + filaments**          | **3** |
| 6         | 6     | envelopes + filaments + VU              | 3 |
| 7         | 7     | envelopes + filaments + VU              | 4 |
| 8         | 8     | envelopes + filaments + VU              | 5 |
| 9         | 9     | envelopes + filaments + VU + labels     | 5 |
| 12        | 12    | envelopes + filaments + VU + labels     | 8 |
| 16        | 16    | envelopes + filaments + VU + labels     | 12 |
| 18+       | 18    | all four, filaments capped at 14        | 14 |

**Why tiered, not continuous:** the visual identity (envelopes, rails, labels) breaks down at small sizes. A smooth scaling function would produce ugly fractional widths and broken glyph alignment. Discrete tiers let each layout be tuned independently.

**Width fill behavior in FULL tier:**

1. Start at `tube_w = TUBE_W_MIN (4)`.
2. Grow `tube_w` toward `TUBE_W_MAX (9)` as long as it fits.
3. Grow `gap` toward `GAP_MAX (5)` as long as it fits.
4. Whatever cols remain become symmetric left/right padding (centering).

This means narrow-to-medium terminals fully use their width; very wide terminals stop expanding gaps before they look like a sparse fence, and the remainder pads to center the block. Realistic terminal sizes (80–160 cols) end up >95% utilized.

```lua
local TUBE_W_MIN = 4   -- minimum tube width for FULL tier (with rails)
local TUBE_W_MAX = 9   -- maximum tube width (above this, tubes look stretched)
local GAP_MAX    = 5   -- maximum inter-tube gap when stretching to fill width
```

**Why HIDDEN exists:** when the terminal is too small to fit even the MINI tier (cols < 19 or rows < 3), wrapping mini-tubes across multiple visual rows looks broken. Returning `""` (an empty string is a valid Lua return that cliamp passes through verbatim) means the pane goes blank until the user resizes back up. State (smoothed levels, peak hold, afterglow) is updated on every render regardless of tier, so resizing back to a visible tier resumes mid-flow rather than starting cold.

```lua
local function tube_width(cols)
    local usable = cols - 4
    local per = math.floor(usable / 10)
    return clamp(per, 4, 9)
end
```

The above (from v1.0.0) was replaced in v1.1.0 by `pick_layout(rows, cols)`, which returns a struct containing tube_w, gap, left_pad, plus boolean flags for which optional rows (rails, envelope, VU, labels) to render.

### The render pipeline

For each render call:

1. **Smooth + peak track** every band:
   - Asymmetric smoothing: if raw > smoothed, `smoothed += (raw - smoothed) * cfg_smooth_up` (fast attack).
   - If raw < smoothed, `smoothed -= (smoothed - raw) * cfg_smooth_down` (slow release).
   - This gives the "filament heats fast, cools slow" feel and decouples animation from the upstream band update rate.
   - Peak tracker: new peak captures the smoothed value and resets `peak_age` to 0. Otherwise age increments. After 10 frames of hold, the peak falls by 0.012 per frame.
2. **Build layout**: pick `tube_width` and `tube_inner_rows`.
3. **Emit rows in order**:
   - Glass top: `╭──...─╮` chrome-colored, joined across all 10 tubes with a 1-space gap.
   - Filament rows (top to bottom): for each band, compute fill density for this row, pick a glow color, place the peak marker if the peak lives in this row.
   - Glass base: `╰──...─╯`.
   - VU needle row: `[▬▬▬··]` per band, filled `level * inner_width` chars, colored along the same ramp.
   - Chassis label row: centered frequency string per band.
4. Return the assembled string.

### Filament fill rendering

For each filament row in each tube, we compute:

- `row_bottom = (row - 1) / tube_inner_rows`
- `row_top    = row     / tube_inner_rows`
- If `level >= row_top`: row is fully filled.
- Else if `level > row_bottom`: row is partial — `fill_density = (level - row_bottom) / (row_top - row_bottom)`.
- Else: row is unlit — but we render a tiny ambient dither (`░` at very dim glow) so the tube isn't pitch black. **This is the "always-warm" phosphor look.**

The shade glyph for the row is picked by density:

| Density | Glyph |
|---------|-------|
| ≤ 0    | space |
| < 0.25 | `░`   |
| < 0.55 | `▒`   |
| < 0.85 | `▓`   |
| ≥ 0.85 | `█`   |

In overdrive, glyphs are emitted with the bold ANSI attribute to push the red filament an extra notch brighter on terminals that map bold to bright.

### Peak marker placement

```lua
local peak_row = math.ceil(peaks[i] * tube_inner_rows + 0.001)
local has_peak_here = (peak_row == row) and (peaks[i] > 0.05) and (peak_age[i] <= 30)
```

A small `●` (yellow normally, red in overdrive) is inserted at the visual midpoint of the filament row at the peak's altitude. It floats above the filament because the row containing it is shaded the same way whether peak or not — only the center cell is overwritten. The `peak_age[i] <= 30` cap suppresses the marker once it's old enough to be distracting.

### VU needle

Per band, the bottom row draws `[ ... ]` brackets around `inner_w` cells. The leftmost `level * inner_w` cells get filled `▬` characters, colored along the glow ramp by their **position in the needle** (not by overall level), so the needle itself is multi-colored — green/amber on the left, gold on the right, red when overdriven.

### Chassis labels

Just centered text in `tube_width` columns, rendered in dim gray to suggest engraving. Labels are hardcoded:

```lua
local band_labels = { "32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k" }
```

---

## 7. Color system

### Why ANSI 256 (not truecolor)

- cliamp's first-party visualizers use Lip Gloss's `lipgloss.ANSIColor(n)` — ANSI 16/256 throughout. Matching that palette keeps the plugin consistent with the chassis on themes that use ANSI bright colors.
- ANSI 256 is universally supported. Truecolor (24-bit) is supported on most modern terminals but not all, and the failure mode (color stripped or mangled) is much uglier than a 256→16 fallback.

### Palette reference

| Role | ANSI 256 index | What it looks like |
|------|----------------|--------------------|
| Cold filament | 232–234 | nearly black, faint warmth |
| Deep glow | 52 | dark red-brown |
| Warming up | 94, 130 | dark amber → amber |
| Hot | 166, 202 | orange → bright orange |
| Very hot | 208, 214 | amber-yellow → gold |
| White-hot | 220, 226 | bright yellow → pure yellow |
| Overdrive 1 | 160 | red |
| Overdrive 2 | 196 | bright red |
| Overdrive 3 | 197, 198 | red-pink → magenta |
| Chrome bright | 250 | bright gray |
| Chrome mid | 240 | mid gray |
| Chrome shadow | 236 | dark gray |
| Label engraving | 244 | dim gray |

All values were tuned by eye against a dark terminal background. Light terminal backgrounds (which nobody runs cliamp on, but in principle) will wash out the cold filament shades.

---

## 8. State & per-frame timing

### Why a custom smoother

cliamp already smooths the bands before the visualizer sees them (see `ui/visualizer.go` band smoothing chain). But that smoother is tuned for the default smooth-bars look — symmetric attack/release, conservative decay.

The tube look wants asymmetric behavior: **fast attack** so a kick drum lights the bass tube immediately, **slow release** so the filament glows on after the transient. So tubeamp does its own additional smoothing pass on top of the already-smoothed bands.

Defaults (`attack=0.55`, `release=0.18`) are tuned for the typical 20 FPS render cadence. If render is called slower (overlay open, 5 FPS), the smoother converges proportionally slower per call — which mostly looks correct because the bands aren't changing fast in those states anyway. There is no `dt`-aware smoothing here; we trust the cadence.

### Peak hold + decay

- 10-frame hold from the moment a new peak is captured.
- After that, `peak -= 0.012` per render until it meets `smoothed`.
- At 20 FPS, this is a ~1.7 second decay from peak=1.0 to peak=0 — feels right for a VU meter.

### Frame counter

`frame` is exposed by the host but we don't use it for anything. All animation falls out of the smoothed/peak state machine. That's deliberate — using `frame` to drive flicker or oscillation would look fake against a visualizer whose entire premise is "this is reacting to the music."

---

## 9. Configuration surface

Lives in `~/.config/cliamp/config.toml`:

```toml
[plugins.tubeamp]
gain = 1.0        # multiplier on incoming bands (clamped to 1.0 post-multiply)
attack = 0.55     # 0..1 — higher = snappier rise on signal
release = 0.18    # 0..1 — lower = slower fade = more afterglow
overdrive = 0.78  # 0..1 — bands at or above this level flare red
```

All four are read once at plugin load. Hot-reload of config is not supported (would require restarting cliamp or re-installing the plugin) because we cache them in module-locals.

Why not more config? Because everything else is part of the visual identity. The chrome color, the glyph set, the band labels, the layout — those are not knobs, they're the design. If a user wants a different visualizer, they should use a different visualizer.

---

## 10. Constraints & sandbox boundaries

| Limit | Source | Why it matters here |
|-------|--------|---------------------|
| 10 ms per `render` call | `luaplugin/visualizer.go` | Our render loop is O(rows × cols) string concat per frame. At 20×80 that's well under budget. At fullscreen on a 4K terminal it might tighten — see "v2 ideas" below. |
| Return-string only | host | Returning `nil`, a number, or accidentally not returning at all causes silent frame reuse. Always `return table.concat(lines, "\n")`. |
| No `os.execute` / `io.*` / `dofile` | sandbox | We don't need them. All state is in-memory. |
| Render serialized per plugin | host mutex | We can't be re-entered. State mutation in `render` doesn't need locks. |
| ANSI escapes pass through | Bubbletea | Confirmed by inspection of cliamp's `vis_*.go` first-party renderers which use the same mechanism via Lip Gloss. |
| Bands always length 10 | host | The Go side passes `[10]float64` unconditionally. Loops can be unrolled / 1-indexed without bounds checks. |

---

## 11. Testing & local verification

### Syntax check (no host)

```sh
lua /home/nick/builds/cliamp-plugin-tubeamp/tubeamp.lua
```

Will print "attempt to index a nil value (global 'plugin')" — that's expected if you don't stub the host. A clean syntax error (unexpected symbol, missing end, etc.) will surface here before the host loads it.

### Standalone render harness

The repo doesn't include a harness file (to keep distribution minimal), but the pattern is:

```lua
-- /tmp/render_tubeamp.lua
plugin = {
    register = function(spec)
        function spec:config(k) return nil end
        function spec:on(ev, fn) end
        function spec:bind(k, d, fn) end
        _G.PLUGIN_OBJ = spec
        return spec
    end
}
cliamp = { log = { info = function() end, warn = function() end, error = function() end, debug = function() end } }

dofile("/home/nick/builds/cliamp-plugin-tubeamp/tubeamp.lua")

local p = _G.PLUGIN_OBJ
if p.init then p:init(20, 80) end

-- Pump several frames so smoothing converges
local bands = {0.65, 0.70, 0.55, 0.40, 0.35, 0.45, 0.55, 0.50, 0.40, 0.30}
for f = 1, 12 do
    local out = p:render(bands, f, 20, 80)
    if f == 12 then io.write(out, "\n") end
end
```

Then `lua /tmp/render_tubeamp.lua`. Piping to a terminal that supports ANSI will render the colored output.

This was the exact harness used during development to verify all 5 brightness scenes (idle, quiet bass, rock mix, hot/overdrive, max-everything) before installing.

### In-host verification

1. `cp ~/builds/cliamp-plugin-tubeamp/tubeamp.lua ~/.config/cliamp/plugins/` (or symlink).
2. Start cliamp on real audio.
3. Press `v` until the cycle reaches `tubeamp`.
4. Check `~/.config/cliamp/plugins.log` for errors. If `render handler error: ...` shows up, the visualizer falls back to the previous frame silently — you won't see it in the UI.

### What to look for during QA

- Tubes light bottom-up smoothly as signal rises.
- On a kick drum, the bass tube (leftmost) snaps to bright fast and decays over ~1 second.
- On loud music, the top of the brightest tubes should flare red — not the whole tube, just the top portion.
- Peak markers (`●`) float and decay; no markers stuck at altitude.
- VU needles read like fluid bars under the tubes.
- Chassis labels stay aligned across cliamp window resizes.
- Fullscreen mode (resize cliamp's spectrum pane to full): tube width should grow to the cap (9 cols) and rows should grow to the cap (14 inner) — no rendering glitches at either extreme.

---

## 12. Installation & distribution

### cliamp's install convention

cliamp's plugin manager (`pluginmgr/`) recognizes repos named `cliamp-plugin-<name>` and installs the entry `<name>.lua` from the repo root. The `cliamp-plugin-` prefix is stripped on install, so the user-visible plugin name is just `tubeamp`.

This repo follows that convention exactly: repo is `cliamp-plugin-tubeamp`, entry is `tubeamp.lua` at the root, no directory wrapper.

### Install sources accepted by cliamp

```sh
# Once the repo is public:
cliamp plugins install 8bit64k/cliamp-plugin-tubeamp
cliamp plugins install 8bit64k/cliamp-plugin-tubeamp@v1.0.0
# Always:
cliamp plugins install https://raw.githubusercontent.com/8bit64k/cliamp-plugin-tubeamp/master/tubeamp.lua
# Manually:
cp tubeamp.lua ~/.config/cliamp/plugins/
```

### Versioning

- `version` in `plugin.register({...})` is informational only; cliamp doesn't act on it.
- Git tags (`v1.0.0`, etc.) are how cliamp's plugin manager pins installs.
- Bump the version string in `tubeamp.lua` alongside any meaningful release tag for human-readable plugin logs.

### Branch policy

- `master` is the default and only long-lived branch.
- Feature work happens in topic branches → PR → merge into master.
- Tags created off master after each release.

### Visibility

- Currently **private** during QA.
- Flip to public when ready:
  ```sh
  gh repo edit 8bit64k/cliamp-plugin-tubeamp --visibility public
  ```

---

## 13. Known limitations & ideas for v2

### Limitations

1. **No truecolor mode.** Users on terminals that render 256 colors poorly (rare) will see banding in the warm ramp. The fix would be a runtime detection of `COLORTERM=truecolor` and a secondary `fg24(r,g,b)` path. Not done because we have no way to read env vars… actually, the sandbox does expose `os.getenv()` — so this is a one-liner to add in v2.
2. **No fractional Unicode block fill.** First-party `vis_bars.go` uses `▁▂▃▄▅▆▇█` for sub-row vertical resolution. Tubeamp uses `░▒▓█` instead, which is more shading than partial fill. The trade-off: shade glyphs look like glowing density (correct for tubes), partial-block glyphs look like discrete bar tips (correct for bars). Reconsider if the v2 brief is "more precise level reading."
3. **Smoothing is not dt-aware.** If cliamp's tick rate changes (it does — TickSlow at 200ms during pauses), the smoother converges per-tick at the same rate regardless of wall-clock dt. In practice this is fine because the visible motion during slow ticks is minimal. A dt-aware smoother would be more correct but adds complexity for a benefit users won't notice.
4. **Wide-terminal cap.** Above ~165 cols, the FULL tier stops expanding and centers the block. Tubes don't sprawl across a 200-col terminal because they'd look like islands. This is a deliberate choice; v2 could expose `max_block_width` as config if users want different behavior.

### v2 ideas

- **24-bit truecolor ramp** behind a config toggle (`color_mode = "truecolor"`), with smooth amber gradient interpolation.
- **Glass reflection** — a faint highlight on the upper-left of each tube envelope, drawn with one or two extra characters at fixed positions.
- **Filament flicker** — a small `frame`-driven oscillation on tube brightness when the band is steady, simulating real-world tube noise. Subtle. Easy to overdo.
- **Heater preamp glow** — a thin always-on warm row at the very bottom inside the tube (1-2 chars wide, dim red-orange), independent of signal. This is what the cathode heater looks like on a real tube viewed sideways.
- **Per-band custom labels** — for users with non-standard EQ (Bass/Mid/Treble custom builds).
- **Themes** — `vintage` (current), `military` (green phosphor instead of amber), `nixie` (orange like Nixie tubes), `cathode` (cyan-green like an old oscilloscope).

---

## 14. File map

```
cliamp-plugin-tubeamp/
├── .gitignore              # .DS_Store, *.swp, *.bak
├── LICENSE                 # MIT, Copyright 2026 8bit64k
├── README.md               # User-facing install + config
├── tubeamp.lua             # The plugin itself (single file, ~330 lines)
└── docs/
    └── DESIGN.md           # This document
```

Repo root holds the entry file (`tubeamp.lua`) because cliamp's plugin manager looks there. Don't move it into `src/` or `plugin/` — installation will break.

---

## 15. Agent handoff checklist

Before declaring any change "done," verify:

- [ ] `lua tubeamp.lua` parses (will error on `plugin global` but that's expected — what matters is no syntax errors).
- [ ] Standalone render harness produces visible output across all 5 brightness scenes (idle, quiet bass, rock mix, overdrive, max).
- [ ] Tubes still light bottom-up. (Easy to flip the row iteration accidentally.)
- [ ] ANSI escape counts are non-zero in the output (`lua harness.lua | grep -c $'\\x1b\\['`).
- [ ] Frequency labels (`32, 64, 125, ... 16k`) are present and aligned.
- [ ] Plugin installs into `~/.config/cliamp/plugins/tubeamp.lua` and shows up in cliamp's visualizer cycle.
- [ ] `~/.config/cliamp/plugins.log` has no `[tubeamp] error` entries after a fresh playback session.
- [ ] README.md reflects the current config keys (no drift between README and `tubeamp.lua`).
- [ ] If you changed the rendering shape (rows, columns, glyphs, colors), update the ASCII example block near the top of this DESIGN.md and the README.
- [ ] Commits authored as 8bit64k (per `/home/nick/builds/AGENTS.md`).
- [ ] Bump `version` in `plugin.register({...})` for any user-visible behavior change.
- [ ] CHECKPOINT.md updated (if the project gains one). At time of writing, this is a small single-file plugin and a CHECKPOINT isn't warranted — but if scope grows, create one.

---

*Last reviewed: 2026-05-28. Version covered: tubeamp 1.2.0.*
