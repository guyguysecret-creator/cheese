--[[
    Infinite Force + Hitbox Expander - one script, one small UI (made for Potassium)

    Infinite Force (same as InfiniteForce.lua v5):
      - ForceRegenMultiplier = huge      -> normal refill is instant
      - AfflictionForceDrainPerTick = -450 -> +1 full bar every second, no 2.5s wait

    Hitbox Expander (written from scratch, replaces the obfuscated ScriptBlox one):
      - The game's lightsaber hits are client raycasts from your blade: any part of
        a character the ray touches counts. So each enemy gets an extra anchored,
        non-colliding box (only you see it) that follows them every frame.
        Their real body is never touched, so no frozen/glitchy players.
      - Turning it off deletes the boxes.

    Infinite Block:
      - hook mode (getgc + hookfunction): hit-block animation still plays, meter is
        pinned at full, and only the client's own "block broken" stun is dropped.
      - delete mode (fallback, e.g. Xeno): deletes the server's "Block" value on your
        side; works, but the hit-block animation won't play.

    Every ON feature re-checks itself every 2s, and hiding the panel (Ctrl+H) never
    turns anything off. Hidden = fully gone; F9 prints what's still ON.

    Infinite Parry / Infinite Kicks (need a real getgc - NOT Xeno):
      - finds your Lightsaber component in memory and keeps ParriesLeft = 5, KicksLeft = 3.

    UI: draggable panel, ON/OFF switches (force, block, parry, kicks, HBE, team check),
    hitbox size + transparency boxes.
    Ctrl + H hides/shows the panel.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer
local PASSWORD = "xoSwiftyxo"

if enteredPassword == PASSWORD then
    print("Access granted")
    -- Show authorized testing UI
else
    print("Incorrect password")
end

-- clean up an older copy if you re-execute
local GUI_NAME = "ForceHBE_UI"
if getgenv and getgenv().ForceHBE_Cleanup then pcall(getgenv().ForceHBE_Cleanup) end

------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------
local settings = {
    force = false,
    block = false,
    parry = false,
    kick = false,
    hbe = false,
    hbeSize = 12,          -- studs (normal HumanoidRootPart is 2 x 2 x 1)
    hbeTransparency = 0.7, -- so you can see the box
    teamCheck = true,      -- don't expand teammates
}

-- shared so the block-break hook (installed once per game session) always reads the
-- settings of the copy of this script that's currently running
do
    local env = (getgenv and getgenv()) or _G
    env.ForceHBE_Settings = settings
end

local connections = {}
local function track(c) table.insert(connections, c); return c end

------------------------------------------------------------------------
-- Infinite Force
------------------------------------------------------------------------
local DRAIN_ATTR, REGEN_ATTR = "AfflictionForceDrainPerTick", "ForceRegenMultiplier"
local REFILL_PER_TICK, REGEN_MULTIPLIER = 450, 100000
local forceConns = {}

local function forceDisconnect()
    for _, c in ipairs(forceConns) do c:Disconnect() end
    table.clear(forceConns)
end

local function forceApply(char)
    forceDisconnect()
    if not char then return end
    local function enforce(attr, value)
        if char:GetAttribute(attr) ~= value then char:SetAttribute(attr, value) end
    end
    enforce(REGEN_ATTR, REGEN_MULTIPLIER)
    enforce(DRAIN_ATTR, -REFILL_PER_TICK)
    table.insert(forceConns, char:GetAttributeChangedSignal(REGEN_ATTR):Connect(function()
        if settings.force then enforce(REGEN_ATTR, REGEN_MULTIPLIER) end
    end))
    table.insert(forceConns, char:GetAttributeChangedSignal(DRAIN_ATTR):Connect(function()
        if settings.force then enforce(DRAIN_ATTR, -REFILL_PER_TICK) end
    end))
end

local function forceRemove(char)
    forceDisconnect()
    if not char then return end
    if char:GetAttribute(REGEN_ATTR) == REGEN_MULTIPLIER then char:SetAttribute(REGEN_ATTR, nil) end
    if char:GetAttribute(DRAIN_ATTR) == -REFILL_PER_TICK then char:SetAttribute(DRAIN_ATTR, nil) end
end

local function setForce(on)
    settings.force = on
    if on then forceApply(LocalPlayer.Character) else forceRemove(LocalPlayer.Character) end
end

track(LocalPlayer.CharacterAdded:Connect(function(char)
    if settings.force then
        task.wait(1) -- let the game's Character component set up first
        if settings.force then forceApply(char) end
    end
end))

local function log(...) print("[ForceHBE]", ...) end

------------------------------------------------------------------------
-- Infinite Block
--   How the game does it (Lightsaber.States.Combat.Blocking):
--     The server puts a NumberValue "Block" on your character and lowers it per hit.
--     Your client's handler then: sets BlocksLeft = Value, PLAYS THE HIT-BLOCK
--     ANIMATION + camera shake, and if BlocksLeft <= 0 fires
--     zap.LightsaberStunFromClient.Fire({ BlockBreak = true, StunType = 2 }).
--
--   MODE "hook" (executor has getgc + hookfunction) - keeps the animation:
--     - leave the Block value alone, so the handler + animation run on every hit
--     - hook LightsaberStunFromClient.Fire and drop only block-break stuns
--     - keep your Lightsaber component's BlocksLeft pinned at 140 (full) every frame,
--       so the meter stays full and each new block reports a full meter to the server
--   MODE "delete" (fallback, e.g. Xeno) - no animation:
--     - delete the Block value on your side so hits never reach the client
------------------------------------------------------------------------
local MAX_BLOCK = 140         -- CombatConstants.BLOCK.MAXIMUM
local STUN_BLOCK_BROKEN = 2   -- CombatConstants.ENUM.STUN_TYPE.BLOCK_BROKEN
local blockMode = nil         -- "hook" or "delete", decided the first time block is turned on
local blockConn, blockHookedChar
local stunHooked = false

-- find zap's LightsaberStunFromClient.Fire and hook it (once per game session)
local function hookBlockBreakStun()
    if stunHooked then return true end
    local env = (getgenv and getgenv()) or _G
    if env.ForceHBE_StunHooked then
        stunHooked = true
        return true
    end
    if type(getgc) ~= "function" or type(hookfunction) ~= "function" then return false end

    local fireFn
    local ok, list = pcall(getgc, true)
    if not ok or type(list) ~= "table" then return false end
    -- 1) the zap module's export table: { LightsaberStunFromClient = { Fire = fn }, LightsaberBlock = ... }
    for _, t in ipairs(list) do
        if type(t) == "table" then
            local entry = rawget(t, "LightsaberStunFromClient")
            if type(entry) == "table" and rawget(t, "LightsaberBlock") ~= nil
                and type(rawget(entry, "Fire")) == "function" then
                fireFn = rawget(entry, "Fire")
                break
            end
        end
    end
    -- 2) fallback: the function whose constants include its profiler label
    if not fireFn and debug.getconstants then
        for _, f in ipairs(list) do
            if type(f) == "function" and (not iscclosure or not iscclosure(f)) then
                local okC, consts = pcall(debug.getconstants, f)
                if okC and type(consts) == "table" then
                    for _, c in ipairs(consts) do
                        if c == "LightsaberStunFromClient Fire" then fireFn = f break end
                    end
                end
                if fireFn then break end
            end
        end
    end
    if not fireFn then return false end

    local old
    local okH = pcall(function()
        old = hookfunction(fireFn, function(payload, ...)
            -- read live settings through the global so a re-executed script stays in control
            local s = env.ForceHBE_Settings
            if s and s.block and type(payload) == "table"
                and (payload.BlockBreak == true or payload.StunType == STUN_BLOCK_BROKEN) then
                return -- swallow the self-reported block break
            end
            return old(payload, ...)
        end)
    end)
    if okH then
        stunHooked = true
        env.ForceHBE_StunHooked = true
    end
    return okH
