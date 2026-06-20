loadstring(game:HttpGet("https://raw.githubusercontent.com/Larinax999/rbx-script/refs/heads/main/redline/bullet_hud.lua"))()
local LocalPlayer = game:GetService("Players").LocalPlayer

-- Event-free cache: instead of relying on CharacterAdded/CharacterRemoving
-- (not available in every executor environment), we lazily revalidate the
-- cached references against the live LocalPlayer.Character on access. The
-- expensive part (FindFirstChild) only runs when the character actually
-- changed (respawn/reset) or the root part isn't resolved yet.
local Character = nil
local RootPart = nil

local function GetCharacter()
    local char = LocalPlayer.Character
    if char ~= Character then
        -- Respawn / reset / death: the Character instance changed (or went nil).
        Character = char
        RootPart = char and char:FindFirstChild("HumanoidRootPart") or nil
    end
    return Character
end

local function GetPlayerRootPart()
    GetCharacter() -- keep Character/RootPart in sync with the live character
    -- Re-resolve only if the root part was never found yet, or was removed while
    -- the Character instance stayed the same (cheap parent check, no lookup
    -- unless it's actually stale).
    if Character and (RootPart == nil or RootPart.Parent == nil) then
        RootPart = Character:FindFirstChild("HumanoidRootPart")
    end
    return RootPart
end
GetPlayerRootPart()
-- if true then return end

-- ─── External memory reading via Matcha's getbase / memory_read ──────────────────
-- Pulls the camera's LookVector straight from process memory instead of going
-- through workspace.CurrentCamera.CFrame each frame.
--
-- API used:
--   getbase()                          -> int     base of RobloxPlayerBeta.exe
--   memory_read("uintptr_t", addr)     -> int     64-bit pointer
--   memory_read("float",     addr)     -> number  (32-bit IEEE-754; see note)
--   httpget(url)                       -> string  (empty string on failure)
--   isfile/readfile/writefile          -> local disk cache for offsets
--
-- Offsets strategy:
--   1. Load from local cache file if present (no network call on startup).
--   2. Otherwise fetch from imtheo.lol and persist to the cache file.
--   3. If a cached resolve fails (Roblox version drifted since last save),
--      refetch from network once, retry, and overwrite the cache.
local VERSION_URL          = "https://offsets.imtheo.lol/roblox/version" -- idk who own this i found in discord
local OFFSETS_URL_TEMPLATE = "https://offsets.imtheo.lol/%s/offsets.json"
local CACHE_PATH           = "redliner_offsets_cache.json"

local OFFSETS = {}
local OFFSETS_LOADED        = false
local OFFSETS_FROM_CACHE    = false
local OFFSETS_REFETCH_TRIED = false  -- guard so we refetch at most once per session

-- Parse a raw JSON body into the 5 offsets we actually use. Returns nil if the
-- JSON is malformed or any required field is missing (treat as cache miss).
local function ParseOffsets(body)
    if not body or body == "" then return nil end
    local ok, decoded = pcall(function()
        return game:GetService("HttpService"):JSONDecode(body)
    end)
    if not ok or type(decoded) ~= "table" or type(decoded.Offsets) ~= "table" then
        return nil
    end
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

-- Fetch current Roblox version tag, then the offsets JSON for that version.
-- Returns the raw JSON body (or "" on failure) so the caller can both parse it
-- AND write the exact same bytes to the cache file.
local function FetchOffsetsBody()
    local version = httpget(VERSION_URL)
    if version == "" then return "" end
    return httpget(string.format(OFFSETS_URL_TEMPLATE, version))
end

local function ApplyOffsets(parsed, fromCache)
    OFFSETS = parsed
    OFFSETS_LOADED = true
    OFFSETS_FROM_CACHE = fromCache
end

-- Startup load: try cache, fall back to network.
do
    local cached = isfile(CACHE_PATH) and ParseOffsets(readfile(CACHE_PATH)) or nil
    if cached then
        ApplyOffsets(cached, true)
    else
        local body = FetchOffsetsBody()
        local parsed = ParseOffsets(body)
        if parsed then
            ApplyOffsets(parsed, false)
            pcall(writefile, CACHE_PATH, body)
        end
    end
end

local BASE = getbase()

local function ReadPtr(addr)
    if not addr or addr == 0 then return 0 end
    return memory_read("uintptr_t", addr) or 0
end

local function ReadFloat(addr)
    if not addr or addr == 0 then return 0 end
    return memory_read("float", addr) or 0
end

-- Cached camera pointer. Resolution is only 4 reads now (vs ~100 with the old
-- children-enumeration approach), so the background loop just re-resolves
-- unconditionally each second — no class-name check needed.
local CameraPtr = 0

local function ResolveCameraPtrOnce()
    CameraPtr = 0
    if not OFFSETS_LOADED then return 0 end
    local fdm = ReadPtr(BASE + OFFSETS.FakeDataModelPointer)
    if fdm == 0 then return 0 end
    local dm = ReadPtr(fdm + OFFSETS.FakeDataModelToDataModel)
    if dm == 0 then return 0 end
    local ws = ReadPtr(dm + OFFSETS.Workspace)
    if ws == 0 then return 0 end
    CameraPtr = ReadPtr(ws + OFFSETS.CurrentCamera)
    return CameraPtr
end

-- Resolve the camera pointer. If we were running on cached offsets and the
-- resolve failed (likely stale after a Roblox update), refetch from network
-- once per session, overwrite the cache, and retry.
local function ResolveCameraPtr()
    local r = ResolveCameraPtrOnce()
    if r == 0 and OFFSETS_FROM_CACHE and not OFFSETS_REFETCH_TRIED then
        OFFSETS_REFETCH_TRIED = true
        local body = FetchOffsetsBody()
        local parsed = ParseOffsets(body)
        if parsed then
            ApplyOffsets(parsed, false)
            pcall(writefile, CACHE_PATH, body)
            r = ResolveCameraPtrOnce()
        end
    end
    return r
end

-- Camera CFrame rotation: 3x3 row-major float matrix at CameraRotation. Columns
-- are Right, Up, Back; LookVector = -Back column = (-R02, -R12, -R22).
--
-- Precision note: each matrix entry is a 32-bit float in process memory (the
-- 36-byte gap between Camera.Rotation and Camera.Position confirms 9 * 4 bytes,
-- not 9 * 8). Reading as "double" would interpret 8 bytes as one double and
-- return garbage values, not higher precision. What we CAN do is renormalize
-- the Back-column components in double-precision Lua math so any unit-length
-- drift from the 32-bit storage is removed before we hand the vector off.
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

-- print(tostring(GetCameraLookVector()))
-- if true then return end

UI.AddTab("Redliner (by larina :P)", function(tab)
    local sec_speed = tab:Section("Speed (USE WITH CAUTION)", "Left")
    local speed_toggle = false
    local speed_target = 140.0  -- target horizontal speed in studs/sec
    local speed_accel  = 50.0  -- studs/sec^2 ramp toward the target (tune for "slowly")
    local speed_local = 0

    -- toggle
    sec_speed:Toggle("speed_toggle", "Enabled", false, function(state)
        speed_toggle=state
    end)
    speed_toggle=UI.GetValue("speed_toggle") -- :P
    local speed_kb = sec_speed:Keybind("speed_kb", 0x05, "hold") -- X1 mouse button
    speed_kb:AddToHotkey("speed", "speed_toggle")

    -- slider: absolute target speed (studs/sec), not a multiplier
    local speed_target_slider = sec_speed:SliderFloat("speed_target_slider", "Target Speed", 16.0, 200.0, 140.0, "%.1f", function(val)
        speed_target = val
    end)
    speed_target = UI.GetValue("speed_target_slider") -- :P

    local speed_accel_slider = sec_speed:SliderFloat("speed_accel_slider", "Acceleration Speed", 1.0, 200.0, 50.0, "%.1f", function(val)
        speed_accel = val
    end)
    speed_accel = UI.GetValue("speed_accel_slider") -- :P

    -- main script
    task.spawn(function()
        -- Track frame delta via os.clock(); task.wait() doesn't return elapsed
        -- time in this environment, so we measure it ourselves.
        local lastTime = os.clock()
        -- Script-side speed accumulator. nil = inactive; seeded from the live
        -- velocity on each activation so we ramp from current physics speed
        -- instead of fighting whatever the engine did to the velocity since
        -- our last write (collisions, walking input, gravity-applied drag, etc.).
        local speed_local = nil
        while true do
            task.wait()
            local now = os.clock()
            local dt = now - lastTime
            lastTime = now
            -- Clamp dt to guard against huge spikes (window stall / hitch) that
            -- would otherwise warp us straight to the target speed in one step.
            if dt > 0.1 then dt = 0.1 end
            local active = speed_kb:IsEnabled() and speed_toggle and RootPart ~= nil
            if not active then
                speed_local = nil  -- next activation will re-seed from live velocity
                continue
            end
            -- Camera LookVector read straight from process memory (no instance traversal).
            local look = GetCameraLookVector()
            if look == nil then continue end
            -- Horizontal projection so looking up/down doesn't launch us vertically.
            local dir = Vector3.new(look.X, 0, look.Z)
            if dir.Magnitude == 0 then continue end
            dir = dir.Unit
            local vel = RootPart.AssemblyLinearVelocity
            -- Seed once on activation so the ramp starts from where we actually are.
            if speed_local == nil then
                speed_local = Vector3.new(vel.X, 0, vel.Z).Magnitude
            end
            -- Accelerate the local accumulator toward speed_target at a fixed
            -- studs/sec^2. We deliberately ignore the live velocity magnitude here
            -- so external forces can't tug the ramp around.
            local maxChange = speed_accel * dt
            speed_local = speed_local + math.clamp(speed_target - speed_local, -maxChange, maxChange)
            -- Apply: redirect along look direction, preserve vertical for gravity/jumps.
            RootPart.AssemblyLinearVelocity = Vector3.new(dir.X * speed_local, vel.Y, dir.Z * speed_local)
        end
    end)
    task.spawn(function()
        while true do
            task.wait(1)
            GetPlayerRootPart()
            -- Re-resolve the camera pointer unconditionally. With the direct
            -- DataModel.Workspace / Workspace.CurrentCamera offsets this is
            -- only 4 reads, so it's cheaper than validating via class name.
            ResolveCameraPtr()
        end
    end)

    notify("Script Loaded","By larina",5)
end)
