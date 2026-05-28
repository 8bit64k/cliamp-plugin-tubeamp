-- tubeamp.lua — Vintage vacuum-tube amplifier visualizer for cliamp.
--
-- Each EQ band is rendered as a glowing vacuum tube. The amber/orange glow
-- intensity tracks the band level. High signals flare into red overdrive
-- (the "running hot" look). Tubes have phosphor afterglow — they decay
-- slowly rather than snap off, like real heated filaments.
--
-- Top row: a tube row with envelopes (bulb shapes).
-- Middle: filament glow column inside each tube.
-- Bottom: chrome chassis with VU-style needle indicators.
--
-- Color via ANSI 256 — works in any modern terminal. Falls back gracefully
-- when the terminal can't render 256-color; the glyphs still read.

local p = plugin.register({
    name        = "tubeamp",
    type        = "visualizer",
    version     = "1.0.0",
    description = "Vintage vacuum-tube amplifier — warm amber glow per EQ band",
})

-- ---------- Configuration ----------------------------------------------------

-- Optional config: gain multiplier, smoothing rate, overdrive threshold.
local cfg_gain        = tonumber(p:config("gain")) or 1.0
local cfg_smooth_up   = tonumber(p:config("attack")) or 0.55  -- 0..1 (higher = snappier)
local cfg_smooth_down = tonumber(p:config("release")) or 0.18 -- 0..1 (lower = slower fade = more glow)
local cfg_overdrive   = tonumber(p:config("overdrive")) or 0.78

-- ---------- ANSI helpers -----------------------------------------------------

local ESC = string.char(27)
local function fg256(n)  return ESC .. "[38;5;" .. n .. "m" end
local function bg256(n)  return ESC .. "[48;5;" .. n .. "m" end
local function bold()    return ESC .. "[1m"  end
local function reset()   return ESC .. "[0m"  end

-- Amber/orange glow ramp (cold filament → blazing hot → red overdrive)
-- ANSI 256 indices that read well on black backgrounds.
local glow_ramp = {
    232,  -- nearly black (cold)
    234,
    52,   -- deep red-brown
    94,   -- dark amber
    130,  -- amber
    166,  -- orange
    202,  -- bright orange
    208,  -- amber-yellow
    214,  -- gold
    220,  -- bright yellow
    226,  -- pure yellow (white-hot)
}

local overdrive_ramp = {
    160,  -- red
    196,  -- bright red
    197,
    198,  -- magenta-pink (peak)
}