end

local function isBlockValue(obj)
    return obj.Name == "Block" and obj:IsA("NumberValue")
end

local function killBlockValue(obj)
    task.defer(function() -- deferred: reparenting inside ChildAdded can error
        if settings.block and blockMode == "delete" and obj.Parent then
            pcall(function() obj:Destroy() end)
        end
    end)
end

local function blockDeleteHook(char)
    if blockConn then blockConn:Disconnect(); blockConn = nil end
    blockHookedChar = nil
    if not (settings.block and blockMode == "delete" and char) then return end
    for _, child in ipairs(char:GetChildren()) do
        if isBlockValue(child) then killBlockValue(child) end
    end
    blockConn = char.ChildAdded:Connect(function(child)
        if isBlockValue(child) then killBlockValue(child) end
    end)
    blockHookedChar = char
end

local function setBlock(on)
    settings.block = on
    if on and not blockMode then
        if hookBlockBreakStun() then
            blockMode = "hook"
            log("Infinite Block: hook mode (hit-block animation still plays)")
        else
            blockMode = "delete"
            log("Infinite Block: delete mode (no getgc/hookfunction - hit animation won't play)")
        end
    end
    blockDeleteHook(LocalPlayer.Character) -- only does anything in delete mode
end

track(LocalPlayer.CharacterAdded:Connect(function(char)
    if settings.block then blockDeleteHook(char) end
end))

