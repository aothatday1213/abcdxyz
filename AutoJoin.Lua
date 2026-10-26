-- Auto Join (Story / Infinite / Legend / Challenge / Daily / Portal) - Fluent UI
-- Chạy ở LOBBY. Bỏ vào autoexec. Ưu tiên thông minh + tự rời trận khi có challenge mới + webhook Secret.

local Fluent           = loadstring(game:HttpGet("https://raw.githubusercontent.com/discoart/FluentPlus/refs/heads/main/Beta.lua"))()
local SaveManager      = loadstring(game:HttpGet("https://raw.githubusercontent.com/dawid-scripts/Fluent/master/Addons/SaveManager.lua"))()
local InterfaceManager = loadstring(game:HttpGet("https://raw.githubusercontent.com/dawid-scripts/Fluent/master/Addons/InterfaceManager.lua"))()

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local TS = game:GetService("TeleportService")
local lp = Players.LocalPlayer
local Options = Fluent.Options
local ct = RS:WaitForChild("endpoints"):WaitForChild("client_to_server")

---------------------------------------------------------------- DATA
local WORLDS = { Namek = "namek", Karakura = "karakura", Shibuya = "shibuya", Marineford = "marineford" }
local WORLD_NAMES = { "Namek", "Karakura", "Shibuya", "Marineford" }
local STORY_ACTS = { "1", "2", "3", "4", "5", "6" }
local LEGEND_ACTS = { "1", "2", "3" }
local DIFFS = { "Normal", "Hard", "Insane" }
local PODS = { "Auto" }
for i = 1, 11 do table.insert(PODS, "P" .. i) end
local CH_PODS = {}
for i = 1, 4 do table.insert(CH_PODS, "CH" .. i) end
local CH_MODS = {
    "high_cost", "short_range", "fast_enemies", "regen_enemies", "tank_enemies", "shield_enemies",
    "double_cost", "triple_cost", "hyper_regen_enemies", "hyper_shield_enemies",
    "godspeed_enemies", "flying_enemies", "mini_range",
}
local CH_DUR = 1800 -- GameplaySettings.CHALLENGE_DURATION
-- Thứ tự ưu tiên (mode nào bật Auto + đang có thể join thì lấy mode đầu tiên)
local PRIORITY = { "Daily", "Challenge", "Portal", "Legend", "Infinite", "Story" }

local function hasAny(set)
    for _, v in pairs(set or {}) do
        if v == true then return true end
    end
    return false
end

local function buildLevelId(mode, world, act)
    local w = WORLDS[world]
    if mode == "Story" then return w .. "_level_" .. act
    elseif mode == "Infinite" then return w .. "_infinite"
    else return "shibuya_legend_" .. act end
end

---------------------------------------------------------------- STATE (lưu file, sống qua teleport)
local FOLDER = "AutoJoinHub/anime-td"
local STATE_FILE = FOLDER .. "/state.json"

local function readState()
    if not (isfile and readfile) then return {} end
    local ok, d = pcall(function() return HttpService:JSONDecode(readfile(STATE_FILE)) end)
    return (ok and type(d) == "table") and d or {}
end
local function writeState(st)
    if not writefile then return end
    pcall(function()
        if makefolder and isfolder then
            if not isfolder("AutoJoinHub") then makefolder("AutoJoinHub") end
            if not isfolder(FOLDER) then makefolder(FOLDER) end
        end
        writefile(STATE_FILE, HttpService:JSONEncode(st))
    end)
end
local function mutate(fn)
    local st = readState()
    fn(st)
    writeState(st)
end
local function serverNow() return workspace:GetServerTimeNow() end
local function windowNow() return math.floor(serverNow() / CH_DUR) end
local busy = false
local cool = {} -- cool[mode] = os.clock() hết cooldown (mode lỗi thì nhường mode khác)

local function inLobby()
    local cfg = workspace:FindFirstChild("_MAP_CONFIG")
    local v = cfg and cfg:FindFirstChild("IsLobby")
    return v and v.Value == true
end

