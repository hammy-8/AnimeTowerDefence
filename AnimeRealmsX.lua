
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService   = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")
local StarterGui        = game:GetService("StarterGui")
local HttpService       = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui   = LocalPlayer:WaitForChild("PlayerGui", 20)

-- Clean up any prior running instances
if PlayerGui:FindFirstChild("ARX_MacroGUI") then
    PlayerGui.ARX_MacroGUI:Destroy()
end
if PlayerGui:FindFirstChild("ARX_AutoGUI") then
    PlayerGui.ARX_AutoGUI:Destroy()
end


local Loader = require(ReplicatedStorage:WaitForChild("Framework"):WaitForChild("Loader"))
local EndpointsClient = Loader.load_client_service(nil, "EndpointsClient")

local function invokeEndpoint(endpointName, ...)
    if EndpointsClient and EndpointsClient.invoke_server then
        return EndpointsClient.invoke_server(endpointName, ...)
    end
    return nil
end

-- ══════════════════════════════════════════════════════════════════════════
--  STATE & CONFIGURATION
-- ══════════════════════════════════════════════════════════════════════════
local CONFIG = {
    delay_after_match     = 4.0,     -- wait time on victory/defeat before restarting
    step_delay            = 0.1,     -- seconds to wait after every macro action (slider: 0.1 - 2.0)
    macro_folder          = "ARX_Macros", -- folder inside the executor's workspace folder
    max_matches           = 0,       -- 0 = infinite
    session_limit_mins    = 0,       -- 0 = infinite
    
    key_replay            = Enum.KeyCode.F1,
    key_pause             = Enum.KeyCode.F2,
    key_stop              = Enum.KeyCode.F3,
    key_record            = Enum.KeyCode.F4,
}

local State = {
    mode             = "IDLE", -- "IDLE" | "RECORDING" | "REPLAYING"
    paused           = false,
    session_start    = 0,
    matches_done     = 0,
    wins             = 0,
    losses           = 0,
    current_wave     = 0,
    current_money    = 0,
    active_step      = 0,
    total_steps      = 0,
    waiting_status   = "",
    log_entries      = {},
}

-- Macro list: array of action objects
local CurrentMacro = {}
local ActiveMacroName = nil -- name of the macro file currently selected / being recorded into

-- ══════════════════════════════════════════════════════════════════════════
-- LOGGING & UTILITIES
-- ══════════════════════════════════════════════════════════════════════════
local MAX_LOGS = 100

local logSink = nil -- assigned by the UI once the Log tab exists

local function addLog(msg, colorType)
    local ts = os.date("%H:%M:%S")
    local entry = {
        time = ts,
        text = "[" .. ts .. "] " .. tostring(msg),
        color = colorType or "normal"
    }
    table.insert(State.log_entries, entry)
    if #State.log_entries > MAX_LOGS then
        table.remove(State.log_entries, 1)
    end
    if logSink then pcall(logSink, entry.text, entry.color) end
end

local function getPlayerMoney()
    local stats = LocalPlayer:FindFirstChild("_stats")
    local res = stats and stats:FindFirstChild("resource")
    return res and res.Value or 0
end

local function getWaveNumber()
    local wv = workspace:FindFirstChild("_wave_num")
    if wv and wv:IsA("NumberValue") then
        return wv.Value
    end
    local wavesGui = PlayerGui:FindFirstChild("Waves")
    if wavesGui then
        local num = wavesGui:FindFirstChild("HealthBar") and wavesGui.HealthBar:FindFirstChild("WaveNumber")
        if num and tonumber(num.Text) then
            return tonumber(num.Text)
        end
    end
    return 0
end

local function getUnitUuid(unitModel)
    if not unitModel then return nil end
    local stats = unitModel:FindFirstChild("_stats")
    if stats then
        return stats:GetAttribute("uuid")
    end
    return unitModel:GetAttribute("uuid")
end

-- Strictly returns ONLY player-placed units, sorted in chronological spawn order
local function getPlayerUnitsOnField()
    local list = {}
    local folder = workspace:FindFirstChild("_UNITS")
    if folder then
        for _, u in ipairs(folder:GetChildren()) do
            -- Filter out PVE enemies completely
            if not u.Name:lower():find("^pve") then
                table.insert(list, u)
            end
        end
    end
    -- Sort strictly by chronological placement order (_SPAWN_UNIT_UUID)
    table.sort(list, function(a, b)
        local idA = tonumber(a:GetAttribute("_SPAWN_UNIT_UUID")) or 0
        local idB = tonumber(b:GetAttribute("_SPAWN_UNIT_UUID")) or 0
        return idA < idB
    end)
    return list
end

local function getSlotUuid(slotNum)
    local su = PlayerGui:FindFirstChild("spawn_units")
    if not su then return nil end
    local frame = su:FindFirstChild("Lives") and su.Lives:FindFirstChild("Frame") and su.Lives.Frame:FindFirstChild("Units")
    if frame then
        local btn = frame:FindFirstChild(tostring(slotNum))
        if btn then
            return btn:GetAttribute("_unit_uuid")
        end
    end
    return nil
end

