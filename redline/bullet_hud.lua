-- Bullet / heat HUD (standalone)
-- Draws bullet boxes + count/percentage under the crosshair using the Drawing lib.
-- Reads game.Players.LocalPlayer.ReadOnly { heat, heat_max, heat_per_bullet }
--   total bullets     = floor(heat_max / heat_per_bullet)
--   available bullets = floor(heat / heat_per_bullet)        (filled boxes)
--   percentage        = (heat % heat_per_bullet) / heat_per_bullet * 100  (progress to next bullet)
-- Call _G.BulletHudStop() to remove it.

local pcall = pcall
local tick = tick
local ipairs = ipairs
local task_wait = task.wait
local task_spawn = task.spawn
local math_floor = math.floor
local string_format = string.format
local Vector2_new = Vector2.new
local Color3_fromRGB = Color3.fromRGB
local Drawing_new = Drawing.new

local CONFIG = {
    ENABLED = true,
    Y_OFFSET = 70,            -- pixels below screen center
    UPDATE_INTERVAL = 0.05,
    FONT_SIZE = 16,
    BOX_SIZE = 12,            -- bullet box square size (px)
    BOX_GAP = 4,             -- gap between bullet boxes (px)
    GAP = 8,                 -- gap between boxes and the count/percentage text (px)
    CHAR_WIDTH = 0.55,       -- approx char width as fraction of font size (used for centering)
    COLOR = Color3_fromRGB(255, 255, 255),
    COLOR_RED = Color3_fromRGB(255, 60, 60),     -- text 0-50%, spent bullet box
    COLOR_YELLOW = Color3_fromRGB(255, 210, 50), -- text 51-99%
    COLOR_GREEN = Color3_fromRGB(70, 230, 90),   -- text 100%, available bullet box
}

-- percentage text color: red (0-50), yellow (51-99), green (100)
local function pctColor(pct)
    if pct >= 100 then return CONFIG.COLOR_GREEN
    elseif pct >= 51 then return CONFIG.COLOR_YELLOW
    else return CONFIG.COLOR_RED end
end

local function getLocalPlayer()
    local ok, svc = pcall(function() return game:GetService("Players") end)
    if not ok or not svc then return nil end
    local ok2, lp = pcall(function() return svc.LocalPlayer end)
    return ok2 and lp or nil
end

local function getViewport()
    local ok, cam = pcall(function() return workspace.CurrentCamera end)
    if not ok or not cam then return nil end
    local ok2, vp = pcall(function() return cam.ViewportSize end)
    if not ok2 or not vp then return nil end
    return vp
end

local function readVal(inst)
    if not inst then return nil end
    local ok, v = pcall(function() return inst.Value end)
    if ok then return v end
    return nil
end

local HUD = {
    suffix = nil,
    boxes = {},
    built = false,
    valHeat = nil,
    valHeatMax = nil,
    valHeatPerBullet = nil,
    lastBuild = 0,
}

local function buildHudInfo()
    HUD.valHeat = nil
    HUD.valHeatMax = nil
    HUD.valHeatPerBullet = nil
    HUD.lastBuild = tick()
    local lp = getLocalPlayer()
    if not lp then return end
    local ok, ro = pcall(function() return lp:FindFirstChild("ReadOnly") end)
    if not ok or not ro then return end
    local okA, a = pcall(function() return ro:FindFirstChild("heat") end)
    if okA then HUD.valHeat = a end
    local okB, b = pcall(function() return ro:FindFirstChild("heat_max") end)
    if okB then HUD.valHeatMax = b end
    local okC, c = pcall(function() return ro:FindFirstChild("heat_per_bullet") end)
    if okC then HUD.valHeatPerBullet = c end
end

local function getHudInfo()
    if not HUD.valHeat or (tick() - HUD.lastBuild > 1) then
        buildHudInfo()
    end
    return readVal(HUD.valHeat), readVal(HUD.valHeatMax), readVal(HUD.valHeatPerBullet)
end

local function ensureHud()
    if HUD.built then return true end
    local okS, suffix = pcall(Drawing_new, "Text")
    if not okS or not suffix then return false end
    suffix.Size = CONFIG.FONT_SIZE
    pcall(function() suffix.Font = Drawing.Fonts.System end)
    suffix.Outline = true
    suffix.Center = false
    suffix.Color = CONFIG.COLOR
    suffix.Visible = false
    suffix.ZIndex = 5
    HUD.suffix = suffix
    HUD.built = true
    return true