local rcache = {}
local function call(remote, ...)
    local args = table.pack(...)
    local r = rcache[remote] or ct:FindFirstChild(remote) or RS.endpoints:FindFirstChild(remote, true)
    if not r then return false, "no remote " .. remote end
    rcache[remote] = r
    return pcall(function() return r:InvokeServer(table.unpack(args, 1, args.n)) end)
end

local function podValue(pod, name)
    local v = pod:FindFirstChild(name)
    return v and v.Value
end

local function podFree(pod)
    local owner = pod:FindFirstChild("Owner")
    local plrs = pod:FindFirstChild("Players")
    local tele = pod:FindFirstChild("Teleporting")
    local lock = pod:FindFirstChild("Locked")
    if owner and owner:IsA("ObjectValue") and owner.Value ~= nil then return false end
    if plrs and #plrs:GetChildren() > 0 then return false end
    if tele and tele.Value == true then return false end
    if lock and lock.Value == true then return false end
    return true
end

local function sortedPods(root, pattern)
    local list = {}
    if not root then return list end
    for _, v in root:GetChildren() do
        if v.Name:match(pattern) then table.insert(list, v) end
    end
    table.sort(list, function(a, b)
        return tonumber(a.Name:match("%d+")) < tonumber(b.Name:match("%d+"))
    end)
    return list
end

local function findStoryPod(choice)
    local l = workspace:FindFirstChild("_LOBBIES")
    for _, v in sortedPods(l and l:FindFirstChild("Story"), "^P%d+$") do
        if (choice == "Auto" or v.Name == choice) and podFree(v) then return v end
    end
end

local function findChallengePod(match)
    local c = workspace:FindFirstChild("_CHALLENGES")
    for _, v in sortedPods(c and c:FindFirstChild("Challenges"), "^CH%d+$") do
        if podFree(v) and match(v) then return v end
    end
end

local function podAnchor(pod)
    local d = pod:FindFirstChild("Door") or pod:FindFirstChild("Teleport") or pod.PrimaryPart
    if d and d:IsA("BasePart") then return d end
    return pod:FindFirstChildWhichIsA("BasePart", true)
end

-- ---- Daily
local dCache, dAt, gcAt = nil, -1e9, -1e9
local function isD(t) return type(t) == "table" and rawget(t, "current_uuid") ~= nil end
local function dailyInfo(force)
    if not force and dCache and os.clock() - dAt < 15 then return dCache end
    local ok, info = call("get_daily_challenge")
    local got = (ok and isD(info)) and info or nil
    if not got and getgc and os.clock() - gcAt > 20 then
        gcAt = os.clock()
        pcall(function()
            for _, t in ipairs(getgc(true)) do
                if isD(t) and rawget(t, "current_level_id") ~= nil then got = t break end
            end
        end)
    end
    if got then dCache, dAt = got, os.clock() end
    return dCache
end

-- session._stats.last_completed_daily_challenge_uuid (theo ChallengeServiceClient)
local KEY_DONE = "last_completed_daily_challenge_uuid"
local statsRef, scanAt = nil, -1e9
local function lastDailyDone()
    if statsRef then return rawget(statsRef, KEY_DONE) end
    if getgc and os.clock() - scanAt > 30 then
        scanAt = os.clock()
        pcall(function()
            for _, t in ipairs(getgc(true)) do
                if type(t) == "table" and rawget(t, KEY_DONE) ~= nil then statsRef = t break end
            end
        end)
        if statsRef then return rawget(statsRef, KEY_DONE) end
    end
end

local function dailyDone(uuid)
    uuid = tostring(uuid)
    local d = lastDailyDone()
    if d ~= nil and tostring(d) == uuid then return true end
    local st = readState()
    local n = (st.dtry and st.dtry[uuid]) or 0
    -- đọc được stats: cho thử tối đa 3 lần; không đọc được: thử 1 lần/ngày
    return n >= ((d ~= nil) and 3 or 1)
end

-- ---- Challenge
local function chKey(p) return tostring(podValue(p, "Level")) .. "|" .. tostring(podValue(p, "Challenge")) end
local function chDone(key)
    local st = readState()
    local t = st.done and st.done[key]
    return t ~= nil and (serverNow() - t) < CH_DUR
end

