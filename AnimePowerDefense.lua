--[[
    Anime Tower Defense - Macro Recorder / Player  (Maclib UI)  v4

    Records ONLY unit placements and unit upgrades, in the exact order you did them, and
    remembers WHICH unit each one was ("Goko #1", "Goko #2", ...).

    Replay follows that exact order. Every step waits until you can afford its exact cost,
    fires, asks the server whether it really worked, and retries if it did not. Nothing is
    timed.

    The server is the source of truth: GameService.GetPlacedUnits returns every unit you own
    with its real upgrade level and its cost data.

    Hotkeys (rebindable in the UI):
        F6  start / stop recording
        F7  start / stop playback

    Macros save to workspace/ATD_Macros as JSON.
]]

local Players           = game:GetService("Players")
local RS                = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local HttpService       = game:GetService("HttpService")

local genv = getgenv()
if genv.__ATDMacro then
    pcall(function() genv.__ATDMacro.destroy() end)
end

local FOLDER = "ATD_Macros"
pcall(makefolder, FOLDER)

local RECORD_ACTIONS = { PlaceUnit = true, UpgradeUnit = true }
local GUID_PAT       = "^%x+%-%x+%-%x+%-%x+%-%x+$"
local SETTLE_QUIET   = 1.0    -- record: no new E press on a unit for this long ...
local SETTLE_STABLE  = 1.0    -- record: ... and its server level unchanged for this long = settled
local PLACE_VERIFY   = 3      -- replay: how long to wait for a placed unit to show up
local STEP_TIMEOUT   = 180    -- replay: give up on one step after this many seconds
local MAX_FAILS      = 4      -- replay: failed attempts WITH enough money before skipping a step
local TIE_RADIUS     = 3      -- record: placements this close count as "same spot" (first one wins)

local M = {
    recording = false,
    finalizing = false,
    playing   = false,
    steps     = {},
    queue     = {},
    watch     = {},
    alive      = true,
    armed      = false,   -- "Play macro" toggle: run the macro when a game starts
    runBusy    = false,
    autoVote   = false,
    autoReplay = false,
    macroName = "my_macro",
    selected  = nil,
    waitText  = nil,
    log       = {},

    unitConn   = nil,
    unitFolder = nil,
    newUnits   = {},
    -- recording state
    nextPid    = 0,
    places     = {},
    guidToPid  = {},
    labelByPid = {},
    numById    = {},
    confirmed  = {},
    pendingUp  = {},     -- [guid] = upgrade steps waiting for the server's verdict, in press order
    lastCall   = {},     -- [guid] = os.clock() of the latest upgrade press
    settling   = {},     -- [guid] = true while a settle worker is running
    autoIgnored = 0,
    -- replay state
    replayMap  = {},
}
genv.__ATDMacro = M
M.autoDismiss = true     -- click through the end-of-match reward pop-ups (Main.View)

---------------------------------------------------------------------------
-- Remotes
---------------------------------------------------------------------------
local Events = RS:WaitForChild("Events")
if Events:FindFirstChild("Game") then M.watch[Events.Game] = true end

local Knit = RS:WaitForChild("Modules"):WaitForChild("Packages"):WaitForChild("Knit"):WaitForChild("Services")
local GetPlacedUnitsRF = Knit:WaitForChild("GameService"):WaitForChild("RF"):WaitForChild("GetPlacedUnits")

---------------------------------------------------------------------------
-- Server truth: every unit we own, with real level + cost data
---------------------------------------------------------------------------
local function getPlaced()
    local ok, res = pcall(function() return GetPlacedUnitsRF:InvokeServer() end)
    if ok and type(res) == "table" then return res end
    return nil
end

local function upgradeCostFor(entry, level)
    local ups = entry and entry.UnitData and entry.UnitData.upgrades
    local u = ups and ups[level]
    return u and tonumber(u.cost) or nil
end

-- unit id -> display name ("Goko"), from the game's own unit modules
local nameById = {}
task.spawn(function()
    local ok, folder = pcall(function() return RS.Assets.Units end)
    if not ok or not folder then return end
    for _, m in ipairs(folder:GetChildren()) do
        if m:IsA("ModuleScript") then
            local okr, data = pcall(require, m)
            if okr and type(data) == "table" and data.id ~= nil and nameById[data.id] == nil then
                nameById[data.id] = m.Name
            end
        end
    end
end)
local function unitName(id)
    return nameById[id] or ("Unit " .. tostring(id))
end

---------------------------------------------------------------------------
-- Money + unit helpers
---------------------------------------------------------------------------
local GameController
pcall(function()
    GameController = require(Players.LocalPlayer.PlayerScripts.Core.Controllers.GameController)
end)

local function getMoney()
    if not GameController then return math.huge end
    return tonumber(GameController.CURRENCY) or math.huge
end

local function unitsFolder()
    local map = workspace:FindFirstChild("Map")
    return map and map:FindFirstChild("Units")
end

local function unitPos(inst)
    local loc = inst:GetAttribute("Location")
    if typeof(loc) == "CFrame" then return loc.Position end
    return nil
end

-- among candidates close to the best distance, take the one fired first (server order)
local function pickPlacement(cands, pos)
    if #cands == 0 then return nil end
    if not pos then return 1 end
    local bestD
    for _, c in ipairs(cands) do
        local d = (c.pos - pos).Magnitude
        if not bestD or d < bestD then bestD = d end
    end
    for i, c in ipairs(cands) do
        if (c.pos - pos).Magnitude <= bestD + TIE_RADIUS then return i end
    end
    return 1
end

---------------------------------------------------------------------------
-- (De)serialisation
---------------------------------------------------------------------------
local function enc(v)
    local t = typeof(v)
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return { _t = "Num", s = tostring(v) } end
        return v
    elseif t == "string" then
        local pid = M.guidToPid[v]
        if pid then return { _t = "Unit", p = pid } end
        return v
    elseif t == "boolean" then
        return v
    elseif t == "Vector3" then
        return { _t = "V3", c = { v.X, v.Y, v.Z } }
    elseif t == "CFrame" then
        return { _t = "CF", c = { v:GetComponents() } }
    end
    return { _t = "nil" }
end

local function dec(v)
    if type(v) ~= "table" then return v end
    local t = v._t
    if t == "Num" then return tonumber(v.s)
    elseif t == "V3" then return Vector3.new(unpack(v.c))
    elseif t == "CF" then return CFrame.new(unpack(v.c))
    elseif t == "Unit" then return M.replayMap[v.p]
    end
    return nil
end

local function remotePath(remote)
    local names, cur = {}, remote
    while cur and cur ~= RS do
        table.insert(names, 1, cur.Name)
        cur = cur.Parent
    end
    return names
end

local function resolveRemote(path)
    local cur = RS
    for _, n in ipairs(path) do
        cur = cur and cur:FindFirstChild(n)
        if not cur then return nil end
    end
    return cur
end

---------------------------------------------------------------------------
-- Namecall hook (installed once per session; dispatches to the current M).
-- It only queues raw calls; all work happens later.
---------------------------------------------------------------------------
if not genv.__ATDHookInstalled then
    genv.__ATDHookInstalled = true
    local old
    old = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        local method = getnamecallmethod()
        local cur = genv.__ATDMacro
        if cur and cur.recording and method == "FireServer"
            and cur.watch[self] and not checkcaller() then
            local q = cur.queue
            q[#q + 1] = { os.clock(), self, table.pack(...) }
        end
        return old(self, ...)
    end), "ATDMacroHook")
end