------------------------------------------------------------------------
-- Infinite Parry + Infinite Kicks  (needs an executor with a REAL getgc)
--   Both counters live on your Lightsaber component (Client.Components.Lightsaber):
--     ParriesLeft (max 5)  -> Parrying state does ParriesLeft -= 1
--     KicksLeft   (max 3)  -> Kicking state does KicksLeft -= 1
--   We find YOUR component in memory (has ParriesLeft + KicksLeft and Local == true)
--   and keep both at max every frame. SetParries/SetKicks refresh the circles on the HUD.
------------------------------------------------------------------------
local MAX_PARRIES, MAX_KICKS = 5, 3
local saberComp
local lastScan = 0
local warnedNoGC = false

local function isMySaber(t)
    if type(t) ~= "table" then return false end
    if type(rawget(t, "ParriesLeft")) ~= "number" or type(rawget(t, "KicksLeft")) ~= "number" then return false end
    return rawget(t, "Local") == true
end

local function saberStillValid(t)
    if not t then return false end
    local ok, valid = pcall(function()
        local cc = rawget(t, "CharacterComponent")
        return isMySaber(t) and cc ~= nil and cc.Instance == LocalPlayer.Character
    end)
    return ok and valid
end

local function scanForSaber()
    lastScan = os.clock()
    -- filtergc is faster where it exists; fall back to a full getgc walk
    if type(filtergc) == "function" then
        local ok, res = pcall(filtergc, "table", { Keys = { "ParriesLeft", "KicksLeft" } })
        if ok and type(res) == "table" then
            for _, t in pairs(res) do
                if saberStillValid(t) then return t end
            end
        end
    end
    if type(getgc) ~= "function" then
        if not warnedNoGC then warnedNoGC = true; log("no getgc in this executor - parry/kicks can't work") end
        return nil
    end
    local ok, list = pcall(getgc, true)
    if not ok or type(list) ~= "table" then return nil end
    for _, t in ipairs(list) do
        if saberStillValid(t) then return t end
    end
    return nil
end

------------------------------------------------------------------------
-- Force pin (fix for "force randomly stops until I toggle it")
--   Cause: the game's drain loop (Character component) only runs
--     `if not (Force <= 0) then Force -= drain end`
--   so with our negative drain it ADDS force - except when Force is exactly 0.
--   And RechargeForce skips normal regen while the drain attribute exists.
--   So once the bar hit 0 (a move costing more than you had, an enemy
--   affliction draining you, etc.) nothing refilled it until you toggled
--   (toggling clears the attribute -> RechargeForce runs -> bar refills).
--   Fix: with getgc, find YOUR Character component and hold Force at MaxForce
--   directly. The attributes stay on as a backup.
------------------------------------------------------------------------
local charComp
local lastCharScan = 0

local function isMyCharComp(t)
    if type(t) ~= "table" then return false end
    local ok, valid = pcall(function()
        return type(rawget(t, "Force")) == "number"
            and type(rawget(t, "MaxForce")) == "number"
            and t.Instance == LocalPlayer.Character
            and t.SetForce ~= nil
    end)
    return ok and valid
end