local function chMatch(p)
    local act = p:FindFirstChild("Active")
    if act and act.Value == false then return false end
    if Options.Challenge_Pods.Value[p.Name] ~= true then return false end
    local mods = Options.Challenge_Mods.Value
    if hasAny(mods) and mods[podValue(p, "Challenge")] ~= true then return false end
    local ws = Options.Challenge_Worlds.Value
    if hasAny(ws) then
        local w, ok = tostring(podValue(p, "World")), false
        for n, v in pairs(ws) do
            if v == true and WORLDS[n] == w then ok = true end
        end
        if not ok then return false end
    end
    if Options.Challenge_SkipDone.Value and chDone(chKey(p)) then return false end
    return true
end

-- ---- Portal (uuid 15 ký tự, item_id chứa "portal")
local portalBad = {}
local function isPortalItem(d)
    return type(d) == "table" and type(rawget(d, "uuid")) == "string"
        and tostring(rawget(d, "item_id")):lower():find("portal") ~= nil
end
local function listPortals()
    local list, seen = {}, {}
    if not getgc then return list end
    pcall(function()
        for _, t in getgc(true) do
            if type(t) == "table" then
                local cands = {}
                if isPortalItem(t) then cands[1] = t
                else
                    local ui = rawget(t, "unique_items")
                    if type(ui) == "table" then cands = ui end
                end
                for _, d in pairs(cands) do
                    if isPortalItem(d) and not seen[d.uuid] then
                        seen[d.uuid] = true
                        table.insert(list, d.uuid)
                    end
                end
            end
        end
    end)
    return list
end
local pCache, pAt = {}, -1e9
local function nextPortal()
    if os.clock() - pAt > 20 then pCache = listPortals() pAt = os.clock() end
    for _, u in ipairs(pCache) do
        if not portalBad[u] then return u end
    end
end
local function usePortal(uuid, friends)
    if friends then return call("use_portal", uuid, { friends_only = true }) end
    return call("use_portal", uuid)
end

-- ---- Mode nào đang join được? (dùng cho ưu tiên thông minh)
local function canJoin(mode)
    if (cool[mode] or 0) > os.clock() then return false end
    if mode == "Daily" then
        local info = dailyInfo()
        return info ~= nil and not dailyDone(info.current_uuid)
    elseif mode == "Challenge" then
        return findChallengePod(chMatch) ~= nil
    elseif mode == "Portal" then
        return nextPortal() ~= nil
    end
    return findStoryPod(Options[mode .. "_Pod"].Value) ~= nil
end

---------------------------------------------------------------- WINDOW
local Window = Fluent:CreateWindow({
    Title = "CanHongSon", SubTitle = "", TabWidth = 160,
    Size = UDim2.fromOffset(560, 420), Acrylic = false, Theme = "Dark",
    MinimizeKey = Enum.KeyCode.LeftControl,
    DropdownsOutsideWindow = true,
})
local Minimizer = Fluent:CreateMinimizer({
    Icon = "rbxassetid://116068983769705", Size = UDim2.fromOffset(60, 60),
    Position = UDim2.new(0, 320, 0, 24), Acrylic = true, Transparency = 1,
    Corner = 999, IconCorner = 999, IconTransparency = 0,
    Draggable = true, IconDraggable = true,
})
Minimizer.Visible = true
for _, v in pairs(Minimizer:GetDescendants()) do
    if v:IsA("ImageLabel") or v:IsA("ImageButton") then
        v.BackgroundTransparency = 1
        v.ScaleType = Enum.ScaleType.Crop
        v.Size = UDim2.new(1.2, 0, 1.2, 0)
        v.AnchorPoint = Vector2.new(0.5, 0.5)
        v.Position = UDim2.new(0.5, 0, 0.5, 0)
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(1, 0)
        corner.Parent = v
    end
end

local Tabs = {
    General   = Window:AddTab({ Title = "Chung", Icon = "sliders-horizontal" }),
    Story     = Window:AddTab({ Title = "Story", Icon = "book-open" }),
    Infinite  = Window:AddTab({ Title = "Infinite", Icon = "infinity" }),
    Legend    = Window:AddTab({ Title = "Legend", Icon = "crown" }),
    Challenge = Window:AddTab({ Title = "Challenge", Icon = "swords" }),
    Daily     = Window:AddTab({ Title = "Daily Challenge", Icon = "calendar-days" }),
    Portal    = Window:AddTab({ Title = "Portal", Icon = "door-open" }),
    Webhook   = Window:AddTab({ Title = "Webhook", Icon = "send" }),
    Settings  = Window:AddTab({ Title = "Settings", Icon = "settings" }),
}

