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

    Auto Parry (needs getgc; hold right-click with your saber ignited): clicks left-click
      for you when a swing is really aimed at you - see the "Auto Parry" section below.

    UI: draggable panel, ON/OFF switches (force, block, parry, kicks, auto parry, HBE, team check),
    hitbox size + transparency boxes.
    Ctrl + H hides/shows the panel.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer

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
    autoParry = false,
    pingAdjust = true,     -- Auto Parry follows your live ping (spikes / drops adjust it)
    parryOffset = -75,     -- ms: Auto Parry timing, + = later, - = earlier (added on top of ping)
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

-- Some executors send print() to their OWN console instead of Roblox's F9 console, so
-- everything is also kept in a buffer that the menu shows in a small box under the panel.
local logEntries = {}  -- { who = player name or nil (system line), msg = text }
local logSink -- set once the UI exists
local function pushLog(who, msg)
    pcall(print, "[ForceHBE]", msg)
    table.insert(logEntries, { who = who, msg = msg })
    if #logEntries > 120 then table.remove(logEntries, 1) end
    if logSink then pcall(logSink) end
end
local function joinArgs(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    return table.concat(parts, " ")
end
local function log(...) pushLog(nil, joinArgs(...)) end            -- system line
local function logP(who, ...) pushLog(who, joinArgs(...)) end      -- line about one player

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
    if not (settings.parry or settings.kick or pinBlock or settings.autoParry) then return end
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
-- Auto Parry
--   You hold right-click (saber ignited, state "blocking"); the script presses
--   left-click for you when an incoming swing is really aimed at you.
--
--   How it detects swings: attackers' swing animations replicate to your client, so
--   we look at every other player's Animator for one of the game's attack animations
--   (Attack_1-4 for every form + dash attacks) and read its TimePosition.
--
--   A swing counts as a THREAT only if ALL of these hold:
--     - aimed at you: attacker's facing is within ~65 deg of the line to you
--       (stray swings at other people / at nothing are ignored)
--     - about to land: we track their blade and predict the time until it reaches you
--       (distance / closing speed), and click when that is <= ping + 0.18s - so fast
--       dash attacks and high ping automatically trigger from further away
--     - committed: swing has been running >= 50ms (a feint that's cancelled instantly
--       never gets a parry), and it isn't past ~70% of the animation (hit already done)
--   Parry in the game stays active ~0.7s, so firing a little early is safe.
--
--   Multiple attackers: all threats are scored each frame, ONE parry covers every swing
--   in that window, and each swing (animation instance) can only trigger once - so
--   combo follow-ups are new swings and get their own check once the 1.5s cooldown ends.
--   Baits: right before clicking the threat is re-checked; if the swing was cancelled
--   in the meantime, that attacker gets a "bait score" that makes us wait slightly
--   longer on their next swings.
--   Timing: a small random delay (0-40ms) and a per-swing random +-12% on the trigger
--   time, so it isn't frame-perfect every time. "Parry timing (ms)" in the panel
--   shifts everything: + = later, - = earlier.
--
--   Safety: never clicks unless your saber is in the BLOCKING state, you have parries
--   left and the parry cooldown is over - otherwise a click would swing instead.
------------------------------------------------------------------------
local AP = {
    CONE_COS = 0.3,      -- cos(~72 deg): how directly the attacker must face you
    MAX_RANGE = 55,      -- studs: ignore attackers further than this (dash attacks start far away)
    DASH_REACH = 8,      -- studs in front of a dashing attacker that their blade can hit
    BODY_RADIUS = 2.5,   -- studs: blade counts as "landed" this close to your center
    MIN_SWING_SPEED = 9, -- studs/s: blade speed relative to THEIR body that counts as a swing
    HIT_RADIUS = 4.5,    -- studs: blade's closest approach to your center that counts as "aimed at you"
    MIN_CLOSING = 5,     -- studs/s: blade must be heading toward you at least this fast
    KICK_RESPONSE = "parry", -- what to do about an incoming kick: "parry" or "dash" (taps E)
    KICK_TOL = 3,        -- studs of forgiveness around the kick's real hit box
    KICK_RANGE = 9,     -- studs: kick hit box reaches ~4.5 studs, plus slack (after ping/dash compensation)
    KICK_CONE = 0.45,    -- cos(~63 deg): kicker must face you (beyond NEAR_RANGE)
    KICK_WINDUP = 0.4,   -- s from kick start until the hit box turns on (game constant)
    NEAR_RANGE = 7,      -- studs: inside this, facing is ignored (sweeping swings from the side)
    CLOSE_COMMIT = 0.015, -- s: shorter feint filter when the attacker is within CLOSE_RANGE
    CLOSE_RANGE = 12,  -- studs: inside this, a swing animation facing you = parry right away
    CLOSE_CONE = 0.55,   -- cos(~57 deg): how directly they must face you for the close rule
    CLOSE_MISS = 6.5,    -- studs: close rule is skipped if the blade clearly passes this far from you
    MIN_COMMIT = 0.03,   -- s the swing must have run (feint filter)
    MAX_PHASE = 0.85,    -- ignore swings nearly finished
    AIM = 0.18,          -- s: we want the hit to land this long AFTER our parry is active
    TIME_VARIANCE = 0.12, -- per-swing random +-12% on the trigger time
    JITTER_MAX = 0.025,  -- extra human delay 0..25ms (triangular, ~12ms average)
    DASH_CLOSING = 22,   -- studs/s: attacker body rushing at you this fast = dash attack
    DEBUG = true,        -- prints to F9 why a swing was ignored (turn off once it works well)
    FALLBACK_HIT = 0.25, -- s into a swing the hit lands, only if no blade parts are found
}

-- every swing animation id used by the game's forms (Shared.Modules.SaberModule.Animations)
local ATTACK_IDS = {}
for _, id in ipairs({
    6317098079, 6317098902, 6317099741, 6317100331,                 -- single / double
    6669636003, 6669636402, 6669636848, 6669637298,                 -- dual
    6753355600, 6753356943, 6753357989, 6753358978,                 -- temple guard
    6860766921, 6860768068, 6860769042, 6860769691,                 -- temple guard single
    10443651597, 10443656282, 10443658943, 10443661334,             -- dark honor guard / pyke
    73848906817428, 116587032990420, 70845951518050, 88799039982454, -- pyke
    98442653394978, 6368651662,                                     -- dash attacks
}) do ATTACK_IDS[tostring(id)] = true end

-- the kick uses the "ParryBreak" animation (Client.Components.Lightsaber.States.Combat.Kicking)
local KICK_ID = "13552157283"

local pingEma = 0.08
local baitScore = {}                              -- [player] = n
local handledSwing = setmetatable({}, { __mode = "k" }) -- swing track -> true
local swingVariance = setmetatable({}, { __mode = "k" }) -- swing track -> random factor
local apBusy = false
local apLoggedFirst = false

-- The game can SWAP a player's attack/block/parry animation ids at runtime (custom
-- animation packs: Animations.ChangeTempleGuard & co), so a fixed attack-id list misses
-- those players. Fix: every animation id the game ships that is NOT an attack is listed
-- here; any other non-looping animation on a player whose saber is out is treated as a
-- swing too ("unknown" attack) - and the id is printed once so you can see it.
local NON_ATTACK_IDS = {}
for _, id in ipairs({
    6312272936, 6312274072, 6317093733, 6317094309, 6728895746,           -- flips, roll
    6584511045, 7873070812,                                               -- throws
    72741768067322, 89740527877951, 128004514519482, 108843758967999,
    91879086197386, 117020519174436,                                      -- force powers
    13552166958, 13552173835, 13552177816, 13552182822,                   -- skids
    6322860474, 6669642689, 101135636991956, 6753364277, 10443668308,     -- parries
    6297531803, 6322313635, 6322315386,                                   -- stuns
    6291932252, 6291933169, 6292610264, 6292625270, 6292146811, 6292155163,
    6291934524, 6291935220, 6292615823, 6292632003,                       -- equip / sheathe
    6317096682, 6688720735, 6753335745, 6860753522, 10443588041, 109060630722907, -- idles
    6317097513, 6312280575, 6312281206, 6312281779, 6312282511, 6669641262,
    7101397703, 6736233297, 7101402353, 6861038808, 6861088961, 6860799757,
    7101356513, 6753361279, 6860759883, 109369432331476,                  -- blocks
    6302511048, 6302512079, 6382639524, 6392682622,                       -- dashes (movement)
}) do NON_ATTACK_IDS[tostring(id)] = true end
local loggedUnknown = {}