local function getSlotCost(slotNum)
    local su = PlayerGui:FindFirstChild("spawn_units")
    if not su then return 0 end
    local frame = su:FindFirstChild("Lives") and su.Lives:FindFirstChild("Frame") and su.Lives.Frame:FindFirstChild("Units")
    if frame then
        local btn = frame:FindFirstChild(tostring(slotNum))
        if btn then
            local txt = btn:FindFirstChild("text")
            if txt and tonumber(txt.Text) then
                return tonumber(txt.Text)
            end
        end
    end
    return 0
end

local function findSlotByUuid(uuid)
    if not uuid then return nil end
    local su = PlayerGui:FindFirstChild("spawn_units")
    if not su then return nil end
    local frame = su:FindFirstChild("Lives") and su.Lives:FindFirstChild("Frame") and su.Lives.Frame:FindFirstChild("Units")
    if frame then
        for i = 1, 6 do
            local btn = frame:FindFirstChild(tostring(i))
            if btn and btn:GetAttribute("_unit_uuid") == uuid then
                return i
            end
        end
    end
    return nil
end

local function isMatchOver()
    local results = PlayerGui:FindFirstChild("ResultsUI")
    if not results or not results.Enabled then
        return false, nil
    end

    local holder = results:FindFirstChild("Holder")
    if holder and holder.Visible then
        local banner = holder:FindFirstChild("Banner") and holder.Banner:FindFirstChild("Title")
        local isWin = banner and string.find(string.upper(banner.Text), "VICTORY") ~= nil
        return true, isWin
    end

    local finished = results:FindFirstChild("Finished")
    if finished and finished.Visible then
        return true, true
    end

    return false, nil
end

local function clickGuiButton(btn)
    if not btn then return end
    pcall(function()
        if firesignal then
            firesignal(btn.MouseButton1Click)
            firesignal(btn.Activated)
        elseif btn.Activate then
            btn:Activate()
        end
    end)
end

local function formatClock(seconds)
    seconds = math.max(0, math.floor(seconds))
    local m = math.floor(seconds / 60)
    local s = seconds % 60
    return string.format("%02d:%02d", m, s)
end

-- ══════════════════════════════════════════════════════════════════════════
--  SECTION 5: SAFE RECORDING HOOK (ENDPOINTSCLIENT)
-- ══════════════════════════════════════════════════════════════════════════
local originalInvokeServer = EndpointsClient.invoke_server

EndpointsClient.invoke_server = function(remoteName, ...)
    local args = {...}

    if State.mode == "RECORDING" and not checkcaller() then
        local moneyBefore = getPlayerMoney()
        local result = originalInvokeServer(remoteName, unpack(args))
        
        pcall(function()
            task.wait(0.05)
            local moneyAfter = getPlayerMoney()
            local diffCost = math.max(0, moneyBefore - moneyAfter)

            if remoteName == "spawn_unit" and result ~= false then
                local uuid = args[1]
                local rayDict = args[2]
                local rot = args[3] or 0
                local slotNum = findSlotByUuid(uuid) or 1
                local slotCost = getSlotCost(slotNum)
                local finalCost = diffCost > 0 and diffCost or slotCost

                local origX, origY, origZ = 0, 0, 0
                local dirX, dirY, dirZ = 0, -1, 0
                if rayDict and rayDict.Origin then
                    origX, origY, origZ = rayDict.Origin.X, rayDict.Origin.Y, rayDict.Origin.Z
                end
                if rayDict and rayDict.Direction then
                    dirX, dirY, dirZ = rayDict.Direction.X, rayDict.Direction.Y, rayDict.Direction.Z
                end

                local action = {
                    type      = "SPAWN",
                    slot      = slotNum,
                    cost      = finalCost,
                    rotation  = rot,
                    origin    = {x = origX, y = origY, z = origZ},
                    direction = {x = dirX, y = dirY, z = dirZ},
                }
                table.insert(CurrentMacro, action)
                addLog("RECORDED: Spawn Slot " .. slotNum .. " (Cost: " .. finalCost .. "¥)", "action")

            elseif remoteName == "upgrade_unit_ingame" and result ~= false then
                local targetUuid = args[1]
                -- Match against player units ONLY
                local playerUnits = getPlayerUnitsOnField()
                local targetIdx = 1
                for idx, u in ipairs(playerUnits) do
                    if getUnitUuid(u) == targetUuid or u.Name == targetUuid then
                        targetIdx = idx
                        break
                    end
                end

                local action = {
                    type       = "UPGRADE",
                    unit_index = targetIdx,
                    cost       = diffCost,
                }
                table.insert(CurrentMacro, action)
                addLog("RECORDED: Upgrade Unit #" .. targetIdx .. " (Cost: " .. diffCost .. "¥)", "action")

            elseif remoteName == "sell_unit_ingame" and result ~= false then
                local targetUuid = args[1]
                local playerUnits = getPlayerUnitsOnField()
                local targetIdx = 1
                for idx, u in ipairs(playerUnits) do
                    if getUnitUuid(u) == targetUuid or u.Name == targetUuid then
                        targetIdx = idx
                        break
                    end
                end

                local action = {
                    type       = "SELL",
                    unit_index = targetIdx,
                }
                table.insert(CurrentMacro, action)
                addLog("RECORDED: Sell Unit #" .. targetIdx, "action")

            elseif remoteName == "cycle_priority" and result ~= false then
                local targetUuid = args[1]
                local playerUnits = getPlayerUnitsOnField()
                local targetIdx = 1
                for idx, u in ipairs(playerUnits) do
                    if getUnitUuid(u) == targetUuid or u.Name == targetUuid then
                        targetIdx = idx
                        break
                    end
                end

                local action = {
                    type       = "PRIORITY",
                    unit_index = targetIdx,
                }
                table.insert(CurrentMacro, action)
                addLog("RECORDED: Priority Unit #" .. targetIdx, "action")

            elseif remoteName == "vote_wave_skip" then
                local action = {
                    type = "SKIP",
                    wave = getWaveNumber(),
                }
                table.insert(CurrentMacro, action)
                addLog("RECORDED: Skip Wave " .. action.wave, "action")
            end
        end)

        return result
    end

    return originalInvokeServer(remoteName, unpack(args))