---------------------------------------------------------------- JOIN
local function startAndWait(pod, name, mode, key, undo)
    local st0 = dailyInfo()
    mutate(function(st)
        st.mode, st.key, st.joinedAt, st.window = mode, tostring(key), os.time(), windowNow()
        st.dailyAtJoin = st0 and tostring(st0.current_uuid) or nil
    end)
    if Options.AutoStart.Value then
        task.wait(Options.StartDelay.Value)

        task.wait(2)
        local tele = pod and pod:FindFirstChild("Teleporting")
        if inLobby() and not (tele and tele.Value) then

        end
    end
    local t0 = os.clock()
    while os.clock() - t0 < Options.Timeout.Value and inLobby() and not Fluent.Unloaded do
        task.wait(1)
    end
    if inLobby() then -- không vào được trận: rời pod, mode này nghỉ 30s để mode khác được chạy
        call("request_leave_lobby", name)
        cool[mode] = os.clock() + 30
        if undo then undo() end
        task.wait(1)
    end
end

local function joinOnce(mode)
    if busy then return end
    busy = true
    local ok, err = pcall(function()
        if not inLobby() then
            Fluent:Notify({ Title = mode, Content = "Không phải lobby.", Duration = 4 })
            return
        end
        local char = lp.Character or lp.CharacterAdded:Wait()
        local hrp = char:WaitForChild("HumanoidRootPart")

        if mode == "Daily" then
            local info = dailyInfo(true)
            if not info then cool.Daily = os.clock() + 30 return end
            local u = tostring(info.current_uuid)
            mutate(function(st)
                st.dtry = st.dtry or {}
                st.dtry[u] = (st.dtry[u] or 0) + 1
            end)

            task.wait(1)
            Fluent:Notify({ Title = "Daily", Content = u .. " | " .. tostring(info.current_challenge), Duration = 4 })
            startAndWait(nil, "Daily", "Daily", u)
            return
        end

        if mode == "Portal" then
            local chosen = nextPortal()
            if not chosen then return end
            local pok, pres = usePortal(chosen, Options.Portal_Friends.Value)

            if not pok or pres == false then portalBad[chosen] = true end
            pAt = -1e9
            task.wait(1)
            Fluent:Notify({ Title = "Portal", Content = chosen, Duration = 4 })
            startAndWait(nil, chosen, "Portal", chosen)
            return
        end

        if mode == "Challenge" then
            local pod = findChallengePod(chMatch)
            if not pod then return end
            local name, key = pod.Name, chKey(pod)
            local anchor = podAnchor(pod)
            if anchor then
                hrp.CFrame = anchor.CFrame + Vector3.new(0, 3, 0)
                task.wait(0.4)
            end

            task.wait(1)
            Fluent:Notify({ Title = "Challenge " .. name, Content = key, Duration = 4 })
            mutate(function(st) st.done = st.done or {} st.done[key] = serverNow() end)
            startAndWait(pod, name, "Challenge", key, function()
                mutate(function(st) if st.done then st.done[key] = nil end end)
            end)
            return
        end

        -- Story / Infinite / Legend
        local pod = findStoryPod(Options[mode .. "_Pod"].Value)
        if not pod then return end
        local world = (mode == "Legend") and "Shibuya" or Options[mode .. "_World"].Value
        local act = Options[mode .. "_Act"] and Options[mode .. "_Act"].Value or "1"
        local level = buildLevelId(mode, world, act)
        local diff = Options[mode .. "_Diff"].Value
        local friends = Options[mode .. "_Friends"].Value
        local name = pod.Name

        hrp.CFrame = pod.Door.CFrame + Vector3.new(0, 3, 0)
        task.wait(0.4)
        local ok1, r1 = call("request_join_lobby", name)
        task.wait(0.4)
        local ok2, r2 = call("request_lock_level", name, level, friends, diff)
        task.wait(0.8)
        local lv = pod:FindFirstChild("Level")

        -- Lock không ăn (màn chưa mở khoá...) -> rời pod, nhường mode khác
        if lv and lv.Value ~= level then
            call("request_leave_lobby", name)
            cool[mode] = os.clock() + 60
            Fluent:Notify({ Title = mode, Content = "Không chọn được " .. level .. " (chưa mở khoá?)", Duration = 5 })
            return
        end
        Fluent:Notify({ Title = mode, Content = name .. " | " .. level .. " | " .. diff, Duration = 4 })
        startAndWait(pod, name, mode, level)
    end)
    busy = false