-- returns track, isKick, isUnknownAnim
local function findAttackTrack(char)
    local hum = char:FindFirstChildOfClass("Humanoid")
    local animator = hum and hum:FindFirstChildOfClass("Animator")
    if not animator then return nil end
    local ok, tracks = pcall(animator.GetPlayingAnimationTracks, animator)
    if not ok or type(tracks) ~= "table" then return nil end
    local unknown, attack
    for _, trk in ipairs(tracks) do
        local okId, id = pcall(function() return string.match(trk.Animation.AnimationId, "%d+") end)
        if okId and id then
            -- a KICK wins over everything: the swing animation that was playing a moment
            -- earlier can still be fading out and used to hide the kick from us
            if id == KICK_ID then return trk, true, false end
            if ATTACK_IDS[id] then
                attack = attack or trk
            elseif not unknown and not NON_ATTACK_IDS[id] then
                local okL, looped, len = pcall(function() return trk.Looped, trk.Length end)
                if okL and not looped and len > 0.2 and len < 4 then unknown = { trk, id } end
            end
        end
    end
    if attack then return attack, false, false end
    if unknown then
        -- only count it if their saber is actually out (blade parts exist) - filters emotes
        local hasBlade = false
        for _, d in ipairs(char:GetDescendants()) do
            if d.Name == "Core" and d.Parent and string.match(d.Parent.Name, "Blade") then hasBlade = true break end
        end
        if hasBlade then
            if AP.DEBUG and not loggedUnknown[unknown[2]] then
                loggedUnknown[unknown[2]] = true
                logP(char.Name, "Auto Parry: treating unrecognised animation " .. unknown[2] .. " from " .. char.Name .. " as a swing (custom attack pack?)")
            end
            return unknown[1], false, true
        end
    end
    return nil