end

-- ══════════════════════════════════════════════════════════════════════════
--  SECTION 5.5: MACRO FILES (saved in the executor WORKSPACE folder)
--  Path: <workspace>/ARX_Macros/<name>.json
-- ══════════════════════════════════════════════════════════════════════════
local fsOK = type(writefile) == "function" and type(readfile) == "function"
    and type(isfolder) == "function" and type(makefolder) == "function"
    and type(isfile) == "function" and type(listfiles) == "function"

-- UI hook (assigned later once the dropdown exists)
local refreshMacroDropdown = function() end
local notifyHook = function() end

local function sanitizeMacroName(raw)
    local s = tostring(raw or "")
    s = (s:gsub("[^%w _%-]", ""))
    s = (s:gsub("^%s+", ""))
    s = (s:gsub("%s+$", ""))
    return s:sub(1, 40)
end

local function macroPath(name)
    return CONFIG.macro_folder .. "/" .. name .. ".json"
end

local function ensureMacroFolder()
    if not fsOK then return false end
    local ok = pcall(function()
        if not isfolder(CONFIG.macro_folder) then
            makefolder(CONFIG.macro_folder)
        end
    end)
    return ok
end

local function macroFileExists(name)
    if not fsOK then return false end
    local ok, res = pcall(isfile, macroPath(name))
    return ok and res == true
end

