-- tubeamp.lua — Vintage vacuum-tube amplifier visualizer for cliamp.
--
-- Each EQ band is rendered as a glowing vacuum tube. The amber/orange glow
-- intensity tracks the band level. High signals flare into red overdrive
-- (the "running hot" look). Tubes have phosphor afterglow — they decay
-- slowly rather than snap off, like real heated filaments.
--
-- Layout adapts to terminal size in tiers (see pick_layout() below):
--   FULL    — rails, gaps, envelopes, filaments, VU, frequency labels.
--   COMPACT — no rails, tight gaps, envelopes + filaments + VU.
--   MINI    — 2-char glow columns + thin VU; no envelopes; no labels.
--   HIDDEN  — return empty string rather than wrap into multiple rows.
--
-- Color via ANSI 256 — works in any modern terminal.

local p = plugin.register({
    name        = "tubeamp",
    type        = "visualizer",
    version     = "1.1.0",
    description = "Vintage vacuum-tube amplifier — warm amber glow per EQ band",
})

-- ---------- Configuration ----------------------------------------------------

local cfg_gain        = tonumber(p:config("gain")) or 1.0
local cfg_smooth_up   = tonumber(p:config("attack")) or 0.55
local cfg_smooth_down = tonumber(p:config("release")) or 0.18
local cfg_overdrive   = tonumber(p:config("overdrive")) or 0.78

-- ---------- ANSI helpers -----------------------------------------------------

local ESC = string.char(27)
local function fg256(n)  return ESC .. "[38;5;" .. n .. "m" end
local function bg256(n)  return ESC .. "[48;5;" .. n .. "m" end
local function bold()    return ESC .. "[1m"  end
local function reset()   return ESC .. "[0m"  end

-- Amber/orange glow ramp (cold filament → blazing hot → red overdrive)
local glow_ramp = {
    232, 234, 52, 94, 130, 166, 202, 208, 214, 220, 226,
}

local overdrive_ramp = {
    160, 196, 197, 198,
}

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

local CHROME_DIM = 240
local CHROME     = 250
local CHROME_LO  = 236
local LABEL      = 244

-- ---------- State ------------------------------------------------------------

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

-- ---------- Layout -----------------------------------------------------------

local band_labels = { "32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k" }

-- Tube-width caps for each tier. Picked to keep tubes legible without
-- becoming a sparse fence at wide terminals.
local TUBE_W_MIN = 4   -- minimum tube width for FULL tier (with rails)
local TUBE_W_MAX = 9   -- maximum tube width (above this, tubes look stretched)
local GAP_MAX    = 5   -- maximum inter-tube gap when stretching to fill width