-- Pick a glow color for a normalized level 0..1.
local function glow_color(level, hot)
    if hot then
        local idx = math.floor(level * (#overdrive_ramp - 1)) + 1
        if idx < 1 then idx = 1 end
        if idx > #overdrive_ramp then idx = #overdrive_ramp end
        return overdrive_ramp[idx]
    end
    local idx = math.floor(level * (#glow_ramp - 1)) + 1
    if idx < 1 then idx = 1 end
    if idx > #glow_ramp then idx = #glow_ramp end
    return glow_ramp[idx]
end

local CHROME_DIM = 240   -- mid-gray chrome
local CHROME     = 250   -- bright chrome
local CHROME_LO  = 236   -- shadow
local LABEL      = 244

-- ---------- State (per-instance afterglow) -----------------------------------

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

-- ---------- Layout helpers ---------------------------------------------------

-- 10 standard cliamp EQ bands → Hz labels for the chassis row.
local band_labels = { "32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k" }

-- Pick tube width based on terminal columns. Always render 10 tubes.
local function tube_width(cols)
    -- Leave 4 cols for the side rails. Each tube needs at least 4 cols.
    local usable = cols - 4
    local per = math.floor(usable / 10)
    if per < 4 then per = 4 end
    if per > 9 then per = 9 end
    return per
end

-- ---------- Rendering primitives ---------------------------------------------

-- Tube envelope (a glass bulb). Returns 3 rows.
--   ╭──╮     <- glass top
--   │██│     <- filament glow (variable rows)
--   ╰──╯     <- glass base
local function tube_envelope_top(w)
    local inner = string.rep("─", w - 2)
    return fg256(CHROME) .. "╭" .. inner .. "╮" .. reset()
end

local function tube_envelope_bot(w)
    local inner = string.rep("─", w - 2)
    return fg256(CHROME) .. "╰" .. inner .. "╯" .. reset()
end

-- A filament row inside the tube. `fill_level` 0..1 controls how much of this
-- row is filled (we render full blocks for now — fractional adds complexity
-- that doesn't read at typical terminal sizes).
local function tube_filament_row(w, fill_density, glow_idx, hot, has_peak_here)
    local inner_w = w - 2
    local glow_ch
    if fill_density <= 0.0 then
        glow_ch = " "
    elseif fill_density < 0.25 then
        glow_ch = "░"
    elseif fill_density < 0.55 then
        glow_ch = "▒"
    elseif fill_density < 0.85 then
        glow_ch = "▓"
    else
        glow_ch = "█"
    end

    local fg = glow_idx
    local body = string.rep(glow_ch, inner_w)

    local out = fg256(CHROME) .. "│" .. reset()
                .. fg256(fg) .. (hot and bold() or "") .. body .. reset()
                .. fg256(CHROME) .. "│" .. reset()

    -- Peak marker — a tiny "●" floating mid-tube where the peak sits.
    if has_peak_here and inner_w >= 3 then
        local marker_pos = math.floor(inner_w / 2) + 1
        local prefix = string.rep(glow_ch, marker_pos - 1)
        local suffix = string.rep(glow_ch, inner_w - marker_pos)
        local peak_color = hot and 196 or 226
        out = fg256(CHROME) .. "│" .. reset()
              .. fg256(fg) .. prefix .. reset()
              .. fg256(peak_color) .. bold() .. "●" .. reset()
              .. fg256(fg) .. suffix .. reset()
              .. fg256(CHROME) .. "│" .. reset()
    end

    return out
end

-- VU needle for the chassis bottom. Returns a short colored block.
local function vu_needle(w, level, hot)
    local inner_w = w - 2
    local filled = math.floor(level * inner_w + 0.5)
    if filled < 0 then filled = 0 end
    if filled > inner_w then filled = inner_w end

    local out = fg256(CHROME_LO) .. "[" .. reset()
    for i = 1, inner_w do
        if i <= filled then
            local local_level = (i - 1) / math.max(1, inner_w - 1)
            local color = glow_color(local_level, hot and local_level > 0.7)
            out = out .. fg256(color) .. "▬" .. reset()
        else
            out = out .. fg256(CHROME_LO) .. "·" .. reset()
        end
    end
    out = out .. fg256(CHROME_LO) .. "]" .. reset()
    return out
end

-- Label for the chassis: frequency centered in `w` columns, dim gray.
local function chassis_label(w, text)
    if #text > w then text = text:sub(1, w) end
    local pad_total = w - #text
    local pad_left  = math.floor(pad_total / 2)
    local pad_right = pad_total - pad_left
    return fg256(LABEL) .. string.rep(" ", pad_left) .. text .. string.rep(" ", pad_right) .. reset()
end

-- ---------- The render loop --------------------------------------------------

function p:render(bands, frame, rows, cols)
    -- 1) Smooth + peak tracking
    for i = 1, 10 do
        local raw = (bands[i] or 0) * cfg_gain
        if raw > 1.0 then raw = 1.0 end
        if raw < 0.0 then raw = 0.0 end

        if raw > smoothed[i] then
            smoothed[i] = smoothed[i] + (raw - smoothed[i]) * cfg_smooth_up
        else
            smoothed[i] = smoothed[i] - (smoothed[i] - raw) * cfg_smooth_down
        end

        if smoothed[i] >= peaks[i] then
            peaks[i] = smoothed[i]
            peak_age[i] = 0
        else
            peak_age[i] = peak_age[i] + 1
            -- Peak hold for ~10 frames, then decays slowly.
            if peak_age[i] > 10 then
                peaks[i] = peaks[i] - 0.012
                if peaks[i] < smoothed[i] then peaks[i] = smoothed[i] end
            end
        end
    end

    -- 2) Layout
    local w = tube_width(cols)
    local rail_color = CHROME_DIM
    local rail_l = fg256(rail_color) .. "║ " .. reset()
    local rail_r = fg256(rail_color) .. " ║" .. reset()

    -- How many rows do filaments get? Total tube height = rows - 4 (top env,
    -- bot env, chassis VU, chassis label). Clamp.
    local tube_inner_rows = rows - 4
    if tube_inner_rows < 3 then tube_inner_rows = 3 end
    if tube_inner_rows > 14 then tube_inner_rows = 14 end

    local lines = {}

    -- Glass top row for all 10 tubes
    local function join_tube_row(builder)
        local parts = { rail_l }
        for i = 1, 10 do
            parts[#parts + 1] = builder(i)
            if i < 10 then parts[#parts + 1] = " " end
        end
        parts[#parts + 1] = rail_r
        return table.concat(parts)
    end

    lines[#lines + 1] = join_tube_row(function(i) return tube_envelope_top(w) end)

    -- Filament rows — bottom is row=1, top is row=tube_inner_rows.
    for row = tube_inner_rows, 1, -1 do
        lines[#lines + 1] = join_tube_row(function(i)
            local level = smoothed[i]
            local hot = level >= cfg_overdrive

            -- Fill threshold: tubes glow from bottom up.
            local row_bottom = (row - 1) / tube_inner_rows
            local row_top    = row / tube_inner_rows

            -- Fractional fill in this row.
            local fill_density = 0
            if level >= row_top then
                fill_density = 1.0
            elseif level > row_bottom then
                fill_density = (level - row_bottom) / (row_top - row_bottom)
            end

            -- Phosphor afterglow: even unlit rows have a dim glow when the band
            -- is non-zero — gives the tubes that always-warm look.
            local glow_idx
            if fill_density > 0 then
                -- Local intensity ramps from row_bottom..row_top.
                local local_int = level
                if hot then
                    -- Overdrive bleeds into red at the top of the tube.
                    local hot_amount = math.min(1.0, (level - cfg_overdrive) / (1.0 - cfg_overdrive) + (row / tube_inner_rows) * 0.4)
                    glow_idx = glow_color(hot_amount, true)
                else
                    glow_idx = glow_color(local_int, false)
                end
            else
                -- Cold/idle: very dim ambient warmth proportional to total level.
                local ambient = level * 0.18 + 0.02
                glow_idx = glow_color(ambient, false)
                fill_density = 0.20  -- tiny dither so the tube isn't pitch black
            end

            -- Peak marker shown on the row where the peak sits.
            local peak_row = math.ceil(peaks[i] * tube_inner_rows + 0.001)
            local has_peak_here = (peak_row == row) and (peaks[i] > 0.05) and (peak_age[i] <= 30)

            return tube_filament_row(w, fill_density, glow_idx, hot, has_peak_here)
        end)
    end

    -- Glass base row
    lines[#lines + 1] = join_tube_row(function(i) return tube_envelope_bot(w) end)

    -- VU needle chassis row
    lines[#lines + 1] = join_tube_row(function(i)
        return vu_needle(w, smoothed[i], smoothed[i] >= cfg_overdrive)
    end)

    -- Frequency labels (chassis engraving)
    lines[#lines + 1] = join_tube_row(function(i)
        return chassis_label(w, band_labels[i])
    end)

    return table.concat(lines, "\n")
end
