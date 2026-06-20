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

UI.AddTab("Redliner (by larina :P)", function(tab)
    local sec_speed = tab:Section("Speed (USE WITH CAUTION)", "Left")
    local speed_toggle=false
    local speed_multx=1.0

    -- toggle
    sec_speed:Toggle("speed_toggle", "Enabled", false, function(state)
        speed_toggle=state
    end)
    speed_toggle=UI.GetValue("speed_toggle") -- :P
    local speed_kb = sec_speed:Keybind("speed_kb", 0x05, "hold") -- X1 mouse button
    speed_kb:AddToHotkey("speed", "speed_toggle")

    -- slider
    speed_slider=sec_speed:SliderFloat("speed_slider", "Speed Multiplier", 1.0, 6.0, 3.0, "%.1f", function(val)
        speed_multx=val
    end)
    speed_multx=UI.GetValue("speed_slider") -- :P

    -- main script
    RunService.Stepped:Connect(function()
        if not speed_kb:IsEnabled() or not speed_toggle or RootPart == nil then return end
        local vel = RootPart.AssemblyLinearVelocity
        RootPart.AssemblyLinearVelocity = Vector3.new(vel.X*speed_multx, vel.Y, vel.Z*speed_multx)        
    end)
    task.spawn(function()
        while true do
            task.wait(1)
            GetPlayerRootPart()
        end
    end)

    notify("Script Loaded","By larina",5)
end)