local function scanForCharComp()
    lastCharScan = os.clock()
    -- quickest: the saber component points at it
    if saberComp then
        local cc = rawget(saberComp, "CharacterComponent")
        if isMyCharComp(cc) then return cc end
    end
    if type(filtergc) == "function" then
        local ok, res = pcall(filtergc, "table", { Keys = { "Force", "MaxForce" } })
        if ok and type(res) == "table" then
            for _, t in pairs(res) do
                if isMyCharComp(t) then return t end
            end
        end
    end
    if type(getgc) ~= "function" then return nil end
    local ok, list = pcall(getgc, true)
    if not ok or type(list) ~= "table" then return nil end
    for _, t in ipairs(list) do
        if isMyCharComp(t) then return t end
    end
    return nil
end

track(RunService.Heartbeat:Connect(function()
    if not settings.force then return end
    if not isMyCharComp(charComp) then
        charComp = nil
        if os.clock() - lastCharScan < 2 then return end
        charComp = scanForCharComp()
        if not charComp then return end
        log("Infinite Force: found your character component (bar is held full)")
    end
    local maxF = rawget(charComp, "MaxForce")
    if rawget(charComp, "Force") < maxF then
        charComp.Force = maxF
        pcall(function() charComp.SetForce:Fire(1) end)
    end
end))

track(RunService.Heartbeat:Connect(function()
    local pinBlock = settings.block and blockMode == "hook"
    if not (settings.parry or settings.kick or pinBlock) then return end
    if not saberStillValid(saberComp) then
        saberComp = nil
        -- the component is rebuilt when you equip/respawn; rescan every 2s until found
        if os.clock() - lastScan < 2 then return end
        saberComp = scanForSaber()
        if not saberComp then return end
        log("found your lightsaber component")
    end
    if settings.parry and rawget(saberComp, "ParriesLeft") < MAX_PARRIES then
        saberComp.ParriesLeft = MAX_PARRIES
        pcall(function() saberComp:SetParries() end)
    end
    if settings.kick and rawget(saberComp, "KicksLeft") < MAX_KICKS then
        saberComp.KicksLeft = MAX_KICKS
        pcall(function() saberComp:SetKicks() end)
    end
    if pinBlock then
        local b = rawget(saberComp, "BlocksLeft")
        if type(b) == "number" and b < MAX_BLOCK then
            saberComp.BlocksLeft = MAX_BLOCK
            pcall(function() saberComp:SetBlock() end)
        end
    end
end))

------------------------------------------------------------------------
-- Hitbox Expander
------------------------------------------------------------------------
--[[
    v2: we no longer touch the player's real HumanoidRootPart (resizing it broke their
    character physics on your screen = frozen/glitchy players).
    Instead each enemy gets a separate ANCHORED box inside their character model that
    just follows their root part every frame. It's not welded to them, so it can't
    affect their physics. The game's hit check (DamageUtil.GetHumanoidFromHitPart)
    walks up from the hit part to the character's Humanoid, so a ray hitting the box
    counts as hitting that player.
]]
local BOX_NAME = "HBE_Box"
local boxes = {} -- [character] = box part

local function isEnemy(plr)
    if plr == LocalPlayer then return false end
    if not settings.teamCheck then return true end
    if LocalPlayer.Team == nil or plr.Team == nil then return true end
    return plr.Team ~= LocalPlayer.Team
end

local function removeBox(char)
    local box = boxes[char]
    boxes[char] = nil
    if box then box:Destroy() end
end

local function removeAllBoxes()
    for char in pairs(boxes) do removeBox(char) end
end

local function getBox(char)
    local box = boxes[char]
    if box and box.Parent == char then return box end
    box = Instance.new("Part")
    box.Name = BOX_NAME
    box.Anchored = true       -- not welded to the player = no physics side effects
    box.CanCollide = false    -- nobody bumps into it
    box.CanTouch = false      -- doesn't fire .Touched on anything
    box.CanQuery = true       -- raycasts (your saber) CAN hit it
    box.Massless = true
    box.CastShadow = false
    box.Material = Enum.Material.SmoothPlastic
    box.Color = Color3.fromRGB(255, 60, 60)
    box.Parent = char         -- must be inside the character so the hit maps to its Humanoid
    boxes[char] = box
    return box
