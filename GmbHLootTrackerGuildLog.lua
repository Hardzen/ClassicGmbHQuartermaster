--[[ Guild event log capture (Officer+ only).

Reads Classic's guild officer event log and appends new rows to a dedicated
account SavedVariable. Separate from GmbHLootTrackerDB so peer/helper sync
cannot wipe this on logout.
]]

local QUERY_GAP = 60
local MAX_EVENTS = 1000
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
      version = 1,
      events = {},
      gaps = {},
      lastQueryAt = nil,
    }
  end
  local db = GmbHLootTrackerGuildLog
  if type(db.events) ~= "table" then
    db.events = {}
  end
  if type(db.gaps) ~= "table" then
    db.gaps = {}
  end
  return db
end

local function bareName(name)
  if not name or name == "" then
    return ""
  end
  return (tostring(name):match("^([^%-]+)")) or tostring(name)
end

-- Identity only — Classic y/m/d/h are relative ages and drift every hour.
-- The website re-hashes type|p1|p2|rank|#n for durable Discord dedupe.
local function eventTuple(ev)
  return table.concat({
    tostring(ev.t or ""),
    bareName(ev.p1 or ""),
    bareName(ev.p2 or ""),
    tostring(ev.rank or ""),
  }, "|")
end

local function fingerprintFor(ev, occurrence)
  return eventTuple(ev) .. "|#" .. tostring(occurrence or 1)
end

local function normalizeEvent(typeName, player1, player2, rank, year, month, day, hour)
  local t = string.lower(tostring(typeName or ""))
  if not KEEP_TYPES[t] then
    return nil
  end
  return {
    t = t,
    p1 = bareName(player1),
    p2 = bareName(player2),
    rank = tostring(rank or ""),
    y = tonumber(year) or 0,
    m = tonumber(month) or 0,
    d = tonumber(day) or 0,
    h = tonumber(hour) or 0,
  }
end

local function readSnapshot()
  local n = GetNumGuildEvents and GetNumGuildEvents() or 0
  if not n or n <= 0 then
    return {}
  end
  local out = {}
  local occ = {}
  for i = 1, n do
    local typeName, player1, player2, rank, year, month, day, hour = GetGuildEventInfo(i)
    local ev = normalizeEvent(typeName, player1, player2, rank, year, month, day, hour)
    if ev then
      local key = eventTuple(ev)
      occ[key] = (occ[key] or 0) + 1
      ev.fp = fingerprintFor(ev, occ[key])
      out[#out + 1] = ev
    end
  end
  return out
end

local function findOverlap(saved, snap)
  local savedN = #saved
  local snapN = #snap
  if savedN == 0 or snapN == 0 then
    return 0, 0
  end
  local maxLen = math.min(savedN, snapN)
  for len = maxLen, 1, -1 do
    local ok = true
    for i = 1, len do
      if saved[savedN - len + i].fp ~= snap[i].fp then
        ok = false
        break
      end
    end
    if ok then
      return len, savedN - len
    end
  end
  return 0, savedN
end

local function trimEvents(events)
  local n = #events
  if n <= MAX_EVENTS then
    return
  end
  local drop = n - MAX_EVENTS
  for i = 1, MAX_EVENTS do
    events[i] = events[i + drop]
  end
  for i = MAX_EVENTS + 1, n do
    events[i] = nil
  end
end

local function mergeSnapshot(snap)
  local db = ensureDB()
  local saved = db.events
  if #snap == 0 then
    return 0
  end

  if #saved == 0 then
    for i = 1, #snap do
      saved[#saved + 1] = snap[i]
    end
    trimEvents(saved)
    return #snap
  end

  local overlapLen = findOverlap(saved, snap)
  if overlapLen == 0 then
    -- Window scrolled past saved tail: treat whole snapshot as new and note a gap.
    local gap = {
      kind = "gap",
      missed = #snap,
      at = date("!%Y-%m-%dT%H:%M:%SZ"),
      fp = "gap|" .. tostring(time() or 0) .. "|" .. tostring(#snap),
    }
    db.gaps[#db.gaps + 1] = gap
    -- Also store a marker event so the uploader can report it.
    saved[#saved + 1] = {
      t = "gap",
      p1 = "",
      p2 = "",
      rank = "",
      y = 0,
      m = 0,
      d = 0,
      h = 0,
      missed = #snap,
      fp = gap.fp,
    }
    for i = 1, #snap do
      saved[#saved + 1] = snap[i]
    end
    trimEvents(saved)
    return #snap
  end

  local added = 0
  for i = overlapLen + 1, #snap do
    saved[#saved + 1] = snap[i]
    added = added + 1
  end
  trimEvents(saved)
  return added
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
  ensureDB().lastQueryAt = date("!%Y-%m-%dT%H:%M:%SZ")
  after(2, function()
    pendingQuery = false
  end)
end

local function onEventLogUpdate()
  if not canCapture() then
    return
  end
  local snap = readSnapshot()
  mergeSnapshot(snap)
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