end

---------------------------------------------------------------- UI: CHUNG
Tabs.General:AddParagraph({
    Title = "Cách dùng",
    Content = "Ưu tiên thông minh: Daily > Challenge > Portal > Legend > Infinite > Story.\nMode bật Auto nhưng chưa join được (daily đã xong, không có pod Challenge khớp, hết portal...) sẽ tự nhường mode kế tiếp.",
})
Tabs.General:AddToggle("AutoStart", { Title = "Tự bấm Start", Default = true })
Tabs.General:AddSlider("StartDelay", { Title = "Delay trước khi Start (giây)", Default = 1, Min = 0, Max = 10, Rounding = 1 })
Tabs.General:AddSlider("Timeout", { Title = "Rời pod nếu chưa vào trận sau (giây)", Default = 25, Min = 10, Max = 90, Rounding = 0 })
Tabs.General:AddToggle("LeaveOnNew", {
    Title = "Tự rời trận khi có challenge mới",
    Description = "Đang farm mà Daily mới / Challenge mới xuất hiện (và đã bật Auto tương ứng) thì về lobby để join",
    Default = false,
})

---------------------------------------------------------------- UI: Story / Infinite / Legend
local function buildStoryLike(mode, tab, withWorld, acts, actDesc)
    if withWorld then tab:AddDropdown(mode .. "_World", { Title = "Map", Values = WORLD_NAMES, Default = 1 }) end
    if acts then tab:AddDropdown(mode .. "_Act", { Title = "Act", Description = actDesc, Values = acts, Default = 1 }) end
    tab:AddDropdown(mode .. "_Diff", { Title = "Độ khó", Values = DIFFS, Default = 1 })
    tab:AddDropdown(mode .. "_Pod", { Title = "Pod", Values = PODS, Default = 1 })
    tab:AddToggle(mode .. "_Friends", { Title = "Friends Only", Default = false })
    tab:AddButton({ Title = "Join ngay 1 lần", Callback = function() task.spawn(joinOnce, mode) end })
    tab:AddToggle(mode .. "_Auto", { Title = "Auto Join " .. mode .. " (lặp lại)", Description = "Tự join khi đang ở lobby", Default = false })
end
buildStoryLike("Story", Tabs.Story, true, STORY_ACTS, "Act 1-6")
buildStoryLike("Infinite", Tabs.Infinite, true, nil)
Tabs.Legend:AddParagraph({ Title = "Legend", Content = "Hiện chỉ có Shibuya, act 1-3." })
buildStoryLike("Legend", Tabs.Legend, false, LEGEND_ACTS, "Shibuya Legend 1-3")

---------------------------------------------------------------- UI: Challenge
Tabs.Challenge:AddParagraph({
    Title = "Challenge",
    Content = "Pod CH có màn + modifier do server gán, đổi mỗi 30 phút. Script chỉ join pod Active, trống và khớp lọc.\nKhông chọn Modifier/Map = join bất kỳ.",
})
Tabs.Challenge:AddDropdown("Challenge_Pods", { Title = "Pod được phép join (chọn nhiều)", Values = CH_PODS, Multi = true, Default = { "CH1", "CH2", "CH3", "CH4" } })
Tabs.Challenge:AddDropdown("Challenge_Mods", { Title = "Chỉ join modifier (chọn nhiều)", Values = CH_MODS, Multi = true, Default = {} })
Tabs.Challenge:AddDropdown("Challenge_Worlds", { Title = "Chỉ join map (chọn nhiều)", Values = WORLD_NAMES, Multi = true, Default = {} })
Tabs.Challenge:AddToggle("Challenge_SkipDone", {
    Title = "Bỏ qua challenge đã làm (cùng màn + modifier)",
    Description = "Làm lại cùng challenge trong 30 phút chỉ nhận thưởng lặp (gem 15 thay vì 100)",
    Default = true,
})
Tabs.Challenge:AddButton({ Title = "Join ngay 1 lần", Callback = function() task.spawn(joinOnce, "Challenge") end })
Tabs.Challenge:AddToggle("Challenge_Auto", { Title = "Auto Join Challenge (lặp lại)", Description = "Tự join khi đang ở lobby", Default = false })