end

-- RenderStepped runs before Heartbeat, where the game does its blade raycasts,
-- so the boxes are already in place when the game checks for hits.
track(RunService.RenderStepped:Connect(function()
    if not settings.hbe then return end
    local s = settings.hbeSize
    local size = Vector3.new(s, s, s)
    local seen = {}
    for _, plr in ipairs(Players:GetPlayers()) do
        local char = plr.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if hrp and hum and hum.Health > 0 and isEnemy(plr) then
            local box = getBox(char)
            box.CFrame = hrp.CFrame
            if box.Size ~= size then box.Size = size end
            if box.Transparency ~= settings.hbeTransparency then box.Transparency = settings.hbeTransparency end
            seen[char] = true
        end
    end
    -- remove boxes for teammates, dead players, players who left
    for char in pairs(boxes) do
        if not seen[char] then removeBox(char) end
    end
end))

local function setHBE(on)
    settings.hbe = on
    if not on then removeAllBoxes() end
end

------------------------------------------------------------------------
-- Self-heal: every 2s re-check that ON features are really applied to your
-- CURRENT character (covers respawns, the game resetting attributes, etc.).
-- Features never depend on the panel being visible.
------------------------------------------------------------------------
track(task.spawn(function()
    while true do
        task.wait(2)
        local char = LocalPlayer.Character
        if char then
            if settings.force and (char:GetAttribute(REGEN_ATTR) ~= REGEN_MULTIPLIER
                or char:GetAttribute(DRAIN_ATTR) ~= -REFILL_PER_TICK or #forceConns == 0) then
                forceApply(char)
            end
            if settings.block and blockMode == "delete" and blockHookedChar ~= char then
                blockDeleteHook(char)
            end
        end
    end
end))

------------------------------------------------------------------------
-- UI
------------------------------------------------------------------------
local parentGui = (gethui and gethui()) or game:GetService("CoreGui")
local okParent = pcall(function() local _ = parentGui.Name end)
if not okParent then parentGui = LocalPlayer:WaitForChild("PlayerGui") end
local old = parentGui:FindFirstChild(GUI_NAME)
if old then old:Destroy() end

local gui = Instance.new("ScreenGui")
gui.Name = GUI_NAME
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
local okSet = pcall(function() gui.Parent = parentGui end)
if not okSet then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

local COLORS = {
    bg = Color3.fromRGB(24, 24, 28), panel = Color3.fromRGB(34, 34, 40),
    text = Color3.fromRGB(235, 235, 240), sub = Color3.fromRGB(150, 150, 160),
    on = Color3.fromRGB(60, 170, 90), off = Color3.fromRGB(90, 90, 100),
}

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(250, 360)
frame.Position = UDim2.new(0, 20, 0.5, -180)
frame.BackgroundColor3 = COLORS.bg
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -16, 0, 28)
title.Position = UDim2.fromOffset(8, 4)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = COLORS.text
title.Text = "Swift heh"
title.Parent = frame

local hint = Instance.new("TextLabel")
hint.Size = UDim2.new(1, -16, 0, 28)
hint.Position = UDim2.fromOffset(8, 4)
hint.BackgroundTransparency = 1
hint.Font = Enum.Font.Gotham
hint.TextSize = 11
hint.TextXAlignment = Enum.TextXAlignment.Right
hint.TextColor3 = COLORS.sub
hint.Text = "Ctrl+H = hide"
hint.Parent = frame

local function makeRow(y, labelText)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, -16, 0, 34)
    row.Position = UDim2.fromOffset(8, y)
    row.BackgroundColor3 = COLORS.panel
    row.BorderSizePixel = 0
    row.Parent = frame
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, -80, 1, 0)
    label.Position = UDim2.fromOffset(10, 0)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.Gotham
    label.TextSize = 13
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextColor3 = COLORS.text
    label.Text = labelText
    label.Parent = row
    return row
end

