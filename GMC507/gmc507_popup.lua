-- gmc507_popup.lua: popup drawn from the unit's own 3D model.
-- The background is gmc507_face.png, an orthographic render of
-- Avionics_GFC500.obj made by tools/gmc507_render_popup.py (4 image px per
-- design unit = the framebuffer scale S). The click zones below are the key /
-- knob / wheel positions of that same render (tools/gmc507_render_popup.py
-- prints them; _work/gmc507_layout.json), so art and zones cannot drift.
-- On top of the image the popup draws the key LEDs, the knob / wheel state,
-- the pressed-key shade; below the image is a small strip with the selected
-- HDG / ALT (the real unit has no screen). If the image cannot be loaded, the
-- old flat drawing (same zones) is used.
-- 2026-11-18: lit lamps are small pre-rendered sprites (gmc507_lamp_white.png / _amber.png, a lit triangle with an
-- inner shadow, strongest along the top edge: the lamp window is recessed). Each knob has a thin F8FEEA light ring
-- (gmc507_ring.png), on all the time the unit is powered, by day too. Sprites come from tools/gmc507_popup_sprites.py;
-- if one cannot be loaded the lamp falls back to a flat polygon and the ring is left out. The face is tinted for
-- night like the GTX 327 pop-up (POPUP_*_SHADE).
-- 2026-11-18 (power and brightness): "powered" follows autopilot_has_power every frame (GMC507.lua calls
-- set_powered). At night the tinted face would darken the key lettering, which is backlit on the real unit, so a
-- lettering mask of the face (gmc507_glow.png, tools/gmc507_popup_glow.py) is drawn over it, its opacity following
-- laminar/gfc500/key_light (0 unpowered). Lamps and rings: full brightness by day, at night scaled with key_light
-- but never below LIGHT_FLOOR. By day nothing changes: no glow layer is drawn and the lamp colour is exactly white.
-- 2026-11-19 (turning knobs, slots): the white pointer is gone; the knob itself turns. The face has the knob discs
-- replaced by a dark groove; each knob is a sprite (gmc507_knob_hdg.png / _alt.png: the knob disc with its lighting
-- taken out) drawn with XPLMTextureAtlasDrawScaled, turned clockwise by L.knob.hdg / L.knob.alt revolutions (the 3D
-- model's ANIM_rotate on laminar/gfc500/hdg_knob_val / alt_knob_val: axis 0 0 -1, 360 deg per revolution, the same
-- direction). A second sprite (gmc507_knob_light_*.png, black with alpha = the lighting) is drawn over it, not turned,
-- so the light stays where it is. Power does not touch the knob angle (a real knob stays where it is). The unlit
-- lamp windows and the knob light-ring track are flat plastic drawn into the face itself (tools/gmc507_popup_knobs.py),
-- the lit sprites cover them exactly. Without XPLMTextureAtlasDrawScaled or the sprites the knobs are drawn upright, not turned.
-- Every touch goes through XPLMCommandOnce("laminar/gfc500/...") so the popup
-- and a 3D model use the same commands.

local Popup = {}

