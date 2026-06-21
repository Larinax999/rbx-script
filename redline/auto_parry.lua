-- Auto Parry for "Redline" (by larina :P)
-- ─────────────────────────────────────────────────────────────────────────────
-- Combat runs inside a Luau Actor, so the live indicator Lua table is NOT
-- reachable (no getgc), and packets are buffer+AEAD encrypted (can't decode).
-- The reliable, shared signal is the Instance tree: the parry INDICATOR UI.
--
-- Precise timing from the indicator arc (the "tween"):
--   A parryable shot spawns a UI clone named "ShooterIndicator" in
--   PlayerGui > GameplayUI. Every frame the game sets
--       ShooterIndicator.ParryRange.LeftClip.Left.UIGradient.Rotation
--   to  v132 = 2 * deg( acos( 1 - parry_range * alpha ) )  where
--       alpha = (now - appear) / draw_time     rises 0 -> 1 linearly
--   and the SHOT lands exactly at alpha == 1.
--   Let  s = 1 - cos(rad(rotation)/2)  ==  parry_range * alpha.
--
-- PER-GUN behaviour (the v3 upgrade) ────────────────────────────────────────
--   draw_time / parry_range are server-authoritative (not in the client dump),
--   but they differ a LOT between weapons, so one global timer is wrong when
--   several gun types are on the field. We identify the shooter's gun from the
--   Instance tree -- the equipped weapon is a child Model of the shooter's
--   character named exactly "Castigate"/"Phoenix"/"Siege"/"Monarch" -- and time
--   each shot from that gun's profile (seeded from the in-game stat cards, then
--   per-gun auto-calibrated). This fixes:
--     * Monarch  - 1.85s draw (vs the generic ~0.55s): the old timer fired ~1.3s
--                  early and the parry window closed before the shot. Now timed
--                  to Monarch's real, much longer draw.
--     * Siege    - 2 shots per draw (shots_per_draw=2), staggered by the gun's
--                  shot_interval; the parry system resolves ONE shot per press,
--                  so we fire a second parry shortly after the first.
--     * Phoenix  - fires a TRAVELLING rocket (explosion+direct dmg), not a
--                  hitscan bullet. The draw indicator only telegraphs the aim;
--                  the hit lands later when the rocket arrives. We watch
--                  workspace.Effects for the incoming projectile and parry at
--                  IMPACT (pressing at draw-end would burn the window early).
--     * Castigate- left on the baseline timing (it was fine).
--
-- Shooter facing: a parry only counts the shooter if the camera is yawed toward
--   them. The arc also encodes the on-screen angle to the shooter
--   ( ParryRange.Rotation + rotation/2 == game's getRotation ), so we match it
--   against the live characters to find the shooter and yaw-snap to them.
--
-- Trigger: synthetic press of the PARRY key (F) through UserInputService -- the
--   game's own code then builds the correct redliner_parry payload. No forging.
--
-- Reload-safe: call _G.AutoParryStop() to remove the previous instance.
-- ─────────────────────────────────────────────────────────────────────────────

local Players          = game:GetService("Players")

local LocalPlayer = (cloneref and cloneref(Players.LocalPlayer)) or Players.LocalPlayer

-- ── Tunables (defaults; overridden by the UI below if present) ────────────────
local state = {
    enabled       = true, -- master on/off
    autoFace      = false,  -- yaw camera toward the incoming shooter at parry time
    losCheck      = false,  -- only parry a shooter that currently has line of sight
    calibrate     = false, -- auto-tune per-gun draw / sMax from observed shots
    autoGun       = true,  -- identify each shooter's gun and use its profile
    defaultGun    = "Castigate", -- profile used when the gun can't be detected (or Auto-Detect Gun is off); "Generic" = the old single-timer behaviour
    parryLead     = 0.05,  -- seconds-before-shot the predictor aims to press. The shot is
                           -- at arc==sMax; we extrapolate the arc's rise and fire when it's
                           -- this far out. The parry window is ~0.5s so 0.12 sits well inside
                           -- it with margin for loop jitter. Raise if still late, lower if early.
    fallbackDelay = 0.32,  -- if the arc can't be read: press this long after the indicator appears
    cooldown      = 0.0,  -- hard min seconds between any two parries (also used by the rocket watcher).
                           -- The pure latch below already collapses one shot's clone-burst into ONE press,
                           -- so this is just an input-settle floor -- keep it LOW so genuinely separate
                           -- shots <0.2s apart still get parried (0.20 here was dropping fast re-parries).

    -- Ephemeral-indicator mode (REQUIRED in this low-runtime game). The
    -- ShooterIndicator here only lives ~40-60ms -- it is a brief telegraph, not a
    -- 0.5-1.85s draw tween (confirmed: tick() is real-time yet no indicator's age
    -- ever passed ~0.04s over a whole session). So the draw-timer triggers can
    -- never elapse; we parry on DETECTION instead.
    instantParry  = false, -- legacy: fire on first detection (spams once per clone). OFF -> use the arc trigger below.
    appearLead    = 0.0,   -- (legacy instantParry only) seconds to wait after detection before pressing

    -- Siege: 2 shots per draw -> fire a second parry this long after the first.
    siegeDouble   = true,
    siegeDelay    = 0.50,

    -- Phoenix: travelling rocket. false -> parry on its indicator arc like every other
    -- gun (rocket-impact watcher OFF). The impact-watcher approach gave "no parry at all".
    phoenixCheck  = true,
    phoenixLead   = 0.06,  -- press when the rocket is this many seconds from impact
    phoenixRadius = 30,    -- ...or once it's within this many studs (backstop for a fast rocket)
}

local PARRY_VK = 0x46 -- Windows virtual-key code for 'F' (the default PARRY bind)

-- Phoenix rocket detection: ignore effects further than this from us.
local PROJ_MAX_RANGE = 450

-- ── Lazy character cache (executor-agnostic: no CharacterAdded reliance) ───────
local Character, RootPart, Humanoid
local function refreshCharacter()
    local char = LocalPlayer.Character
    if char ~= Character then
        Character = char
        RootPart  = char and char:FindFirstChild("HumanoidRootPart") or nil
        Humanoid  = char and char:FindFirstChildOfClass("Humanoid") or nil
    elseif Character and (RootPart == nil or RootPart.Parent == nil) then
        RootPart = Character:FindFirstChild("HumanoidRootPart")
    end
    return Character
end
local function isAlive()
    refreshCharacter()
    return Character ~= nil and RootPart ~= nil and (Humanoid == nil or Humanoid.Health > 0)
end

-- ── Frame scheduler (alternative to task.delay) ───────────────────────────────
-- Deferred actions (key release, Siege 2nd parry) are queued here and run from
-- the main loop instead of via task.delay. `runPending` is called every frame
-- (even while disabled) and `flushPending` runs them all on stop, so a held key
-- can never get stuck down.
local pending = {}
local function schedule(delay, fn)
    pending[#pending + 1] = { at = tick() + delay, fn = fn }
end
local function runPending(now)
    for i = #pending, 1, -1 do
        if now >= pending[i].at then
            local fn = pending[i].fn
            table.remove(pending, i)
            pcall(fn)
        end
    end
end
local function flushPending()
    local snapshot = pending
    pending = {}
    for _, p in ipairs(snapshot) do pcall(p.fn) end
end

-- ── Parry trigger: tap F through the real input path (non-yielding) ───────────
local HOLD = 0.03 -- key down-time for the tap (seconds)
local function tapParry()
    -- NO print() here: this is the hot path. Console writes in this runtime cost more
    -- as the buffer grows, and a print between the fire decision and keypress adds that
    -- growing latency straight onto every parry -> "fine for a few shots, then too slow".
    --
    -- Hold F for a REAL ~HOLD seconds via the frame scheduler (runPending releases it).
    -- The old code released after a BARE task.wait(), which returns almost instantly in this
    -- runtime (see the main-loop note) -- so press+release landed in the SAME frame and the
    -- game's InputBegan handler could miss the tap entirely (-> "pressed=true but no parry").
    -- A scheduled release also keeps this NON-yielding, so the hot path never stalls mid-press.
    local ok = pcall(keypress, PARRY_VK)
    schedule(HOLD, function() pcall(keyrelease, PARRY_VK) end)
    return ok
end

-- ── Camera read from process memory (ported from script.lua) ──────────────────
-- cam.CFrame.LookVector / .Position return nil in this executor (instance property
-- reads on the camera are unreliable here). script.lua already solves this by
-- resolving the camera's C++ object via Matcha's getbase/memory_read and reading
-- its rotation matrix straight from memory; we reuse the exact same path here, and
-- add GetCameraPosition (the 3 floats right after the rotation matrix) since the
-- facing math below needs the camera world position too.
local CAM_VERSION_URL = "https://offsets.imtheo.lol/roblox/version"
local CAM_OFFSETS_URL = "https://offsets.imtheo.lol/%s/offsets.json"
local CAM_CACHE_PATH  = "redliner_offsets_cache.json"   -- same cache script.lua writes

local OFFSETS = {}
local OFFSETS_LOADED, OFFSETS_FROM_CACHE, OFFSETS_REFETCH_TRIED = false, false, false

local function ParseOffsets(body)
    if not body or body == "" then return nil end
    local ok, decoded = pcall(function()
        return game:GetService("HttpService"):JSONDecode(body)
    end)
    if not ok or type(decoded) ~= "table" or type(decoded.Offsets) ~= "table" then return nil end
    local o = decoded.Offsets
    local out = {
        FakeDataModelPointer     = o.FakeDataModel and o.FakeDataModel.Pointer,
        FakeDataModelToDataModel = o.FakeDataModel and o.FakeDataModel.RealDataModel,
        Workspace                = o.DataModel    and o.DataModel.Workspace,
        CurrentCamera            = o.Workspace    and o.Workspace.CurrentCamera,
        CameraRotation           = o.Camera       and o.Camera.Rotation,
    }
    if out.FakeDataModelPointer and out.FakeDataModelToDataModel
        and out.Workspace and out.CurrentCamera and out.CameraRotation then
        return out
    end
    return nil
end

local function FetchOffsetsBody()
    local version = httpget(CAM_VERSION_URL)
    if version == "" then return "" end
    return httpget(string.format(CAM_OFFSETS_URL, version))
end

local function ApplyOffsets(parsed, fromCache)
    OFFSETS, OFFSETS_LOADED, OFFSETS_FROM_CACHE = parsed, true, fromCache
end

-- Startup: prefer the local cache (no network on load), fall back to fetch.
pcall(function()
    local cached = isfile(CAM_CACHE_PATH) and ParseOffsets(readfile(CAM_CACHE_PATH)) or nil
    if cached then
        ApplyOffsets(cached, true)
    else
        local body = FetchOffsetsBody()
        local parsed = ParseOffsets(body)
        if parsed then
            ApplyOffsets(parsed, false)
            pcall(writefile, CAM_CACHE_PATH, body)
        end
    end
end)

local CAM_BASE = (type(getbase) == "function") and getbase() or 0

local function ReadPtr(addr)
    if not addr or addr == 0 then return 0 end
    return memory_read("uintptr_t", addr) or 0
end
local function ReadFloat(addr)
    if not addr or addr == 0 then return 0 end
    return memory_read("float", addr) or 0
end

local CameraPtr = 0
local function ResolveCameraPtrOnce()
    CameraPtr = 0
    if not OFFSETS_LOADED then return 0 end
    local fdm = ReadPtr(CAM_BASE + OFFSETS.FakeDataModelPointer)
    if fdm == 0 then return 0 end
    local dm = ReadPtr(fdm + OFFSETS.FakeDataModelToDataModel)
    if dm == 0 then return 0 end
    local ws = ReadPtr(dm + OFFSETS.Workspace)
    if ws == 0 then return 0 end
    CameraPtr = ReadPtr(ws + OFFSETS.CurrentCamera)
    return CameraPtr
end
-- Refetch offsets once per session if a cached resolve fails (Roblox updated since save).
local function ResolveCameraPtr()
    local r = ResolveCameraPtrOnce()
    if r == 0 and OFFSETS_FROM_CACHE and not OFFSETS_REFETCH_TRIED then
        OFFSETS_REFETCH_TRIED = true
        local body = FetchOffsetsBody()
        local parsed = ParseOffsets(body)
        if parsed then
            ApplyOffsets(parsed, false)
            pcall(writefile, CAM_CACHE_PATH, body)
            r = ResolveCameraPtrOnce()
        end
    end
    return r
end

-- Rotation is a 3x3 row-major float matrix; LookVector = -Back column = (-R02,-R12,-R22),
-- renormalized in double precision (storage is 32-bit). Identical to script.lua.
local function GetCameraLookVector()
    if CameraPtr == 0 and ResolveCameraPtr() == 0 then return nil end
    local rot = CameraPtr + OFFSETS.CameraRotation
    local r02 = ReadFloat(rot + 8)
    local r12 = ReadFloat(rot + 20)
    local r22 = ReadFloat(rot + 32)
    local mag = math.sqrt(r02 * r02 + r12 * r12 + r22 * r22)
    if mag < 1e-6 then return nil end
    return Vector3.new(-r02 / mag, -r12 / mag, -r22 / mag)
end

-- Camera world position: the 3 floats immediately after the 9-float (36-byte) matrix.
local function GetCameraPosition()
    if CameraPtr == 0 and ResolveCameraPtr() == 0 then return nil end
    local p = CameraPtr + OFFSETS.CameraRotation + 36
    return Vector3.new(ReadFloat(p), ReadFloat(p + 4), ReadFloat(p + 8))
end

-- ── Camera / facing helpers ───────────────────────────────────────────────────
local FLAT = Vector3.new(1, 0, 1)

local function headPosOf(model)
    if not model then return nil end
    local h = model:FindFirstChild("Head")
    if h and h:IsA("BasePart") then return h.Position end
    if model.PrimaryPart then return model.PrimaryPart.Position end
    local ok, pivot = pcall(function() return model:GetPivot().Position end)
    return ok and pivot or nil
end

-- Replica of the game's getRotation(): signed horizontal angle (deg) between the
-- camera look and the (camera -> shooter) axis. Used to identify the shooter.
local function gameAngleTo(headPos)
    local look = GetCameraLookVector()       -- from process memory (cam.CFrame.LookVector is nil here)
    if not look then return nil end
    look = look * FLAT
    if look.Magnitude < 1e-4 then return nil end
    look = look.Unit
    local camPos = GetCameraPosition()
    if not camPos then return nil end
    local v = (camPos * FLAT) - (headPos * FLAT)
    if v.Magnitude < 1e-4 then return nil end
    local u = v.Unit
    local dot   = look:Dot(u)
    local cross = look.X * u.Z - look.Z * u.X
    return math.deg(math.atan2(cross, dot))
end

local function angDiff(a, b)
    return math.abs(((a - b + 180) % 360) - 180)
end

-- Every shooter character (players AND NPCs/dummies, e.g. "EmptyDummy") lives in
-- workspace.Entities, so we match against that. Falls back to Players if the
-- folder is missing for some game state.
local function shooterCandidates()
    local list, seen = {}, {}
    local ents = workspace:FindFirstChild("Entities")
    if ents then
        for _, m in ipairs(ents:GetChildren()) do
            if m ~= Character and m:IsA("Model") and not seen[m] then
                seen[m] = true
                list[#list + 1] = m
            end
        end
    end
    for _, pl in ipairs(Players:GetPlayers()) do
        local c = (pl ~= LocalPlayer) and pl.Character or nil
        if c and c ~= Character and not seen[c] then
            seen[c] = true
            list[#list + 1] = c
        end
    end
    return list
end

-- Find which shooter character matches the indicator's implied shooter angle.
local function findShooter(indicatorAngle)
    if indicatorAngle == nil then return nil end
    local best, bestDiff = nil, math.huge
    for _, model in ipairs(shooterCandidates()) do
        local hp = headPosOf(model)
        if hp then
            local a = gameAngleTo(hp)
            if a then
                local d = angDiff(a, indicatorAngle)
                if d < bestDiff then bestDiff = d; best = model end
            end
        end
    end
    if best and bestDiff <= 14 then return best end
    return nil
end

-- ── Gun identification from the Instance tree ─────────────────────────────────
-- The equipped weapon's 3P rig is parented directly under the shooter character.
-- Its canonical id is the "item_id" attribute (set by SkinDefs and carried on the
-- rig template, so it survives cloning). We must read item_id, NOT the Model name:
-- when a skin is equipped the rig Model is renamed to the SKIN (e.g. "AwpVanilla",
-- "MON_WinterTroop", "PHX_Zealot"), while item_id stays the gun id ("Monarch"...).
-- Redliner (melee) carries item_id "Redliner", which isn't in GUN_NAMES -> ignored.
local GUN_NAMES = {
    Castigate = true, Phoenix = true, Siege = true, Monarch = true, BaseGun = true,
}
local function gunOf(model)
    if not model then return nil end
    local children = model:GetChildren()
    -- primary: skin-proof item_id attribute on the equipped rig
    for _, ch in ipairs(children) do
        local id = ch:GetAttribute("item_id")
        if id and GUN_NAMES[id] then return id end
    end
    -- fallback: default/unskinned rigs are named after the gun itself
    for _, ch in ipairs(children) do
        if GUN_NAMES[ch.Name] and ch:IsA("Model") then return ch.Name end
    end
    return nil
end

-- Aim toward a world position by MOVING THE MOUSE -- the game rotates its camera to follow the
-- mouse, which is more reliable here than writing cam.CFrame directly. Two cases:
--   * target ON screen: drop the cursor on it (WorldToScreen gives the pixel; the resulting delta
--     from screen-centre yaws/pitches the camera onto it).
--   * target BEHIND / off screen: WorldToScreen returns not-visible (no pixel), so we can't aim at
--     it directly -- instead push the cursor to the LEFT/RIGHT screen edge on the target's side
--     (from the camera's own vectors) to spin the camera around until the target enters view, at
--     which point the on-screen branch fine-aims. This is what lets a parry register against a
--     shooter behind the camera. Called every fire (and, for a behind target, repeatedly across the
--     shot's frames) so the turn converges. NOTE: if it ever spins the WRONG way, flip the edgeX sign.
local function faceTowardPos(target)
    if not target then return end

    if type(mousemoveabs) == "function" then
        -- ON screen: move the cursor onto the target.
        if type(WorldToScreen) == "function" then
            local ok, sp, onScreen = pcall(WorldToScreen, target)
            if ok and onScreen and sp then
                pcall(mousemoveabs, math.floor(sp.X + 0.5), math.floor(sp.Y + 0.5))
                return
            end
        end
        -- BEHIND / off screen: turn horizontally toward the target's side until it comes into view.
        local look, camPos = GetCameraLookVector(), GetCameraPosition()
        if look and camPos then
            local lookF = look * FLAT
            local toT   = (target - camPos) * FLAT
            if lookF.Magnitude > 1e-4 and toT.Magnitude > 1e-4 then
                lookF, toT = lookF.Unit, toT.Unit
                local right = Vector3.new(-lookF.Z, 0, lookF.X)         -- camera's horizontal right
                local w, midY = 1920, 540                              -- viewport (ViewportSize may be unreadable here)
                local okv, vp = pcall(function() return workspace.CurrentCamera.ViewportSize end)
                if okv and vp and vp.X and vp.X > 1 then w, midY = vp.X, vp.Y * 0.5 end
                local edgeX = (toT:Dot(right) >= 0) and (w - 2) or 2    -- target to our right -> push right edge
                pcall(mousemoveabs, math.floor(edgeX), math.floor(midY))
            end
        end
        return
    end

    -- Fallback (executor without mousemoveabs): write the camera CFrame directly (the old path).
    local cam = workspace.CurrentCamera
    if not cam then return end
    local camPos = GetCameraPosition()
    if not camPos then return end
    local flat = (target - camPos) * FLAT
    if flat.Magnitude < 1e-3 then return end
    flat = flat.Unit
    local lv   = GetCameraLookVector()
    local curY = lv and lv.Y or 0                       -- preserve pitch if we can read it
    local look = Vector3.new(flat.X, curY, flat.Z)
    if look.Magnitude < 1e-3 then return end
    pcall(function() cam.CFrame = CFrame.lookAt(camPos, camPos + look.Unit) end)
end
local function faceShooter(model)
    faceTowardPos(headPosOf(model))
end

-- Real-time line of sight from us to the shooter. A blocked shot can't hit, so we
-- hold the parry until LOS exists -- caught each frame, so a last-second opening
-- still triggers in time. Unknowns default to "clear" so we never miss a parry.
local function hasLOS(shooterModel)
    local headPos = headPosOf(shooterModel)
    if not headPos then return true end
    local originPart = (Character and Character:FindFirstChild("Head")) or RootPart
    if not originPart then return true end
    local origin = originPart.Position
    local dir = headPos - origin
    if dir.Magnitude < 1e-3 then return true end
    local ok, res = pcall(function()
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = { Character, shooterModel }
        params.IgnoreWater = true
        return workspace:Raycast(origin, dir, params)
    end)
    if not ok then return true end       -- raycast unavailable -> don't block
    return res == nil                    -- nothing between us and the shooter
end

-- ── Per-gun timing profiles ───────────────────────────────────────────────────
-- draw  = seed draw_time (s) from the in-game stat card (auto-calibrated if on).
-- lead  = press this many seconds before the predicted shot.
-- arcA  = arc fraction (alpha) at which the refine trigger may fire early.
-- Indicator lifetime ~= draw_time, so the EMA self-corrects toward the real
-- server value once a couple of shots have been seen.
local drawByGun = {
    Castigate = 0.75, Phoenix = 0.80, Siege = 1.10, Monarch = 1.85, BaseGun = 0.75,
    __default = 0.55,
}
local leadByGun = {                 -- per-gun seconds-before-shot; absent guns use state.parryLead
    Monarch = 0.12, Siege = 0.12, Phoenix = 0.12,
}
-- FLOOR threshold (fraction of the adaptive terminal sTermEst): the PRIMARY trigger. Because
-- sTermEst tracks each shot's real peak, this presses at the SAME arc fraction (alpha) on every
-- shot, so the timing is consistent and never drifts. Castigate/__default at 0.66 give extra
-- lead (press ~alpha 0.66, comfortably inside the ~0.5s parry window) to absorb the fork's input
-- latency and protect the lowest-peak LAST shot of a burst. Monarch/Siege stay HIGHER on purpose:
-- their draws are LONG, so a lower alpha would press so early the parry window expires before the
-- shot lands. The velocity predictor below can only fire EARLIER, never blocks this.
local arcAlphaByGun = {
    Castigate = 0.66, Phoenix = 0.78, Siege = 0.80, Monarch = 0.80, __default = 0.66,
}
-- per-gun terminal arc (== parry_range). MEASURED via [AP-DIAG] termS (max arc value
-- under the 0.85 template-spike cap): Castigate/Siege ~=0.30, Monarch ~=0.15 (half!).
-- The fire threshold is arcAlphaByGun*sMaxByGun -- too-high an sMax means that gun never
-- reaches the threshold and never parries; that was exactly Monarch's "no parry" bug.
local sMaxByGun = {
    Castigate = 0.30, Phoenix = 0.30, Siege = 0.30, Monarch = 0.15, BaseGun = 0.30,
    __default = 0.30,
}

local profileMeta = {                    -- non-timing behaviour flags
    Siege   = { doubleParry = true },
    Phoenix = { projectile  = true },
}

local CAL_K        = 0.30     -- EMA weight
local ARC_SETTLE   = 0.0      -- read the arc immediately: the indicator only lives ~40ms here, no time to wait out template frames
local ARC_MIN_FRAC = 0.40     -- only allow the arc refine after this fraction of draw has elapsed
local MAX_LEAD     = 0.30     -- cap (s) on how early the floor may press before the shot. Over a long
                              -- burst the enemy's draw lengthens (v falls), so a fixed arc fraction
                              -- presses ever-earlier in real time until the ~0.5s parry window expires
                              -- pre-shot ("late" parry ~16-17 shots in). This holds the press until the
                              -- shot is within MAX_LEAD, keeping the lead inside the window. Raise if
                              -- the press feels late, lower if it fires too early.

local function drawFor(gun)     return (gun and drawByGun[gun])     or drawByGun.__default end
local function sMaxFor(gun)     return (gun and sMaxByGun[gun])     or sMaxByGun.__default end
local function arcAlphaFor(gun) return (gun and arcAlphaByGun[gun]) or arcAlphaByGun.__default end
local function leadFor(gun)     return (gun and leadByGun[gun])     or state.parryLead end

-- Configurable fallback when the shooter's gun can't be read from the tree (and
-- the value the "Default Gun" slider maps to). "Generic" -> the __default profile.
local DEFAULT_GUNS = { "Generic", "Castigate", "Phoenix", "Siege", "Monarch" }
local function gunIndex(name)
    for i, n in ipairs(DEFAULT_GUNS) do if n == name then return i end end
    return 2 -- Castigate
end
-- The gun profile to actually use for a shot: the detected gun, else the
-- configured default ("Generic" resolves to nil = the __default profile).
local function resolveGun(st)
    if type(st.gun) == "string" then return st.gun end
    local d = state.defaultGun
    if d == nil or d == "Generic" then return nil end
    return d
end

local function sFromRotation(r)
    if r > 180 then r = 360 - r end          -- keep within the principal arc
    if r < 0 then r = 0 end
    return 1 - math.cos(math.rad(r) / 2)     -- == parry_range * alpha
end

-- ── Read .Rotation straight from process memory (script.lua style) ────────────
-- Same Matcha memory_read path script.lua uses for the camera. Reading the value
-- from raw memory instead of the `.Rotation` property bypasses any __index hook
-- the game could place on Instance access. The instance's base address comes from
-- the executor's `Instance.Address` property; the Rotation float sits at a
-- class-specific byte offset. If the read fails, readArc falls back to .Rotation.
-- https://github.com/BenMcAvoy/roblox-dumper/blob/main/docs/public/offsets.hpp
local GRADIENT_ROTATION_OFFSET  = 0x160   -- UIGradient.Rotation (float)
local GUIOBJECT_ROTATION_OFFSET = 0x188   -- GuiObject.Rotation  (Frame, e.g. ParryRange)

local function memReadFloat(addr)
    if not addr or addr == 0 or type(memory_read) ~= "function" then return nil end
    local ok, v = pcall(memory_read, "float", addr)
    -- Reject garbage so a STALE/REUSED instance address (possible after clone churn) can't
    -- poison the arc. v == v rejects NaN; the magnitude bound rejects +/-inf and denormal junk.
    -- A real Rotation is well within this, so a bad read returns nil and readArc skips it (the
    -- .Rotation property is nil on this executor, so memory_read is the only source).
    if ok and type(v) == "number" and v == v and v > -1e6 and v < 1e6 then return v end
    return nil
end

-- The instance's C++ base address via the executor's Instance.Address property.
-- _readAddr is a SHARED function handed to pcall (with inst as an ARG) so we never allocate a
-- closure per call. The old `pcall(function() return inst.Address end)` built a fresh closure
-- on EVERY call -- x2 per clone x dozens of clones every frame -- and that per-frame garbage
-- was the GC pressure that collapsed the loop to ~12Hz mid-draw (it ramped exactly as clones
-- piled up during the draw). memory_read itself is cheap; the allocations around it weren't.
local function _readAddr(inst) return inst.Address end
local function instanceAddr(inst)
    local ok, a = pcall(_readAddr, inst)
    if ok and type(a) == "number" and a ~= 0 then return a end
    return nil
end

-- The .Rotation PROPERTY returns nil on this executor (confirmed), so the arc can ONLY be read
-- via memory_read at Address+offset. To keep that cheap under a clone burst we CACHE the
-- UIGradient/ParryRange instances AND their Addresses on the shot state -- the 4-deep
-- FindFirstChild chain and the Address fetch run ONCE per clone, then each frame the arc is a
-- single memory_read. The shooter ANGLE needs a 2nd read, so it's taken only for the leading
-- clone (readAngle, from step), never per clone.
local function readArc(st, ind)          -- returns s (arc progress) | nil
    local grad = st.grad
    if not grad or grad.Parent == nil then
        local pr = ind:FindFirstChild("ParryRange")
        if not pr then return nil end
        local lc   = pr:FindFirstChild("LeftClip")
        local left = lc and lc:FindFirstChild("Left")
        grad = left and left:FindFirstChild("UIGradient")
        if not grad then return nil end
        st.grad, st.pr = grad, pr
        st.gradAddr = instanceAddr(grad)
        st.prAddr   = instanceAddr(pr)
    end
    if not st.gradAddr then return nil end
    local r = memReadFloat(st.gradAddr + GRADIENT_ROTATION_OFFSET)
    if not r then return nil end
    return sFromRotation(r)
end

-- shooter on-screen angle (deg) for the LEADING clone only -- one extra memory_read. Facing
-- doesn't gate the parry, so this is never needed for every clone.
local function readAngle(st)
    if not st.gradAddr or not st.prAddr then return nil end
    local r  = memReadFloat(st.gradAddr + GRADIENT_ROTATION_OFFSET)
    local pr = memReadFloat(st.prAddr   + GUIOBJECT_ROTATION_OFFSET)
    if not r or not pr then return nil end
    return pr + r / 2  -- == game's getRotation(shooter)
end

local function clampN(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi else return v end
end

-- called when an indicator is removed; lifetime ~= the shot's draw_time
local function calibrateDraw(gun, lifetime)
    if not state.calibrate then return end          -- frozen: use the seed / manual value
    -- wide clamp so Monarch's ~1.85s is accepted but the 5s Debris timeout is not
    if lifetime and lifetime > 0.20 and lifetime < 2.40 then
        local key = (gun and drawByGun[gun] ~= nil) and gun or "__default"
        drawByGun[key] = clampN(drawByGun[key] + CAL_K * (lifetime - drawByGun[key]), 0.20, 2.40)
    end
end

-- only accept plausible terminal arc values (rejects spurious template spikes)
local function calibrateArc(gun, maxS)
    if not state.calibrate then return end          -- frozen
    if maxS and maxS > 0.08 and maxS < 0.80 then
        local key = (gun and sMaxByGun[gun] ~= nil) and gun or "__default"
        sMaxByGun[key] = clampN(sMaxByGun[key] + CAL_K * (maxS - sMaxByGun[key]), 0.08, 0.80)
    end
end

-- ── Phoenix projectile watcher (parry at impact) ──────────────────────────────
-- A Phoenix shot becomes a travelling rocket -- a clone of EffectAssets.Rocket
-- parented straight into workspace.Effects (confirmed in the client dump). The
-- draw indicator only telegraphs the AIM; the hit lands later when the rocket
-- arrives, so pressing at draw-end burns the parry window early. Instead we watch
-- the live rocket BY NAME and parry as it closes on us.
--   * keyed off the actual instance ("Rocket"), not "any moving effect" -- so
--     muzzle flashes / tracers / auras can't be mistaken for the threat;
--   * standalone + always-on, so it works even if the shooter's gun couldn't be
--     resolved (the old indicator-gated version did nothing in that case);
--   * fires on distance OR time-to-impact (a fixed tti window is too tight for a
--     fast rocket; distance is the reliable backstop);
--   * `closing` test rejects our OWN outgoing Phoenix rocket (it recedes).
local lastNearestDist = nil -- previous frame's NEAREST rocket distance (NOT keyed by instance -- see watchRockets)
local rocketSeen  = false -- a rocket is currently in flight toward us (lock guard)
local lastParry   = 0     -- forward declare (used by the watcher)
local parryLatched = false -- true while inside one arc-fire window; fire once on entry, re-arm when it clears
local gArcS = 0           -- previous frame's leading (max valid) arc value -- for shot-time prediction
local gArcT = 0           -- tick() when gArcS was sampled
local gVel  = 0           -- EMA-smoothed arc rise speed (per-frame v is too noisy to time off)
local gLastShooter = nil  -- last successfully-resolved shooter model. FACING FALLBACK: a parry only
                          -- counts if the camera is yawed at the shooter, so if findShooter misses on
                          -- the firing frame we still face the last-known shooter (correct for 1 enemy).

-- ADAPTIVE arc terminal (== the shot's parry_range), LEARNED from each shot's observed peak.
-- The fire timing no longer depends on (flaky) gun detection / sMaxByGun: whatever the enemy's
-- real terminal is (Monarch ~0.15, Castigate ~0.30) we converge to it within a shot or two.
-- This is the fix for "loop fast, arc peaks at 0.15, but never fires" -- gun fell back to the
-- Castigate default (sMax 0.30) so the 0.234 threshold was unreachable. Seeded mid/low so the
-- first shot still fires roughly right; the parry window is wide (~0.5s) so erring early is safe.
local sTermEst = 0.15
local shotPeak = 0        -- running max arc of the current shot (feeds sTermEst at shot end)
local seededGun = nil     -- gun sTermEst was last seeded from; re-seed on gun change for a good shot-1

local function effectPos(inst)
    if inst:IsA("BasePart") then return inst.Position end
    if inst.PrimaryPart then return inst.PrimaryPart.Position end
    local bp = inst:FindFirstChildWhichIsA("BasePart", true)
    if bp then return bp.Position end
    local ok, p = pcall(function() return inst:GetPivot().Position end)
    return ok and p or nil
end

local function isRocketName(name)
    name = string.lower(name)
    return string.find(name, "rocket", 1, true) ~= nil
end

local function watchRockets(now, dt)
    rocketSeen = false
    if not state.phoenixCheck then lastNearestDist = nil; return end
    local ents = workspace:FindFirstChild("Effects")
    if not ents then lastNearestDist = nil; return end
    local me = headPosOf(Character) or (RootPart and RootPart.Position)
    if not me then return end

    -- Find the NEAREST rocket this frame (by name, in range). We do NOT key distance by the instance
    -- (`ch`): this game re-clones effects -- and the executor re-wraps instance refs -- every frame,
    -- so a per-instance table (rocketTrack[ch]) never matched across frames. `prev` was ALWAYS nil,
    -- the closing speed was never computed, and Phoenix never parried. Tracking ONE global nearest
    -- distance frame-to-frame is identity-free, so it works through the churn.
    local nearestDist, nearestPos = nil, nil
    for _, ch in ipairs(ents:GetChildren()) do
        if isRocketName(ch.Name) then
            local p = effectPos(ch)
            if p then
                local dist = (p - me).Magnitude
                if dist < PROJ_MAX_RANGE and (not nearestDist or dist < nearestDist) then
                    nearestDist, nearestPos = dist, p
                end
            end
        end
    end

    local prev = lastNearestDist
    lastNearestDist = nearestDist            -- nil when no rocket -> delta resets when one next appears
    if not nearestDist then return end

    -- Closing speed of the nearest rocket. The jump guard drops a frame where "nearest" switched to a
    -- DIFFERENT rocket (e.g. our own outgoing vs the incoming one): a real rocket can't travel ~40+
    -- studs in one frame, so a larger delta is an instance swap, not motion -- ignore it that frame.
    local closing = 0
    if prev and dt and dt > 1e-4 then
        local delta = prev - nearestDist
        if math.abs(delta) < 40 then closing = delta / dt end
    end
    if closing <= 5 then return end          -- not approaching (our own outgoing recedes / stationary)

    rocketSeen = true                        -- a rocket is inbound: hold the lock (guards the arc press)
    local tti = (closing > 1) and (nearestDist / closing) or math.huge
    if (now - lastParry) >= state.cooldown
        and (nearestDist <= state.phoenixRadius or tti <= state.phoenixLead) then
        if state.autoFace then faceTowardPos(nearestPos) end   -- ~= the shooter's yaw
        if tapParry() then
            lastParry = now
        end
    end
end

-- ── Track ShooterIndicator clones in PlayerGui ────────────────────────────────
-- shots[indicatorInstance] = { t0=, maxS=, curS=, lastAngle=, shooter=, gun=, handled= }
-- POLLED, not event-driven: some executors return nil for DescendantAdded on the
-- cloneref'd PlayerGui (-> "attempt to index nil with 'Connect'"). Indicators are
-- direct children of the "GameplayUI" ScreenGui (confirmed in the dump), so a
-- cheap per-frame scan is just as timely and works everywhere.
local shots = {}
local gameplayUI

local function findGameplayUI()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return nil end
    if gameplayUI and gameplayUI.Parent == pg then return gameplayUI end
    gameplayUI = pg:FindFirstChild("GameplayUI")
    if gameplayUI then return gameplayUI end
    -- fallback: locate it via any existing indicator, else any ScreenGui holding one
    for _, sg in ipairs(pg:GetChildren()) do
        if sg:FindFirstChild("ShooterIndicator") then
            gameplayUI = sg
            return gameplayUI
        end
    end
    return nil
end

local function scanIndicators(now)
    local gui = findGameplayUI()
    if not gui then return end
    for _, d in ipairs(gui:GetChildren()) do
        if d.Name == "ShooterIndicator" and not shots[d] then
            -- t0 = the SAME `now` step() is using, so a fresh indicator's elapsed is
            -- exactly 0 on its first frame (not negative -- scanIndicators runs after
            -- now was captured, so tick() here would be slightly > now).
            shots[d] = { t0 = now, maxS = 0, handled = false }
        end
    end
end

-- ── Main loop ─────────────────────────────────────────────────────────────────
local running = true

local function activeNow()
    return state.enabled
end

-- The fire decision lives inline in step() now: this game RE-CLONES the ShooterIndicator
-- every frame so per-instance draw timers are useless (every clone is newborn). The only
-- live signal is the ARC value s = parry_range*alpha, rising 0 -> sMax with the SHOT at
-- s == sMax. Rather than wait for s to reach ~90% (a thin lead the loop overruns under
-- load), step() measures the arc's rise SPEED and predicts the instant s will hit sMax,
-- then presses a fixed lead ahead of it -- see the prediction block below.

local function step(dt)
    local now = tick()
    runPending(now)    -- flush deferred key releases etc. even while disabled (no stuck keys)

    if not running or not activeNow() or not isAlive() then return end

    scanIndicators(now)   -- pick up any new ShooterIndicator clones (polled, no events)

    -- Phoenix: parry the live rocket at impact (sets rocketSeen for the guard below).
    watchRockets(now, dt)

    -- Read each tracked clone's arc (CHEAP now) and pick the LEADING shot = the highest VALID
    -- arc value (s < 0.85; >=0.85 is the fresh-clone template spike at rotation 180). All clones
    -- of one shot share the live arc, so the max valid s IS this frame's draw progress. NO
    -- shooter/gun work in this loop -- doing it per clone was O(clones x candidates) per frame
    -- and is what crushed the loop to ~12Hz mid-draw (then it under-sampled the arc peak and
    -- missed). It's done once below, only for the leading clone.
    local lead_st, lead_s = nil, -1
    for inst, st in pairs(shots) do
        if typeof(inst) ~= "Instance" or inst.Parent == nil then
            calibrateDraw(st.gun, now - st.t0)    -- lifetime ~= draw_time
            calibrateArc(st.gun, st.maxS)         -- terminal arc value ~= parry_range
            shots[inst] = nil
        else
            local ok, s = pcall(readArc, st, inst)   -- one cached memory_read; no per-clone angle/shooter
            if ok and s ~= nil then
                st.curS = s
                if s > st.maxS then st.maxS = s end
                st.noArc = nil
            elseif st.maxS <= 0 and (now - st.t0) > 0.15 then
                st.noArc = true                   -- arc never readable -> fixed delay
            end
            local cs = st.curS
            if cs and cs < 0.85 and cs > lead_s then
                lead_s, lead_st = cs, st
            end
        end
    end

    -- Resolve shooter + gun for the LEADING clone ONLY (once per frame). Facing/gun don't
    -- gate clone selection, so this is all the resolution we ever need per frame.
    local gun = nil
    if lead_st then
        if lead_st.shooter == nil then
            local ang = readAngle(lead_st)          -- leader-only 2nd read, only until resolved
            if ang then lead_st.lastAngle = ang end
        end
        pcall(function()
            if lead_st.shooter == nil and lead_st.lastAngle then
                lead_st.shooter = findShooter(lead_st.lastAngle)
            end
            if state.autoGun and lead_st.shooter and lead_st.gun == nil then
                lead_st.gun = gunOf(lead_st.shooter) or false   -- false = resolved-but-none
            end
        end)
        gun = resolveGun(lead_st)
        if typeof(lead_st.shooter) == "Instance" then gLastShooter = lead_st.shooter end
        -- Seed the adaptive terminal IMMEDIATELY from the gun we're actually timing with -- the
        -- DETECTED gun OR the configured default (resolveGun) -- so it never cold-starts from the
        -- 0.15 seed and warms up (that warmup was the press-drifts-late bug). Re-seed only on a
        -- gun change. After the seed, the SHOTEND EMA tracks each shot's REAL peak, including the
        -- slight decline across a burst, which keeps the press at a CONSTANT arc fraction (alpha)
        -- on every shot -- so the LAST, lowest-peak shot is timed exactly like the first.
        if gun and gun ~= seededGun then
            sTermEst  = sMaxFor(gun)
            seededGun = gun
        end
    end

    -- PRE-AIM for a BEHIND/off-screen shooter: a mouse turn can't cover 180 in one nudge, so start
    -- turning toward them NOW (every frame) so the camera is on target by the press. Only when the
    -- shooter is OFF screen -- an on-screen shooter is left to the press-time face, so a normal
    -- front-on fight isn't dragged around continuously. (No-op unless mouse aiming is available.)
    if state.autoFace and type(mousemoveabs) == "function" and type(WorldToScreen) == "function" then
        local sh = (lead_st and typeof(lead_st.shooter) == "Instance" and lead_st.shooter) or gLastShooter
        if typeof(sh) == "Instance" then
            local hp = headPosOf(sh)
            if hp then
                local ok, _, onScreen = pcall(WorldToScreen, hp)
                if ok and not onScreen then faceTowardPos(hp) end
            end
        end
    end

    -- ── Fire decision: press at a CONSISTENT arc FRACTION, every shot ─────────────────
    -- Shot lands at arc == the terminal (parry_range). We press at floor = arcAlpha*sTerm.
    -- sTerm is the adaptive terminal sTermEst -- now SEEDED immediately (above) so it never warms
    -- up, and it TRACKS each shot's real peak. That matters because the peak DECLINES across a
    -- burst (0.300->0.270 in the logs); a fixed terminal would keep the floor at a constant arc
    -- VALUE, so the press fraction would creep later as the peak shrank (the last shot landed at
    -- alpha 0.78 vs 0.70 on the first -> the late "last shot not parried"). Tracking the peak keeps
    -- floor/peak constant, so every shot -- including the last, lowest one -- presses at the same
    -- alpha. The velocity predictor can fire EARLIER for a short shot, but never later.
    local fire, fireShooter = false, nil
    if lead_st and lead_s > 0 then
        if lead_s > shotPeak then shotPeak = lead_s end          -- track this shot's peak
        local sTerm = sTermEst
        local v = 0
        if gArcT > 0 then
            local d = now - gArcT
            if d > 1e-4 then v = (lead_s - gArcS) / d end         -- arc units per second (rising)
        end
        -- SMOOTHED arc speed: per-frame v is jittery (arc-read noise), but within one shot the true
        -- rise speed is ~constant, so an EMA settles to it in a few frames -- a reliable basis for
        -- the time-to-shot below. A single noisy v must not mis-time the press.
        if v > 1e-4 then gVel = (gVel > 1e-4) and (gVel + 0.30 * (v - gVel)) or v end
        local vEff = (gVel > 1e-4) and gVel or v
        local tti = math.huge
        if vEff > 1e-4 and lead_s < sTerm then tti = (sTerm - lead_s) / vEff end
        -- FLOOR = press at a consistent arc fraction, BUT capped so we never press too early: over a
        -- long burst the draw lengthens (v falls), and at a fixed arc fraction that makes the press
        -- land ever-further before the shot until the ~0.5s window expires pre-shot. So hold the
        -- floor until the shot is within MAX_LEAD seconds. At normal v the floor's natural lead is
        -- already < MAX_LEAD, so this is a no-op; it only pulls the press LATER once the draw is long.
        -- `lateArc` is a hard backstop: never wait past ~alpha 0.85, so a bad (under-read) vEff can't
        -- delay the press too far. v unreadable -> fire on the arc fraction alone.
        local floorReady = (lead_s >= arcAlphaFor(gun) * sTerm)
        local lateArc    = (lead_s >= 0.85 * sTerm)
        local floorHit   = lateArc or (floorReady and (vEff <= 1e-4 or tti <= MAX_LEAD))
        -- predictor: fires EARLIER for a short shot, but only once we're past the arc's first half
        -- so a noisy velocity spike can't trigger a premature press way down the arc.
        local predicted  = (tti <= leadFor(gun)) and (lead_s >= 0.45 * sTerm)
        if predicted or floorHit then
            fire, fireShooter = true, lead_st.shooter
        end
        gArcS, gArcT = lead_s, now
    else
        gArcS, gArcT = 0, now              -- no shot in progress -> reset the velocity envelope
        gVel = 0                           -- reset smoothed speed between shots
    end

    -- RE-ARM the latch as soon as the arc falls out of FIRE RANGE (below the floor) -- the shot we
    -- parried has resolved. Re-arming on the floor (not full collapse to <0.03) is what catches
    -- OVERLAPPING shots in a fast/accelerating burst: the next shot's indicator appears before the
    -- previous one's arc collapses, so the arc dips below the floor between them WITHOUT ever
    -- reaching 0 -- the old `lead_s < 0.03` re-arm then never fired, the latch stayed stuck, and the
    -- last overlapping shot got no press (the "doesn't parry the last shot" bug; logs showed
    -- shots=47..50 latched=true for ~2s with no re-arm). Still safe against double-pressing ONE
    -- shot: its arc PLATEAUS at the peak, well above the floor, so this never trips mid-shot. The
    -- 0.15s refractory guards against a post-press arc-read dropout dipping below the floor.
    -- Siege is EXCLUDED (its long sMax plateau + the scheduled siegeDouble would over-parry); it
    -- keeps the full-collapse re-arm below.
    local meta = gun and profileMeta[gun] or nil
    if parryLatched and not (meta and meta.doubleParry)
        and lead_s < (arcAlphaFor(gun) * sTermEst) and (now - lastParry) > 0.15 then
        parryLatched = false
    end

    -- Shot fully ended (arc collapsed to ~0): LEARN its terminal into sTermEst (fast EMA, converges
    -- in a shot or two), reset the per-shot peak tracker, and re-arm (covers Siege + the clean,
    -- non-overlapping case). 0.15s refractory as above.
    if lead_s < 0.03 then
        if shotPeak > 0.05 then
            sTermEst = clampN(sTermEst + 0.5 * (shotPeak - sTermEst), 0.08, 0.40)
            shotPeak = 0
        end
        if (now - lastParry) > 0.15 then parryLatched = false end
    end

    -- Phoenix (projectile): parried at rocket impact by watchRockets, not on its arc.
    if fire and gun then
        local meta = profileMeta[gun]
        if meta and meta.projectile and state.phoenixCheck then fire = false end
    end
    -- LOS gate (off by default): don't fire at a shooter we have no clear line to.
    if fire and state.losCheck and fireShooter and not hasLOS(fireShooter) then fire = false end

    if fire and not rocketSeen and not parryLatched and (now - lastParry) >= state.cooldown then
        local faceModel = fireShooter or gLastShooter      -- fall back to last-known shooter for facing
        if state.autoFace and faceModel then faceShooter(faceModel) end
        if tapParry() then
            lastParry    = now
            parryLatched = true     -- one press per shot; re-arms when the arc collapses
            -- Siege fires 2 shots per draw; the parry resolves one per press, so schedule
            -- a second tap to catch the follow-up shot.
            local meta = gun and profileMeta[gun] or nil
            if meta and meta.doubleParry and state.siegeDouble then
                local sh = fireShooter or gLastShooter
                schedule(state.siegeDelay, function()
                    if not running or not activeNow() then return end
                    if state.autoFace and sh then faceShooter(sh) end
                    tapParry()
                end)
            end
        end
    end
end

-- ── Lifecycle / reload guard ──────────────────────────────────────────────────
local function stop()
    running = false                      -- the loop below sees this and exits
    flushPending()                       -- release any held key so it can't stick
    lastNearestDist = nil
end
if _G.AutoParryStop then pcall(_G.AutoParryStop) end   -- kill a previous instance on reload
_G.AutoParryStop = stop

-- Drive the loop with a plain task.spawn + task.wait frame loop (no RunService
-- event access needed in this low-runtime executor). TWO things are required for
-- the timing to actually work in this Matcha runtime:
--   1) Yield a REAL interval: task.wait(LOOP_DT), NOT a bare task.wait(). A bare
--      task.wait() does not wait a real frame here -- it returns almost instantly,
--      so the loop busy-spins, starves the engine, and the indicator arc never
--      animates. A real ~0.01s yield (the interval the working a.lua loop uses)
--      lets the engine step. ~100 Hz is plenty for the ~0.5s parry window.
--   2) Measure time with tick(), NOT os.clock(). Here os.clock() is CPU/processor
--      time: once the loop sleeps via task.wait() the thread is idle ~99% of the
--      time, so os.clock() crawls (~0.07 per real second) and the draw timer
--      (elapsed >= draw - lead ~0.5s) never matures -> never parries. tick() is the
--      real wall clock in this runtime (a.lua uses tick() with 0.15s cooldowns and
--      works). task.wait() returns nothing here, so we derive dt from tick() deltas
--      ourselves (the Phoenix closing-speed math needs real dt).
local LOOP_DT = 0.01
task.spawn(function()
    local last = tick()
    local lastResolve = last
    while running do
        task.wait(LOOP_DT)
        local now = tick()
        local dt = now - last
        last = now
        if now - lastResolve >= 1.0 then    -- once/sec: refresh camera pointer (heals a stale ptr after respawn)
            lastResolve = now
            pcall(ResolveCameraPtr)
        end
        if dt > 0.1 then dt = 0.1 end       -- clamp hitches (window stall) so speeds don't spike
        local okStep = pcall(step, dt)
        if not okStep then task.wait(0.1); last = tick() end
    end
end)

-- ── UI tab (matches the existing Redliner menu style) ─────────────────────────
local hasUI = (UI ~= nil and type(UI.AddTab) == "function")
if hasUI then
    UI.AddTab("Auto Parry (by larina :P)", function(tab)
        local sec = tab:Section("Auto Parry", "Left")

        sec:Toggle("ap_enabled", "Enabled", state.enabled, function(v) state.enabled = v end)
        state.enabled = UI.GetValue("ap_enabled")

        sec:Toggle("ap_autoface", "Auto-Face Shooter", state.autoFace, function(v) state.autoFace = v end)
        state.autoFace = UI.GetValue("ap_autoface")

        sec:Toggle("ap_los", "LOS Check", state.losCheck, function(v) state.losCheck = v end)
        state.losCheck = UI.GetValue("ap_los")

        sec:Toggle("ap_autogun", "Auto-Detect Gun", state.autoGun, function(v) state.autoGun = v end)
        state.autoGun = UI.GetValue("ap_autogun")

        -- Fallback profile when the gun can't be detected (1Gen 2Cas 3Phx 4Sie 5Mon).
        sec:SliderFloat("ap_defgun", "Default Gun | 1Gen / 2Cas / 3Phx / 4Sie / 5Mon", 1, 5, gunIndex(state.defaultGun), "%.0f",
            function(v) state.defaultGun = DEFAULT_GUNS[math.clamp(math.floor(v + 0.5), 1, 5)] end)
        state.defaultGun = DEFAULT_GUNS[math.clamp(math.floor(UI.GetValue("ap_defgun") + 0.5), 1, 5)]

        sec:Toggle("ap_calibrate", "Auto-Calibrate", state.calibrate, function(v) state.calibrate = v end)
        state.calibrate = UI.GetValue("ap_calibrate")

        sec:SliderFloat("ap_lead", "Parry Lead (s)", 0.00, 0.40, state.parryLead, "%.2f", function(v) state.parryLead = v end)
        state.parryLead = UI.GetValue("ap_lead")

        sec:SliderFloat("ap_fbdelay", "Fallback Delay (s)", 0.00, 1.00, state.fallbackDelay, "%.2f", function(v) state.fallbackDelay = v end)
        state.fallbackDelay = UI.GetValue("ap_fbdelay")

        sec:SliderFloat("ap_cd", "Cooldown (s)", 0.00, 1.50, state.cooldown, "%.2f", function(v) state.cooldown = v end)
        state.cooldown = UI.GetValue("ap_cd")

        -- ── Per-gun tuning ────────────────────────────────────────────────────
        local g = tab:Section("Per-Gun", "Right")

        -- Monarch: very long draw (1.85s). Lower lead = press later = "less early".
        g:SliderFloat("ap_mon_draw", "Monarch Draw (s)", 0.50, 2.40, drawByGun.Monarch, "%.2f", function(v) drawByGun.Monarch = v end)
        drawByGun.Monarch = UI.GetValue("ap_mon_draw")
        g:SliderFloat("ap_mon_lead", "Monarch Lead (s)", 0.00, 0.30, leadByGun.Monarch, "%.2f", function(v) leadByGun.Monarch = v end)
        leadByGun.Monarch = UI.GetValue("ap_mon_lead")

        -- Siege: 2 shots per draw -> double parry.
        g:SliderFloat("ap_siege_draw", "Siege Draw (s)", 0.50, 2.00, drawByGun.Siege, "%.2f", function(v) drawByGun.Siege = v end)
        drawByGun.Siege = UI.GetValue("ap_siege_draw")
        g:Toggle("ap_siege_double", "Siege Double Parry", state.siegeDouble, function(v) state.siegeDouble = v end)
        state.siegeDouble = UI.GetValue("ap_siege_double")
        g:SliderFloat("ap_siege_delay", "Siege 2nd Parry (s)", 0.05, 0.50, state.siegeDelay, "%.2f", function(v) state.siegeDelay = v end)
        state.siegeDelay = UI.GetValue("ap_siege_delay")

        -- Phoenix: travelling rocket -> parry at impact.
        g:Toggle("ap_phx_check", "Phoenix Projectile Check", state.phoenixCheck, function(v) state.phoenixCheck = v end)
        state.phoenixCheck = UI.GetValue("ap_phx_check")
        g:SliderFloat("ap_phx_lead", "Phoenix Impact Lead (s)", 0.00, 0.30, state.phoenixLead, "%.2f", function(v) state.phoenixLead = v end)
        state.phoenixLead = UI.GetValue("ap_phx_lead")
        g:SliderFloat("ap_phx_radius", "Phoenix Impact Radius", 5, 80, state.phoenixRadius, "%.0f", function(v) state.phoenixRadius = v end)
        state.phoenixRadius = UI.GetValue("ap_phx_radius")
    end)

    if type(notify) == "function" then
        notify("Auto Parry Loaded", "Per-gun timing. Toggle it in the Auto Parry tab", 5)
    end
else
    state.enabled = true
    if type(notify) == "function" then
        notify("Auto Parry Loaded", "No UI found - running enabled by default", 5)
    end
end