local function saveMacroFile(name)
    if not fsOK then
        addLog("Your executor has no file functions (writefile) - cannot save!", "warn")
        return false
    end
    ensureMacroFolder()
    local ok, err = pcall(function()
        writefile(macroPath(name), HttpService:JSONEncode(CurrentMacro))
    end)
    if ok then
        addLog("Saved " .. #CurrentMacro .. " actions -> workspace/" .. macroPath(name), "success")
        notifyHook("Macro saved", name .. " (" .. #CurrentMacro .. " actions)")
    else
        addLog("Failed to save macro '" .. name .. "': " .. tostring(err), "warn")
    end
    return ok
end

local function loadMacroFile(name)
    if not macroFileExists(name) then
        addLog("Macro file '" .. name .. "' not found!", "warn")
        return false
    end
    local ok, data = pcall(function()
        return HttpService:JSONDecode(readfile(macroPath(name)))
    end)
    if ok and type(data) == "table" then
        CurrentMacro = data
        addLog("Loaded macro '" .. name .. "' (" .. #CurrentMacro .. " actions)", "success")
        return true
    end
    addLog("Macro file '" .. name .. "' is corrupted / invalid JSON", "warn")
    return false
end

local function deleteMacroFile(name)
    if not macroFileExists(name) then return false end
    if type(delfile) ~= "function" then
        addLog("Your executor has no delfile - delete it manually from workspace/" .. CONFIG.macro_folder, "warn")
        return false
    end
    local ok = pcall(delfile, macroPath(name))
    if ok then addLog("Deleted macro '" .. name .. "'", "info") end
    return ok
end

local function listMacroNames()
    local names = {}
    if not fsOK then return names end
    ensureMacroFolder()
    local ok, files = pcall(listfiles, CONFIG.macro_folder)
    if ok and type(files) == "table" then
        for _, path in ipairs(files) do
            local n = tostring(path):match("([^/\\]+)%.json$")
            if n then table.insert(names, n) end
        end
    end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names
end

-- Called the moment a recording finishes: writes straight into the macro's file
local function autoSaveRecording()
    if #CurrentMacro == 0 then
        addLog("Recording captured 0 actions - nothing saved (existing file untouched).", "warn")
        return
    end
    if not ActiveMacroName then
        ActiveMacroName = "Macro_" .. os.date("%m%d_%H%M%S")
        addLog("No macro name was set - auto-named it '" .. ActiveMacroName .. "'", "info")
    end
    saveMacroFile(ActiveMacroName)
    refreshMacroDropdown()
end

-- ══════════════════════════════════════════════════════════════════════════
--  SECTION 6: RECORD CONTROLS
-- ══════════════════════════════════════════════════════════════════════════
local function startRecording(clearExisting)
    if State.mode == "REPLAYING" then
        addLog("Cannot record while replaying! Stop first.", "warn")
        return
    end
    if clearExisting ~= false then
        CurrentMacro = {}
    end
    State.mode = "RECORDING"
    addLog("RECORDING STARTED" .. (ActiveMacroName and (" -> '" .. ActiveMacroName .. "' (auto-saves when you stop)") or " (no macro name set; will auto-name)") .. ". Play normally!", "record")
end

local function stopRecording()
    if State.mode == "RECORDING" then
        State.mode = "IDLE"
        addLog("RECORDING STOPPED. Total actions captured: " .. #CurrentMacro, "success")
        autoSaveRecording()
    end
end

local function toggleRecording()
    if State.mode == "RECORDING" then
        stopRecording()
    else
        startRecording(true)
    end
end

-- ══════════════════════════════════════════════════════════════════════════
--  SECTION 7: MONEY-DRIVEN REPLAY ENGINE (NEVER SKIPS / NO HANG)
-- ══════════════════════════════════════════════════════════════════════════
local ReplayThread = nil

local function waitForPlayerUnitsCount(targetMinCount)
    local t0 = os.clock()
    while State.mode == "REPLAYING" and not isMatchOver() and (os.clock() - t0) < 4 do
        local units = getPlayerUnitsOnField()
        if #units >= targetMinCount then
            return units
        end
        task.wait(0.1)
    end
    return getPlayerUnitsOnField()
end

local function executeReplayActionMoney(action)
    if not action then return false end

    if action.type == "SPAWN" then
        local slotCost = action.cost or 0
        local preCount = #getPlayerUnitsOnField()
        
        while State.mode == "REPLAYING" and not isMatchOver() do
            if State.paused then
                task.wait(0.5)
            else
                local curMoney = getPlayerMoney()
                if slotCost > 0 and curMoney < slotCost then
                    State.waiting_status = "Waiting for " .. curMoney .. " / " .. slotCost .. "¥ (Slot " .. action.slot .. ")"
                    task.wait(0.3)
                else
                    local slotUuid = getSlotUuid(action.slot)
                    if not slotUuid then
                        State.waiting_status = "Waiting for slot " .. action.slot .. " uuid..."
                        task.wait(0.5)
                    else
                        State.waiting_status = "Placing Slot " .. action.slot .. "..."
                        local rayDict = {
                            Origin    = Vector3.new(action.origin.x, action.origin.y, action.origin.z),
                            Direction = Vector3.new(action.direction.x, action.direction.y, action.direction.z)
                        }
                        
                        local success = false
                        pcall(function()
                            local res = invokeEndpoint("spawn_unit", slotUuid, rayDict, action.rotation or 0)
                            if res ~= false and res ~= nil then
                                success = true
                            end
                        end)

                        if success then
                            addLog("✔ Placed Slot " .. action.slot .. (slotCost > 0 and (" (-" .. slotCost .. "¥)") or ""), "success")
                            waitForPlayerUnitsCount(preCount + 1)
                            State.waiting_status = ""
                            return true
                        else
                            task.wait(0.5)
                        end
                    end
                end
            end
        end

    elseif action.type == "UPGRADE" then
        local upgCost = action.cost or 0
        local attempts = 0

        while State.mode == "REPLAYING" and not isMatchOver() do
            if State.paused then
                task.wait(0.5)
            else
                local curMoney = getPlayerMoney()
                if upgCost > 0 and curMoney < upgCost then
                    State.waiting_status = "Waiting for " .. curMoney .. " / " .. upgCost .. "¥ (Unit #" .. (action.unit_index or 1) .. " Upgrade)"
                    task.wait(0.3)
                else
                    local playerUnits = getPlayerUnitsOnField()
                    if #playerUnits == 0 then
                        State.waiting_status = "Waiting for placed units..."
                        task.wait(0.4)
                    else
                        -- Clamp target index so it NEVER gets stuck on phantom units (e.g. Unit #15)
                        local targetIdx = math.clamp(action.unit_index or 1, 1, #playerUnits)
                        local target = playerUnits[targetIdx]
                        local uuid = getUnitUuid(target)

                        if not uuid then
                            task.wait(0.4)
                        else
                            State.waiting_status = "Upgrading Unit #" .. targetIdx .. "..."
                            local success = false
                            pcall(function()
                                local res = invokeEndpoint("upgrade_unit_ingame", uuid)
                                if res ~= false and res ~= nil then
                                    success = true
                                end
                            end)

                            if success then
                                addLog("✔ Upgraded Unit #" .. targetIdx .. (upgCost > 0 and (" (-" .. upgCost .. "¥)") or ""), "success")
                                State.waiting_status = ""
                                return true
                            else
                                attempts = attempts + 1
                                if attempts >= 8 then
                                    addLog("⚠️ Unit #" .. targetIdx .. " upgrade skipped (already maxed / completed)", "warn")
                                    State.waiting_status = ""
                                    return true
                                end
                                task.wait(0.5)
                            end
                        end
                    end
                end
            end
        end

    elseif action.type == "SELL" then
        local playerUnits = getPlayerUnitsOnField()
        if #playerUnits > 0 then
            local targetIdx = math.clamp(action.unit_index or 1, 1, #playerUnits)
            local target = playerUnits[targetIdx]
            local uuid = getUnitUuid(target)
            if uuid then
                pcall(function() invokeEndpoint("sell_unit_ingame", uuid) end)
                addLog("✔ Sold Unit #" .. targetIdx, "success")
                return true
            end
        end

    elseif action.type == "PRIORITY" then
        local playerUnits = getPlayerUnitsOnField()
        if #playerUnits > 0 then
            local targetIdx = math.clamp(action.unit_index or 1, 1, #playerUnits)
            local target = playerUnits[targetIdx]
            local uuid = getUnitUuid(target)
            if uuid then
                pcall(function() invokeEndpoint("cycle_priority", uuid) end)
                addLog("✔ Cycled Priority on Unit #" .. targetIdx, "success")
                return true
            end
        end

    elseif action.type == "SKIP" then
        while State.mode == "REPLAYING" and not isMatchOver() do
            if getWaveNumber() >= (action.wave or 1) then
                pcall(function() invokeEndpoint("vote_wave_skip") end)
                addLog("✔ Voted Skip Wave " .. tostring(action.wave), "success")
                return true
            end
            task.wait(0.5)
        end
    end

    State.waiting_status = ""
    return false
end

local function runReplayLoop()
    addLog("REPLAY ENGINE STARTED (Money-Driven Mode)", "record")
    State.session_start = os.clock()

    while State.mode == "REPLAYING" do
        if CONFIG.session_limit_mins > 0 then
            local elapsedMins = (os.clock() - State.session_start) / 60
            if elapsedMins >= CONFIG.session_limit_mins then
                addLog("Session time limit reached. Stopping replay.", "warn")
                break
            end
        end

        if CONFIG.max_matches > 0 and State.matches_done >= CONFIG.max_matches then
            addLog("Reached match limit (" .. State.matches_done .. "). Stopping.", "success")
            break
        end

        local curWave = getWaveNumber()
        if curWave < 1 or isMatchOver() then
            task.wait(0.5)
            continue
        end

        addLog("Beginning match replay (" .. #CurrentMacro .. " actions queued)", "info")
        State.total_steps = #CurrentMacro
        State.active_step = 0

        for idx, action in ipairs(CurrentMacro) do
            if State.mode ~= "REPLAYING" or isMatchOver() then break end

            while State.paused and State.mode == "REPLAYING" do
                task.wait(0.5)
            end

            State.active_step = idx
            executeReplayActionMoney(action)

            -- user-configurable delay between macro steps
            if CONFIG.step_delay > 0 and State.mode == "REPLAYING" then
                State.waiting_status = string.format("Step delay (%.1fs)...", CONFIG.step_delay)
                task.wait(CONFIG.step_delay)
                State.waiting_status = ""
            end
        end

        State.waiting_status = "Macro complete! Waiting for game to end..."
        addLog("All macro actions executed! Awaiting match conclusion...", "info")

        while State.mode == "REPLAYING" do
            local over, isWin = isMatchOver()
            if over then
                State.matches_done = State.matches_done + 1
                if isWin then
                    State.wins = State.wins + 1
                    addLog("VICTORY! Total Wins: " .. State.wins, "success")
                else
                    State.losses = State.losses + 1
                    addLog("DEFEAT. Total Losses: " .. State.losses, "warn")
                end
                break
            end
            task.wait(0.5)
        end

        if State.mode ~= "REPLAYING" then break end

        task.wait(CONFIG.delay_after_match)
        if State.mode ~= "REPLAYING" then break end

        addLog("Sending Replay vote...", "info")
        pcall(function()
            invokeEndpoint("set_game_finished_vote", "retry")
        end)
        
        local resUi = PlayerGui:FindFirstChild("ResultsUI")
        if resUi and resUi:FindFirstChild("Finished") then
            local nextRetry = resUi.Finished:FindFirstChild("NextRetry")
            if nextRetry and nextRetry.Visible then
                clickGuiButton(nextRetry)
            end
        end

        local reloadTimeout = os.clock()
        while State.mode == "REPLAYING" and isMatchOver() and (os.clock() - reloadTimeout) < 15 do
            task.wait(0.5)
        end
        task.wait(2.0)
    end

    State.mode = "IDLE"
    State.waiting_status = ""
    addLog("Replay engine stopped.", "record")
end

local function startReplaying()
    if #CurrentMacro == 0 then
        addLog("Cannot replay: Current macro is empty! Record or import actions first.", "warn")
        return
    end
    if State.mode == "RECORDING" then
        stopRecording()
    end
    State.mode   = "REPLAYING"
    State.paused = false
    if ReplayThread then
        task.cancel(ReplayThread)
    end
    ReplayThread = task.spawn(runReplayLoop)
end

local function pauseReplay()
    if State.mode ~= "REPLAYING" then return end
    State.paused = not State.paused
    addLog(State.paused and "Replay PAUSED" or "Replay RESUMED", "record")
end

local function stopAll()
    State.mode   = "IDLE"
    State.paused = false
    State.waiting_status = ""
    if ReplayThread then
        task.cancel(ReplayThread)
        ReplayThread = nil
    end
    addLog("ALL AUTOMATION STOPPED", "record")
end

-- ══════════════════════════════════════════════════════════════════════════
--  SECTION 8: PRESET & SERIALIZATION SYSTEM
-- ══════════════════════════════════════════════════════════════════════════
local function exportMacroJson()
    local ok, json = pcall(function()
        return HttpService:JSONEncode(CurrentMacro)
    end)
    return ok and json or "[]"
end

local function importMacroJson(str)
    local ok, data = pcall(function()
        return HttpService:JSONDecode(str)
    end)
    if ok and type(data) == "table" then
        CurrentMacro = data
        addLog("Successfully imported " .. #CurrentMacro .. " actions from JSON", "success")
        return true
    else
        addLog("JSON parse error: Invalid macro structure", "warn")
        return false
    end
end

-- ══════════════════════════════════════════════════════════════════════════
--  SECTION 9: KEYBOARD CONTROLS
-- ══════════════════════════════════════════════════════════════════════════
UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == CONFIG.key_replay then
        startReplaying()
    elseif input.KeyCode == CONFIG.key_pause then
        pauseReplay()
    elseif input.KeyCode == CONFIG.key_stop then
        stopAll()
    elseif input.KeyCode == CONFIG.key_record then
        toggleRecording()
    end
end)

-- ══════════════════════════════════════════════════════════════════════════
--  SECTION 10: USER INTERFACE (RAYFIELD GEN2)
--  Docs: https://docs.sirius.menu/rayfield-gen2
-- ══════════════════════════════════════════════════════════════════════════
local genv = (type(getgenv) == "function" and getgenv()) or _G

-- Shut down any previous instance of this script (re-execution safe)
if genv.ARX_Stop then pcall(genv.ARX_Stop) end
if genv.ARX_Window then pcall(function() genv.ARX_Window:Unload() end) end

local okLoad, Rayfield = pcall(function()
    return loadstring(game:HttpGet("https://sirius.menu/gen2"))()
end)
if not okLoad or type(Rayfield) ~= "table" then
    warn("[ARX] Failed to load Rayfield Gen2: " .. tostring(Rayfield))
    return
end

local Window = Rayfield:CreateWindow({
    name          = "Anime Realms X",
    subtitle      = "Money-Driven Macro",
    sidebarLayout = true,
    theme         = "default",
    showName      = "ARX Macro",
})
genv.ARX_Window = Window
genv.ARX_Stop   = function() State.mode = "IDLE"; if ReplayThread then pcall(task.cancel, ReplayThread) end end

-- last-written cache so Text/Stat/Console only update when something changed
local lastValue = setmetatable({}, {__mode = "k"})
local function setText(el, str)
    if el and lastValue[el] ~= str then
        lastValue[el] = str
        el:Set(str)
    end
end

-- hooks used by the engine above
notifyHook = function(title, content)
    pcall(function() Window:Notify({ title = title, content = content, duration = 4 }) end)
end

local function describeAction(act)
    if act.type == "SPAWN" then
        return "SPAWN [Slot " .. tostring(act.slot) .. "] - Cost: " .. (act.cost or 0) .. "¥"
    elseif act.type == "UPGRADE" then
        return "UPGRADE [Unit #" .. tostring(act.unit_index) .. "] - Cost: " .. (act.cost or 0) .. "¥"
    elseif act.type == "SELL" then
        return "SELL [Unit #" .. tostring(act.unit_index) .. "]"
    elseif act.type == "PRIORITY" then
        return "PRIORITY [Unit #" .. tostring(act.unit_index) .. "]"
    elseif act.type == "SKIP" then
        return "SKIP WAVE " .. tostring(act.wave or "")
    end
    return tostring(act.type)
end

-- ──────────────────────────── TAB 1: MACRO ────────────────────────────────
local TabMacro = Window:CreateTab({ name = "Macro" })

local StatusText = TabMacro:CreateText({ name = "Status", text = "IDLE" })
local SummaryText = TabMacro:CreateText({ name = "Macro", text = "None selected | Actions: 0" })

local ControlRow = TabMacro:CreateGroup()
ControlRow:CreateButton({ name = "Record [F4]",  callback = toggleRecording })
ControlRow:CreateButton({ name = "Replay [F1]",  callback = startReplaying })
ControlRow:CreateButton({ name = "Pause [F2]",   callback = pauseReplay })
ControlRow:CreateButton({ name = "Stop [F3]",    callback = stopAll })

TabMacro:CreateButton({
    name = "Clear current macro",
    description = "Clears it from memory only. The saved file is untouched until you record or Save Now.",
    callback = function()
        if State.mode ~= "IDLE" then
            addLog("Stop recording/replaying before clearing.", "warn")
            return
        end
        CurrentMacro = {}
        addLog("Macro sequence cleared.", "info")
    end,
})

local ActionConsole = TabMacro:CreateConsole({
    name     = "Actions",
    height   = 260,
    follow   = false,
    maxLines = 500,
})

-- ─────────────────────────── TAB 2: PRESETS ───────────────────────────────
local TabPresets = Window:CreateTab({ name = "Presets" })

TabPresets:CreateSection({ name = "Create Macro" })

local NameInput = TabPresets:CreateInput({
    name        = "Macro name",
    description = "Type a name, press Create, then Record. It saves itself when you stop recording.",
    placeholder = "e.g. Easy Farm",
    forgetState = true,
})

TabPresets:CreateSection({ name = "My Macros" })

local MacroDropdown
local InfoText = TabPresets:CreateText({ name = "Selected", text = "None" })
local suppressDropdown = false

local function macrosLocked()
    if State.mode ~= "IDLE" then
        addLog("Stop recording/replaying before changing macros.", "warn")
        return true
    end
    return false
end

-- (re)build dropdown options from the files in workspace/ARX_Macros
refreshMacroDropdown = function()
    local names = listMacroNames()
    if MacroDropdown then
        suppressDropdown = true
        pcall(function() MacroDropdown:Refresh(names) end)
        if ActiveMacroName then
            pcall(function() MacroDropdown:Set(ActiveMacroName, true) end)
        end
        suppressDropdown = false
    end
    if not fsOK then
        setText(InfoText, "Executor has no file API - macros can't be saved to disk!")
    else
        setText(InfoText, (ActiveMacroName or "None") .. "  |  " .. #names ..
            " macro(s) in workspace/" .. CONFIG.macro_folder .. "/")
    end
end

local function selectMacro(name)
    if macrosLocked() then
        refreshMacroDropdown() -- snap dropdown back to the real selection
        return
    end
    if loadMacroFile(name) then
        ActiveMacroName = name
    end
    refreshMacroDropdown()
end

MacroDropdown = TabPresets:CreateDropdown({
    name        = "Macro list",
    description = "Pick a macro to load it.",
    options     = listMacroNames(),
    placeholder = "Select a macro...",
    forgetState = true,
    callback    = function(selected)
        if suppressDropdown then return end
        if type(selected) == "table" then selected = selected[1] end
        if type(selected) ~= "string" or selected == "" then return end
        if selected == ActiveMacroName then return end
        selectMacro(selected)
    end,
})

local function createMacro()
    if macrosLocked() then return end
    local name = sanitizeMacroName(NameInput.value)
    if name == "" then
        addLog("Type a macro name first (letters, numbers, spaces, - and _).", "warn")
        return
    end
    NameInput:Set("", true)
    if macroFileExists(name) then
        addLog("Macro '" .. name .. "' already exists - selected it. Recording will overwrite it.", "warn")
        selectMacro(name)
        return
    end
    CurrentMacro = {}
    ActiveMacroName = name
    if saveMacroFile(name) then
        addLog("Created macro '" .. name .. "'. Press RECORD [F4] - it auto-saves when you stop.", "success")
    end
    refreshMacroDropdown()
end

local MacroBtnRow = TabPresets:CreateGroup()
MacroBtnRow:CreateButton({ name = "Create", callback = createMacro })
MacroBtnRow:CreateButton({
    name = "Save Now",
    callback = function()
        if not ActiveMacroName then
            addLog("Select or create a macro first.", "warn")
            return
        end
        saveMacroFile(ActiveMacroName)
        refreshMacroDropdown()
    end,
})
MacroBtnRow:CreateButton({ name = "Refresh", callback = refreshMacroDropdown })
MacroBtnRow:CreateButton({
    name = "Delete",
    callback = function()
        if macrosLocked() then return end
        if not ActiveMacroName then
            addLog("Select a macro to delete first.", "warn")
            return
        end
        deleteMacroFile(ActiveMacroName)
        ActiveMacroName = nil
        refreshMacroDropdown()
    end,
})

TabPresets:CreateSection({ name = "Export / Import JSON" })

TabPresets:CreateButton({
    name = "Copy current macro JSON to clipboard",
    callback = function()
        local json = exportMacroJson()
        if type(setclipboard) == "function" then
            pcall(setclipboard, json)
            addLog("Copied " .. #CurrentMacro .. " actions to clipboard", "success")
        else
            addLog("Executor has no setclipboard. Macros are plain .json files in workspace/" .. CONFIG.macro_folder, "warn")
        end
    end,
})

local ImportInput
ImportInput = TabPresets:CreateInput({
    name        = "Import JSON",
    description = "Paste macro JSON and press Enter. Use Save Now afterwards to keep it.",
    placeholder = "[{\"type\":\"SPAWN\", ...}]",
    forgetState = true,
    callback    = function(text)
        if type(text) ~= "string" or text == "" then return end
        if macrosLocked() then return end
        importMacroJson(text)
        ImportInput:Set("", true)
    end,
})

-- ─────────────────────────── TAB 3: SETTINGS ──────────────────────────────
local TabSettings = Window:CreateTab({ name = "Settings" })

TabSettings:CreateSection({ name = "Step Delay" })
TabSettings:CreateSlider({
    name        = "Step delay",
    description = "Wait after every macro action during replay.",
    range       = { 0.1, 2.0 },
    increment   = 0.1,
    value       = CONFIG.step_delay,
    suffix      = "s",
    forgetState = true,
    callback    = function(value)
        CONFIG.step_delay = math.clamp(tonumber(value) or 0.1, 0.1, 2.0)
    end,
})

TabSettings:CreateSection({ name = "Replay Options" })
TabSettings:CreateText({ name = "Mode", text = "Money-Driven (No Skip)" })
TabSettings:CreateText({ name = "Post-Match Delay", text = CONFIG.delay_after_match .. "s" })
TabSettings:CreateText({ name = "Max Matches (0 = inf)", text = tostring(CONFIG.max_matches) })
TabSettings:CreateText({ name = "Session Limit (0 = inf)", text = tostring(CONFIG.session_limit_mins) })

TabSettings:CreateSection({ name = "Shortcuts" })
TabSettings:CreateText({
    name = "Hotkeys",
    text = "F1 - Start Replay\nF2 - Pause / Resume\nF3 - Stop\nF4 - Toggle Record",
})

TabSettings:CreateSection({ name = "Interface" })
TabSettings:CreateDropdown({
    name        = "Theme",
    options     = { "default", "cobalt", "ember", "amethyst", "frost", "rose" },
    value       = "default",
    forgetState = true,
    callback    = function(selected)
        if type(selected) == "table" then selected = selected[1] end
        if type(selected) == "string" and selected ~= "" then
            pcall(function() Window:ChangeTheme(selected) end)
        end
    end,
})
TabSettings:CreateButton({
    name = "Unload script",
    description = "Stops all automation and destroys this window.",
    callback = function()
        stopAll()
        Window:Unload()
    end,
})

-- ───────────────────────────── TAB 4: STATS ───────────────────────────────
local TabStats = Window:CreateTab({ name = "Stats" })

TabStats:CreateSection({ name = "Live Statistics" })
local StatGrid = TabStats:CreateGroup()
local StatWave    = StatGrid:CreateStat({ name = "Wave",    value = 0 })
local StatCash    = StatGrid:CreateStat({ name = "Cash",    value = 0, suffix = "¥" })
local StatMatches = StatGrid:CreateStat({ name = "Matches", value = 0 })
local StatWins    = StatGrid:CreateStat({ name = "Wins",    value = 0 })
local StatLosses  = StatGrid:CreateStat({ name = "Losses",  value = 0 })
local StatRate    = StatGrid:CreateStat({ name = "Win Rate", value = 0, suffix = "%" })

local StatMode     = TabStats:CreateText({ name = "Mode",           text = "IDLE" })
local StatProgress = TabStats:CreateText({ name = "Macro Progress", text = "No macro" })
local StatAction   = TabStats:CreateText({ name = "Current Action", text = "Normal" })
local StatRuntime  = TabStats:CreateText({ name = "Session Time",   text = "00:00" })

-- ────────────────────────────── TAB 5: LOG ────────────────────────────────
local TabLog = Window:CreateTab({ name = "Log" })

local LogConsole = TabLog:CreateConsole({
    name     = "Log",
    height   = 300,
    follow   = true,
    maxLines = MAX_LOGS,
})
TabLog:CreateButton({
    name = "Clear Logs",
    callback = function()
        State.log_entries = {}
        LogConsole:Clear()
    end,
})

local LOG_PREFIX = { warn = "[!] ", success = "[+] ", record = "[*] " }
logSink = function(text, colorType)
    LogConsole:Append((LOG_PREFIX[colorType] or "    ") .. text)
end
-- replay anything logged before the UI existed
for _, e in ipairs(State.log_entries) do
    logSink(e.text, e.color)
end

-- ══════════════════════════════════════════════════════════════════════════
--  SECTION 11: UI REFRESH LOOP (only touches elements whose value changed)
-- ══════════════════════════════════════════════════════════════════════════
local function setStat(stat, v)
    if stat and stat.value ~= v then stat:Set(v) end
end

local function updateUi()
    local wave  = getWaveNumber()
    local money = getPlayerMoney()
    State.current_wave  = wave
    State.current_money = money

    local modeText
    if State.mode == "RECORDING" then
        modeText = "RECORDING"
    elseif State.mode == "REPLAYING" then
        modeText = State.paused and "PAUSED" or "REPLAYING"
    else
        modeText = "IDLE"
    end

    local extra = State.waiting_status ~= "" and State.waiting_status or ("Cash: " .. tostring(money) .. "¥")
    setText(StatusText, string.format("%s | %s | Wave %s | Matches: %d (%dW/%dL)",
        modeText, extra, tostring(wave), State.matches_done, State.wins, State.losses))

    local total = #CurrentMacro
    setText(SummaryText, string.format("%s | Actions: %d | Step: %d/%d",
        ActiveMacroName or "No macro selected", total, State.active_step, total))

    -- action list
    local lines = {}
    for i, act in ipairs(CurrentMacro) do
        local marker = (State.mode == "REPLAYING" and State.active_step == i) and ">> " or "   "
        lines[#lines + 1] = marker .. string.format("[%02d] %s", i, describeAction(act))
    end
    local body = table.concat(lines, "\n")
    if lastValue[ActionConsole] ~= body then
        lastValue[ActionConsole] = body
        ActionConsole:Set(body)
    end

    -- stats tab
    local elapsed = State.session_start > 0 and (os.clock() - State.session_start) or 0
    local totalM  = State.wins + State.losses
    setStat(StatWave, wave)
    setStat(StatCash, money)
    setStat(StatMatches, State.matches_done)
    setStat(StatWins, State.wins)
    setStat(StatLosses, State.losses)
    setStat(StatRate, totalM > 0 and math.floor((State.wins / totalM) * 1000 + 0.5) / 10 or 0)
    setText(StatMode, modeText)
    setText(StatProgress, total > 0 and (State.active_step .. " / " .. total) or "No macro")
    setText(StatAction, State.waiting_status ~= "" and State.waiting_status or "Normal")
    setText(StatRuntime, formatClock(elapsed))
end

task.spawn(function()
    while not Window.unloaded do
        pcall(updateUi)
        task.wait(0.25)
    end
    stopAll()
end)

-- ══════════════════════════════════════════════════════════════════════════
--  SECTION 12: INITIALIZATION
-- ══════════════════════════════════════════════════════════════════════════
refreshMacroDropdown()

pcall(function()
    Window:Notify({
        title    = "ARX Macro System",
        content  = "Loaded! Create a macro in Presets, then press F4 to record.",
        duration = 6,
    })
end)

addLog("=================================================", "info")
addLog("ARX MONEY-DRIVEN MACRO ENGINE INITIALIZED", "success")
addLog("PVE enemy models filtered. Unit indexing strictly player-only.", "record")
addLog("Press F4 to record, F1 to replay.", "info")
addLog("=================================================", "info")