end

-- Timing model (v2): instead of "are they within X studs" we predict WHEN the blade
-- will reach you. Every frame we track points along each attacker's blade (the "Core"
-- parts inside their "Blade" models - the same parts the game raycasts from), measure
-- how fast they're moving toward you (minus your own movement), and compute
--     timeToHit = (distance - bodyRadius) / closingSpeed
-- We click when timeToHit <= ping + AIM (+ your offset), i.e. so the parry is already
-- active when the hit lands but hasn't run out yet (it lasts ~0.7s).
local bladeCache = setmetatable({}, { __mode = "k" }) -- character -> { cores, t }
local swingState = {}                                  -- [player] = { trk, prev, speed, ttc }

local function getCores(char)
    local c = bladeCache[char]
    if c and os.clock() - c.t < 1.5 then return c.cores end
    local cores = {}
    for _, d in ipairs(char:GetDescendants()) do
        if d.Name == "Core" and d:IsA("BasePart") and d.Parent and string.match(d.Parent.Name, "Blade") then
            cores[#cores + 1] = d
        end
    end
    bladeCache[char] = { cores = cores, t = os.clock() }
    return cores
end

-- called once per frame: refresh every attacker's blade speed + time-to-hit
local function updateSwings(myHrp, dt)
    local myPos, myVel = myHrp.Position, myHrp.AssemblyLinearVelocity
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer then
            local char = plr.Character
            local trk, isKick, isUnknown
            if char then trk, isKick, isUnknown = findAttackTrack(char) end
            local old = swingState[plr]
            if old and (not trk or old.trk ~= trk) and AP.DEBUG and not handledSwing[old.trk] and old.why
                and old.why ~= "too early" and os.clock() - (AP._lastDbg or 0) > 0.7 then
                -- that swing/kick ended without us answering it: say why (rate-limited)
                AP._lastDbg = os.clock()
                logP(plr.Name, ("Auto Parry ignored %s from %s: %s"):format(old.isKick and "kick" or "swing", plr.Name, old.why))
            end
            if not trk then
                swingState[plr] = nil
            else
                local st = swingState[plr]
                if not st or st.trk ~= trk then
                    st = { trk = trk, prev = nil, relV = {}, swingV = {}, ttc = nil,
                           isKick = isKick, unknown = isUnknown, t0 = os.clock(), maxSwing = 0 }
                    swingState[plr] = st
                    if isKick and AP.DEBUG then
                        local hrpK = char:FindFirstChild("HumanoidRootPart")
                        logP(plr.Name, ("Auto Parry SAW a kick from %s (%.0f studs away)"):format(
                            plr.Name, hrpK and (hrpK.Position - myPos).Magnitude or -1))
                    end
                end
                local pts = {}
                for _, core in ipairs(getCores(char)) do
                    if core.Parent then
                        local cf, half = core.CFrame, core.Size.Y / 2
                        pts[#pts + 1] = cf.Position + cf.UpVector * half
                        pts[#pts + 1] = cf.Position
                        pts[#pts + 1] = cf.Position - cf.UpVector * half
                    end
                end
                -- enemy body velocity from position change (to separate SWING motion
                -- from simply walking / strafing around you)
                local hrpE = char:FindFirstChild("HumanoidRootPart")
                local ePos = hrpE and hrpE.Position
                local eVel = (ePos and st.prevE and dt > 0) and (ePos - st.prevE) / dt or Vector3.zero
                st.prevE = ePos

                -- how fast is their whole BODY rushing at you? (dash attacks come from far away)
                local bodyClosing = 0
                if ePos then
                    local toMeB = myPos - ePos
                    bodyClosing = (eVel - myVel):Dot(toMeB / math.max(toMeB.Magnitude, 0.01))
                end
                st.bodyClosing = bodyClosing

                local best, missMin
                if st.prev and #pts == #st.prev and dt > 0 then
                    for i, pt in ipairs(pts) do
                        local worldVel = (pt - st.prev[i]) / dt
                        -- smooth so a single jittery frame can't trigger it
                        local rel = worldVel - myVel                -- blade motion as YOU see it
                        local swing = worldVel - eVel               -- blade motion relative to their body
                        st.relV[i] = (st.relV[i] or rel) * 0.5 + rel * 0.5
                        st.swingV[i] = (st.swingV[i] or swing) * 0.5 + swing * 0.5
                        if st.swingV[i].Magnitude > st.maxSwing then st.maxSwing = st.swingV[i].Magnitude end
                        local relV = st.relV[i]
                        local relSpeed = relV.Magnitude
                        if relSpeed > 3 then
                            local toMe = myPos - pt
                            -- follow the blade's path forward: where does it pass closest to you?
                            local tStar = toMe:Dot(relV) / (relSpeed * relSpeed)
                            if tStar >= 0 and tStar < 1 then
                                local miss = (toMe - relV * tStar).Magnitude
                                if not missMin or miss < missMin then missMin = miss end
                                -- path threat: a real swing (fast relative to THEIR body, so walking
                                -- past you doesn't count) that passes through you
                                if (st.swingV[i].Magnitude >= AP.MIN_SWING_SPEED or bodyClosing >= AP.DASH_CLOSING)
                                    and miss <= AP.HIT_RADIUS
                                    and relV:Dot(toMe) / math.max(toMe.Magnitude, 0.01) >= AP.MIN_CLOSING then
                                    local t = math.max(tStar - AP.BODY_RADIUS / relSpeed, 0)
                                    if not best or t < best then best = t end
                                end
                            end
                        end
                    end
                end
                st.prev = (#pts > 0) and pts or nil
                st.ttc = best
                st.missMin = missMin
                st.hasBlade = #pts > 0
            end
        end
    end
end

-- when to click: parry must be active by the time the hit lands
local function triggerTime(trk)
    local v = swingVariance[trk]
    if not v then
        v = 1 + (math.random() * 2 - 1) * AP.TIME_VARIANCE
        swingVariance[trk] = v
    end
    local offset = (settings.parryOffset or 0) / 1000 -- + = later, - = earlier
    if settings.pingAdjust then
        -- "ping sweet spot": your own ping, flipped negative, plus the box value on top
        -- (e.g. 80ms ping + box -75 => -155ms). Because pingEma follows your live ping, a
        -- spike makes it fire earlier and a drop makes it fire later, automatically.
        offset = offset - pingEma
    end
    return math.max((pingEma + AP.AIM) * v - offset, 0.02)
end

-- is this player's current swing a real threat to us? returns urgency (lower = sooner), swingTrack
local function assessThreat(plr, myHrp)
    local char = plr.Character
    if not char then return nil end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    local hum = char:FindFirstChildOfClass("Humanoid")
    local st = swingState[plr]
    if not hrp or not hum or hum.Health <= 0 or not st then return nil end

    local trk = st.trk
    if handledSwing[trk] then return nil end
    st.why = nil

    local function no(why) st.why = why return nil end

    local okT, timePos, speed, length, playing = pcall(function()
        return trk.TimePosition, trk.Speed, trk.Length, trk.IsPlaying
    end)
    if not okT or not playing then return no("animation stopped (cancelled / stunned)") end

    local toMe = myHrp.Position - hrp.Position
    local d = math.max(toMe.Magnitude, 0.01)
    local face = hrp.CFrame.LookVector:Dot(toMe / d)

    -- KICK: no blade involved. The kick's hit box is a ~4.5 stud cube in front of the
    -- kicker that switches on 0.4s after the kick starts (Kicking state: KICK_WINDUP),
    -- so: kicker is close (or rushing in), facing you, and the active moment is near.
    if st.isKick then
        -- HIGH PING: we only SEE the kick about one ping after it really started, and the
        -- kicker's position we see is that old too. So: (1) the kick is further along than
        -- it looks, (2) a kicker who dashes in during the 0.4s windup is closer than shown.
        local sinceStart = os.clock() - st.t0 + pingEma
        if sinceStart > AP.KICK_WINDUP + 0.75 + pingEma then return no("kick was already over") end
        local closingK = math.min(math.max(st.bodyClosing or 0, 0), 70)
        -- slack: with high ping BOTH positions are stale (the kicker's by a ping, yours by
        -- the time the kick lands), so the faster anyone is moving the less exact "d" is
        local slack = math.min(pingEma, 0.5)
            * (math.min(myHrp.AssemblyLinearVelocity.Magnitude, 60) + math.min(hrp.AssemblyLinearVelocity.Magnitude, 60)) * 0.5
        -- Test 1 (geometry): is your body inside the kick's real hit box (4.5-stud cube
        -- in front of the kicker) once we add tolerance for turning / ping drift?
        local rel = hrp.CFrame:PointToObjectSpace(myHrp.Position)
        local tol = AP.KICK_TOL + slack
        local inBox = (-rel.Z) >= -1.5 and (-rel.Z) <= 4.5 + tol
            and math.abs(rel.X) <= 2.25 + tol and math.abs(rel.Y) <= 2.25 + tol
        -- Test 2 (old rule, now ping-aware): close enough + roughly facing you
        local reach = d - closingK * (AP.KICK_WINDUP + pingEma)
        local coneK = AP.KICK_CONE - math.min(pingEma, 0.4) * 0.8 -- laggier = more forgiving aim
        local nearOK = reach <= AP.KICK_RANGE + slack and (face >= coneK or d <= AP.NEAR_RANGE)
        if not inBox and not nearOK then
            if reach > AP.KICK_RANGE + slack then return no(("kicker too far (%.0f studs)"):format(d)) end
            return no("kicker not facing you")
        end
        -- a kick can't be cancelled and its windup is fixed, so there is nothing to wait
        -- for: answer the moment we recognise it (any waiting only costs ping-time we lack)
        return math.max(AP.KICK_WINDUP - sinceStart, 0), trk
    end

    local elapsed = timePos / math.max(speed, 0.1)
    -- up close there is almost no time, so the feint filter is much shorter there
    local minCommit = (d <= AP.CLOSE_RANGE and AP.CLOSE_COMMIT or AP.MIN_COMMIT)
        + math.min(0.12, (baitScore[plr] or 0) * 0.03)
    if elapsed < minCommit then return no("too early") end                -- feint filter
    if length > 0 and timePos / length > AP.MAX_PHASE then return no("swing was nearly over") end

    if d > AP.MAX_RANGE then return no(("attacker too far (%.0f studs)"):format(d)) end
    -- facing only matters at range: someone beside you can sweep the blade across you
    -- without their body facing you, so inside NEAR_RANGE the blade path decides instead
    if face < AP.CONE_COS and d > AP.NEAR_RANGE then return no("attacker not facing you") end

    local ttc = st.ttc
    -- DASH ATTACK: their whole body is rushing at you - no need for the blade path
    local bodyClosing = st.bodyClosing or 0
    if not ttc and bodyClosing >= AP.DASH_CLOSING then
        ttc = math.max(d - AP.DASH_REACH, 0) / bodyClosing
    end
    -- CLOSE-RANGE RULE: slow regular swings and fast multi-hit combos right next to you
    -- don't move fast enough for the path check, so up close the swing animation itself
    -- is the signal: attacker is near, facing you, and the blade isn't clearly going
    -- somewhere else -> parry right away. (Unknown/custom animations must show some
    -- real blade movement first.)
    if not ttc and d <= AP.CLOSE_RANGE
        and (face >= AP.CLOSE_CONE or d <= AP.NEAR_RANGE)
        and (st.missMin == nil or st.missMin <= AP.CLOSE_MISS)
        and (not st.unknown or st.maxSwing >= 5) then
        ttc = 0
    end
    if not st.hasBlade then
        -- no blade parts found on this player: fall back to swing-animation timing
        ttc = math.max(AP.FALLBACK_HIT - elapsed, 0)
    end
    if not ttc then
        if d <= AP.CLOSE_RANGE then
            return no(("swing is aimed away from you (blade passes %.1f studs off)"):format(st.missMin or -1))
        end
        return no("blade not heading toward you")
    end
    if ttc > triggerTime(trk) then return no("too early") end
    return ttc, trk
end

-- only true when a left-click would really PARRY (not swing)
local function canParryNow()
    local sc = saberComp
    if not saberStillValid(sc) then return false end
    local okS, state = pcall(function() return rawget(sc, "CombatStateMachine"):GetCurrentState() end)
    if not okS or state ~= "blocking" then return false end
    if (rawget(sc, "ParriesLeft") or 0) <= 0 then return false end
    local okC, onCd = pcall(function() return rawget(sc, "Cooldowns"):OnCooldown("parry") end)
    if okC and onCd then return false end
    return true
end

local function sendParryClick()
    if type(mouse1click) == "function" and pcall(mouse1click) then return true end
    if type(mouse1press) == "function" and type(mouse1release) == "function" then
        if pcall(mouse1press) then
            task.wait(0.03)
            pcall(mouse1release)
            return true
        end
    end
    -- last resort (best effort): feed the saber's own state machine the attack input
    return pcall(function()
        saberComp.CombatStateMachine:Input("ATTACK", { inputState = Enum.UserInputState.Begin })
    end)
end

-- Parry through the game's own input handler - the exact function a real left-click
-- calls (Lightsaber:ProcessInput), minus the delay of the OS mouse pipeline. If the
-- game didn't start a parry (parry cooldown still not running after 80ms) we click.
local function sendParryDirect()
    local ok = pcall(function()
        saberComp:ProcessInput(true, { name = "ATTACK", inputState = Enum.UserInputState.Begin })
    end)
    if not ok then return sendParryClick() end
    task.delay(0.08, function()
        local sc = saberComp
        if not sc or not saberStillValid(sc) then return end
        local okC, onCd = pcall(function() return rawget(sc, "Cooldowns"):OnCooldown("parry") end)
        if okC and not onCd then sendParryClick() end -- parry didn't register: real click
    end)
    return true
end

-- optional kick answer: tap E (Force Dash) to get out of the kick's hit box
local lastDash = 0
local function sendDash()
    if type(keypress) == "function" and type(keyrelease) == "function" then
        if pcall(keypress, 0x45) then -- 0x45 = E
            task.wait(0.03)
            pcall(keyrelease, 0x45)
            return true
        end
    end
    return false
end
local function usesDash(st) return st ~= nil and st.isKick and AP.KICK_RESPONSE == "dash" end
local function responseAvailable(st, canParry)
    if usesDash(st) then return os.clock() - lastDash > 1 end
    return canParry
end

track(RunService.Heartbeat:Connect(function(dt)
    if not settings.autoParry then return end

    local okP, p = pcall(function() return LocalPlayer:GetNetworkPing() end)
    if okP and type(p) == "number" then
        -- follow a spike quickly (so we compensate right away) but come back down gently
        -- (so one lucky low reading doesn't make us late)
        local rate = (p > pingEma) and 8 or 1.5
        pingEma = pingEma + (p - pingEma) * math.min(1, dt * rate)
    end

    local char = LocalPlayer.Character
    local myHrp = char and char:FindFirstChild("HumanoidRootPart")
    if not myHrp then return end
    updateSwings(myHrp, dt) -- keep blade speeds fresh every frame, even before you block
    if apBusy then return end
    local canParry = canParryNow()

    -- score every attacker, react to the most urgent swing/kick we can actually answer
    local bestEta, bestTrk, bestPlr
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer then
            local eta, trk = assessThreat(plr, myHrp)
            if eta then
                if not responseAvailable(swingState[plr], canParry) then
                    swingState[plr].why = "it WAS a threat, but you weren't blocking / parry on cooldown / no parries left"
                elseif not bestEta or eta < bestEta then
                    bestEta, bestTrk, bestPlr = eta, trk, plr
                end
            end
        end
    end
    if not bestTrk then return end

    apBusy = true
    -- humanized delay, but when the hit is basically here (close fights) react instantly
    local bestIsKick = swingState[bestPlr] and swingState[bestPlr].isKick
    local delay = (bestIsKick or bestEta < 0.1) and 0 or ((math.random() + math.random()) / 2) * AP.JITTER_MAX
    local function respond()
        apBusy = false
        if not settings.autoParry then return end
        local c = LocalPlayer.Character
        local hrp2 = c and c:FindFirstChild("HumanoidRootPart")
        if not hrp2 then return end

        -- bait / feint check: is it still a live, aimed, in-range swing?
        local eta2, trk2 = assessThreat(bestPlr, hrp2)
        if trk2 ~= bestTrk then
            if not bestTrk.IsPlaying then baitScore[bestPlr] = (baitScore[bestPlr] or 0) + 1 end
            return
        end
        local st2 = swingState[bestPlr]
        if not responseAvailable(st2, canParryNow()) then return end
        baitScore[bestPlr] = math.max(0, (baitScore[bestPlr] or 0) - 0.5)

        if usesDash(st2) then
            -- kick answered with a dash instead of a parry
            handledSwing[bestTrk] = true
            lastDash = os.clock()
            task.spawn(sendDash)
            return
        end

        -- one parry covers everyone swinging (or kicking) right now
        handledSwing[bestTrk] = true
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer and not usesDash(swingState[plr]) then
                local _, t2 = assessThreat(plr, hrp2)
                if t2 then handledSwing[t2] = true end
            end
        end

        -- kicks are the time-critical case: use the game's own input path (no OS mouse
        -- latency), with a real click as a back-up if it didn't take
        local sent
        if st2 and st2.isKick then sent = sendParryDirect() else sent = sendParryClick() end
        if sent and not apLoggedFirst then
            apLoggedFirst = true
            logP(bestPlr.Name, ("Auto Parry fired (first one this session) vs %s | live ping %.0f ms"):format(bestPlr.Name, pingEma * 1000))
        end
    end
    if delay <= 0 then task.spawn(respond) else task.delay(delay, respond) end
end))

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
frame.Size = UDim2.fromOffset(250, 480)
frame.Position = UDim2.new(0, 20, 0.5, -240)
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
title.Text = "comp"
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

-- everything below the title lives in `content`, which stays hidden until the
-- password is entered
local content = Instance.new("Frame")
content.Size = UDim2.fromScale(1, 1)
content.BackgroundTransparency = 1
content.BorderSizePixel = 0
content.Visible = false
content.Parent = frame

local function makeRow(y, labelText)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, -16, 0, 34)
    row.Position = UDim2.fromOffset(8, y)
    row.BackgroundColor3 = COLORS.panel
    row.BorderSizePixel = 0
    row.Parent = content
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
makeSwitch(198, "Auto Parry", settings.autoParry, function(on)
    settings.autoParry = on
    if on then
        -- self-test so you can see in F9 whether everything Auto Parry needs is there
        task.delay(2.5, function()
            if not settings.autoParry then return end
            log(("Auto Parry ON | lightsaber component: %s | click function: %s | live ping %.0f ms"):format(
                saberStillValid(saberComp) and "found" or "NOT FOUND (equip + ignite your saber; needs getgc)",
                (type(mouse1click) == "function" or type(mouse1press) == "function") and "yes" or "NO (executor has no mouse1click)",
                pingEma * 1000))
        end)
    end
end)
makeSwitch(238, "Hitbox Expander", settings.hbe, setHBE)
makeSwitch(278, "HBE team check", settings.teamCheck, function(on) settings.teamCheck = on end)
makeSwitch(318, "Parry follows ping", settings.pingAdjust, function(on) settings.pingAdjust = on end)

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

makeNumberBox(358, "Hitbox size", "hbeSize", 2, 50)
-- 0 = solid (easiest to see), 1 = invisible
makeNumberBox(398, "Transparency (0-1)", "hbeTransparency", 0, 1)
-- Auto Parry timing: parry too EARLY (it expires before the hit) -> raise this;
-- parry too LATE (you get hit first) -> lower it (negative is fine).
-- With "Parry follows ping" ON this is added on top of your (negated) live ping.
makeNumberBox(438, "Parry timing (ms)", "parryOffset", -500, 500)

------------------------------------------------------------------------
-- Password lock. The panel shows only this screen until the right password is
-- typed. Only a hash is stored here, not the password itself.
-- NOTE: this keeps casual users out of the menu; it isn't real security (anyone
-- who reads/edits the script on GitHub can remove it).
------------------------------------------------------------------------
local PASSWORD_HASH = 2300189347
local function hashPassword(s)
    local h = 5381
    for i = 1, #s do
        h = bit32.bxor((h * 33) % 4294967296, string.byte(s, i))
    end
    return h
end

local lock = Instance.new("Frame")
lock.Size = UDim2.new(1, 0, 1, -36)
lock.Position = UDim2.fromOffset(0, 36)
lock.BackgroundTransparency = 1
lock.BorderSizePixel = 0
lock.Parent = frame

local lockLabel = Instance.new("TextLabel")
lockLabel.Size = UDim2.new(1, -16, 0, 40)
lockLabel.Position = UDim2.fromOffset(8, 40)
lockLabel.BackgroundTransparency = 1
lockLabel.Font = Enum.Font.Gotham
lockLabel.TextSize = 13
lockLabel.TextWrapped = true
lockLabel.TextColor3 = COLORS.sub
lockLabel.Text = "Locked. Enter the password to see the features."
lockLabel.Parent = lock

local pwBox = Instance.new("TextBox")
pwBox.Size = UDim2.new(1, -16, 0, 32)
pwBox.Position = UDim2.fromOffset(8, 96)
pwBox.BackgroundColor3 = COLORS.panel
pwBox.BorderSizePixel = 0
pwBox.Font = Enum.Font.GothamBold
pwBox.TextSize = 13
pwBox.TextColor3 = COLORS.text
pwBox.PlaceholderText = "Password"
pwBox.PlaceholderColor3 = COLORS.sub
pwBox.Text = ""
pwBox.ClearTextOnFocus = false
pwBox.Parent = lock
Instance.new("UICorner", pwBox).CornerRadius = UDim.new(0, 6)

local unlockBtn = Instance.new("TextButton")
unlockBtn.Size = UDim2.new(1, -16, 0, 32)
unlockBtn.Position = UDim2.fromOffset(8, 138)
unlockBtn.BackgroundColor3 = COLORS.on
unlockBtn.BorderSizePixel = 0
unlockBtn.Font = Enum.Font.GothamBold
unlockBtn.TextSize = 13
unlockBtn.TextColor3 = Color3.new(1, 1, 1)
unlockBtn.Text = "Unlock"
unlockBtn.Parent = lock
Instance.new("UICorner", unlockBtn).CornerRadius = UDim.new(0, 6)

local function tryUnlock()
    if hashPassword(pwBox.Text) == PASSWORD_HASH then
        pwBox.Text = ""
        lock.Visible = false
        content.Visible = true
        log("unlocked")
    else
        pwBox.Text = ""
        lockLabel.Text = "Wrong password."
        lockLabel.TextColor3 = Color3.fromRGB(220, 80, 80)
    end
end
unlockBtn.MouseButton1Click:Connect(tryUnlock)
pwBox.FocusLost:Connect(function(enterPressed)
    if enterPressed then tryUnlock() end
end)

-- on-screen log box (under the panel, moves/hides with it): the same lines the script
-- prints to F9, in case your executor doesn't show print() there
do
    local selected = {}   -- [player name] = true ; empty = show everything
    local nSelected = 0

    local box = Instance.new("Frame")
    box.Size = UDim2.new(1, 0, 0, 190)
    box.Position = UDim2.new(0, 0, 1, 6)
    box.BackgroundColor3 = COLORS.bg
    box.BackgroundTransparency = 0.15
    box.BorderSizePixel = 0
    box.Parent = content
    Instance.new("UICorner", box).CornerRadius = UDim.new(0, 8)

    -- "Track: ..." button that opens the player list
    local pick = Instance.new("TextButton")
    pick.Size = UDim2.new(1, -12, 0, 24)
    pick.Position = UDim2.fromOffset(6, 6)
    pick.BackgroundColor3 = COLORS.panel
    pick.BorderSizePixel = 0
    pick.Font = Enum.Font.GothamBold
    pick.TextSize = 12
    pick.TextColor3 = COLORS.text
    pick.TextTruncate = Enum.TextTruncate.AtEnd
    pick.AutoButtonColor = true
    pick.Parent = box
    Instance.new("UICorner", pick).CornerRadius = UDim.new(0, 6)

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -12, 1, -38)
    lbl.Position = UDim2.fromOffset(6, 34)
    lbl.BackgroundTransparency = 1
    lbl.Font = Enum.Font.Code
    lbl.TextSize = 11
    lbl.TextColor3 = COLORS.sub
    lbl.TextWrapped = true
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.TextYAlignment = Enum.TextYAlignment.Bottom
    lbl.Text = ""
    lbl.Parent = box

    -- the drop-down list (opens over the log text)
    local list = Instance.new("ScrollingFrame")
    list.Size = UDim2.new(1, -12, 0, 150)
    list.Position = UDim2.fromOffset(6, 32)
    list.BackgroundColor3 = COLORS.panel
    list.BorderSizePixel = 0
    list.ScrollBarThickness = 4
    list.CanvasSize = UDim2.new(0, 0, 0, 0)
    list.AutomaticCanvasSize = Enum.AutomaticSize.Y
    list.Visible = false
    list.ZIndex = 5
    list.Parent = box
    Instance.new("UICorner", list).CornerRadius = UDim.new(0, 6)
    local layout = Instance.new("UIListLayout")
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = list

    local function render()
        -- button text
        if nSelected == 0 then
            pick.Text = "Track: everyone  v"
        else
            local names = {}
            for n in pairs(selected) do names[#names + 1] = n end
            table.sort(names)
            pick.Text = "Track: " .. table.concat(names, ", ") .. "  v"
        end
        -- log text: only lines about selected players (system lines only when tracking everyone)
        local out = {}
        for i = #logEntries, 1, -1 do
            local e = logEntries[i]
            local show
            if nSelected == 0 then show = true else show = e.who ~= nil and selected[e.who] == true end
            if show then
                table.insert(out, 1, e.msg)
                if #out >= 12 then break end
            end
        end
        lbl.Text = (#out > 0) and table.concat(out, "\n")
            or (nSelected > 0 and "(nothing yet from the selected players)" or "")
    end
    logSink = render

    local function entry(order, text, isOn, onClick)
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(1, -6, 0, 22)
        b.LayoutOrder = order
        b.BackgroundColor3 = isOn and COLORS.on or COLORS.panel
        b.BackgroundTransparency = isOn and 0.35 or 0
        b.BorderSizePixel = 0
        b.Font = Enum.Font.Gotham
        b.TextSize = 12
        b.TextColor3 = COLORS.text
        b.TextXAlignment = Enum.TextXAlignment.Left
        b.Text = "  " .. (isOn and "[x] " or "[ ] ") .. text
        b.ZIndex = 6
        b.Parent = list
        b.MouseButton1Click:Connect(onClick)
        return b
    end

    local function rebuildList()
        for _, c in ipairs(list:GetChildren()) do
            if c:IsA("TextButton") then c:Destroy() end
        end
        entry(0, "Everyone (clear selection)", nSelected == 0, function()
            table.clear(selected); nSelected = 0
            rebuildList(); render()
        end)
        local names = {}
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer then names[#names + 1] = plr.Name end
        end
        table.sort(names)
        for i, name in ipairs(names) do
            entry(i, name, selected[name] == true, function()
                if selected[name] then selected[name] = nil; nSelected -= 1
                else selected[name] = true; nSelected += 1 end
                rebuildList(); render()
            end)
        end
    end

    pick.MouseButton1Click:Connect(function()
        list.Visible = not list.Visible
        if list.Visible then rebuildList() end
    end)
    track(Players.PlayerAdded:Connect(function() if list.Visible then rebuildList() end end))
    track(Players.PlayerRemoving:Connect(function(p)
        if selected[p.Name] then selected[p.Name] = nil; nSelected -= 1 end
        task.defer(function() if list.Visible then rebuildList() end; render() end)
    end))

    render()
end

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
    if settings.autoParry then table.insert(on, "AutoParry") end
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
    settings.parry, settings.kick, settings.autoParry = false, false, false
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

log("loaded (auto-parry build 10: player filter) - Ctrl+H toggles the panel")
