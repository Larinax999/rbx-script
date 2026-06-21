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
local RunService       = game:GetService("RunService")

local LocalPlayer = (cloneref and cloneref(Players.LocalPlayer)) or Players.LocalPlayer

-- ── Tunables (defaults; overridden by the UI below if present) ────────────────
local state = {
    enabled       = false, -- master on/off
    autoFace      = true,  -- yaw camera toward the incoming shooter at parry time
    losCheck      = true,  -- only parry a shooter that currently has line of sight
    calibrate     = false, -- auto-tune per-gun draw / sMax from observed shots
    autoGun       = true,  -- identify each shooter's gun and use its profile
    defaultGun    = "Castigate", -- profile used when the gun can't be detected (or Auto-Detect Gun is off); "Generic" = the old single-timer behaviour
    parryLead     = 0.05,  -- default press-ahead (s) for guns without an override
    fallbackDelay = 0.32,  -- if the arc can't be read: press this long after the indicator appears
    cooldown      = 0.0,   -- min seconds between two parries (0 = rely on the game's own lock)

    -- Siege: 2 shots per draw -> fire a second parry this long after the first.
    siegeDouble   = true,
    siegeDelay    = 0.50,

    -- Phoenix: travelling rocket -> parry at impact, not draw-end.
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
    return Character ~= nil and RootPart ~= nil
        and (Humanoid == nil or Humanoid.Health > 0)
end

-- ── Parry trigger: tap F through the real input path (non-yielding) ───────────
local VIM = nil
pcall(function() VIM = game:GetService("VirtualInputManager") end)
local HOLD = 0.03 -- key down-time for the tap (seconds)

local function tapParry()
    if type(keypress) == "function" and type(keyrelease) == "function" then
        if pcall(keypress, PARRY_VK) then
            task.delay(HOLD, function() pcall(keyrelease, PARRY_VK) end)
            return true
        end
    end
    if type(keytap) == "function" then
        if pcall(keytap, PARRY_VK) then return true end
    end
    if VIM then
        local ok = pcall(function() VIM:SendKeyEvent(true, Enum.KeyCode.F, false, game) end)
        if ok then
            task.delay(HOLD, function()
                pcall(function() VIM:SendKeyEvent(false, Enum.KeyCode.F, false, game) end)
            end)
            return true
        end
    end
    return false
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
    local cam = workspace.CurrentCamera
    if not cam then return nil end
    local look = (cam.CFrame.LookVector * FLAT)
    if look.Magnitude < 1e-4 then return nil end
    look = look.Unit
    local v = (cam.CFrame.Position * FLAT) - (headPos * FLAT)
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

-- Yaw the camera toward a world position (pitch preserved; the game only checks
-- the horizontal facing). World-position based, so it's always the correct way round.
local function faceTowardPos(target)
    local cam = workspace.CurrentCamera
    if not cam or not target then return end
    local camPos = cam.CFrame.Position
    local flat   = (target - camPos) * FLAT
    if flat.Magnitude < 1e-3 then return end
    flat = flat.Unit
    local curY = cam.CFrame.LookVector.Y
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
local leadByGun = {                 -- guns absent here fall back to state.parryLead
    Monarch = 0.05, Siege = 0.05, Phoenix = 0.05,
}
local arcAlphaByGun = {
    Castigate = 0.90, Phoenix = 0.90, Siege = 0.92, Monarch = 0.94, __default = 0.90,
}
local sMaxByGun = {                       -- per-gun terminal arc (== parry_range), refined by calibration
    Castigate = 0.30, Phoenix = 0.30, Siege = 0.30, Monarch = 0.30, BaseGun = 0.30,
    __default = 0.30,
}

local profileMeta = {                    -- non-timing behaviour flags
    Siege   = { doubleParry = true },
    Phoenix = { projectile  = true },
}

local CAL_K        = 0.30     -- EMA weight
local ARC_SETTLE   = 0.06     -- ignore arc readings this soon after clone (template frames)
local ARC_MIN_FRAC = 0.40     -- only allow the arc refine after this fraction of draw has elapsed

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

-- returns: s (progress), shooterAngle (deg) | nil if the arc isn't readable
local function readArc(ind)
    local pr = ind:FindFirstChild("ParryRange")
    if not pr then return nil end
    local lc   = pr:FindFirstChild("LeftClip")
    local left = lc and lc:FindFirstChild("Left")
    local grad = left and left:FindFirstChild("UIGradient")
    if not grad then return nil end
    local r = grad.Rotation
    local s = sFromRotation(r)
     print(r,pr.Rotation)
    local shooterAngle = pr.Rotation + r / 2  -- == game's getRotation(shooter)
    return s, shooterAngle
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
local rocketTrack = {}    -- rocketInstance -> last distance to us
local rocketSeen  = false -- a rocket is currently in flight toward us (lock guard)
local lastParry   = 0     -- forward declare (used by the watcher)

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
    if not state.phoenixCheck then return end
    local ents = workspace:FindFirstChild("Effects")
    if not ents then return end
    local me = headPosOf(Character) or (RootPart and RootPart.Position)
    if not me then return end

    local bestDist, bestTTI, bestPos = nil, math.huge, nil
    local present = {}
    for _, ch in ipairs(ents:GetChildren()) do
        if isRocketName(ch.Name) then
            local p = effectPos(ch)
            if p then
                present[ch] = true
                local dist = (p - me).Magnitude
                local prev = rocketTrack[ch]
                rocketTrack[ch] = dist
                if prev and dt and dt > 1e-4 then
                    local closing = (prev - dist) / dt          -- studs/s toward us
                    if closing > 5 and dist < PROJ_MAX_RANGE then   -- incoming, not our own outgoing
                        rocketSeen = true
                        local tti = (closing > 1) and (dist / closing) or math.huge
                        if not bestDist or dist < bestDist then
                            bestDist, bestTTI, bestPos = dist, tti, p
                        end
                    end
                end
            end
        end
    end
    for inst in pairs(rocketTrack) do
        if not present[inst] then rocketTrack[inst] = nil end
    end

    if bestDist and (now - lastParry) >= state.cooldown then
        if bestDist <= state.phoenixRadius or bestTTI <= state.phoenixLead then
            if state.autoFace then faceTowardPos(bestPos) end   -- ~= the shooter's yaw
            if tapParry() then lastParry = now end
        end
    end
end

-- ── Track ShooterIndicator clones in PlayerGui ────────────────────────────────
-- shots[indicatorInstance] = { t0=, maxS=, curS=, lastAngle=, shooter=, gun=, handled= }
local shots = {}
local guiConn

local function watchGui()
    if guiConn then guiConn:Disconnect() guiConn = nil end
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return end
    guiConn = pg.DescendantAdded:Connect(function(inst)
        if inst.Name == "ShooterIndicator" then
            shots[inst] = { t0 = os.clock(), maxS = 0, handled = false }
        end
    end)
    for _, d in ipairs(pg:GetDescendants()) do
        if d.Name == "ShooterIndicator" and not shots[d] then
            shots[d] = { t0 = os.clock(), maxS = 0, handled = false }
        end
    end
end

-- ── Main loop ─────────────────────────────────────────────────────────────────
local running = true
local hbConn

local function activeNow()
    if state.enabled then return true end
    if state.holdKb then
        local ok, held = pcall(function() return state.holdKb:IsEnabled() end)
        if ok and held then return true end
    end
    return false
end

-- Should we press now for this indicator? Per-gun draw + arc refine.
--   PRIMARY (draw-time): elapsed >= draw - lead. Guaranteed to fire each shot.
--   REFINE  (arc):       fires earlier for shots shorter than the draw estimate,
--                        when the arc says the shot is imminent. Bounded so a bad
--                        sMax can't fire absurdly early, and it can never *block*
--                        a parry (the draw-time trigger still applies).
local function shouldFire(st, now, gun)
    local elapsed = now - st.t0
    if elapsed < 0.03 then return false, elapsed end
    if st.noArc then
        return elapsed >= state.fallbackDelay, elapsed
    end
    local draw = drawFor(gun)
    local lead = leadFor(gun)
    if elapsed >= (draw - lead) then
        return true, elapsed                      -- primary: guaranteed trigger
    end
    local s = st.curS
    if s and s > 1e-3 and elapsed >= ARC_MIN_FRAC * draw then
        if (s / sMaxFor(gun)) >= arcAlphaFor(gun) then
            return true, elapsed                  -- refine: arc says shot is near
        end
    end
    return false, elapsed
end

local function step(dt)
    if not running or not activeNow() or not isAlive() then return end
    local now = os.clock()

    -- Phoenix: parry the live rocket at impact (sets rocketSeen for the guard below).
    watchRockets(now, dt)

    local fireSt, fireElapsed, fireShooter, fireGun = nil, -1, nil, nil
    for inst, st in pairs(shots) do
        if typeof(inst) ~= "Instance" or inst.Parent == nil then
            calibrateDraw(st.gun, now - st.t0)    -- lifetime ~= draw_time
            calibrateArc(st.gun, st.maxS)         -- terminal arc value ~= parry_range
            shots[inst] = nil
        else
            -- trust the arc only after the template frames have been overwritten
            if (now - st.t0) >= ARC_SETTLE then
                local ok, s, ang = pcall(readArc, inst)
                if ok and s ~= nil then
                    st.curS = s
                    if s > st.maxS then st.maxS = s end
                    if ang then st.lastAngle = ang end
                    st.noArc = nil
                elseif st.maxS <= 0 and (now - st.t0) > 0.15 then
                    st.noArc = true               -- arc never readable -> fixed delay
                end
            end

            -- resolve shooter + gun once we have the implied angle
            if not st.shooter and st.lastAngle then
                st.shooter = findShooter(st.lastAngle)
            end
            if state.autoGun and st.shooter and st.gun == nil then
                st.gun = gunOf(st.shooter) or false   -- false = resolved-but-none, don't re-scan
            end
            local gun = resolveGun(st)                 -- detected gun, else the configured default

            if not st.handled then
                local due, elapsed = shouldFire(st, now, gun)
                if due then
                    local meta = (gun and profileMeta[gun]) or nil
                    if meta and meta.projectile and state.phoenixCheck then
                        -- Phoenix: suppress the draw-end press -- watchRockets()
                        -- parries the actual rocket at impact instead.
                        st.handled = true
                    elseif elapsed > fireElapsed then
                        -- normal hitscan parry; gate on real-time LOS
                        local shooter = st.shooter
                        if (not state.losCheck) or (not shooter) or hasLOS(shooter) then
                            fireElapsed = elapsed
                            fireSt      = st
                            fireShooter = shooter
                            fireGun     = gun
                        end
                    end
                end
            end
        end
    end

    -- A rocket in flight owns the parry window (watchRockets handles it); don't
    -- waste it on a draw-end press for a possibly-misdetected Phoenix shooter.
    if fireSt and not rocketSeen and (now - lastParry) >= state.cooldown then
        if state.autoFace and fireShooter then faceShooter(fireShooter) end
        if tapParry() then
            lastParry = now
            fireSt.handled = true
            -- Siege fires 2 shots per draw; the parry system resolves one per
            -- press, so schedule a second tap to catch the follow-up shot.
            local meta = (fireGun and profileMeta[fireGun]) or nil
            if meta and meta.doubleParry and state.siegeDouble then
                local sh = fireShooter
                task.delay(state.siegeDelay, function()
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
    running = false
    if hbConn then hbConn:Disconnect() hbConn = nil end
    if guiConn then guiConn:Disconnect() guiConn = nil end
    rocketTrack = {}
end
if _G.AutoParryStop then pcall(_G.AutoParryStop) end
_G.AutoParryStop = stop

watchGui()
task.spawn(function()
    while running do
        task.wait(2)
        if not guiConn or guiConn.Connected == false then watchGui() end
    end
end)
hbConn = RunService.Heartbeat:Connect(step)

-- ── UI tab (matches the existing Redliner menu style) ─────────────────────────
local hasUI = (UI ~= nil and type(UI.AddTab) == "function")
if hasUI then
    UI.AddTab("Auto Parry (by larina :P)", function(tab)
        local sec = tab:Section("Auto Parry", "Left")

        sec:Toggle("ap_enabled", "Enabled", state.enabled, function(v) state.enabled = v end)
        state.enabled = UI.GetValue("ap_enabled")

        state.holdKb = sec:Keybind("ap_hold_kb", 0x06, "hold") -- optional hold-to-parry (X2 mouse)

        sec:Toggle("ap_autoface", "Auto-Face Shooter", state.autoFace, function(v) state.autoFace = v end)
        state.autoFace = UI.GetValue("ap_autoface")

        sec:Toggle("ap_los", "LOS Check", state.losCheck, function(v) state.losCheck = v end)
        state.losCheck = UI.GetValue("ap_los")

        sec:Toggle("ap_autogun", "Auto-Detect Gun", state.autoGun, function(v) state.autoGun = v end)
        state.autoGun = UI.GetValue("ap_autogun")

        -- Fallback profile when the gun can't be detected (1Gen 2Cas 3Phx 4Sie 5Mon).
        sec:SliderFloat("ap_defgun", "Default Gun 1Gen2Cas3Phx4Sie5Mon", 1, 5, gunIndex(state.defaultGun), "%.0f",
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
