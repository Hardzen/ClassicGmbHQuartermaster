--[[ Guild event log capture (Officer+ only).

Raw-dumps Classic's officer guild event log into account SavedVariable
GmbHLootTrackerGuildLog. No fingerprints / dedupe / name munging here —
the Windows helper parses and uploads.
]]

local QUERY_GAP = 60
local KEEP_TYPES = {
  invite = true,
  join = true,
  promote = true,
  demote = true,
  remove = true,
  quit = true,
}

GmbHLootTrackerGuildLogMod = GmbHLootTrackerGuildLogMod or {}
local Mod = GmbHLootTrackerGuildLogMod

local queryFrame = nil
local queryTicker = nil
local pendingQuery = false

local function after(delay, fn)
  local f = CreateFrame("Frame")
  local left = delay or 0
  f:SetScript("OnUpdate", function(self, elapsed)
    left = left - elapsed
    if left <= 0 then
      self:SetScript("OnUpdate", nil)
      fn()
    end
  end)
end

local function canCapture()
  local Sync = GmbHLootTrackerSync
  if not Sync or not Sync.CanUseWishlist then
    return false
  end
  return Sync.CanUseWishlist()
end

local function ensureDB()
  if type(GmbHLootTrackerGuildLog) ~= "table" then
    GmbHLootTrackerGuildLog = {
      version = 2,
      events = {},
      lastQueryAt = nil,
    }
  end
  local db = GmbHLootTrackerGuildLog
  db.version = 2
  if type(db.events) ~= "table" then
    db.events = {}
  end
  -- gaps removed; leave key absent going forward
  db.gaps = nil
  return db
end

local function rawString(value)
  if value == nil then
    return ""
  end
  return tostring(value)
end

-- Exact GetGuildEventInfo payload — helper does bare-name / fingerprint / dedupe.
local function readRawSnapshot()
  local n = GetNumGuildEvents and GetNumGuildEvents() or 0
  if not n or n <= 0 then
    return {}
  end
  local out = {}
  for i = 1, n do
    local typeName, player1, player2, rank, year, month, day, hour = GetGuildEventInfo(i)
    local t = string.lower(rawString(typeName))
    if KEEP_TYPES[t] then
      out[#out + 1] = {
        t = t,
        p1 = rawString(player1),
        p2 = rawString(player2),
        rank = rawString(rank),
        y = tonumber(year) or 0,
        m = tonumber(month) or 0,
        d = tonumber(day) or 0,
        h = tonumber(hour) or 0,
      }
    end
  end
  return out
end

local function replaceEvents(snap)
  local db = ensureDB()
  local events = db.events
  for i = 1, #events do
    events[i] = nil
  end
  for i = 1, #snap do
    events[i] = snap[i]
  end
  db.lastQueryAt = date("!%Y-%m-%dT%H:%M:%SZ")
  db.n = #snap
end

local function requestLog()
  if pendingQuery then
    return
  end
  if not canCapture() then
    return
  end
  if not QueryGuildEventLog then
    return
  end
  pendingQuery = true
  pcall(QueryGuildEventLog)
  after(2, function()
    pendingQuery = false
  end)
end

local function onEventLogUpdate()
  if not canCapture() then
    return
  end
  replaceEvents(readRawSnapshot())
end

local function startTicker()
  if queryTicker then
    return
  end
  local elapsed = 0
  queryTicker = CreateFrame("Frame")
  queryTicker:SetScript("OnUpdate", function(self, dt)
    if not canCapture() then
      return
    end
    elapsed = elapsed + dt
    if elapsed < QUERY_GAP then
      return
    end
    elapsed = 0
    requestLog()
  end)
end

function Mod.Register()
  if queryFrame then
    return
  end
  ensureDB()
  queryFrame = CreateFrame("Frame")
  queryFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
  queryFrame:RegisterEvent("PLAYER_GUILD_UPDATE")
  queryFrame:RegisterEvent("GUILD_EVENT_LOG_UPDATE")
  queryFrame:SetScript("OnEvent", function(_, event)
    if event == "GUILD_EVENT_LOG_UPDATE" then
      onEventLogUpdate()
      return
    end
    if event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_GUILD_UPDATE" then
      after(3, function()
        if canCapture() then
          requestLog()
          startTicker()
        end
      end)
    end
  end)
end

Mod.Register()
