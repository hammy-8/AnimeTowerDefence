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
            if M.autoReplay and not (M.recording or M.finalizing)
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
    else
        notify("Save failed: " .. tostring(err))
    end
end

local function loadMacro(name)
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
    notify(("Loaded '%s' (%d steps)."):format(name, #M.steps))
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

MacLib:SetFolder("ATD_Macro_Config")
tabSettings:InsertConfigSection("Left")

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
notify("Loaded v5. F6 = record on/off, F7 = play on/off.")