end

local function getBox(i)
    local b = HUD.boxes[i]
    if b then return b end
    local ok, sq = pcall(Drawing_new, "Square")
    if not ok or not sq then return nil end
    sq.Filled = false
    sq.Color = CONFIG.COLOR
    sq.Visible = false
    sq.ZIndex = 5
    HUD.boxes[i] = sq
    return sq
end

local function hideHud()
    if HUD.suffix then HUD.suffix.Visible = false end
    for _, b in ipairs(HUD.boxes) do b.Visible = false end
end

local function estTextWidth(text)
    return #text * CONFIG.FONT_SIZE * CONFIG.CHAR_WIDTH
end

local function updateHud()
    if not CONFIG.ENABLED then hideHud() return end
    if not ensureHud() then return end
    local vp = getViewport()
    if not vp then hideHud() return end
    local heat, heatMax, hpb = getHudInfo()
    if not heat or not heatMax or not hpb or hpb <= 0 then hideHud() return end

    local maxBullet = math_floor(heatMax / hpb + 1e-4) -- total bullets
    local bullet = math_floor(heat / hpb + 1e-4)        -- available bullets
    if bullet < 0 then bullet = 0 end
    if bullet > maxBullet then bullet = maxBullet end

    local pctToNext = (heat % hpb) / hpb * 100 -- fractional progress toward the next bullet
    local pctRounded = math_floor(pctToNext + 0.5)
    local suffixText = string_format("(%d%%)", pctRounded) -- bullet, maxBullet
    HUD.suffix.Text = suffixText
    HUD.suffix.Color = pctColor(pctRounded)

    local boxSize = CONFIG.BOX_SIZE
    local boxGap = CONFIG.BOX_GAP
    local gap = CONFIG.GAP
    local fontSize = CONFIG.FONT_SIZE

    local suffixW = estTextWidth(suffixText)
    local boxesW = 0
    if maxBullet > 0 then
        boxesW = maxBullet * boxSize + (maxBullet - 1) * boxGap
    end
    local totalW = boxesW + gap + suffixW

    local startX = (vp.X / 2) - (totalW / 2)
    local y = (vp.Y / 2) + CONFIG.Y_OFFSET

    -- bullet boxes
    local boxX = startX
    local boxY = y + (fontSize - boxSize) / 2
    for i = 1, maxBullet do
        local b = getBox(i)
        if b then
            local have = (i <= bullet)
            b.Size = Vector2_new(boxSize, boxSize)
            b.Position = Vector2_new(boxX + (i - 1) * (boxSize + boxGap), boxY)
            b.Filled = have -- filled = have that bullet, hollow = spent
            b.Color = have and CONFIG.COLOR_GREEN or CONFIG.COLOR_RED
            b.Visible = true
        end
    end
    for i = maxBullet + 1, #HUD.boxes do
        HUD.boxes[i].Visible = false
    end

    -- count / percentage suffix
    HUD.suffix.Position = Vector2_new(boxX + boxesW + gap, y)
    HUD.suffix.Visible = true
end

local function destroyHud()
    if HUD.suffix then pcall(function() HUD.suffix:Remove() end) HUD.suffix = nil end
    for _, b in ipairs(HUD.boxes) do pcall(function() b:Remove() end) end
    HUD.boxes = {}
    HUD.built = false
    HUD.valHeat = nil
    HUD.valHeatMax = nil
    HUD.valHeatPerBullet = nil
end

local running = true

local function isGameValid()
    local ok, svc = pcall(function() return game:GetService("Players") end)
    if not ok or not svc then return false end
    local ok2, lp = pcall(function() return svc.LocalPlayer end)
    if not ok2 or not lp then return false end
    local ok3, pid = pcall(function() return game.PlaceId end)
    return ok3 and pid ~= nil
end

local function stop()
    running = false
    destroyHud()
end

-- stop any previous instance before starting a new one
if _G.BulletHudStop then pcall(_G.BulletHudStop) end
_G.BulletHudStop = stop

local function hudLoop()
    while running do
        if not isGameValid() then stop() break end
        pcall(updateHud)
        task_wait(CONFIG.UPDATE_INTERVAL)
    end
    pcall(destroyHud)
end

task_spawn(hudLoop)