---------------------------------------------------------------- UI: Daily
Tabs.Daily:AddParagraph({
    Title = "Daily Challenge",
    Content = "Join bằng request_join_lobby(\"Daily\"). Tự bỏ qua nếu hôm nay đã hoàn thành (đọc last_completed_daily_challenge_uuid), tối đa 3 lần thử/ngày.",
})
Tabs.Daily:AddButton({ Title = "Join ngay 1 lần", Callback = function() task.spawn(joinOnce, "Daily") end })
Tabs.Daily:AddToggle("Daily_Auto", { Title = "Auto Join Daily (lặp lại)", Description = "Tự join khi đang ở lobby", Default = false })

---------------------------------------------------------------- UI: Portal
Tabs.Portal:AddParagraph({ Title = "Portal", Content = "Dùng portal bất kỳ trong túi. Portal lỗi tự bỏ qua, hết portal thì nhường mode khác." })
Tabs.Portal:AddToggle("Portal_Friends", { Title = "Friends Only", Default = false })
Tabs.Portal:AddButton({ Title = "Dùng portal 1 lần", Callback = function() task.spawn(joinOnce, "Portal") end })
Tabs.Portal:AddToggle("Portal_Auto", { Title = "Auto dùng Portal (lặp lại)", Description = "Tự dùng portal khi đang ở lobby", Default = false })

---------------------------------------------------------------- WEBHOOK
Tabs.Webhook:AddInput("Webhook_Url", { Title = "Webhook URL", Default = "", Placeholder = "https://discord.com/api/webhooks/..." })
Tabs.Webhook:AddInput("Webhook_PingId", { Title = "Discord User ID để ping", Default = "", Placeholder = "Chỉ nhập ID số" })
Tabs.Webhook:AddToggle("Webhook_SecretPing", { Title = "Ping khi nhận Secret (unit/item)", Default = false })
Tabs.Webhook:AddToggle("Webhook_AfterMatch", { Title = "Gửi kết quả + item mới sau mỗi ván", Default = false })
Tabs.Webhook:AddToggle("Webhook_Mythic", { Title = "Ping  Mythical", Default = false })

local httpReq = (syn and syn.request) or http_request or request or (fluxus and fluxus.request)

function sendWebhook(title, desc, shouldPing)
    local url = tostring(Options.Webhook_Url.Value or ""):gsub("%s+", "")
    if url == "" then
        Fluent:Notify({ Title = "Webhook", Content = "Chưa nhập URL.", Duration = 4 })
        return false
    end
    if not httpReq then
        Fluent:Notify({ Title = "Webhook", Content = "Executor thiếu request/http_request.", Duration = 4 })
        return false
    end
    local pingId = tostring(Options.Webhook_PingId.Value or ""):gsub("%s+", "")
    local validPing = shouldPing and pingId:match("^%d+$") ~= nil
    if #desc > 3900 then desc = desc:sub(1, 3890) .. "\n… đã rút gọn" end
    local payload = {
        username = "CanHongSon Inventory",
        embeds = {{
            title = title, description = desc, color = 13381611,
            fields = {
                { name = "Roblox", value = lp.Name, inline = true },
                { name = "PlaceId", value = tostring(game.PlaceId), inline = true },
                { name = "Thời gian", value = os.date("%d/%m/%Y %H:%M:%S"), inline = true },
            },
        }},
        allowed_mentions = validPing and { users = { pingId } } or { parse = {} },
    }
    if validPing then payload.content = "<@" .. pingId .. ">" end
    local ok, result = pcall(function()
        return httpReq({
            Url = url, Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = HttpService:JSONEncode(payload),
        })
    end)
    local status = ok and result and (result.StatusCode or result.Status)

    local good = ok and status ~= nil and status >= 200 and status < 300
    if not good then Fluent:Notify({ Title = "Webhook lỗi", Content = tostring(status or result), Duration = 6 }) end
    return good