-- Pick the layout tier and parameters for a given (rows, cols).
--
-- Returns a table:
--   tier        : "full" | "compact" | "mini" | "hidden"
--   tube_w      : tube width in columns (including 2 envelope chars for full/compact, 0 for mini)
--   gap         : inter-tube gap in columns
--   left_pad    : leading spaces to center the block
--   show_rails  : boolean
--   show_envelope : boolean (top/bottom glass rows)
--   show_vu     : boolean
--   show_labels : boolean
--   inner_rows  : number of filament rows
local function pick_layout(rows, cols)
    if rows == nil or cols == nil then return { tier = "hidden" } end

    -- Helper: total width = left_rail(2) + 10*tube_w + 9*gap + right_rail(2)
    -- For tiers without rails, rail cost is 0.

    -- ---------- FULL tier ----------
    -- Requires: rows >= 6 (1 top + 1 filament + 1 bot + 1 vu + 1 label, and one
    --   more for a usable filament height; we clamp inner_rows >= 1 but prefer >= 2),
    --   cols >= 4 (rails) + 10*TUBE_W_MIN + 9 (gaps) = 53.
    local full_min_cols = 4 + 10 * TUBE_W_MIN + 9  -- 53
    local full_min_rows = 5                         -- glass top + 1 filament + glass bot + vu + label

    if rows >= full_min_rows and cols >= full_min_cols then
        -- Tube width grows to TUBE_W_MAX, then gap absorbs leftover up to GAP_MAX,
        -- then any remainder becomes left padding (centering).
        local tube_w = TUBE_W_MIN
        -- Grow tubes first.
        while tube_w < TUBE_W_MAX do
            local needed = 4 + 10 * (tube_w + 1) + 9
            if needed > cols then break end
            tube_w = tube_w + 1
        end
        -- Now grow gaps.
        local gap = 1
        while gap < GAP_MAX do
            local needed = 4 + 10 * tube_w + 9 * (gap + 1)
            if needed > cols then break end
            gap = gap + 1
        end
        local used = 4 + 10 * tube_w + 9 * gap
        local left_pad = math.floor((cols - used) / 2)
        if left_pad < 0 then left_pad = 0 end

        -- Allocate rows. We always want top glass + bot glass + at least one
        -- filament row. VU and labels are optional based on row budget.
        local show_vu     = rows >= 4
        local show_labels = rows >= 5
        local fixed = 2 + (show_vu and 1 or 0) + (show_labels and 1 or 0)
        local inner_rows = rows - fixed
        if inner_rows < 1 then inner_rows = 1 end
        if inner_rows > 14 then inner_rows = 14 end

        return {
            tier          = "full",
            tube_w        = tube_w,
            gap           = gap,
            left_pad      = left_pad,
            show_rails    = true,
            show_envelope = true,
            show_vu       = show_vu,
            show_labels   = show_labels,
            inner_rows    = inner_rows,
        }
    end

    -- ---------- COMPACT tier ----------
    -- No rails, gap=1, tube_w=3 (│█│). Minimum width: 10*3 + 9 = 39 cols.
    -- Drop labels by default; keep VU.
    local compact_min_cols = 10 * 3 + 9   -- 39
    local compact_min_rows = 4            -- top + 1 filament + bot + vu

    if rows >= compact_min_rows and cols >= compact_min_cols then
        local tube_w = 3
        local gap = 1
        local used = 10 * tube_w + 9 * gap
        local left_pad = math.floor((cols - used) / 2)
        if left_pad < 0 then left_pad = 0 end

        local show_vu     = rows >= 4
        local fixed = 2 + (show_vu and 1 or 0)  -- envelope top + bot + optional vu
        local inner_rows = rows - fixed
        if inner_rows < 1 then inner_rows = 1 end
        if inner_rows > 10 then inner_rows = 10 end

        return {
            tier          = "compact",
            tube_w        = tube_w,
            gap           = gap,
            left_pad      = left_pad,
            show_rails    = false,
            show_envelope = true,
            show_vu       = show_vu,
            show_labels   = false,
            inner_rows    = inner_rows,
        }
    end

    -- ---------- MINI tier ----------
    -- No envelopes, no rails. Pure 1-char glow columns with 1-char gaps.
    -- Width: 10*1 + 9 = 19 cols. Always show at least a thin VU strip.
    local mini_min_cols = 10 + 9          -- 19
    local mini_min_rows = 3               -- 2 filament + 1 vu (no top/bot envelope)

    if rows >= mini_min_rows and cols >= mini_min_cols then
        local tube_w = 1
        local gap = 1
        local used = 10 * tube_w + 9 * gap
        local left_pad = math.floor((cols - used) / 2)
        if left_pad < 0 then left_pad = 0 end

        local show_vu = rows >= 3
        local fixed = (show_vu and 1 or 0)
        local inner_rows = rows - fixed
        if inner_rows < 2 then inner_rows = 2 end
        if inner_rows > 8 then inner_rows = 8 end

        return {
            tier          = "mini",
            tube_w        = tube_w,
            gap           = gap,
            left_pad      = left_pad,
            show_rails    = false,
            show_envelope = false,
            show_vu       = show_vu,
            show_labels   = false,
            inner_rows    = inner_rows,
        }
    end

    -- ---------- HIDDEN tier ----------
    return { tier = "hidden" }
end

-- ---------- Rendering primitives ---------------------------------------------

-- FULL/COMPACT envelope rows.
local function tube_envelope_top(w)
    if w < 2 then return "" end
    local inner = string.rep("─", w - 2)
    return fg256(CHROME) .. "╭" .. inner .. "╮" .. reset()
end

local function tube_envelope_bot(w)
    if w < 2 then return "" end
    local inner = string.rep("─", w - 2)
    return fg256(CHROME) .. "╰" .. inner .. "╯" .. reset()
end

-- A filament row inside a tube. For FULL/COMPACT (w >= 3) this is
-- │ + body + │ ; for w==2 it's a 2-char colored body with no envelope walls;
-- for w==1 it's a single colored cell.
local function tube_filament_row(w, fill_density, glow_idx, hot, has_peak_here, with_envelope)
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
    local boldness = hot and bold() or ""

    if with_envelope and w >= 3 then
        local inner_w = w - 2
        local body = string.rep(glow_ch, inner_w)
        local out = fg256(CHROME) .. "│" .. reset()
                    .. fg256(fg) .. boldness .. body .. reset()
                    .. fg256(CHROME) .. "│" .. reset()

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

    -- No envelope (MINI tier or very narrow). Just colored cells, full width.
    local body = string.rep(glow_ch, w)
    return fg256(fg) .. boldness .. body .. reset()