---------------------------------------------------------------------------
-- UI
---------------------------------------------------------------------------
local MacLib = loadstring(game:HttpGet("https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()

local Window = MacLib:Window({
    Title = "Anime Power Defense",
    Subtitle = "",
    Size = UDim2.fromOffset(760, 520),
    DragStyle = 1,
    DisabledWindowControls = {},
    ShowUserInfo = false,
    Keybind = Enum.KeyCode.RightControl,
    AcrylicBlur = false,
})

local function notify(desc, life)
    Window:Notify({ Title = "Anime Power Defense", Description = desc, Lifetime = life or 4 })
end

local group = Window:TabGroup()
local tabMacro    = group:Tab({ Name = "Macro",        Image = "rbxassetid://18821914323" })
local tabJoiners  = group:Tab({ Name = "Joiners",      Image = "rbxassetid://18821914323" })
local tabPortal   = group:Tab({ Name = "Portal",       Image = "rbxassetid://18821914323" })
local tabLog      = group:Tab({ Name = "Steps & Log",  Image = "rbxassetid://18821914323" })
local tabSettings = group:Tab({ Name = "Settings",     Image = "rbxassetid://10734950309" })

local secControl = tabMacro:Section({ Side = "Left" })
local secLibrary = tabMacro:Section({ Side = "Right" })
local secLog     = tabLog:Section({ Side = "Left" })
local secSteps   = tabLog:Section({ Side = "Right" })

local statusPara, logPara, stepsPara

local function describe(s)
    local cost = s.cost and ("$" .. s.cost) or "$?"
    if s.k == "place" then
        return ("Place %s (%s)"):format(s.label or "unit", cost)
    end
    return ("Upgrade %s to Lv %s (%s)"):format(s.label or "unit", tostring(s.level or "?"), cost)
end

local function status()
    local places, ups = 0, 0
    for _, s in ipairs(M.steps) do
        if s.k == "place" then places += 1 else ups += 1 end
    end
    local state = M.recording and "RECORDING"
        or (M.finalizing and "Finishing...")
        or (M.playing and "PLAYING")
        or (M.armed and "ARMED (waiting for game start)")
        or "Idle"
    local lines = { ("State: %s"):format(state), ("Placements: %d   Upgrades: %d"):format(places, ups) }
    if M.playing and M.waitText then table.insert(lines, M.waitText) end
    if #M.log > 0 then table.insert(lines, "Last: " .. M.log[#M.log]) end
    if statusPara then statusPara:UpdateBody(table.concat(lines, "\n")) end
end

local function refreshSteps()
    if not stepsPara then return end
    if #M.steps == 0 then stepsPara:UpdateBody("No steps yet.") return end
    local lines = {}
    for i, s in ipairs(M.steps) do
        if i > 30 then table.insert(lines, ("... +%d more"):format(#M.steps - 30)) break end
        table.insert(lines, ("%d. %s"):format(i, describe(s)))
    end
    stepsPara:UpdateBody(table.concat(lines, "\n"))
end

local function addLog(text)
    table.insert(M.log, text)
    while #M.log > 14 do table.remove(M.log, 1) end
    if logPara then logPara:UpdateBody(table.concat(M.log, "\n")) end
    status()
end

local function removeStep(step)
    for i, s in ipairs(M.steps) do
        if s == step then table.remove(M.steps, i) return end
    end
end

---------------------------------------------------------------------------
-- Unit tracking while recording: match each new unit model to its placement
---------------------------------------------------------------------------
local function ensureUnitWatch()
    local f = unitsFolder()
    if f == M.unitFolder then return end
    if M.unitConn then M.unitConn:Disconnect() M.unitConn = nil end
    M.unitFolder = f
    if f then
        M.unitConn = f.ChildAdded:Connect(function(child)
            -- only real unit models (guid-named); ignore stray Parts and effects
            if child:IsA("Model") and child.Name:match(GUID_PAT) then
                M.newUnits[#M.newUnits + 1] = { inst = child, t = os.clock() }
            end
        end)
    end
end

local function onUnitMatched(place, guid)
    M.guidToPid[guid] = place.pid
    local step = place.step
    local uid = place.uid
    M.numById[uid] = (M.numById[uid] or 0) + 1
    step.label = ("%s #%d"):format(unitName(uid), M.numById[uid])
    M.labelByPid[place.pid] = step.label
    M.confirmed[guid] = 0
    step.pending = nil
    task.spawn(function()
        local e
        for _ = 1, 6 do
            local placed = getPlaced()
            e = placed and placed[guid]
            if e then break end
            task.wait(0.3)
        end
        if e then
            step.cost = tonumber(e.UnitData and e.UnitData.costToPlace)
            M.confirmed[guid] = tonumber(e.Upgrade) or 0
        end
        refreshSteps()
        addLog(step.label .. " placed" .. (step.cost and (" ($" .. step.cost .. ")") or ""))
    end)
end

local function processNewUnits()
    if #M.newUnits == 0 then return end
    local keep = {}
    for _, nu in ipairs(M.newUnits) do
        local inst = nu.inst
        local age = os.clock() - nu.t
        local done = false
        if not inst.Parent then
            done = true
        elseif M.recording or M.finalizing then
            local pos = unitPos(inst)
            if pos or age > 0.5 then
                local i = pickPlacement(M.places, pos)
                if i then
                    onUnitMatched(table.remove(M.places, i), inst.Name)
                    done = true
                end
            end
        else
            done = true
        end
        if not done and age < 6 then table.insert(keep, nu) end
    end
    M.newUnits = keep
end

---------------------------------------------------------------------------
-- Recording (placements + upgrades only)
---------------------------------------------------------------------------
-- One worker per unit. Waits until presses on that unit stop AND the server level stops
-- changing, then reconciles the queued presses against the real level.
local function reconcileUnit(guid, placed)
    local list = M.pendingUp[guid] or {}
    M.pendingUp[guid] = nil
    local e = placed and placed[guid]
    local lv = e and tonumber(e.Upgrade)
    local conf = M.confirmed[guid] or 0
    if not lv then
        for _, step in ipairs(list) do step.pending = nil end   -- server unreachable: keep as-is
        return
    end
    local applied = math.max(0, lv - conf)
    for i, step in ipairs(list) do
        if i <= applied then
            conf += 1
            step.level = conf
            step.cost = upgradeCostFor(e, conf)
            step.pending = nil
            addLog(("%s upgraded to Lv %d%s"):format(step.label or "unit", conf,
                step.cost and (" ($" .. step.cost .. ")") or ""))
        else
            removeStep(step)    -- server never applied this press (can't afford / max level)
        end
    end
    M.confirmed[guid] = conf
    refreshSteps()
end

function settleUnit(guid)
    if M.settling[guid] then return end
    M.settling[guid] = true
    task.spawn(function()
        local lastLevel, stableSince, placed = nil, os.clock(), nil
        while true do
            task.wait(0.4)
            placed = getPlaced()
            local e = placed and placed[guid]
            local lv = e and tonumber(e.Upgrade)
            if lv ~= lastLevel then lastLevel, stableSince = lv, os.clock() end
            local quiet  = os.clock() - (M.lastCall[guid] or 0) >= SETTLE_QUIET
            local stable = os.clock() - stableSince >= SETTLE_STABLE
            if quiet and stable then break end
        end
        reconcileUnit(guid, placed)
        M.settling[guid] = nil
        if M.pendingUp[guid] and #M.pendingUp[guid] > 0 then settleUnit(guid) end
        status()
    end)
end

local function drainQueue()
    local q = M.queue
    if #q == 0 then return end
    M.queue = {}
    for _, item in ipairs(q) do
        local remote, packed = item[2], item[3]
        -- The hook is installed once per session and can't be swapped out. An older script
        -- version may have installed it, writing entries as { t, remote, method, packed }.
        if type(packed) == "string" then packed = item[4] end
        if type(packed) ~= "table" then continue end
        M.rawCaptured = (M.rawCaptured or 0) + 1
        local action = (type(packed[1]) == "string") and packed[1] or nil

        -- the game's own auto-upgrade loop fires UpgradeUnit(guid, true); not a user action
        local isAuto = (action == "UpgradeUnit" and packed[3] == true)
        if isAuto then M.autoIgnored += 1 end

        if action and RECORD_ACTIONS[action] and not isAuto then
            if action == "PlaceUnit" then
                M.nextPid += 1
                local cf = packed[3]
                local step = { k = "place", pid = M.nextPid, r = remotePath(remote), m = "FireServer", n = packed.n, pending = true }
                local args = {}
                for i = 1, packed.n do args[i] = enc(packed[i]) end
                step.a = args
                table.insert(M.steps, step)
                table.insert(M.places, {
                    pid = step.pid,
                    uid = packed[2],
                    pos = (typeof(cf) == "CFrame") and cf.Position or Vector3.zero,
                    step = step,
                })

            elseif action == "UpgradeUnit" and type(packed[2]) == "string" then
                local guid = packed[2]
                local pid = M.guidToPid[guid]
                if not pid then
                    M.unknownUpgrades = (M.unknownUpgrades or 0) + 1
                else
                    local step = {
                        k = "upgrade", pid = pid, label = M.labelByPid[pid],
                        r = remotePath(remote), m = "FireServer", n = packed.n, pending = true,
                    }
                    local args = {}
                    for i = 1, packed.n do args[i] = enc(packed[i]) end
                    step.a = args
                    table.insert(M.steps, step)

                    -- Don't judge this press alone. Queue it; once the unit's server level has
                    -- stopped changing, the first N queued presses (N = levels the server really
                    -- applied) are kept in order and the rest are dropped.
                    M.pendingUp[guid] = M.pendingUp[guid] or {}
                    table.insert(M.pendingUp[guid], step)
                    M.lastCall[guid] = os.clock()
                    settleUnit(guid)
                end
            end
        end
    end
    refreshSteps()
    status()
end

local hbConn = RunService.Heartbeat:Connect(function()
    if M.recording or M.finalizing then ensureUnitWatch() end
    if M.recording then drainQueue() end
    if M.recording or M.finalizing then processNewUnits() end
end)

local function startRecording()
    if M.playing then return notify("Stop playback first.") end
    if M.finalizing then return notify("Still finishing the last recording.") end
    M.steps = {}
    M.queue = {}
    M.places = {}
    M.guidToPid = {}
    M.labelByPid = {}
    M.numById = {}
    M.confirmed = {}
    M.pendingUp = {}
    M.lastCall = {}
    M.settling = {}
    M.newUnits = {}
    M.nextPid = 0
    M.autoIgnored = 0
    M.unknownUpgrades = 0
    M.rawCaptured = 0
    M.log = {}
    M.recording = true
    refreshSteps()
    addLog("Recording started")
    notify("Recording started. Place your units AFTER pressing F6.")
end

local saveMacro, recToggle, playToggle

local function stopRecording()
    if not M.recording then return end
    drainQueue()
    M.recording = false
    M.finalizing = true
    status()
    notify("Finishing up...", 2)
    task.spawn(function()
        -- wait for every unit's upgrade burst to settle and every placement to be matched
        local waited = 0
        repeat
            task.wait(0.25)
            waited += 0.25
        until (next(M.settling) == nil and #M.newUnits == 0 and #M.queue == 0) or waited > 15
        task.wait(0.5)
        drainQueue()
        local dropped = 0
        local kept = {}
        for _, s in ipairs(M.steps) do
            if s.k == "place" and s.pending then
                dropped += 1       -- placement that never produced a unit
            else
                s.pending = nil
                table.insert(kept, s)
            end
        end
        M.steps = kept
        M.places = {}
        M.finalizing = false
        refreshSteps()
        status()
        local msg = ("Recorded %d steps."):format(#M.steps)
        if dropped > 0 then msg ..= (" Dropped %d failed placements."):format(dropped) end
        if (M.unknownUpgrades or 0) > 0 then
            msg ..= (" Ignored %d upgrades of units placed before recording."):format(M.unknownUpgrades)
        end
        if M.autoIgnored > 0 then msg ..= (" Ignored %d auto-upgrade calls."):format(M.autoIgnored) end
        addLog(("Hook captured %d game calls"):format(M.rawCaptured or 0))
        addLog("Recording finished: " .. #M.steps .. " steps")
        notify(msg, 6)
        if #M.steps > 0 then saveMacro() end   -- toggling record off saves the macro
    end)
end

local function toggleRecording()
    if M.recording then stopRecording() else startRecording() end
end

---------------------------------------------------------------------------
-- Playback: exact order, exact unit, exact cost, server-verified, with retries
---------------------------------------------------------------------------
local function waitForMoney(cost, label)
    if not cost or cost <= 0 then M.waitText = nil return end
    while M.playing do
        local m = getMoney()
        if m >= cost then M.waitText = nil status() return end
        M.waitText = ("%s - Money required: %d (have %d)"):format(label, cost, m)
        status()
        task.wait(0.25)
    end
end

local function waitForMoneyIncrease(maxWait)
    local m0, t = getMoney(), os.clock()
    while M.playing and getMoney() <= m0 and os.clock() - t < maxWait do task.wait(0.1) end
end

local function fire(remote, step)
    local args = {}
    for i = 1, step.n do args[i] = dec(step.a[i]) end
    pcall(remote.FireServer, remote, unpack(args, 1, step.n))
end

local function knownSet(placed)
    local s = {}
    if placed then for guid in pairs(placed) do s[guid] = true end end
    return s
end

local function runPlace(step, remote)
    local label = step.label or "unit"
    local deadline = os.clock() + STEP_TIMEOUT
    local fails = 0
    while M.playing and os.clock() < deadline do
        waitForMoney(step.cost, "Next: place " .. label)
        if not M.playing then return false end

        local before = getPlaced()
        if not before then return false end
        local known = knownSet(before)
        for _, guid in pairs(M.replayMap) do known[guid] = true end
        local enoughMoney = (not step.cost) or getMoney() >= step.cost
        fire(remote, step)

        local t = os.clock()
        while M.playing and os.clock() - t < PLACE_VERIFY do
            task.wait(0.3)
            local placed = getPlaced()
            if placed then
                for guid in pairs(placed) do
                    if not known[guid] then
                        M.replayMap[step.pid] = guid
                        addLog(label .. " placed")
                        return true
                    end
                end
            end
        end

        if enoughMoney then
            fails += 1
            if fails >= MAX_FAILS then return false end
        end
        waitForMoneyIncrease(1.5)
    end
    return false
end

local function runUpgrade(step, remote)
    local label = step.label or "unit"
    local guid = M.replayMap[step.pid]
    if not guid then
        addLog(("Skipped upgrade: %s was never placed"):format(label))
        return false
    end

    local deadline = os.clock() + STEP_TIMEOUT
    local fails = 0
    while M.playing and os.clock() < deadline do
        -- already at (or past) the target level? then nothing to do
        local placed = getPlaced()
        local e = placed and placed[guid]
        local lv0 = e and tonumber(e.Upgrade)
        if lv0 and step.level and lv0 >= step.level then
            addLog(("%s already Lv %d"):format(label, lv0))
            return true
        end

        waitForMoney(step.cost, ("Next: %s to Lv %s"):format(label, tostring(step.level or "?")))
        if not M.playing then return false end

        local enoughMoney = (not step.cost) or getMoney() >= step.cost
        fire(remote, step)

        local t = os.clock()
        while M.playing and os.clock() - t < 3 do
            task.wait(0.3)
            local p2 = getPlaced()
            local e2 = p2 and p2[guid]
            local lv = e2 and tonumber(e2.Upgrade)
            if lv and lv0 and lv > lv0 then
                addLog(("%s upgraded to Lv %d"):format(label, lv))
                return true
            end
            if not (lv and lv0) then return true end  -- can't verify; assume applied
        end

        if enoughMoney then
            fails += 1
            if fails >= MAX_FAILS then return false end
        end
        waitForMoneyIncrease(1.5)
    end
    return false
end

local function stopPlayback()
    if not M.playing then return end
    M.playing = false
    M.waitText = nil
    addLog("Macro run stopped")
end

-- One run of the macro. Called by the game watcher when a game starts (or by "Run macro now").
local function runMacro()
    if M.playing or M.runBusy or M.recording or M.finalizing then return end
    if #M.steps == 0 then return notify("No macro loaded or recorded.") end
    if not getPlaced() then return notify("Can't reach the game's unit data. Are you in a match?") end
    M.playing = true
    M.runBusy = true
    M.log = {}
    addLog("Game started - macro running")
    task.spawn(function()
        M.replayMap = {}
        local skipped = 0
        for _, step in ipairs(M.steps) do
            if not M.playing then break end
            local remote = resolveRemote(step.r)
            local ok = false
            if remote then
                if step.k == "place" then ok = runPlace(step, remote)
                elseif step.k == "upgrade" then ok = runUpgrade(step, remote) end
            end
            if not ok and M.playing then
                skipped += 1
                addLog("Skipped: " .. describe(step))
            end
        end
        if M.playing then
            local msg = "Macro finished."
            if skipped > 0 then msg ..= (" Skipped %d steps that kept failing."):format(skipped) end
            addLog(msg)
            notify(msg, 5)
        end
        M.playing = false
        M.waitText = nil
        M.runBusy = false
        status()
    end)
end

---------------------------------------------------------------------------
-- Game watcher: auto vote start, auto replay, and "run macro only when the game starts".
-- Signals (from the game's own UI):
--   Main.SkipIntermission visible  -> pre-game vote is open
--   Main.Ending visible            -> win / lose screen
--   neither                        -> game in progress
---------------------------------------------------------------------------
local function guiVisible(name)
    local pg = Players.LocalPlayer:FindFirstChild("PlayerGui")
    local main = pg and pg:FindFirstChild("Main")
    local o = main and main:FindFirstChild(name)
    return (o and o:IsA("GuiObject") and o.Visible) or false
end

local function fireGame(...)
    local args = table.pack(...)
    pcall(function() Events.Game:FireServer(unpack(args, 1, args.n)) end)
end

-- The end-of-match reward pop-ups (gems, items, units) are the game's Main.View frame. It
-- shows one reward at a time and every mouse click moves to the next; Replay does nothing
-- useful until they are all gone.
local function rewardPopupOpen()
    return guiVisible("View")
end

-- Auto replay waits until every reward pop-up has been clicked through.
local function rewardsBlocking()
    return rewardPopupOpen()
end

task.spawn(function()
    local function phaseNow()
        if guiVisible("Ending") then return "ending" end
        if guiVisible("SkipIntermission") then return "intermission" end
        return "running"
    end
    local phase = phaseNow()
    -- if we load mid-game we do NOT start the macro; it waits for the next game start
    local startable = (phase ~= "running")
    local endSeen, lastVote, lastRetry = os.clock(), 0, 0

    while genv.__ATDMacro == M and M.alive do
        task.wait(0.4)
        local now = phaseNow()

        if now == "ending" then
            if phase ~= "ending" then endSeen = os.clock() end
            if M.playing then stopPlayback() end
            startable = true
            if M.autoReplay and not (M.recording or M.finalizing) and not rewardsBlocking()
                and os.clock() - endSeen >= 1.5 and os.clock() - lastRetry >= 6 then
                lastRetry = os.clock()
                addLog("Auto replay")
                fireGame("Retry")
            end
        elseif now == "intermission" then
            startable = true
            if M.autoVote and os.clock() - lastVote >= 2 then
                lastVote = os.clock()
                addLog("Auto vote start")
                fireGame("SkipIntermission")
            end
        else -- running
            if startable then
                startable = false
                if M.armed and not (M.recording or M.finalizing or M.playing or M.runBusy) then
                    task.delay(0.5, runMacro)
                end
            end
        end
        phase = now
    end
end)

---------------------------------------------------------------------------
-- Library (save / load)
---------------------------------------------------------------------------
local macroDropdown
local function listMacros()
    local out = {}
    local ok, files = pcall(listfiles, FOLDER)
    if ok then
        for _, f in ipairs(files) do
            local name = tostring(f):match("([^/\\]+)%.json$")
            if name then table.insert(out, name) end
        end
    end
    table.sort(out)
    return out
end

local function refreshDropdown()
    if not macroDropdown then return end
    macroDropdown:ClearOptions()
    local list = listMacros()
    if #list > 0 then macroDropdown:InsertOptions(list) end
end

function saveMacro()
    if M.recording or M.finalizing then return notify("Stop recording first.") end
    if #M.steps == 0 then return notify("Nothing to save.") end
    local name = M.macroName:gsub("[^%w_%-]", "")
    if name == "" then return notify("Enter a valid macro name.") end
    local ok, err = pcall(function()
        writefile(FOLDER .. "/" .. name .. ".json", HttpService:JSONEncode({ v = 4, steps = M.steps }))
    end)
    if ok then
        notify(("Saved '%s' (%d steps)."):format(name, #M.steps))
        refreshDropdown()
        -- select what we just saved, so a config saved now remembers (and autoloads) this macro
        M.selected = name
        if macroDropdown then pcall(function() macroDropdown:UpdateSelection(name) end) end
    else
        notify("Save failed: " .. tostring(err))
    end
end

local function loadMacro(name, quiet)
    name = name or M.selected
    if not name then return notify("Select a macro first.") end
    local ok, data = pcall(function()
        return HttpService:JSONDecode(readfile(FOLDER .. "/" .. name .. ".json"))
    end)
    if not ok or type(data) ~= "table" or type(data.steps) ~= "table" then
        return notify("Could not read macro '" .. tostring(name) .. "'.")
    end
    if (data.v or 1) < 4 then
        return notify("'" .. name .. "' is from an older version and can't be replayed. Please re-record it.", 7)
    end
    M.steps = data.steps
    refreshSteps()
    status()
    addLog(("Loaded '%s' (%d steps)"):format(name, #M.steps))
    if not quiet then notify(("Loaded '%s' (%d steps)."):format(name, #M.steps)) end
    return true
end

local function deleteMacro()
    if not M.selected then return notify("Select a macro first.") end
    local name = M.selected
    Window:Dialog({
        Title = "Delete macro",
        Description = ("Delete '%s'? This cannot be undone."):format(name),
        Buttons = {
            { Name = "Delete", Callback = function()
                pcall(delfile, FOLDER .. "/" .. name .. ".json")
                M.selected = nil
                refreshDropdown()
                notify("Deleted '" .. name .. "'.")
            end },
            { Name = "Cancel" },
        },
    })
end

---------------------------------------------------------------------------
-- Controls
---------------------------------------------------------------------------
secControl:Header({ Text = "Macro" })
statusPara = secControl:Paragraph({ Header = "Status", Body = "State: Idle\nPlacements: 0   Upgrades: 0" })

local function syncToggle(t, v)
    if t then pcall(function() t:UpdateState(v) end) end
end

local setArmed

local function setRecording(v)
    if v then
        if M.recording then return end
        if M.configLoading then
            -- a config must never start a recording on rejoin
            syncToggle(recToggle, false)
            return
        end
        if M.finalizing then
            notify("Still finishing the last recording.")
            syncToggle(recToggle, false)
            return
        end
        if M.armed then
            setArmed(false)
            syncToggle(playToggle, false)
        end
        if M.playing then stopPlayback() end
        startRecording()
        if not M.recording then syncToggle(recToggle, false) end
    else
        if M.recording then stopRecording() end   -- saves automatically when it finishes
    end
end

function setArmed(v)
    if v then
        if M.armed then return end
        if M.configLoading then
            -- a config is being applied: its saved macro isn't loaded yet. Remember the wish and
            -- let finishConfig arm once the macro is in (the toggle stays ON meanwhile).
            M.wantArm = true
            return
        end
        if M.recording or M.finalizing then
            notify("Stop recording first.")
            syncToggle(playToggle, false)
            return
        end
        if #M.steps == 0 then
            notify("Record or load a macro first.")
            syncToggle(playToggle, false)
            return
        end
        M.armed = true
        addLog("Macro armed - runs when the next game starts")
        notify("Macro armed. It runs when a game starts.")
    else
        if not M.armed then return end
        M.armed = false
        stopPlayback()
        addLog("Macro disarmed")
    end
    status()
end

recToggle = secControl:Toggle({
    Name = "Record macro (turn off to save)", Default = false, Callback = setRecording,
}, "RecordMacro")
recToggle.IgnoreConfig = true   -- never saved in configs: loading one must not start a recording
secControl:Keybind({
    Name = "Record hotkey", Default = Enum.KeyCode.F6,
    Callback = function()
        setRecording(not M.recording)
        syncToggle(recToggle, M.recording)
    end,
}, "RecordKey")

secControl:Divider()
playToggle = secControl:Toggle({
    Name = "Play macro (runs on game start)", Default = false, Callback = setArmed,
}, "PlayMacro")
secControl:Keybind({
    Name = "Play hotkey", Default = Enum.KeyCode.F7,
    Callback = function()
        setArmed(not M.armed)
        syncToggle(playToggle, M.armed)
    end,
}, "PlayKey")

secControl:Divider()
secControl:Header({ Text = "Automation" })
secControl:Toggle({
    Name = "Auto vote start game", Default = false,
    Callback = function(v) M.autoVote = v end,
}, "AutoVote")
secControl:Toggle({
    Name = "Auto replay game (win screen)", Default = false,
    Callback = function(v) M.autoReplay = v end,
}, "AutoReplay")
secControl:Toggle({
    Name = "Auto click reward pop-ups (end of match)", Default = true,
    Callback = function(v) M.autoDismiss = v end,
}, "AutoDismissRewards")
secControl:Button({
    Name = "Run macro now (testing)",
    Callback = function()
        if M.recording or M.finalizing then return notify("Stop recording first.") end
        runMacro()
    end,
})

secControl:Divider()
secControl:Button({
    Name = "Remove last step",
    Callback = function()
        if M.recording or M.finalizing or M.playing then return notify("Stop first.") end
        if #M.steps > 0 then table.remove(M.steps) refreshSteps() status() end
    end,
})
secControl:Button({
    Name = "Clear macro",
    Callback = function()
        if M.recording or M.finalizing or M.playing then return notify("Stop first.") end
        M.steps = {}
        refreshSteps()
        status()
    end,
})

secLibrary:Header({ Text = "Library" })
secLibrary:Input({
    Name = "Macro name",
    Placeholder = "my_macro",
    AcceptedCharacters = "All",
    Callback = function(txt) if txt ~= "" then M.macroName = txt end end,
}, "MacroName")

secLibrary:Divider()
macroDropdown = secLibrary:Dropdown({
    Name = "Saved macros",
    Search = true,
    Multi = false,
    Required = false,
    Options = listMacros(),
    Callback = function(v) M.selected = v end,
}, "SavedMacros")
secLibrary:Button({ Name = "Load selected", Callback = function() loadMacro() end })
secLibrary:Button({ Name = "Refresh list", Callback = refreshDropdown })
secLibrary:Button({ Name = "Delete selected", Callback = deleteMacro })

secLibrary:Divider()
secLibrary:Paragraph({
    Header = "How to use",
    Body = "Record: name the macro, turn on 'Record macro' BEFORE placing units, play normally, turn it off - it saves itself.\nPlay: load a macro, turn on 'Play macro'. It waits and runs the moment a game starts (after the vote). Combine with 'Auto vote start game' and 'Auto replay game' to loop hands-free.\nSee the 'Steps & Log' tab for live progress.",
})

secLog:Header({ Text = "Live log" })
logPara = secLog:Paragraph({ Header = "Events", Body = "Nothing yet." })
secSteps:Header({ Text = "Macro steps (exact order)" })
stepsPara = secSteps:Paragraph({ Header = "Steps", Body = "No steps yet." })

---------------------------------------------------------------------------
-- Joiners: pick gamemode / map / stage / difficulty, walk into a pod, configure it, start it.
-- Flow (verified in the lobby): touching a pod's Entrance makes the server fire
--   Events.Pod "Open", true, <pod folder>
-- then we send SetMap / SetStage / SetDifficulty and finally "Start". The server decides what
-- you may pick (locked stages are silently ignored), so we read the pod's label back to check.
---------------------------------------------------------------------------
local LocalPlayer = Players.LocalPlayer
local PodRemote   = Events:FindFirstChild("Pod")
local ResourcesMod
pcall(function() ResourcesMod = require(RS.Modules.Resources) end)

local JOIN_MODES = {
    { name = "Story",       pod = "Play",        filter = function(d) return d.MapType == "Story" and d.Section == "Play" end },
    { name = "Raid",        pod = "Raid",        filter = function(d) return d.MapType == "Raid" end },
    { name = "Cavern",      pod = "Cavern",      filter = function(d) return d.MapType == "Cavern" end },
    { name = "Garden Maze", pod = "Garden Maze", filter = function(d) return d.MapType == "Garden Maze" end },
}
local JOIN_BY_NAME, JOIN_NAMES = {}, {}
for _, m in ipairs(JOIN_MODES) do
    JOIN_BY_NAME[m.name] = m
    table.insert(JOIN_NAMES, m.name)
end

local J = {
    mode = "Story", map = nil, stage = nil, diff = nil,
    autoStart = false, auto = false, busy = false, nextTry = 0,
}
M.join = J

local function mapDataOf(id)
    if not (ResourcesMod and id) then return nil end
    local ok, d = pcall(function() return ResourcesMod.Maps:GetMapData(id) end)
    return ok and d or nil
end

local function mapsForMode(mode)
    local rows = {}
    if not ResourcesMod then return rows end
    local ok, all = pcall(function() return ResourcesMod.Maps:GetMaps() end)
    if not ok or type(all) ~= "table" then return rows end
    for id, d in pairs(all) do
        if mode.filter(d) then table.insert(rows, { id = id, order = d.Order or 99 }) end
    end
    table.sort(rows, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.id < b.id
    end)
    local names = {}
    for _, r in ipairs(rows) do table.insert(names, r.id) end
    return names
end

local function countOf(t)
    if type(t) ~= "table" then return 0 end
    local n = #t
    if n > 0 then return n end
    for _ in pairs(t) do n += 1 end
    return n
end

local function stageLabels(mapId)
    local d = mapDataOf(mapId)
    local out = {}
    if not d then return out end
    local n = d.CustomStages and countOf(d.CustomStages) or countOf(d.Stages)
    for i = 1, n do
        local custom = d.CustomStages and d.CustomStages[i]
        table.insert(out, custom and ("Stage %d (%s)"):format(i, tostring(custom)) or ("Stage %d"):format(i))
    end
    if d.HasInfiniteMode then table.insert(out, "Infinite") end
    return out
end

local function stageValue(label)
    if not label then return nil end
    if label == "Infinite" then return "Infinite" end
    return tonumber(label:match("^Stage (%d+)"))
end

local function difficultiesFor(mapId)
    local d = mapDataOf(mapId)
    local out = {}
    if d and type(d.Difficulties) == "table" then
        for _, v in ipairs(d.Difficulties) do table.insert(out, v) end
    end
    return out
end

local joinStatus, ddMode, ddMap, ddStage, ddDiff

local function jStatus(text)
    J.lastStatus = text
    if joinStatus then pcall(function() joinStatus:UpdateBody(text) end) end
end

local function setOptions(dd, list, pick)
    if not dd then return end
    pcall(function() dd:ClearOptions() end)
    if #list > 0 then pcall(function() dd:InsertOptions(list) end) end
    if pick then pcall(function() dd:UpdateSelection(pick) end) end
end

local refreshStagesAndDiffs
local function refreshMaps()
    local list = mapsForMode(JOIN_BY_NAME[J.mode])
    J.map = list[1]
    setOptions(ddMap, list, J.map)
    refreshStagesAndDiffs()
end

function refreshStagesAndDiffs()
    local stages = stageLabels(J.map)
    J.stage = stages[1]
    setOptions(ddStage, stages, J.stage)
    local diffs = difficultiesFor(J.map)
    J.diff = diffs[1]
    setOptions(ddDiff, diffs, J.diff)
end

local function inLobby()
    if not ResourcesMod then return false end
    local ok, place = pcall(function() return ResourcesMod.IsCurrentPlace() end)
    return ok and place == "Lobby"
end

local function podUiOpen()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local main = pg and pg:FindFirstChild("Main")
    local ui = main and main:FindFirstChild("Pod")
    return (ui and ui:IsA("GuiObject") and ui.Visible) or false
end

local function podRemote(...)
    local args = table.pack(...)
    pcall(function() PodRemote:FireServer(unpack(args, 1, args.n)) end)
end

-- touch a pod's Entrance and wait for the server to open it for us
local function tryEnter(pod)
    local opened = false
    local conn = PodRemote.OnClientEvent:Connect(function(act, _, inst)
        if act == "Open" and inst == pod then opened = true end
    end)
    local char = LocalPlayer.Character
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    local ent  = pod:FindFirstChild("Entrance")
    if hrp and ent then
        pcall(firetouchinterest, hrp, ent, 1)
        task.wait(0.15)
        pcall(firetouchinterest, hrp, ent, 0)
        local t = os.clock()
        while not opened and os.clock() - t < 2 do task.wait(0.1) end
    end
    conn:Disconnect()
    return opened
end

-- pod label looks like "Desert Town - 1 (1/4)"
local function readPodLabel(pod)
    local label = pod:GetAttribute("TextLabel")
    if type(label) ~= "string" then return nil end
    local map, stage = label:match("^(.-) %- (.-) %(%d+/%d+%)$")
    return map, stage
end

local function joinSelected(startNow)
    if J.busy then return notify("Already joining...") end
    if M.recording or M.finalizing then return notify("Stop recording first.") end
    if not PodRemote then return notify("Pod remote not found.") end
    if not inLobby() then return notify("Joiners only work in the lobby.") end
    local mode = JOIN_BY_NAME[J.mode]
    if not mode then return notify("Pick a gamemode.") end
    local stage = stageValue(J.stage)
    if not J.map or stage == nil then return notify("Pick a map and a stage.") end
    local diffs = difficultiesFor(J.map)
    local diff = (#diffs > 0) and (J.diff or diffs[1]) or nil

    J.busy = true
    task.spawn(function()
        local ok, err = pcall(function()
            if podUiOpen() then
                podRemote("Leave")
                task.wait(0.7)
            end

            local pods = {}
            for _, p in ipairs(workspace:WaitForChild("Pods"):GetChildren()) do
                if p.Name == mode.pod and p:FindFirstChild("Entrance") then table.insert(pods, p) end
            end
            if #pods == 0 then
                jStatus("No '" .. mode.pod .. "' pods found.")
                return
            end

            local pod
            for i, p in ipairs(pods) do
                jStatus(("Entering %s pod %d/%d..."):format(mode.name, i, #pods))
                if tryEnter(p) then pod = p break end
            end
            if not pod then
                jStatus("No pod would open (all full or locked?).")
                notify("Could not enter any " .. mode.name .. " pod.")
                return
            end

            podRemote("SetMap", J.map)
            task.wait(0.35)
            podRemote("SetStage", stage)
            task.wait(0.35)
            if diff then
                podRemote("SetDifficulty", diff)
                task.wait(0.35)
                podRemote("SetStage", stage)   -- the game re-selects the stage after a difficulty change
                task.wait(0.5)
            end

            -- the server ignores locked picks, so confirm what the pod really holds
            local gotMap, gotStage = readPodLabel(pod)
            if gotMap and (gotMap ~= (mapDataOf(J.map) and mapDataOf(J.map).DisplayName or J.map)
                or tostring(gotStage) ~= tostring(stage)) then
                podRemote("Leave")
                local msg = ("Server kept %s - %s (you asked for %s - %s). Locked? Not started."):format(
                    tostring(gotMap), tostring(gotStage), J.map, tostring(stage))
                jStatus(msg)
                notify(msg, 6)
                J.nextTry = os.clock() + 15
                return
            end

            local desc = ("%s: %s, %s%s"):format(mode.name, J.map, tostring(J.stage), diff and (", " .. diff) or "")
            if startNow then
                podRemote("Start")
                jStatus("Started " .. desc)
                notify("Started " .. desc)
            else
                jStatus("Ready in pod: " .. desc .. " (press Start in the pod UI)")
                notify("Joined pod: " .. desc)
            end
        end)
        if not ok then
            jStatus("Join error: " .. tostring(err))
            J.nextTry = os.clock() + 15
        end
        J.busy = false
    end)
end

M.joinSelected = joinSelected

local secJoinPick = tabJoiners:Section({ Side = "Left" })
local secJoinRun  = tabJoiners:Section({ Side = "Right" })

secJoinPick:Header({ Text = "Pick what to join" })
ddMode = secJoinPick:Dropdown({
    Name = "Gamemode", Search = false, Multi = false, Required = true,
    Options = JOIN_NAMES, Default = 1,
    Callback = function(v)
        if v and v ~= J.mode and JOIN_BY_NAME[v] then
            J.mode = v
            refreshMaps()
        end
    end,
}, "JoinMode")
ddMap = secJoinPick:Dropdown({
    Name = "Map", Search = true, Multi = false, Required = false,
    Options = {},
    Callback = function(v)
        if v and v ~= J.map then
            J.map = v
            refreshStagesAndDiffs()
        end
    end,
}, "JoinMap")
ddStage = secJoinPick:Dropdown({
    Name = "Stage", Search = false, Multi = false, Required = false,
    Options = {},
    Callback = function(v) if v then J.stage = v end end,
}, "JoinStage")
ddDiff = secJoinPick:Dropdown({
    Name = "Difficulty", Search = false, Multi = false, Required = false,
    Options = {},
    Callback = function(v) if v then J.diff = v end end,
}, "JoinDifficulty")

secJoinRun:Header({ Text = "Join" })
joinStatus = secJoinRun:Paragraph({ Header = "Status", Body = "Idle. Pick a gamemode, map, stage and difficulty." })
secJoinRun:Toggle({
    Name = "Start the match after joining", Default = false,
    Callback = function(v) J.autoStart = v end,
}, "JoinAutoStart")
secJoinRun:Button({
    Name = "Join selected",
    Callback = function() joinSelected(J.autoStart) end,
})
secJoinRun:Toggle({
    Name = "Auto join (while in the lobby)", Default = false,
    Callback = function(v) J.auto = v end,
}, "JoinAuto")
secJoinRun:Button({
    Name = "Leave current pod",
    Callback = function() podRemote("Leave") end,
})
secJoinRun:Divider()
secJoinRun:Paragraph({
    Header = "Notes",
    Body = "Works from the lobby only. It walks your character into a real pod, so the game's own unlock rules still apply: if you have not unlocked a stage or difficulty the server refuses it, and this tab leaves the pod and tells you instead of starting the wrong stage.",
})

task.spawn(function()
    while genv.__ATDMacro == M and M.alive do
        task.wait(3)
        if J.auto and not J.busy and os.clock() >= J.nextTry
            and not (M.recording or M.finalizing) and inLobby() and not podUiOpen() then
            joinSelected(true)
        end
    end
end)

refreshMaps()

---------------------------------------------------------------------------
-- Portal: replay a chosen portal + tier from the end screen.
-- Portals are inventory items (data.Inventory[key] = { id, tier, amount }, item category
-- "Portal"). On a portal match's end screen the game's own list sends
--   Events.Game:FireServer("Retry", <inventory key>)
-- so that is exactly what we send. This is separate from the "Auto replay game" toggle.
---------------------------------------------------------------------------
local P = { name = nil, tier = nil, auto = false, lastFire = 0 }
M.portal = P

local function dataController()
    local ok, dc = pcall(function()
        return require(RS.Modules.Packages.Knit).GetController("DataController")
    end)
    return ok and dc or nil
end

-- every portal you own: { key, id, name, tier, amount }
local function ownedPortals()
    local out = {}
    local dc  = dataController()
    local inv = dc and dc.data and dc.data.Inventory
    if type(inv) ~= "table" or not ResourcesMod then return out end
    for key, entry in pairs(inv) do
        if type(entry) == "table" and entry.id ~= nil then
            local ok, name, def = pcall(ResourcesMod.GetItem, entry.id)
            if ok and type(def) == "table" and def.category == "Portal" then
                table.insert(out, {
                    key = key, id = entry.id, name = tostring(name),
                    tier = tonumber(entry.tier) or 0, amount = tonumber(entry.amount) or 1,
                })
            end
        end
    end
    table.sort(out, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        return a.tier < b.tier
    end)
    return out
end

-- Every portal the game defines (not just the ones you hold), so the picks never depend on
-- how many you own: playing a portal uses it up, and a win hands one back at the same tier or
-- higher, so we resolve the actual item at replay time.
-- The true top tier comes from the game's own portal definition: `tierCap` (a win only
-- upgrades a portal while its tier is below the cap). Portals with no tierCap have no cap in
-- the game's code, so for those the highest tier you actually hold is the real ceiling.
local PORTAL_TIER_MIN = 0
local allPortalNamesCache
local portalCapByName = {}    -- name -> tierCap (only for capped portals)
local function allPortalNames()
    if allPortalNamesCache then return allPortalNamesCache end
    local names, seen = {}, {}
    if ResourcesMod then
        for id = 5000, 5100 do
            local ok, name, def = pcall(ResourcesMod.GetItem, id)
            if ok and type(def) == "table" and def.category == "Portal" and not seen[name] then
                seen[name] = true
                table.insert(names, tostring(name))
                if tonumber(def.tierCap) then portalCapByName[tostring(name)] = tonumber(def.tierCap) end
            end
        end
    end
    allPortalNamesCache = names
    return names
end

-- highest tier you can pick for this portal: its tierCap, else the best tier you hold
local function maxTierFor(name, list)
    allPortalNames()
    local cap = portalCapByName[name]
    if cap then return cap, true end
    local best = PORTAL_TIER_MIN
    for _, p in ipairs(list or {}) do
        if p.name == name and p.tier > best then best = p.tier end
    end
    return best, false
end

local function portalNames(list)
    local names, seen = {}, {}
    for _, n in ipairs(allPortalNames()) do
        if not seen[n] then seen[n] = true table.insert(names, n) end
    end
    for _, p in ipairs(list) do
        if not seen[p.name] then seen[p.name] = true table.insert(names, p.name) end
    end
    table.sort(names)
    return names
end

local function tierLabelFor(t) return "Tier " .. t end

local function tierOptions(name, list)
    local out = {}
    local maxT = maxTierFor(name, list)
    for t = PORTAL_TIER_MIN, maxT do table.insert(out, tierLabelFor(t)) end
    return out
end

local portalStatus, ddPortal, ddTier, portalOwnedPara

local function pStatus(text)
    if portalStatus then pcall(function() portalStatus:UpdateBody(text) end) end
end

-- rebuild the Tier dropdown for the current portal, keeping the pick when it is still valid
local function refreshTierOptions(list)
    list = list or ownedPortals()
    local maxT = maxTierFor(P.name, list)
    if P.tier == nil then
        local best
        for _, p in ipairs(list) do
            if p.name == P.name and (not best or p.tier > best) then best = p.tier end
        end
        P.tier = best or 0
    end
    P.tier = math.clamp(P.tier, PORTAL_TIER_MIN, maxT)
    setOptions(ddTier, tierOptions(P.name, list), tierLabelFor(P.tier))
end

-- one line per portal, tiers collapsed: "Heaven Portal (best Tier 2): T0 x1, T1 x19, T2 x1"
local function ownedSummary(list)
    local order, byName = {}, {}
    for _, p in ipairs(list) do
        local g = byName[p.name]
        if not g then g = { name = p.name, tiers = {} } byName[p.name] = g table.insert(order, g) end
        g.tiers[p.tier] = (g.tiers[p.tier] or 0) + p.amount
    end
    local lines = {}
    for _, g in ipairs(order) do
        local ts = {}
        for t in pairs(g.tiers) do table.insert(ts, t) end
        table.sort(ts)
        local parts = {}
        for _, t in ipairs(ts) do table.insert(parts, ("T%d x%d"):format(t, g.tiers[t])) end
        local maxT, capped = maxTierFor(g.name, list)
        table.insert(lines, ("%s (%s Tier %d): %s"):format(g.name, capped and "max" or "best", maxT, table.concat(parts, ", ")))
    end
    return lines
end

local lastOwnedSig
local function refreshPortals()
    local list  = ownedPortals()
    local names = portalNames(list)
    if not (P.name and table.find(names, P.name)) then
        P.name = (list[1] and list[1].name) or names[1]
    end
    setOptions(ddPortal, names, P.name)
    refreshTierOptions(list)

    local lines = ownedSummary(list)
    if portalOwnedPara then
        pcall(function()
            portalOwnedPara:UpdateBody(#lines > 0 and table.concat(lines, "\n") or "No portals in your inventory.")
        end)
    end
    local sig = {}
    for _, p in ipairs(list) do table.insert(sig, p.name .. ":" .. p.tier .. ":" .. p.amount) end
    lastOwnedSig = table.concat(sig, "|")
end

-- the key of a portal we own right now matching the picked name + tier
local function pickedPortalKey()
    for _, p in ipairs(ownedPortals()) do
        if p.name == P.name and p.tier == P.tier then return p.key, p end
    end
    return nil
end

local function endScreenHasPortal(key)
    local pg   = LocalPlayer:FindFirstChild("PlayerGui")
    local main = pg and pg:FindFirstChild("Main")
    local list = main and main:FindFirstChild("Ending") and main.Ending:FindFirstChild("Portals")
    list = list and list:FindFirstChild("List")
    return (list and list:FindFirstChild(tostring(key))) ~= nil
end

local function replayPickedPortal(fromAuto)
    if not (P.name and P.tier ~= nil) then
        if not fromAuto then notify("Pick a portal and tier first.") end
        return false
    end
    local key, p = pickedPortalKey()
    if not key then
        pStatus(("Waiting: you do not hold %s Tier %d right now."):format(tostring(P.name), P.tier))
        if not fromAuto then notify(("You don't hold %s Tier %d right now."):format(tostring(P.name), P.tier)) end
        return false
    end
    if rewardPopupOpen() then
        if not fromAuto then notify("Click through the reward pop-ups first.") end
        return false
    end
    if not guiVisible("Ending") then
        if not fromAuto then notify("Finish a portal match first - this replays from the end screen.") end
        return false
    end
    if not endScreenHasPortal(key) then
        if not fromAuto then notify("The end screen is not offering portals (not a portal match).") end
        return false
    end
    fireGame("Retry", key)
    P.lastFire = os.clock()
    local msg = ("Replaying %s - Tier %d"):format(p.name, p.tier)
    pStatus(msg)
    addLog(msg)
    return true
end

---------------------------------------------------------------------------
-- Portal joiner (lobby): open the picked portal from your inventory, wait X seconds (so
-- friends can hop in), then start it.
--   ItemService.RF.UsePortal(<inventory key>)   what the inventory "Use" button calls
--   PodService.RF.StartPortal()                 what the portal's Start button calls
---------------------------------------------------------------------------
local PJ = { auto = false, busy = false, nextTry = 0, cancel = false, delay = 10 }
M.portalJoin = PJ

local function svcRemote(service, kind, name)
    local s = Knit:FindFirstChild(service)
    local k = s and s:FindFirstChild(kind)
    return k and k:FindFirstChild(name) or nil
end

local joinStatus2, delaySlider
local function jStat(text)
    PJ.lastStatus = text
    if joinStatus2 then pcall(function() joinStatus2:UpdateBody(text) end) end
end

local function joinDelay()
    local v = delaySlider and tonumber(delaySlider.Value)   -- .Value is always current, even after a config load
    return math.floor((v or PJ.delay) + 0.5)
end

local function runPortalJoiner(fromAuto)
    if PJ.busy then return end
    if M.recording or M.finalizing then return end
    if not inLobby() then
        if not fromAuto then notify("The portal joiner only works in the lobby.") end
        return
    end
    local key, p = pickedPortalKey()
    if not key then
        jStat(("Waiting: you do not hold %s Tier %d right now."):format(tostring(P.name), P.tier or 0))
        if not fromAuto then notify(("You don't hold %s Tier %d right now."):format(tostring(P.name), P.tier or 0)) end
        PJ.nextTry = os.clock() + 10
        return
    end
    local use   = svcRemote("ItemService", "RF", "UsePortal")
    local start = svcRemote("PodService", "RF", "StartPortal")
    if not (use and start) then
        jStat("Portal remotes not found (ItemService.UsePortal / PodService.StartPortal).")
        PJ.nextTry = os.clock() + 30
        return
    end

    PJ.busy, PJ.cancel = true, false
    task.spawn(function()
        local ok, err = pcall(function()
            local desc = ("%s - Tier %d"):format(p.name, p.tier)
            local okUse, res = pcall(function() return use:InvokeServer(key) end)
            if not okUse then error("UsePortal failed: " .. tostring(res)) end
            addLog("Opened portal: " .. desc)

            local waitFor = joinDelay()
            for left = waitFor, 1, -1 do
                if PJ.cancel or not M.alive then jStat("Cancelled.") return end
                jStat(("Opened %s. Starting in %ds..."):format(desc, left))
                task.wait(1)
            end
            if PJ.cancel or not M.alive then jStat("Cancelled.") return end

            local okStart, res2 = pcall(function() return start:InvokeServer() end)
            if not okStart then error("StartPortal failed: " .. tostring(res2)) end
            jStat("Started " .. desc)
            addLog("Started portal: " .. desc)
            notify("Started " .. desc)
        end)
        if not ok then
            jStat("Portal joiner error: " .. tostring(err))
            PJ.nextTry = os.clock() + 20
        else
            PJ.nextTry = os.clock() + 25   -- the match is loading; don't re-open while teleporting
        end
        PJ.busy = false
    end)
end
M.runPortalJoiner = runPortalJoiner

local secPortalPick = tabPortal:Section({ Side = "Left" })
local secPortalRun  = tabPortal:Section({ Side = "Right" })

secPortalPick:Header({ Text = "Portal" })
ddPortal = secPortalPick:Dropdown({
    Name = "Portal", Search = true, Multi = false, Required = false,
    Options = {},
    Callback = function(v)
        if v and v ~= P.name then
            P.name = v
            refreshTierOptions()      -- each portal has its own top tier
        end
    end,
}, "PortalName")
ddTier = secPortalPick:Dropdown({
    Name = "Tier", Search = false, Multi = false, Required = false,
    Options = {},
    Callback = function(v)
        if v then P.tier = tonumber(v:match("^Tier (%d+)")) end
    end,
}, "PortalTier")
secPortalPick:Button({ Name = "Refresh my portals", Callback = refreshPortals })
portalOwnedPara = secPortalPick:Paragraph({ Header = "Your portals", Body = "..." })

secPortalRun:Header({ Text = "Replay" })
portalStatus = secPortalRun:Paragraph({ Header = "Status", Body = "Pick a portal and tier." })
secPortalRun:Button({
    Name = "Replay selected portal now",
    Callback = function() replayPickedPortal(false) end,
})
local portalAutoToggle = secPortalRun:Toggle({
    Name = "Auto replay selected portal (end screen)", Default = false,
    Callback = function(v) P.auto = v end,
}, "PortalAutoReplay")

secPortalRun:Divider()
secPortalRun:Header({ Text = "Portal joiner (lobby)" })
joinStatus2 = secPortalRun:Paragraph({ Header = "Joiner status", Body = "Idle." })
delaySlider = secPortalRun:Slider({
    Name = "Wait before joining (seconds)", Default = 10, Minimum = 0, Maximum = 120, Precision = 0,
    DisplayMethod = "Value",
    Callback = function(v) PJ.delay = v end,
}, "PortalJoinDelay")
secPortalRun:Button({
    Name = "Open & join selected portal now",
    Callback = function() runPortalJoiner(false) end,
})
secPortalRun:Button({
    Name = "Cancel joiner",
    Callback = function() PJ.cancel = true end,
})
secPortalRun:Toggle({
    Name = "Auto portal joiner (while in the lobby)", Default = false,
    Callback = function(v) PJ.auto = v if not v then PJ.cancel = true end end,
}, "PortalJoinAuto")
secPortalRun:Divider()
secPortalRun:Paragraph({
    Header = "Notes",
    Body = "Replays from the end screen of a portal match, using the portal and tier you pick here. The pick does not depend on how many you hold: whichever portal of that tier you have at the end screen is the one replayed (a win gives you one back at the same tier or higher). If you hold none of that exact tier it just says so and waits. Independent of 'Auto replay game' on the Macro tab.",
})

task.spawn(function()
    local endSince
    while genv.__ATDMacro == M and M.alive do
        task.wait(0.5)
        if guiVisible("Ending") then
            endSince = endSince or os.clock()
            if P.auto and not (M.recording or M.finalizing) and not rewardsBlocking()
                and os.clock() - endSince >= 1.5 and os.clock() - P.lastFire >= 6 then
                local key = pickedPortalKey()
                if not key then
                    -- nothing of that tier right now (e.g. the win gave a higher one): say so, keep waiting
                    P.lastFire = os.clock() - 3
                    pStatus(("Waiting: you do not hold %s Tier %d right now."):format(tostring(P.name), P.tier or 0))
                elseif endScreenHasPortal(key) then
                    replayPickedPortal(true)
                end
            end
        else
            endSince = nil
        end
    end
end)

M.replayPortal = replayPickedPortal
pcall(refreshPortals)

-- keep the owned list / max tiers current (a win hands out a higher tier) and drive the joiner
task.spawn(function()
    while genv.__ATDMacro == M and M.alive do
        task.wait(3)
        local list = ownedPortals()
        local sig = {}
        for _, p in ipairs(list) do table.insert(sig, p.name .. ":" .. p.tier .. ":" .. p.amount) end
        if table.concat(sig, "|") ~= lastOwnedSig and not M.configLoading then pcall(refreshPortals) end
        if PJ.auto and not PJ.busy and os.clock() >= PJ.nextTry and not M.configLoading
            and not (M.recording or M.finalizing) and inLobby() and not podUiOpen() then
            runPortalJoiner(true)
        end
    end
end)

-- Reward pop-up clicker. While a pop-up is open the game keeps a UserInputService.InputBegan
-- handler that moves to the next reward on a left click. We find that handler in memory and
-- call it directly with a fake click, so no real or simulated mouse is needed: it works with
-- the window unfocused, the screen off, or on another desktop. A simulated mouse click is only
-- a backup if the handler cannot be found or the pop-up stops moving. Only in a match: in the
-- lobby the same frame is used for viewing your own units, which we leave alone.
local UIS = game:GetService("UserInputService")
local VIM = game:GetService("VirtualInputManager")

local function popupView()
    local pg   = LocalPlayer:FindFirstChild("PlayerGui")
    local main = pg and pg:FindFirstChild("Main")
    return main and main:FindFirstChild("View")
end

-- the handler holds a "skip" function, and skip holds the Main.View frame
local function findPopupHandler()
    local view = popupView()
    if not view or not filtergc then return nil end
    local ok, found = pcall(filtergc, "function", { Upvalues = { UIS } }, false)
    if not ok or type(found) ~= "table" then return nil end
    for _, f in ipairs(found) do
        local okU, ups = pcall(debug.getupvalues, f)
        if okU and type(ups) == "table" then
            for _, v in pairs(ups) do
                if type(v) == "function" then
                    local ok2, inner = pcall(debug.getupvalues, v)
                    if ok2 and type(inner) == "table" then
                        for _, x in pairs(inner) do
                            if x == view then return f end
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function callPopupHandler()
    local h = findPopupHandler()
    if not h then return false end
    return (pcall(h, { UserInputType = Enum.UserInputType.MouseButton1, KeyCode = Enum.KeyCode.Unknown }, false))
end
local function clickScreen()
    local cam = workspace.CurrentCamera
    local vp  = cam and cam.ViewportSize or Vector2.new(1280, 720)
    pcall(function()
        VIM:SendMouseButtonEvent(vp.X * 0.5, vp.Y * 0.5, 0, true, game, 1)
        task.wait(0.05)
        VIM:SendMouseButtonEvent(vp.X * 0.5, vp.Y * 0.5, 0, false, game, 1)
    end)
end

task.spawn(function()
    local lastSig
    while genv.__ATDMacro == M and M.alive do
        task.wait(0.45)
        local open = rewardPopupOpen()
        -- remember when the pop-up last changed (shown, or moved on to the next reward)
        local pg   = LocalPlayer:FindFirstChild("PlayerGui")
        local view = pg and pg:FindFirstChild("Main") and pg.Main:FindFirstChild("View")
        local unit = view and view:FindFirstChild("Unit")
        local sig  = open and (unit and unit.Text or "?") or nil
        if sig ~= lastSig then
            lastSig = sig
            M.popupChangedAt = os.clock()
        end
        if M.autoDismiss and open and not inLobby()
            and not (M.recording or M.finalizing) then
            local viaHandler = callPopupHandler()
            M.popupMode = viaHandler and "handler" or "mouse"
            -- backup: handler missing, or the pop-up has not moved for a while
            if not viaHandler or os.clock() - (M.popupChangedAt or os.clock()) > 2 then
                clickScreen()
            end
        end
    end
end)

---------------------------------------------------------------------------
-- Configs
-- MacLib applies a config by firing every saved element at once, in no particular order, and it
-- skips toggles that were saved OFF. That broke three things, so we finish the job ourselves
-- after it has run (for the autoload on rejoin AND for the manual "Load Config" button):
--   * dependent dropdowns (gamemode -> map -> stage -> difficulty, portal -> tier) are re-applied in order
--   * toggles saved OFF are really switched off (otherwise a default-ON toggle could never stay off)
--   * the saved macro is loaded, and only THEN is "Play macro" armed
---------------------------------------------------------------------------
local CFG_ORDER = { "JoinMode", "JoinMap", "JoinStage", "JoinDifficulty", "PortalName", "PortalTier" }
local CFG_SKIP  = { RecordMacro = true }

MacLib:SetFolder("ATD_Macro_Config")
tabSettings:InsertConfigSection("Left")

local function readConfig(name)
    local ok, data = pcall(function()
        return HttpService:JSONDecode(readfile(MacLib.Folder .. "/settings/" .. name .. ".json"))
    end)
    local saved = {}
    if ok and type(data) == "table" and type(data.objects) == "table" then
        for _, o in ipairs(data.objects) do
            if type(o) == "table" and o.flag then saved[o.flag] = o end
        end
    end
    return saved
end

local function finishConfig(name)
    local saved = readConfig(name)

    for _, flag in ipairs(CFG_ORDER) do
        local o, opt = saved[flag], MacLib.Options[flag]
        if o and opt and o.value then
            pcall(function() opt:UpdateSelection(o.value) end)
            task.wait(0.2)
        end
    end

    for flag, o in pairs(saved) do
        if o.type == "Toggle" and o.state == false and not CFG_SKIP[flag] then
            local opt = MacLib.Options[flag]
            if opt and opt.GetState and opt:GetState() then
                pcall(function() opt:UpdateState(false) end)
            end
        end
    end

    -- the macro stored in this config
    local macroName = saved.SavedMacros and saved.SavedMacros.value
    if type(macroName) ~= "string" or macroName == "" then macroName = M.selected end
    if macroName and not (M.recording or M.finalizing or M.playing) then
        M.selected = macroName
        loadMacro(macroName, true)
    end

    M.configLoading = false
    if M.wantArm then
        M.wantArm = false
        if not M.armed then
            setArmed(true)     -- macro is loaded now; this keeps the toggle on instead of bouncing it off
        end
    end
    status()
end

do
    local origLoadConfig = MacLib.LoadConfig
    function MacLib:LoadConfig(path)
        M.configLoading = true
        local ok, err = origLoadConfig(self, path)
        if ok == true and path then
            task.spawn(function()
                task.wait(0.8)       -- MacLib applies each saved element in its own thread
                local okF, errF = pcall(finishConfig, path)
                M.configLoading = false
                if not okF then notify("Config finish error: " .. tostring(errF), 6) end
            end)
        else
            M.configLoading = false
        end
        return ok, err
    end
end

---------------------------------------------------------------------------
-- Cleanup
---------------------------------------------------------------------------
function M.destroy()
    M.alive = false
    M.armed = false
    M.recording = false
    M.finalizing = false
    M.playing = false
    pcall(function() hbConn:Disconnect() end)
    pcall(function() if M.unitConn then M.unitConn:Disconnect() end end)
    pcall(function() Window:Unload() end)
end

Window.onUnloaded(function()
    M.alive = false
    M.armed = false
    M.recording = false
    M.finalizing = false
    M.playing = false
    pcall(function() hbConn:Disconnect() end)
    pcall(function() if M.unitConn then M.unitConn:Disconnect() end end)
end)

tabMacro:Select()
status()
notify("Loaded v6. F6 = record on/off, F7 = play on/off.")

-- apply the autoload config now that every element exists (this is what makes the selected
-- config actually load on rejoin; finishConfig then runs through the LoadConfig wrapper)
task.spawn(function()
    task.wait(0.5)
    if genv.__ATDMacro ~= M or not M.alive then return end
    local ok, err = pcall(function() MacLib:LoadAutoLoadConfig() end)
    if not ok then notify("Autoload failed: " .. tostring(err), 6) end
end)