function Popup.new(ctx)
    local L = ctx.L
    local P = {}

    local FACE_W, FACE_H = 667, 225    -- the rendered face, design units
    local STRIP = 22                   -- label strip under the face (outside the bezel image)
    local W, H = FACE_W, FACE_H + STRIP -- design units, y up
    local S = 4                    -- framebuffer pixels per design unit = image px per unit
    local FACE_FILE = "gmc507_face.png"
    local FONT_FILE = "Resources/fonts/Roboto-Bold.ttf"
    local PREFIX = "laminar/gfc500/"
    local SPRITE_FILES = { white = "gmc507_lamp_white.png", amber = "gmc507_lamp_amber.png", ring = "gmc507_ring.png",
        glow = "gmc507_glow.png",
        knob_hdg = "gmc507_knob_hdg.png", knob_alt = "gmc507_knob_alt.png",
        knob_light_hdg = "gmc507_knob_light_hdg.png", knob_light_alt = "gmc507_knob_light_alt.png" }
    local KNOB_HALF = 36                              -- knob sprites are 72 x 72 units (288 px), axis in the centre
    local KNOB_PX = 288                               -- sprite size in image px; the pivot is its centre
    local LAMP_HW, LAMP_TOP, LAMP_BOT = 9, 10, -1     -- sprite box around the old 16 x 9 triangle (design units)
    local RING_HALF = 44                              -- ring sprite is 88 x 88 units, centred on the knob axis
    -- face brightness: 1 = the image as drawn. Same scheme as the GTX 327 pop-up (X-Plane's own night factor,
    -- percent_lights_on, eased over about 3 s); day is the image as approved, night the 327's 0.18.
    local POPUP_DAY_SHADE, POPUP_NIGHT_SHADE, SHADE_EASE_S = 1.0, 0.18, 3.0
    local NIGHT_DATAREF = "sim/graphics/scenery/percent_lights_on"
    -- night look (key_light is the dimmer curve, 0.09 at dimmer 0 and 0.45 at dimmer 1, 0 unpowered)
    local KEY_FULL = 0.4545        -- key_light at dimmer 1: the lettering mask is fully opaque there
    local GLOW_MAX = 0.9           -- mask opacity at KEY_FULL (night); less before, in proportion to key_light
    local LIGHT_FLOOR = 0.35       -- lamps and rings never fall below this fraction of full at night
    local function key_light()
        if ctx.key_light then return ctx.key_light() or 0 end
        return 1
    end
    P.W, P.H, P.S = W, H, S
    -- power: "powered" = autopilot_has_power and the plugin enabled (GMC507.lua sets it every frame; Disable sets it
    -- false and L.shutdown zeroes the lamps). Unpowered: no lamps, no rings, no lettering glow, and the keys do nothing.
    local powered = true
    function P.set_powered(on) powered = on and true or false end
    function P.is_powered() return powered end

    -- controls: keys fire on release, knob halves and wheel halves on press.
    -- Boxes and pivots: tools/gmc507_render_popup.py (y of the face, plus STRIP)
    local controls = {}
    local function key(id, label, x, y, w, h)
        controls[#controls + 1] = { kind = "key", id = id, label = label, x = x, y = y + STRIP, w = w, h = h }
    end
    local KW, KH = 59.2, 43.2
    key("hdg", "HDG", 60.9, 17.2, KW, KH) key("trk", "TRK", 142.2, 17.2, KW, KH)
    key("nav", "NAV", 142.2, 82.2, KW, KH) key("apr", "APR", 142.2, 147.2, KW, KH)
    key("ap", "AP", 225.6, 114.0, KW, KH) key("lvl", "LVL", 306.9, 114.0, KW, KH)
    key("fd", "FD", 225.6, 48.9, KW, KH) key("yd", "YD", 306.9, 48.9, KW, KH)
    key("ias", "IAS", 466.6, 147.2, KW, KH) key("vnav", "VNAV", 466.6, 82.2, KW, KH)
    key("vs", "VS", 466.6, 17.2, KW, KH) key("alt", "ALT", 547.9, 17.2, KW, KH)
    local KNOB_R = 33
    controls[#controls + 1] = { kind = "knob", id = "hdg_knob", cx = 91.0, cy = 144.4 + STRIP, r = KNOB_R, title = "HDG/TRK" }
    controls[#controls + 1] = { kind = "knob", id = "alt_sel_knob", cx = 578.0, cy = 144.3 + STRIP, r = KNOB_R, title = "ALT SEL" }
    -- the wheel's visible window (the mesh itself reaches past the bezel opening)
    controls[#controls + 1] = { kind = "wheel", id = "wheel", x = 417.0, y = 51.0 + STRIP, w = 23, h = 122 }
    P.controls = controls
    local PUSH_R = 13

    -- the command a hit stands for ("button_ap", "hdg_knob_left", "wheel_up")
    -- and the logic id used for greying
    local function hit_at(x, y)
        for _, c in ipairs(controls) do
            if c.kind == "key" then
                if x >= c.x and x <= c.x + c.w and y >= c.y and y <= c.y + c.h then
                    return c, c.id, "button_" .. c.id
                end
            elseif c.kind == "knob" then
                local dx, dy = x - c.cx, y - c.cy
                local d = math.sqrt(dx * dx + dy * dy)
                if d <= c.r then
                    local part = d < PUSH_R and "push" or (dx < 0 and "left" or "right")
                    return c, c.id .. "_" .. part, c.id .. "_" .. part
                end
            else
                if x >= c.x and x <= c.x + c.w and y >= c.y and y <= c.y + c.h then
                    -- DN is printed on top, UP below (real unit)
                    local a = (y > c.y + c.h / 2) and "wheel_dn" or "wheel_up"
                    return c, a, a
                end
            end
        end
    end
    P.hit_at = hit_at
    -- logic id for greying: keys by key id, knob parts are always enabled
    local function usable(c, action)
        if not powered then return false end      -- dead unit: the press goes back to X-Plane (window drag)
        if c.kind == "key" then return L.enabled(c.id) end
        if c.kind == "wheel" then return L.enabled(action) end
        return true
    end

    local function fire(cmdname)
        local c = XPLMFindCommand(PREFIX .. cmdname)
        if c then XPLMCommandOnce(c) else ctx.log("command not found: " .. PREFIX .. cmdname) end
    end

    ------------------------------------------------------------------ drawing
    local C, font, JC = {}, nil, nil
    local function hex(s)
        return XPLMMakeColor(tonumber(s:sub(1, 2), 16) / 255, tonumber(s:sub(3, 4), 16) / 255,
            tonumber(s:sub(5, 6), 16) / 255, 1)
    end
    local function init_gfx()
        C.bg = hex("1A1B1F")
        C.plate = hex("2B2D33")
        C.frame = hex("6A6E7A")
        C.key = hex("3A3D46")
        C.key_down = hex("565A66")
        C.key_edge = hex("9CA0B4")
        C.label = hex("F2F2F2")
        C.grey = hex("4A4C52")
        C.grey_label = hex("8A8C92")
        C.tri_lit = hex("F8FEEA")      -- lit lamp (armed and active alike): the real unit's lamp colour
        C.tri_amber = hex("FFB000")
        C.knob = hex("14151A")
        C.knob_edge = hex("8A8EA0")
        C.mark = hex("F2F2F2")
        C.cyan = hex("2FD0E0")
        C.sep = hex("7A7E8C")
        C.shade = XPLMMakeColor(0, 0, 0, 0.38)        -- pressed key
        C.dim = XPLMMakeColor(0, 0, 0, 0.5)           -- disabled key
        C.ridge = XPLMMakeColor(0, 0, 0, 0.45)
        C.strip = hex("0C0D10")
        C.white = XPLMMakeColor(1, 1, 1, 1)
        JC = XPLMJustification_t.xplm_JustCenter
        font = XPLMCreateFont(XPLMCharSet_t.xplm_CharSetUnicode)
        XPLMFontAddFace(font, FONT_FILE)
    end

    local pts = {}
    local function round_rect(x0, y0, x1, y1, r)
        local n = 0
        local corners = { { x1 - r, y1 - r, 0 }, { x0 + r, y1 - r, 90 }, { x0 + r, y0 + r, 180 }, { x1 - r, y0 + r, 270 } }
        for _, c in ipairs(corners) do
            for k = 0, 4 do
                local a = math.rad(c[3] + k * 22.5)
                n = n + 1
                local p = pts[n]
                if p == nil then p = {} pts[n] = p end
                p.x, p.y = (c[1] + r * math.cos(a)) * S, (c[2] + r * math.sin(a)) * S
            end
        end
        for i = n + 1, #pts do pts[i] = nil end
        return pts, n
    end
    local function fill_rr(x0, y0, x1, y1, r, col) local v, n = round_rect(x0, y0, x1, y1, r) XPLMPolygon(col, v, n) end
    local function edge_rr(x0, y0, x1, y1, r, col, w) local v, n = round_rect(x0, y0, x1, y1, r) XPLMLineLoopWithWidth(col, w * S, v, n) end
    local lbuf = { {}, {} }
    local function line(x0, y0, x1, y1, col, w)
        lbuf[1].x, lbuf[1].y, lbuf[2].x, lbuf[2].y = x0 * S, y0 * S, x1 * S, y1 * S
        XPLMLinesWithWidth(col, w * S, lbuf, 2)
    end
    local function text(str, x, y, size, col) XPLMFontDrawString(font, col, size * S, x * S, y * S, str, JC) end
    local function disc(cx, cy, r, col)
        local v = {}
        for i = 1, 28 do
            local a = (i - 1) / 28 * 2 * math.pi
            v[i] = { x = (cx + r * math.cos(a)) * S, y = (cy + r * math.sin(a)) * S }
        end
        XPLMPolygon(col, v, 28)
    end

    local pressed = nil
    local held = false       -- a knob / wheel press is in progress (its drag and release are consumed)
    local function draw_key(c)
        local i = L.KEY_INDEX[c.id]
        local x0, y0, x1, y1 = c.x, c.y, c.x + c.w, c.y + c.h
        local down = pressed == c or L.anim_val[i] > 0
        if L.enabled(c.id) then
            fill_rr(x0, y0, x1, y1, 5, down and C.key_down or C.key)
            edge_rr(x0, y0, x1, y1, 5, C.key_edge, 1)
            text(c.label, x0 + c.w / 2, y0 + c.h / 2 - 5, 15, C.label)
        else
            fill_rr(x0, y0, x1, y1, 5, C.grey)
            edge_rr(x0, y0, x1, y1, 5, C.frame, 1)
            text(c.label, x0 + c.w / 2, y0 + c.h / 2 - 5, 15, C.grey_label)
        end
        P.draw_led(c)
    end

    -- the LED above the key (the real unit's triangle): lamp 0 off = nothing drawn (dead front),
    -- 1 armed and 2 active = the same F8FEEA, 3 amber flashing at 2 Hz (nothing on the off phase).
    -- Textured path: a sprite with the inner shadow; otherwise (or when the sprite is missing) a flat polygon.
    local spr = {}                     -- sprite images in the atlas, nil when not loaded
    local lamp_col = nil               -- colour the lamp and ring sprites are drawn with (white by day, dimmer at night)
    local atlas, face = nil, nil
    function P.draw_led(c)
        if not powered then return end
        local v = L.lamp[L.KEY_INDEX[c.id]]
        local col, which
        if v == 1 or v == 2 then col, which = C.tri_lit, "white"
        elseif v == 3 and math.floor(ctx.now() * 4) % 2 == 0 then col, which = C.tri_amber, "amber" end
        if not col then return end
        local cx, ty = c.x + c.w / 2, c.y + c.h + 4
        if face and spr[which] then
            XPLMTextureAtlasDrawIn(atlas, spr[which], lamp_col or C.white, (cx - LAMP_HW) * S, (ty + LAMP_TOP) * S, (cx + LAMP_HW) * S, (ty + LAMP_BOT) * S)
            return
        end
        XPLMPolygon(col, { { x = (cx - 8) * S, y = (ty + 9) * S }, { x = (cx + 8) * S, y = (ty + 9) * S },
            { x = cx * S, y = ty * S } }, 3)
    end

    -- the light ring around a knob: lit all the time while powered (day too), full brightness
    local function draw_ring(c)
        if not (powered and face and spr.ring) then return end
        XPLMTextureAtlasDrawIn(atlas, spr.ring, lamp_col or C.white, (c.cx - RING_HALF) * S, (c.cy + RING_HALF) * S, (c.cx + RING_HALF) * S, (c.cy - RING_HALF) * S)
    end

    -- the knob itself: the sprite turned clockwise by the knob's revolutions (about the knob axis), tinted like the face,
    -- then the fixed light over it. Always drawn, powered or not.
    local face_tint = 1.0
    local function draw_knob_sprite(c)
        local nm = (c.id == "hdg_knob") and "hdg" or "alt"
        local img, lit = spr["knob_" .. nm], spr["knob_light_" .. nm]
        if not (face and img) then return end
        local rev = (c.id == "hdg_knob") and L.knob.hdg or L.knob.alt
        local col = face_tint == 1.0 and C.white or XPLMMakeColor(face_tint, face_tint, face_tint, 1)
        if XPLMTextureAtlasDrawScaled then
            XPLMTextureAtlasDrawScaled(atlas, img, col, c.cx * S, c.cy * S, KNOB_PX / 2, KNOB_PX / 2, 1, 1, rev * 360)
        else
            XPLMTextureAtlasDrawIn(atlas, img, col, (c.cx - KNOB_HALF) * S, (c.cy + KNOB_HALF) * S, (c.cx + KNOB_HALF) * S, (c.cy - KNOB_HALF) * S)
        end
        if lit then
            XPLMTextureAtlasDrawIn(atlas, lit, C.white, (c.cx - KNOB_HALF) * S, (c.cy + KNOB_HALF) * S, (c.cx + KNOB_HALF) * S, (c.cy - KNOB_HALF) * S)
        end
    end

    -- face tint, eased
    local shade_now, shade_t = 1.0, nil
    local function face_shade()
        local night = 0
        if ctx.has and ctx.has(NIGHT_DATAREF) then night = math.max(0, math.min(1, ctx.getf(NIGHT_DATAREF))) end
        local target = POPUP_NIGHT_SHADE + (POPUP_DAY_SHADE - POPUP_NIGHT_SHADE) * (1 - night)
        local t = ctx.now()
        if shade_t == nil then shade_now = target
        else
            local step = math.max(0, math.min(1, t - shade_t)) / SHADE_EASE_S
            if shade_now < target then shade_now = math.min(target, shade_now + step)
            else shade_now = math.max(target, shade_now - step) end
        end
        shade_t = t
        return shade_now
    end
    P.face_shade = face_shade
    -- 0 by day, 1 at full night, eased with the face tint (derived from it, so the glow and the tint always agree)
    local function night_factor()
        local f = (POPUP_DAY_SHADE - shade_now) / (POPUP_DAY_SHADE - POPUP_NIGHT_SHADE)
        if f < 1e-6 then return 0 end
        return f > 1 and 1 or f
    end
    P.night_factor = night_factor
    -- per-frame light state for the lamps / rings and the lettering glow
    local function light_state()
        local nf = night_factor()
        local k = powered and key_light() or 0
        local m = 1
        if nf > 0 then
            local lvl = k < LIGHT_FLOOR and LIGHT_FLOOR or (k > 1 and 1 or k)
            m = 1 + (lvl - 1) * nf
        end
        lamp_col = m == 1 and C.white or XPLMMakeColor(m, m, m, 1)
        local glow = 0
        if powered and nf > 0 then
            glow = nf * GLOW_MAX * math.min(1, k / KEY_FULL)
        end
        return glow
    end
    P.light_state = function() return light_state() end

    local function draw_knob(c)
        local val = ((c.id == "hdg_knob") and L.knob.hdg or L.knob.alt) * 360   -- revolutions -> degrees
        disc(c.cx, c.cy, c.r, C.knob)
        local v = {}
        for i = 1, 28 do
            local a = (i - 1) / 28 * 2 * math.pi
            v[i] = { x = (c.cx + c.r * math.cos(a)) * S, y = (c.cy + c.r * math.sin(a)) * S }
        end
        XPLMLineLoopWithWidth(C.knob_edge, 1.5 * S, v, 28)
        local a = math.rad(90 - val)
        line(c.cx + 18 * math.cos(a), c.cy + 18 * math.sin(a), c.cx + (c.r - 5) * math.cos(a), c.cy + (c.r - 5) * math.sin(a), C.mark, 2)
        text(c.title, c.cx, c.cy + c.r + 30, 15, C.label)
        text("PUSH SYNC", c.cx, c.cy - c.r - 14, 9, C.label)
    end

    local function draw_wheel(c)
        fill_rr(c.x, c.y, c.x + c.w, c.y + c.h, 6, C.knob)
        edge_rr(c.x, c.y, c.x + c.w, c.y + c.h, 6, C.knob_edge, 1)
        for k = 1, 9 do
            local yy = c.y + 8 + (k - 1) * (c.h - 16) / 8 + (L.knob.wheel * 24 % 1) * 4
            if yy < c.y + c.h - 4 then line(c.x + 4, yy, c.x + c.w - 4, yy, C.key_edge, 1) end
        end
        local on = L.enabled("wheel_up")
        text("DN", c.x + c.w / 2, c.y + c.h + 6, 12, on and C.label or C.grey_label)
        text("UP", c.x + c.w / 2, c.y - 16, 12, on and C.label or C.grey_label)
        -- VS / IAS reference beside the wheel
        local m = L.vertical_mode()
        if on and m == "vs" then
            text("VS", c.x + c.w / 2, c.y + c.h + 26, 11, C.label)
            text(string.format("%d", math.floor(ctx.getf("sim/cockpit2/autopilot/vvi_dial_fpm") / 10 + 0.5) * 10), c.x + c.w / 2, c.y + c.h + 40, 14, C.cyan)
        elseif on and m == "ias" then
            text("IAS", c.x + c.w / 2, c.y + c.h + 26, 11, C.label)
            text(string.format("%d", math.floor(ctx.getf("sim/cockpit2/autopilot/airspeed_dial_kts") + 0.5)), c.x + c.w / 2, c.y + c.h + 40, 14, C.cyan)
        end
    end

    -- the rendered face (atlas / face / spr declared above); nil when the image could not be loaded
    -- X-Plane wants image paths relative to its root: an absolute one gives "bad directory character",
    -- a modal and an XLua crash (sim 2026-11-12). Returns the path relative to root (root prefix compared
    -- case-insensitively, slashes normalised), or nil when it is outside the root or still looks absolute.
    local function relative_path(full, root)
        full = tostring(full):gsub("\\", "/")
        root = tostring(root or ""):gsub("\\", "/")
        full, root = full:gsub("/+", "/"), root:gsub("/+", "/")
        if root == "" then return nil end
        if root:sub(-1) ~= "/" then root = root .. "/" end
        if full:sub(1, #root):lower() ~= root:lower() then return nil end
        local rel = full:sub(#root + 1)
        if rel == "" or rel:sub(1, 1) == "/" or rel:match("^%a:") or rel:find("\\", 1, true) then return nil end
        return rel
    end
    P.relative_path = relative_path
    local function load_face()
        if not (XPLMCreateTextureAtlas and XPLMTextureAtlasAddImageFile and XPLMTextureAtlasBake and XPLMTextureAtlasDrawIn) then
            return
        end
        local src = (debug and debug.getinfo and debug.getinfo(1, "S").source) or ""
        local dir = src:sub(1, 1) == "@" and src:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$") or ctx.dir
        if not dir then ctx.log("popup face: script folder unknown, flat drawing") return end
        local rel
        if XPLMGetSystemPath then
            local okp, r = pcall(XPLMGetSystemPath)
            if okp and type(r) == "table" then r = r.outSystemPath or r[1] end
            if okp then rel = relative_path(dir .. "/" .. FACE_FILE, r) end
        end
        if not rel then
            ctx.log("popup face: no path relative to the X-Plane root for " .. dir .. "/" .. FACE_FILE .. "; flat drawing")
            return
        end
        -- M4: a missing / unreadable PNG must not reach AddImageFile (native errors are not catchable)
        local fh = io and io.open and io.open(dir .. "/" .. FACE_FILE, "rb")
        if not fh then
            ctx.log("popup face: " .. dir .. "/" .. FACE_FILE .. " missing or unreadable; flat drawing")
            return
        end
        fh:close()
        local ok, err = pcall(function()
            local a = XPLMCreateTextureAtlas()
            atlas = a
            local img = XPLMTextureAtlasAddImageFile(a, rel)
            if img == nil then error("image not found: " .. rel) end
            -- sprites: each one optional; a missing file is skipped before the native call (M4 rule)
            local reldir = rel:sub(1, #rel - #FACE_FILE)
            for name, file in pairs(SPRITE_FILES) do
                local sh = io.open(dir .. "/" .. file, "rb")
                if sh then
                    sh:close()
                    spr[name] = XPLMTextureAtlasAddImageFile(a, reldir .. file)
                else
                    ctx.log("popup sprite " .. file .. " missing; flat lamp / no ring")
                end
            end
            XPLMTextureAtlasBake(a)
            face = img
        end)
        if not ok then
            ctx.log("popup face: " .. tostring(err) .. "; flat drawing")
            if atlas and XPLMDestroyTextureAtlas then pcall(XPLMDestroyTextureAtlas, atlas) end
            atlas, face, spr = nil, nil, {}
        end
    end

    local function rect(x0, y0, x1, y1, col)
        XPLMPolygon(col, { { x = x0 * S, y = y0 * S }, { x = x0 * S, y = y1 * S }, { x = x1 * S, y = y1 * S },
            { x = x1 * S, y = y0 * S } }, 4)
    end

    -- on top of the image: key state, LEDs, knob index marks, wheel ridges
    local function draw_overlays()
        for _, c in ipairs(controls) do
            if c.kind == "key" then
                local down = pressed == c or L.anim_val[L.KEY_INDEX[c.id]] > 0
                if not L.enabled(c.id) then fill_rr(c.x, c.y, c.x + c.w, c.y + c.h, 7, C.dim)
                elseif down then fill_rr(c.x, c.y, c.x + c.w, c.y + c.h, 7, C.shade) end
                P.draw_led(c)
            elseif c.kind == "knob" then
                draw_ring(c)
                draw_knob_sprite(c)
            else
                local off = (L.knob.wheel * 24 % 1) * 6
                for k = 0, 20 do
                    local yy = c.y + off + k * 6
                    if yy > c.y + 1 and yy < c.y + c.h - 1 then line(c.x + 2, yy, c.x + c.w - 2, yy, C.ridge, 1) end
                end
                if not L.enabled("wheel_up") then rect(c.x, c.y, c.x + c.w, c.y + c.h, C.dim) end
            end
        end
    end

    -- readouts under the face, outside the bezel image
    local function draw_strip()
        rect(0, 0, W, STRIP, C.strip)
        local hdg = string.format("HDG %03d", math.floor(ctx.getf("sim/cockpit2/autopilot/heading_dial_deg_mag_pilot") + 0.5) % 360)
        local alt = string.format("ALT %d", math.floor(ctx.getf("sim/cockpit2/autopilot/altitude_dial_ft") + 0.5))
        text(hdg, 91, 5, 11, C.cyan)
        text(alt, 578, 5, 11, C.cyan)
        local m = L.vertical_mode()
        if L.enabled("wheel_up") and m == "vs" then
            text(string.format("VS %d", math.floor(ctx.getf("sim/cockpit2/autopilot/vvi_dial_fpm") / 10 + 0.5) * 10), 428, 5, 11, C.cyan)
        elseif L.enabled("wheel_up") and m == "ias" then
            text(string.format("IAS %d", math.floor(ctx.getf("sim/cockpit2/autopilot/airspeed_dial_kts") + 0.5)), 428, 5, 11, C.cyan)
        end
    end

    local function draw_page()
        XPLMPolygon(C.bg, { { x = 0, y = 0 }, { x = 0, y = H * S }, { x = W * S, y = H * S }, { x = W * S, y = 0 } }, 4)
        if face then
            local sh = face_shade()
            face_tint = sh
            XPLMTextureAtlasDrawIn(atlas, face, XPLMMakeColor(sh, sh, sh, 1), 0, H * S, W * S, STRIP * S)
            local glow = light_state()
            if glow > 0.001 and spr.glow then
                -- backlit lettering over the tinted face (night only)
                XPLMTextureAtlasDrawIn(atlas, spr.glow, XPLMMakeColor(1, 1, 1, glow), 0, H * S, W * S, STRIP * S)
            end
            draw_overlays()
        else
            -- flat fallback: same zones
            fill_rr(8, STRIP + 8, W - 8, H - 8, 12, C.plate)
            edge_rr(8, STRIP + 8, W - 8, H - 8, 12, C.frame, 1)
            for _, c in ipairs(controls) do
                if c.kind == "key" then draw_key(c) elseif c.kind == "knob" then draw_knob(c) else draw_wheel(c) end
            end
        end
        draw_strip()
    end

    ------------------------------------------------------------------ device
    local popup, toggle_cmd = nil, nil

    local function draw_cb(ref)
        local ok, err = pcall(draw_page)
        if not ok then ctx.log("draw error: " .. tostring(err)) end
    end
    -- the screen is composited additively over the bezel: opaque background here
    local function bezel_cb(r, g, b, ref)
        if C.bg then
            XPLMPolygon(C.bg, { { x = 0, y = 0 }, { x = 0, y = H * S }, { x = W * S, y = H * S }, { x = W * S, y = 0 } }, 4)
        end
    end
    local function brightness_cb(rheo, ambient, bus, ref) return 1 end

    -- mouse: 1 down, 2 drag, 3 up; x, y framebuffer pixels from bottom left.
    -- Only presses on a usable control are consumed; the rest goes back to
    -- X-Plane (return false), which drags the window.
    local function touch_cb(x, y, mouse, ref)
        local mine = false
        local ok, err = pcall(function()
            local c, action, cmd = hit_at(x / S, y / S)
            if c and not usable(c, action) then c = nil end
            if mouse == 1 then
                mine = c ~= nil
                pressed = (c and c.kind == "key") and c or nil
                -- a knob half or the wheel fires on press; its drag and release are ours too, so X-Plane
                -- never sees an orphan drag / up that could start a window drag (review C4, 2026-11-13)
                held = (c and c.kind ~= "key") and true or false
                if c and c.kind ~= "key" then fire(cmd) end
            else
                mine = pressed ~= nil or held
                if mouse == 3 then
                    if pressed and c == pressed then fire(cmd) end
                    pressed = nil
                    held = false
                end
            end
        end)
        if not ok then ctx.log("touch error: " .. tostring(err)) end
        return mine
    end
    P.touch = touch_cb

    -- the framebuffer stays at S = 2 for sharp text; the window opens at W x H
    -- screen pixels (top left kept), once; after that the user's size sticks
    local sized = false
    local function default_size()
        if sized or not popup then return end
        local ok, geom = pcall(XPLMGetAvionicsGeometry, popup)
        if not ok or type(geom) ~= "table" then return end
        local left = tonumber(tostring(geom.outLeft))
        local top = tonumber(tostring(geom.outTop))
        local right = tonumber(tostring(geom.outRight))
        local bottom = tonumber(tostring(geom.outBottom))
        -- M2: a zero-sized or missing reading is not trusted; sized stays false and the next show retries
        if not left or not top or not right or not bottom or right <= left or top <= bottom then return end
        pcall(XPLMSetAvionicsGeometry, popup, math.floor(left), math.floor(top),
            math.floor(left + W), math.floor(top - H))
        sized = true
    end

    function P.toggle_cb(cmd, phase, ref)
        if phase == XPLMCommandPhase.xplm_CommandBegin and popup then
            local show = not XPLMIsAvionicsPopupVisible(popup)
            XPLMSetAvionicsPopupVisible(popup, show)
            if show then default_size() end
        end
        return 1
    end

    -- the device, font and atlas are created once and kept across Disable / Enable (xLua keeps every
    -- callback it is handed); create() on an existing device only sets the visibility
    function P.create(visible)
        if popup then
            XPLMSetAvionicsPopupVisible(popup, visible and true or false)
            if visible then default_size() end
            return
        end
        init_gfx()
        load_face()
        popup = XPLMCreateAvionicsEx({
            screenWidth = W * S, screenHeight = H * S,
            bezelWidth = W * S, bezelHeight = H * S,
            screenOffsetX = 0, screenOffsetY = 0,
            bezelDrawCallback = bezel_cb,
            drawCallback = draw_cb,
            brightnessCallback = brightness_cb,
            screenTouchCallback = touch_cb,
            deviceID = "laminar_gmc507",
            deviceName = "GMC 507",
            refcon = "popup",
            contentType = XPLMWindowContentType.xplm_WindowContentTypePanelGraphics,
        })
        XPLMSetAvionicsBrightnessRheo(popup, 1.0)
        XPLMSetAvionicsPopupVisible(popup, visible and true or false)
        if visible then default_size() end   -- hidden: sized on first show (M2)
    end

    -- Disable: hide, keep the device
    function P.hide()
        if popup then pcall(XPLMSetAvionicsPopupVisible, popup, false) end
    end

    -- the toggle command is registered once (XPluginStart) and removed in
    -- XPluginStop; create / destroy only handle the device (M4)
    function P.register()
        if toggle_cmd then return end
        toggle_cmd = XPLMCreateCommand("laminar/gmc507/popup_toggle", "GMC 507 popup: show / hide")
        if toggle_cmd then
            XPLMRegisterCommandHandler(toggle_cmd, P.toggle_cb, true, nil)
        else
            ctx.log("command could not be created, skipped: laminar/gmc507/popup_toggle")
        end
    end

    function P.unregister()
        if toggle_cmd then pcall(XPLMUnregisterCommandHandler, toggle_cmd, P.toggle_cb, true, nil) toggle_cmd = nil end
    end

    function P.destroy()
        sized = false    -- M1: a new device starts at the default size again
        if popup then pcall(XPLMDestroyAvionics, popup) popup = nil end
        if font then pcall(XPLMDestroyFont, font) font = nil end
        if atlas and XPLMDestroyTextureAtlas then pcall(XPLMDestroyTextureAtlas, atlas) end
        atlas, face, spr = nil, nil, {}
    end

    -- test hook: run the drawing code against stubs
    function P.draw_once() init_gfx() draw_page() bezel_cb() end

    return P
end

return Popup