end

local function vu_needle(w, level, hot, with_brackets)
    if with_brackets and w >= 3 then
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

    -- Bracketless mini VU: just a colored block.
    local filled = math.floor(level * w + 0.5)
    if filled < 0 then filled = 0 end
    if filled > w then filled = w end
    local out = ""
    for i = 1, w do
        if i <= filled then
            local local_level = (i - 1) / math.max(1, w - 1)
            local color = glow_color(local_level, hot and local_level > 0.7)
            out = out .. fg256(color) .. "▬" .. reset()
        else
            out = out .. fg256(CHROME_LO) .. "·" .. reset()
        end
    end
    return out
end

local function chassis_label(w, text)
    if #text > w then text = text:sub(1, w) end
    local pad_total = w - #text
    local pad_left  = math.floor(pad_total / 2)
    local pad_right = pad_total - pad_left
    return fg256(LABEL) .. string.rep(" ", pad_left) .. text .. string.rep(" ", pad_right) .. reset()
end

-- ---------- The render loop --------------------------------------------------

function p:render(bands, frame, rows, cols)
    -- 1) Smooth + peak tracking (always, regardless of tier — keeps state warm
    --    so a resize back up doesn't reveal cold tubes).
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
            if peak_age[i] > 10 then
                peaks[i] = peaks[i] - 0.012
                if peaks[i] < smoothed[i] then peaks[i] = smoothed[i] end
            end
        end
    end

    -- 2) Pick layout tier for the current terminal size.
    local L = pick_layout(rows, cols)

    if L.tier == "hidden" then
        return ""
    end

    -- 3) Build line builder for this tier.
    local pad = L.left_pad > 0 and string.rep(" ", L.left_pad) or ""
    local gap_str = L.gap > 0 and string.rep(" ", L.gap) or ""

    local rail_l, rail_r = "", ""
    if L.show_rails then
        rail_l = fg256(CHROME_DIM) .. "║ " .. reset()
        rail_r = fg256(CHROME_DIM) .. " ║" .. reset()
    end

    local function join_tube_row(builder)
        local parts = { pad, rail_l }
        for i = 1, 10 do
            parts[#parts + 1] = builder(i)
            if i < 10 then parts[#parts + 1] = gap_str end
        end
        parts[#parts + 1] = rail_r
        return table.concat(parts)
    end

    local lines = {}

    -- 4) Optional top glass envelope.
    if L.show_envelope then
        lines[#lines + 1] = join_tube_row(function(i) return tube_envelope_top(L.tube_w) end)
    end

    -- 5) Filament rows (top to bottom).
    for row = L.inner_rows, 1, -1 do
        lines[#lines + 1] = join_tube_row(function(i)
            local level = smoothed[i]
            local hot = level >= cfg_overdrive

            local row_bottom = (row - 1) / L.inner_rows
            local row_top    = row / L.inner_rows

            local fill_density = 0
            if level >= row_top then
                fill_density = 1.0
            elseif level > row_bottom then
                fill_density = (level - row_bottom) / (row_top - row_bottom)
            end

            local glow_idx
            if fill_density > 0 then
                local local_int = level
                if hot then
                    local hot_amount = math.min(1.0, (level - cfg_overdrive) / (1.0 - cfg_overdrive) + (row / L.inner_rows) * 0.4)
                    glow_idx = glow_color(hot_amount, true)
                else
                    glow_idx = glow_color(local_int, false)
                end
            else
                -- Phosphor afterglow at idle.
                local ambient = level * 0.18 + 0.02
                glow_idx = glow_color(ambient, false)
                fill_density = 0.20
            end

            local peak_row = math.ceil(peaks[i] * L.inner_rows + 0.001)
            local has_peak_here = (peak_row == row) and (peaks[i] > 0.05) and (peak_age[i] <= 30)

            return tube_filament_row(L.tube_w, fill_density, glow_idx, hot, has_peak_here, L.show_envelope)
        end)
    end

    -- 6) Optional bottom glass envelope.
    if L.show_envelope then
        lines[#lines + 1] = join_tube_row(function(i) return tube_envelope_bot(L.tube_w) end)
    end

    -- 7) Optional VU needle row.
    if L.show_vu then
        lines[#lines + 1] = join_tube_row(function(i)
            return vu_needle(L.tube_w, smoothed[i], smoothed[i] >= cfg_overdrive, L.show_envelope)
        end)
    end

    -- 8) Optional frequency labels.
    if L.show_labels then
        lines[#lines + 1] = join_tube_row(function(i)
            return chassis_label(L.tube_w, band_labels[i])
        end)
    end

    return table.concat(lines, "\n")
end