end


-- Bảng Secret: quét getgc lấy mọi bảng có rarity == "Secret" và id (unit, portal, skin...)
local SECRET, lastLoad = {}, -1e9
local function loadSecret()
    if not getgc or os.clock() - lastLoad < 30 then return end
    lastLoad = os.clock()
    pcall(function()
        for _, t in ipairs(getgc(true)) do
            if type(t) == "table" and rawget(t, "rarity") == "Secret" then
                local id = rawget(t, "id")
                if type(id) == "string" and not id:find("^autosell") then
                    SECRET[id] = (tostring(rawget(t, "name") or id):gsub("<[^>]+>", ""))
                end
            end
        end
    end)
end
task.spawn(loadSecret)

local function findSecret(v, depth, seen)
    depth, seen = depth or 0, seen or {}
    if type(v) == "string" then return SECRET[v] and v or nil end
    if type(v) ~= "table" or depth > 4 or seen[v] then return nil end
    seen[v] = true
    if rawget(v, "rarity") == "Secret" then return tostring(rawget(v, "id") or rawget(v, "name") or "Secret") end
    for k, x in pairs(v) do
        if type(k) == "string" and SECRET[k] then return k end
        local r = findSecret(x, depth + 1, seen)
        if r then return r end
    end
end

local t0, lastSecret = os.clock(), {}
local function pingSecret(label, evt)
    if os.clock() - t0 < 8 then return end -- bỏ qua event nạp túi lúc mới load
    if lastSecret[label] and os.clock() - lastSecret[label] < 10 then return end
    lastSecret[label] = os.clock()
    task.spawn(sendWebhook, "Nhận được Secret!", string.format("**%s**\nEvent: %s", label, evt), true)
end

local lastMatchSent = 0
local function nm(v)
    if type(v) ~= "table" then return tostring(v) end
    return tostring(rawget(v, "item_id") or rawget(v, "unit_id") or rawget(v, "id") or rawget(v, "name"))
end
local function sendMatchResult(p)
    if type(p) ~= "table" then return end
    local lines = {}
    local function add(list, tag)
        if type(list) ~= "table" then return end
        for _, v in pairs(list) do
            local a = type(v) == "table" and rawget(v, "amount")
            table.insert(lines, string.format("• %s%s%s", tag, nm(v), a and (" x" .. tostring(a)) or ""))
        end
    end
    add(p.new_units, "[Unit] ")
    add(p.new_items, "")
    local st = type(p.stats) == "table" and p.stats or {}
    local head = string.format("%s | %s\nThời gian: %ss | Wave %s/%s\nGem +%s | Gold +%s | XP +%s",
        tostring(p.title or "?"), p.victory and "THẮNG" or "THUA", tostring(st.time_taken or "?"),
        tostring(st.waves_completed or "?"), tostring(st.num_waves or "?"),
        tostring(p.gem_reward or 0), tostring(p.gold_reward or 0), tostring(p.xp_reward or 0))
    if #lines == 0 then lines[1] = "(không có item/unit mới)" end
    sendWebhook("Kết thúc ván", head .. "\n\n" .. table.concat(lines, "\n"), false)
end

local SECRET_EVT = { unit_added = 1, normal_item_added = 1, unique_item_added = 1, units_hatched_through_banner = 1, show_unit_and_item_rewards = 1 }
local WATCH = { game_finished = 1, show_chat_message = 1 }
for k in pairs(SECRET_EVT) do WATCH[k] = 1 end

local function onRemoteEvent(evt, ...)
    local args = table.pack(...)
