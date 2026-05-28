# cliamp-plugin-tubeamp

A vintage **vacuum-tube amplifier** visualizer for [cliamp](https://github.com/bjarneo/cliamp). Each EQ band is rendered as a glowing tube. Filaments heat from warm amber through gold and white-hot, then bleed into red when the signal overdrives. Phosphor afterglow gives tubes that always-warm look — even at idle, the bulbs have a faint ember glow.

```
║ ╭─────╮ ╭─────╮ ╭─────╮ ╭─────╮ ╭─────╮ ╭─────╮ ╭─────╮ ╭─────╮ ╭─────╮ ╭─────╮ ║
║ │█████│ │██●██│ │░░░░░│ │░░░░░│ │░░░░░│ │░░░░░│ │▒▒●▒▒│ │▓▓●▓▓│ │░░░░░│ │░░░░░│ ║
║ │█████│ │█████│ │░░●░░│ │░░░░░│ │░░░░░│ │▒▒●▒▒│ │█████│ │█████│ │░░░░░│ │░░░░░│ ║
║ │█████│ │█████│ │█████│ │░░░░░│ │██●██│ │█████│ │█████│ │█████│ │▒▒●▒▒│ │░░░░░│ ║
║ │█████│ │█████│ │█████│ │▓▓●▓▓│ │█████│ │█████│ │█████│ │█████│ │█████│ │░░░░░│ ║
║ │█████│ │█████│ │█████│ │█████│ │█████│ │█████│ │█████│ │█████│ │█████│ │▒▒●▒▒│ ║
║ ╰─────╯ ╰─────╯ ╰─────╯ ╰─────╯ ╰─────╯ ╰─────╯ ╰─────╯ ╰─────╯ ╰─────╯ ╰─────╯ ║
║ [▬▬▬▬·] [▬▬▬▬▬] [▬▬▬▬·] [▬▬▬··] [▬▬▬▬·] [▬▬▬▬·] [▬▬▬▬·] [▬▬▬▬▬] [▬▬▬▬·] [▬▬▬··] ║
║   32      64      125     250     500     1k      2k      4k      8k      16k   ║
```

## Features

- **10 tubes**, one per cliamp EQ band, labeled by frequency (32 Hz – 16 kHz)
- **Warm amber glow** that brightens with level — uses the ANSI 256 color palette so it works on any modern terminal
- **Overdrive flare**: bands above 78% bleed into red, the "running hot" look of a tube driven into clipping
- **Peak hold markers** (`●`) that hover at the recent max and slowly decay — like a classic VU meter's needle hold
- **Phosphor afterglow**: even silent tubes show a faint dim glow tied to overall signal
- **VU needles** below each tube for instantaneous level
- **Chrome chassis** rails and frequency engraving

## Install

```sh
cliamp plugins install 8bit64k/cliamp-plugin-tubeamp
```

Or manually:

```sh
mkdir -p ~/.config/cliamp/plugins
cp tubeamp.lua ~/.config/cliamp/plugins/
```

Then restart cliamp and press `v` to cycle visualizers until you reach `tubeamp`.

## Configuration

Optional. Add to `~/.config/cliamp/config.toml`:

```toml
[plugins.tubeamp]
# Multiplier on incoming band levels (default 1.0). Bump it up if your audio
# sources sit low in the spectrum range.
gain = 1.0

# Attack: how quickly the filament heats up on rising signals (0..1).
# Higher = snappier response. Default 0.55.
attack = 0.55

# Release: how slowly the filament cools on falling signals (0..1).
# Lower = more afterglow / persistence. Default 0.18.
release = 0.18

# Overdrive threshold (0..1). Bands at or above this level flare red.
# Default 0.78.
overdrive = 0.78
```

## Compatibility

- **cliamp** 1.x (Lua plugin API with `type = "visualizer"`)
- Terminal: any with ANSI 256-color support (essentially everything modern: xterm, kitty, wezterm, alacritty, ghostty, foot, iTerm2, Windows Terminal)

## How it looks

Each frame the plugin computes:

1. **Smoothed level** per band (asymmetric attack/release — heating is fast, cooling is slow)
2. **Peak position** with hold-then-decay
3. **Glow color** from an 11-step amber → gold → white-hot ramp, switching to a red overdrive ramp above threshold

Drawing is done with Unicode box-drawing characters (`╭ ╮ ╰ ╯ │ ─`) for the glass envelopes, shade blocks (`░ ▒ ▓ █`) for the filament fill, and ANSI 256 foreground colors for the glow.

## License

MIT.