local function makeSwitch(y, labelText, initial, onChanged)
    local row = makeRow(y, labelText)
    local state = initial
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.fromOffset(56, 22)
    btn.Position = UDim2.new(1, -64, 0.5, -11)
    btn.BorderSizePixel = 0
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 12
    btn.TextColor3 = Color3.new(1, 1, 1)
    btn.AutoButtonColor = true
    btn.Parent = row
    Instance.new("UICorner", btn).CornerRadius = UDim.new(1, 0)
    local function render()
        btn.Text = state and "ON" or "OFF"
        btn.BackgroundColor3 = state and COLORS.on or COLORS.off
    end
    btn.MouseButton1Click:Connect(function()
        state = not state
        render()
        onChanged(state)
    end)
    render()
end

makeSwitch(38, "Infinite Force", settings.force, setForce)
makeSwitch(78, "Infinite Block", settings.block, setBlock)
makeSwitch(118, "Infinite Parry", settings.parry, function(on) settings.parry = on end)
makeSwitch(158, "Infinite Kicks", settings.kick, function(on) settings.kick = on end)
makeSwitch(198, "Hitbox Expander", settings.hbe, setHBE)
makeSwitch(238, "HBE team check", settings.teamCheck, function(on) settings.teamCheck = on end)

-- number boxes (type a value, press Enter or click away)
local function makeNumberBox(y, labelText, key, minV, maxV)
    local row = makeRow(y, labelText)
    local box = Instance.new("TextBox")
    box.Size = UDim2.fromOffset(56, 22)
    box.Position = UDim2.new(1, -64, 0.5, -11)
    box.BackgroundColor3 = COLORS.bg
    box.BorderSizePixel = 0
    box.Font = Enum.Font.GothamBold
    box.TextSize = 12
    box.TextColor3 = COLORS.text
    box.Text = tostring(settings[key])
    box.ClearTextOnFocus = false
    box.Parent = row
    Instance.new("UICorner", box).CornerRadius = UDim.new(0, 6)
    box.FocusLost:Connect(function()
        local n = tonumber(box.Text)
        if n then settings[key] = math.clamp(n, minV, maxV) end
        box.Text = tostring(settings[key])
    end)
end

makeNumberBox(278, "Hitbox size", "hbeSize", 2, 50)
-- 0 = solid (easiest to see), 1 = invisible
makeNumberBox(318, "Transparency (0-1)", "hbeTransparency", 0, 1)

-- dragging
do
    local dragging, dragStart, startPos
    frame.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging, dragStart, startPos = true, input.Position, frame.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    track(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - dragStart
            frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end))
end

local function onList()
    local on = {}
    if settings.force then table.insert(on, "Force") end
    if settings.block then table.insert(on, "Block") end
    if settings.parry then table.insert(on, "Parry") end
    if settings.kick then table.insert(on, "Kicks") end
    if settings.hbe then table.insert(on, "HBE") end
    return #on > 0 and table.concat(on, ", ") or "nothing"
end

--[[
    Ctrl + H fully hides/shows the menu - nothing is left on screen.
    Glitch-proofing:
      - Hiding ONLY flips `frame.Visible`. No feature reads the panel, the switches,
        or `Visible`; they all read the `settings` table, which hiding never touches.
      - The gui itself stays Enabled and parented, so nothing gets destroyed or
        garbage-collected while hidden.
      - The 2s self-heal loop keeps re-applying ON features while hidden.
      - Instead of an on-screen status line, F9 prints what's still ON each time
        you hide it, so you can check without anything showing.
]]
track(UserInputService.InputBegan:Connect(function(input, processed)
    if processed or input.KeyCode ~= Enum.KeyCode.H then return end
    if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl) then
        frame.Visible = not frame.Visible
        if frame.Visible then
            log("menu shown")
        else
            log("menu hidden (Ctrl+H to bring it back) - still ON: " .. onList())
        end
    end
end))

------------------------------------------------------------------------
-- cleanup (used when you re-execute the script)
------------------------------------------------------------------------
local function cleanup()
    setForce(false)
    setBlock(false)
    settings.parry, settings.kick = false, false
    setHBE(false)
    for _, c in ipairs(connections) do
        if type(c) == "thread" then
            pcall(task.cancel, c)
        else
            pcall(function() c:Disconnect() end)
        end
    end
    if gui then gui:Destroy() end
end
if getgenv then getgenv().ForceHBE_Cleanup = cleanup end

print("[ForceHBE] loaded - Ctrl+H toggles the panel")