if Options.Webhook_SecretPing.Value then
        if SECRET_EVT[evt] or evt == "game_finished" then
            if next(SECRET) == nil then loadSecret() end
            local id = findSecret(evt == "game_finished" and type(args[1]) == "table" and args[1].new_units or args)
            if id then pingSecret(SECRET[id] or id, evt) end
        elseif evt == "show_chat_message" then
            local m = args[1]
            if type(m) == "table" and (m.Rarity == "Secret" or (Options.Webhook_Mythic.Value and m.Rarity == "Mythic")) and type(m.Text) == "string"
                and (m.Text:find(lp.Name, 1, true) or m.Text:find(lp.DisplayName, 1, true)) then
                pingSecret(m.Text, evt)
            end
        end
    end

    if evt == "game_finished" and Options.Webhook_AfterMatch.Value and os.clock() - lastMatchSent >= 15 then
        lastMatchSent = os.clock()
        task.spawn(sendMatchResult, args[1])
    end
end

local eps = RS:FindFirstChild("endpoints")
if eps then
    for _, r in ipairs(eps:GetDescendants()) do
        if r:IsA("RemoteEvent") and WATCH[r.Name] then
            r.OnClientEvent:Connect(function(...) onRemoteEvent(r.Name, ...) end)
        end
    end
end

---------------------------------------------------------------- AUTO LOOP (lobby)
local lastHandled
task.spawn(function()
    pcall(function() workspace:WaitForChild("_MAP_CONFIG", 15) end)
    if inLobby() then mutate(function(st) st.lobbyPlace = game.PlaceId end) end
    while not Fluent.Unloaded do
        if inLobby() and not busy then
            -- chọn mode đầu tiên theo ưu tiên mà đã bật Auto VÀ đang join được
            for _, mode in PRIORITY do
                local o = Options[mode .. "_Auto"]
                if o and o.Value and canJoin(mode) then
                    joinOnce(mode)
                    break
                end
            end
            -- đã kiểm tra challenge của khung 30 phút này (tránh rời trận lặp)
            local w = windowNow()
            if w ~= lastHandled then
                lastHandled = w
                mutate(function(st) st.chHandled = w end)
            end
        end
        task.wait(2)
    end
end)

---------------------------------------------------------------- AUTO LEAVE (trong trận)
-- Daily: so current_uuid (dữ liệu thật). Challenge thường: theo khung 30 phút (CHALLENGE_DURATION);
local function newReason()
    local st = readState()
    if not st.mode or (os.time() - (st.joinedAt or 0)) > 14400 then return nil end -- trận không do script join
    local info = dailyInfo()
    local w = windowNow()

    if st.mode == "Daily" then
        if info and tostring(info.current_uuid) ~= tostring(st.key) then return "Daily đã đổi" end
        return nil
    end
    if st.mode == "Challenge" then
        if w ~= st.window then return "Challenge đã đổi" end
        return nil
    end
    if Options.Daily_Auto.Value and info and tostring(info.current_uuid) ~= tostring(st.dailyAtJoin)
        and not dailyDone(info.current_uuid) then
        return "Daily mới"
    end
    if Options.Challenge_Auto.Value and w ~= st.window and w ~= st.chHandled then
        return "Challenge mới"
    end
    return nil
end

local function leaveMatch(why)

    Fluent:Notify({ Title = "Rời trận", Content = why, Duration = 5 })

    task.wait(8)
    if not inLobby() then
        local st = readState()
        TS:Teleport(tonumber(st.lobbyPlace) or game.PlaceId)
    end
end

task.spawn(function()
    task.wait(15) -- chờ vào trận ổn định
    while not Fluent.Unloaded do
        task.wait(5)
        if not inLobby() and Options.LeaveOnNew.Value then
            local ok, why = pcall(newReason)
            if ok and why then
                leaveMatch(why)
                task.wait(30)
            end
        end
    end
end)

---------------------------------------------------------------- SAVE
SaveManager:SetLibrary(Fluent)
InterfaceManager:SetLibrary(Fluent)
SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({})
InterfaceManager:SetFolder("AutoJoinHub")
SaveManager:SetFolder("AutoJoinHub/anime-td")
InterfaceManager:BuildInterfaceSection(Tabs.Settings)
SaveManager:BuildConfigSection(Tabs.Settings)

Window:SelectTab(2)
Fluent:Notify({ Title = "Auto Join", Content = "Đã tải script.", Duration = 5 })
SaveManager:LoadAutoloadConfig()
