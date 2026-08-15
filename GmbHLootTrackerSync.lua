--[[ Guild peer sync.

GMBHWL — wishlist only, whispered to online Officer / Headmaster ranks.
GMBHRS — raid sheets, whispered to online guild members (all ranks).
]]

local PREFIX_WL = "GMBHWL"
local PREFIX_RAID = "GMBHRS"
local PRESENCE_PREFIX = "GMBHPR"
local CHUNK_SIZE = 200
local SHARE_COOLDOWN = 20
-- Per-batch chunk cap (addon message rate). Multiple batches cover the full list.
local MAX_CHUNKS_PER_BATCH = 60
local MAX_BATCHES = 80
-- Slightly slower than before — whisper addon messages drop under load.
local CHUNK_GAP = 0.15
local BATCH_GAP = 2.0
local PRESENCE_TTL = 900
local PRESENCE_ANNOUNCE_GAP = 120
local AUTO_SYNC_GAP = 90

GmbHLootTrackerSync = GmbHLootTrackerSync or {}
local Sync = GmbHLootTrackerSync

-- Repair UTF-8 mojibake (ê stored as Ãª) from double-encoded HelperData / peer sync.
local function utf8Codepoints(s)
  local i, n = 1, #s
  local cps = {}
  while i <= n do
    local c = string.byte(s, i)
    if not c then
      return nil
    end
    if c < 0x80 then
      cps[#cps + 1] = c
      i = i + 1
    elseif c < 0xE0 and i + 1 <= n then
      local c2 = string.byte(s, i + 1)
      if not c2 or c2 < 0x80 or c2 > 0xBF then
        return nil
      end
      cps[#cps + 1] = (c - 0xC0) * 0x40 + (c2 - 0x80)
      i = i + 2
    elseif c < 0xF0 and i + 2 <= n then
      local c2, c3 = string.byte(s, i + 1, i + 2)
      if not c2 or not c3 or c2 < 0x80 or c2 > 0xBF or c3 < 0x80 or c3 > 0xBF then
        return nil
      end
      cps[#cps + 1] = (c - 0xE0) * 0x1000 + (c2 - 0x80) * 0x40 + (c3 - 0x80)
      i = i + 3
    elseif c < 0xF8 and i + 3 <= n then
      local c2, c3, c4 = string.byte(s, i + 1, i + 3)
      if not c2 or not c3 or not c4
        or c2 < 0x80 or c2 > 0xBF or c3 < 0x80 or c3 > 0xBF or c4 < 0x80 or c4 > 0xBF
      then
        return nil
      end
      cps[#cps + 1] = (c - 0xF0) * 0x40000 + (c2 - 0x80) * 0x1000 + (c3 - 0x80) * 0x40 + (c4 - 0x80)
      i = i + 4
    else
      return nil
    end
  end
  return cps
end

function Sync.FixMojibake(s)
  if type(s) ~= "string" or s == "" then
    return s
  end
  -- Fast path: mojibake almost always contains UTF-8 for Ã (C3 83) or Â (C3 82).
  if not string.find(s, "\195\131", 1, true) and not string.find(s, "\195\130", 1, true) then
    return s
  end
  local cur = s
  for _ = 1, 3 do
    local cps = utf8Codepoints(cur)
    if not cps then
      break
    end
    local looks, allLatin = false, true
    for _, cp in ipairs(cps) do
      if cp > 255 then
        allLatin = false
        break
      end
      if cp == 0xC3 or cp == 0xC2 then
        looks = true
      end
    end
    if not allLatin or not looks then
      break
    end
    local parts = {}
    for _, cp in ipairs(cps) do
      parts[#parts + 1] = string.char(cp)
    end
    local nxt = table.concat(parts)
    if nxt == cur or not utf8Codepoints(nxt) then
      break
    end
    cur = nxt
  end
  return cur
end

function Sync.SanitizeTree(obj, seen)
  if type(obj) ~= "table" then
    return obj
  end
  seen = seen or {}
  if seen[obj] then
    return obj
  end
  seen[obj] = true
  for k, v in pairs(obj) do
    if type(v) == "string" then
      obj[k] = Sync.FixMojibake(v)
    elseif type(v) == "table" then
      Sync.SanitizeTree(v, seen)
    end
  end
  return obj
end

-- Guild ranks that may open wishlist + participate in wishlist peer sync.
-- Matches Classic GmbH roster ranks (Officer, Headmaster, …).
Sync.WISHLIST_RANKS = {
  ["officer"] = true,
  ["headmaster"] = true,
  ["guild master"] = true,
  ["gm"] = true,
}

-- bareName(lower) → { t = GetTime(), ver = "1.6.9" }
local peers = {}
local lastPresenceAnnounce = 0
local presenceRefreshAt = 0
local warnedNewerVersion = nil

-- pending receive by channel kind: "wl" | "raid"
local pending = { wl = nil, raid = nil }
local lastShareAt = { wl = 0, raid = 0 }
local lastReqAt = { wl = 0, raid = 0 }
local lastRetryAt = { wl = 0, raid = 0 }
local shareBusy = { wl = false, raid = false }
local shareQuiet = { wl = false, raid = false }
local shareTargets = { wl = nil, raid = nil }
local autoSyncScheduled = false

local function printMsg(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffGmbH|r " .. tostring(msg))
end

-- Short-lived status line for the main window + /gmbh status.
local syncStatusText = nil
local syncStatusAt = 0

local function setSyncStatus(text, opts)
  opts = opts or {}
  syncStatusText = text
  syncStatusAt = GetTime()
  if opts.chat and text and text ~= "" then
    printMsg(text)
  end
  -- Mid-transfer: skip UI refresh (RefreshSyncLabel rebuilds widgets and freezes).
  if opts.quiet then
    return
  end
  -- Never let UI refresh errors abort the sync message handler.
  pcall(function()
    local ui = GmbHLootTrackerUI
    if ui and ui.RefreshSyncLabel then
      ui:RefreshSyncLabel()
    end
  end)
end

local function kindLabel(kind)
  return (kind == "raid") and "raid" or "wishlist"
end

local function pendingProgress(kind)
  local pend = pending[kind]
  if not pend then
    return nil
  end
  local doneBatches = 0
  local chunkGot, chunkTotal = 0, 0
  for b = 1, pend.numBatches or 0 do
    local batch = pend.batches and pend.batches[b]
    if batch then
      if batch.done then
        doneBatches = doneBatches + 1
      end
      local total = tonumber(batch.total) or 0
      chunkTotal = chunkTotal + total
      for i = 1, total do
        if batch.parts and batch.parts[i] then
          chunkGot = chunkGot + 1
        end
      end
    end
  end
  return {
    from = pend.from,
    numBatches = pend.numBatches or 0,
    doneBatches = doneBatches,
    chunkGot = chunkGot,
    chunkTotal = chunkTotal,
  }
end

function Sync.GetLiveStatus()
  for _, kind in ipairs({ "raid", "wl" }) do
    local prog = pendingProgress(kind)
    if prog then
      if prog.numBatches > 1 then
        return string.format(
          "receiving %s from %s — batch %d/%d (%d/%d chunks)",
          kindLabel(kind),
          tostring(prog.from or "?"),
          math.min(prog.doneBatches + 1, prog.numBatches),
          prog.numBatches,
          prog.chunkGot,
          prog.chunkTotal
        )
      end
      return string.format(
        "receiving %s from %s — %d/%d chunks",
        kindLabel(kind),
        tostring(prog.from or "?"),
        prog.chunkGot,
        prog.chunkTotal
      )
    end
    if shareBusy[kind] then
      local n = shareTargets[kind] and #shareTargets[kind] or 0
      return string.format("sharing %s with %d player(s)…", kindLabel(kind), n)
    end
  end
  if syncStatusText and syncStatusText ~= "" and (GetTime() - syncStatusAt) < 12 then
    return syncStatusText
  end
  return nil
end

local function db()
  if GmbHLootTracker_GetDB then
    return GmbHLootTracker_GetDB()
  end
  local h = GmbHLootTrackerHelperData
  if type(h) == "table" and h.syncedAt and tostring(h.syncedAt) ~= "" then
    return h
  end
  local s = GmbHLootTrackerDB
  if type(s) == "table" and s.syncedAt and tostring(s.syncedAt) ~= "" then
    return s
  end
  return s or h
end

-- Shared accessor used by UI + Sync (defined early in Sync, loaded before UI).
function GmbHLootTracker_GetDB()
  local h = GmbHLootTrackerHelperData
  if type(h) == "table" and h.syncedAt and tostring(h.syncedAt) ~= "" then
    return h
  end
  local s = GmbHLootTrackerDB
  if type(s) == "table" and s.syncedAt and tostring(s.syncedAt) ~= "" then
    return s
  end
  if type(h) == "table" then
    return h
  end
  return s
end

-- Only create the SavedVariables table when applying a real peer payload.
-- Never invent {} on boot — that causes Classic to overwrite the helper file on logout.
local function beginPeerDB()
  if type(GmbHLootTrackerDB) ~= "table" then
    GmbHLootTrackerDB = {}
  end
  return GmbHLootTrackerDB
end

local function bareName(name)
  if not name then
    return ""
  end
  return (tostring(name):match("^([^%-]+)")) or tostring(name)
end

local function namesEqual(a, b)
  return string.lower(bareName(a)) == string.lower(bareName(b))
end

local function isWishlistRank(rankName)
  if not rankName then
    return false
  end
  local key = string.lower(tostring(rankName))
  if Sync.WISHLIST_RANKS[key] then
    return true
  end
  if string.sub(key, 1, 6) == "headma" then
    return true
  end
  if string.find(key, "officer", 1, true) then
    return true
  end
  return false
end

function Sync.PlayerGuildRank()
  local guildName, rankName = GetGuildInfo("player")
  if not guildName then
    return nil, nil
  end
  return guildName, rankName
end

function Sync.CanUseWishlist()
  local _, rankName = Sync.PlayerGuildRank()
  return isWishlistRank(rankName)
end

local function notifyPresenceUi()
  local now = GetTime()
  if now < presenceRefreshAt then
    return
  end
  presenceRefreshAt = now + 0.4
  local ui = GmbHLootTrackerUI
  if ui and ui.OnPeerPresence then
    ui:OnPeerPresence()
  end
  if ui and ui.RefreshSyncLabel and ui.syncLabel then
    ui:RefreshSyncLabel()
  end
end

function Sync.LocalVersion()
  local v = GetAddOnMetadata and GetAddOnMetadata("ClassicGmbHQuartermaster", "Version")
  if v and tostring(v) ~= "" then
    return tostring(v)
  end
  return "0"
end

local function parseVersion(v)
  local a, b, c = tostring(v or "0"):match("^(%d+)%.(%d+)%.(%d+)")
  if not a then
    a, b = tostring(v or "0"):match("^(%d+)%.(%d+)")
    c = 0
  end
  return tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0
end

-- -1 if a<b, 0 if equal, 1 if a>b
function Sync.CompareVersions(a, b)
  local a1, a2, a3 = parseVersion(a)
  local b1, b2, b3 = parseVersion(b)
  if a1 ~= b1 then
    return a1 < b1 and -1 or 1
  end
  if a2 ~= b2 then
    return a2 < b2 and -1 or 1
  end
  if a3 ~= b3 then
    return a3 < b3 and -1 or 1
  end
  return 0
end

local function maybeWarnNewerVersion(fromName, fromVer)
  if not fromVer or fromVer == "" then
    return
  end
  local mine = Sync.LocalVersion()
  if Sync.CompareVersions(fromVer, mine) <= 0 then
    return
  end
  if warnedNewerVersion == fromVer then
    return
  end
  warnedNewerVersion = fromVer
  printMsg(string.format(
    "|cffffcc00Update available:|r you have |cffffffff%s|r, |cff66ccff%s|r has |cffffffff%s|r — update Classic GmbH Quartermaster.",
    mine,
    bareName(fromName),
    fromVer
  ))
  notifyPresenceUi()
end

function Sync.MarkPeer(name, version)
  if not name or tostring(name) == "" then
    return
  end
  local key = string.lower(bareName(name))
  local prev = peers[key]
  peers[key] = {
    t = GetTime(),
    ver = (version and tostring(version) ~= "" and tostring(version))
      or (prev and prev.ver)
      or nil,
  }
  if version and tostring(version) ~= "" then
    maybeWarnNewerVersion(name, version)
  end
  notifyPresenceUi()
end

function Sync.HasAddon(name)
  if not name or tostring(name) == "" then
    return false
  end
  local me = UnitName("player")
  if me and namesEqual(name, me) then
    return true
  end
  local row = peers[string.lower(bareName(name))]
  if not row or not row.t then
    return false
  end
  return (GetTime() - row.t) <= PRESENCE_TTL
end

function Sync.PeerVersion(name)
  if not name then
    return nil
  end
  local me = UnitName("player")
  if me and namesEqual(name, me) then
    return Sync.LocalVersion()
  end
  local row = peers[string.lower(bareName(name))]
  return row and row.ver or nil
end

function Sync.NewestKnownVersion()
  local best = Sync.LocalVersion()
  local who = nil
  local now = GetTime()
  for key, row in pairs(peers) do
    if row and row.t and (now - row.t) <= PRESENCE_TTL and row.ver then
      if Sync.CompareVersions(row.ver, best) > 0 then
        best = row.ver
        who = key
      end
    end
  end
  return best, who
end

function Sync.HasNewerVersion()
  local best, who = Sync.NewestKnownVersion()
  if Sync.CompareVersions(best, Sync.LocalVersion()) > 0 then
    return true, best, who
  end
  return false, Sync.LocalVersion(), nil
end

local function presencePayload(cmd)
  return tostring(cmd or "HERE") .. "|" .. Sync.LocalVersion()
end

local function inRaidPresenceContext()
  if IsInRaid and IsInRaid() then
    return true
  end
  -- Classic sometimes reports instance before roster settles.
  local inInstance, instanceType = IsInInstance()
  return inInstance and instanceType == "raid"
end

local function presenceChannel()
  if inRaidPresenceContext() then
    return "RAID"
  end
  return nil
end

local function sendPresence(payload, channel, target)
  channel = channel or presenceChannel()
  if channel == "WHISPER" then
    -- ok
  elseif channel == "RAID" then
    if not inRaidPresenceContext() then
      return false
    end
  elseif channel == "GUILD" then
    -- Presence is raid-only; ignore guild broadcasts.
    return false
  else
    return false
  end
  if C_ChatInfo and C_ChatInfo.SendAddonMessage then
    if channel == "WHISPER" then
      C_ChatInfo.SendAddonMessage(PRESENCE_PREFIX, payload, "WHISPER", target)
    else
      C_ChatInfo.SendAddonMessage(PRESENCE_PREFIX, payload, channel)
    end
  elseif SendAddonMessage then
    if channel == "WHISPER" then
      SendAddonMessage(PRESENCE_PREFIX, payload, "WHISPER", target)
    else
      SendAddonMessage(PRESENCE_PREFIX, payload, channel)
    end
  else
    return false
  end
  return true
end

function Sync.AnnouncePresence(force)
  if not inRaidPresenceContext() then
    return
  end
  local now = GetTime()
  if not force and (now - lastPresenceAnnounce) < PRESENCE_ANNOUNCE_GAP then
    return
  end
  lastPresenceAnnounce = now
  local me = UnitName("player")
  if me then
    Sync.MarkPeer(me, Sync.LocalVersion())
  end
  sendPresence(presencePayload("HERE"), "RAID")
end

local function onPresenceMessage(prefix, message, channel, sender)
  if prefix ~= PRESENCE_PREFIX then
    return
  end
  -- Raid-only presence (plus whisper replies). Ignore leftover guild pings.
  if channel ~= "RAID" and channel ~= "WHISPER" and channel ~= "PARTY" then
    return
  end
  if not sender or namesEqual(sender, UnitName("player")) then
    return
  end
  local msg = tostring(message or "")
  local cmd, ver = msg:match("^([^|]+)|?(.*)$")
  cmd = cmd or msg
  ver = (ver and ver ~= "" and ver) or nil
  if cmd == "PING" then
    Sync.MarkPeer(sender, ver)
    if inRaidPresenceContext() then
      sendPresence(presencePayload("HERE"), "WHISPER", sender)
    end
    return
  end
  if cmd == "HERE" or cmd == "ANN" then
    Sync.MarkPeer(sender, ver)
  end
end

local function listOnlineOfficers()
  local me = UnitName("player")
  local out = {}
  local n = (GetNumGuildMembers and GetNumGuildMembers()) or 0
  for i = 1, n do
    local name, rankName, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
    if online and name and isWishlistRank(rankName) and not namesEqual(name, me) then
      table.insert(out, name)
    end
  end
  return out
end

local function listOnlineGuildMembers()
  local me = UnitName("player")
  local out = {}
  local n = (GetNumGuildMembers and GetNumGuildMembers()) or 0
  for i = 1, n do
    local name, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
    if online and name and not namesEqual(name, me) then
      table.insert(out, name)
    end
  end
  return out
end

local lastRosterPull = 0
local function ensureGuildRoster()
  if not IsInGuild or not IsInGuild() then
    return
  end
  local now = GetTime()
  if now - lastRosterPull < 15 then
    return
  end
  lastRosterPull = now
  if GuildRoster then
    GuildRoster()
  end
end

-- Look up a player on our guild roster (name may include -Realm).
local function lookupGuildMember(sender)
  if not sender or sender == "" or not IsInGuild or not IsInGuild() then
    return nil
  end
  local n = (GetNumGuildMembers and GetNumGuildMembers()) or 0
  for i = 1, n do
    local name, rankName, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
    if name and namesEqual(name, sender) then
      return {
        name = name,
        rankName = rankName,
        online = online and true or false,
        wishlistOk = isWishlistRank(rankName),
      }
    end
  end
  return nil
end

-- Wishlist peer sync: must be in THIS guild and hold an allowed rank.
function Sync.SenderAllowedWishlistSync(sender)
  ensureGuildRoster()
  local info = lookupGuildMember(sender)
  return info and info.wishlistOk and true or false
end

local function senderIsOnlineOfficer(sender)
  local info = lookupGuildMember(sender)
  return info and info.wishlistOk and info.online and true or false
end

local function senderIsOnlineGuildMember(sender)
  local info = lookupGuildMember(sender)
  return info ~= nil and info.online and true or false
end

local function senderIsGuildMember(sender)
  return lookupGuildMember(sender) ~= nil
end

local function sendOne(prefix, payload, target)
  if not target or target == "" then
    return false
  end
  if #payload > 250 then
    return false
  end
  if C_ChatInfo and C_ChatInfo.SendAddonMessage then
    C_ChatInfo.SendAddonMessage(prefix, payload, "WHISPER", target)
  elseif SendAddonMessage then
    SendAddonMessage(prefix, payload, "WHISPER", target)
  else
    return false
  end
  return true
end

-- Whisper targets for a given sync kind (wl → officers, raid → guild).
local function send(kind, payload, targets)
  if not IsInGuild() then
    return false, "not in a guild"
  end
  if #payload > 250 then
    return false, "payload too large"
  end
  local prefix = (kind == "raid") and PREFIX_RAID or PREFIX_WL
  targets = targets or shareTargets[kind]
  if not targets or #targets == 0 then
    targets = (kind == "raid") and listOnlineGuildMembers() or listOnlineOfficers()
  end
  if #targets == 0 then
    return false, "no online targets"
  end
  for _, target in ipairs(targets) do
    sendOne(prefix, payload, target)
  end
  return true
end

local function after(seconds, fn)
  if C_Timer and C_Timer.After then
    C_Timer.After(seconds, fn)
    return
  end
  local t = 0
  local f = CreateFrame("Frame")
  f:SetScript("OnUpdate", function(self, elapsed)
    t = t + elapsed
    if t >= seconds then
      self:SetScript("OnUpdate", nil)
      fn()
    end
  end)
end

-- Peer share stays thin: only players on the wishlist (not full eligible table).
local function encodeByItemLines(byItem, items)
  local lines = {}
  for itemId, rows in pairs(byItem or {}) do
    local name = ""
    if items and items[tostring(itemId)] and items[tostring(itemId)].name then
      name = tostring(items[tostring(itemId)].name)
    end
    name = name:gsub("[%^%|\n]", " ")
    local parts = { tostring(itemId), name }
    local any = false
    for _, r in ipairs(rows) do
      if not r.has_item then
        local onList = r.on_wishlist
        if onList == nil then
          onList = r.priority ~= nil
        end
        if onList then
          local pname = tostring(r.name or ""):gsub("[:%^%|\n]", "")
          table.insert(parts, string.format(
            "%s:%s:%s",
            tostring(tonumber(r.priority) or 0),
            pname,
            tostring(tonumber(r.lost_rolls) or 0)
          ))
          any = true
        end
      end
    end
    if any then
      table.insert(lines, table.concat(parts, "^"))
    end
  end
  table.sort(lines)
  return lines
end

local function decodeByItem(blob)
  local byItem = {}
  local items = {}
  for line in string.gmatch(blob .. "\n", "([^\n]*)\n") do
    if line ~= "" then
      local fields = {}
      for part in string.gmatch(line, "[^%^]+") do
        table.insert(fields, part)
      end
      local itemId = fields[1]
      local name = fields[2] or ""
      if itemId then
        if name ~= "" then
          items[itemId] = items[itemId] or { name = name }
          items[itemId].name = name
        end
        local rows = {}
        for i = 3, #fields do
          local prio, pname, lost = fields[i]:match("^(%d+):([^:]+):(%d+)$")
          if prio and pname then
            table.insert(rows, {
              name = pname,
              priority = tonumber(prio) or 0,
              lost_rolls = tonumber(lost) or 0,
              has_item = false,
              on_wishlist = true,
            })
          end
        end
        byItem[itemId] = rows
      end
    end
  end
  return byItem, items
end

local function escField(v)
  return tostring(v or ""):gsub("[%|\n\r]", " ")
end

local function slotWorthSending(slot)
  if type(slot) ~= "table" or not slot.id then
    return false
  end
  if slot.player_name and tostring(slot.player_name) ~= "" then
    return true
  end
  local role = string.lower(tostring(slot.role or ""))
  if role == "tank" or role == "offtank" or role == "ot" or role == "mt" then
    return true
  end
  local lab = string.lower(tostring(slot.label or ""))
  if lab == "tank" or lab == "mt" or lab == "ot" or lab == "main tank" or lab == "off tank"
    or string.find(lab, "lock tank", 1, true) or string.find(lab, "backup tank", 1, true)
  then
    return true
  end
  -- Peer sync skips empty map/healer placeholders to keep transfers small/safe.
  return false
end

local function encodeRaidLines(raids)
  local lines = {}
  if type(raids) ~= "table" then
    return lines
  end
  local slugs = {}
  for slug, raid in pairs(raids) do
    if type(raid) == "table" and raid.has_sheet then
      table.insert(slugs, tostring(slug))
    end
  end
  table.sort(slugs)
  for _, slug in ipairs(slugs) do
    local raid = raids[slug]
    table.insert(lines, table.concat({
      "RMETA",
      escField(slug),
      escField(raid.title),
      escField(raid.event_start_at),
      escField(raid.version),
      escField(raid.updated_at),
      raid.announced and "1" or "0",
      raid.has_sheet and "1" or "0",
      raid.member_locked and "1" or "0",
      escField(raid.bug_trio_last),
    }, "|"))
    for gi, group in ipairs(raid.groups or {}) do
      if type(group) == "table" then
        for si, seat in ipairs(group) do
          if type(seat) == "table" and seat.name and tostring(seat.name) ~= "" then
            table.insert(lines, table.concat({
              "RGRP",
              escField(slug),
              tostring(gi),
              tostring(si),
              escField(seat.name),
              escField(seat.class),
              escField(seat.class_color),
              escField(seat.role),
            }, "|"))
          end
        end
      end
    end
    for _, seat in ipairs(raid.bench or {}) do
      if type(seat) == "table" and seat.name and tostring(seat.name) ~= "" then
        table.insert(lines, table.concat({
          "RBENCH",
          escField(slug),
          escField(seat.name),
          escField(seat.class),
          escField(seat.class_color),
          escField(seat.role),
        }, "|"))
      end
    end
    for secIdx, section in ipairs(raid.sections or {}) do
      if type(section) == "table" then
        table.insert(lines, table.concat({
          "RSEC",
          escField(slug),
          tostring(secIdx),
          escField(section.id),
          escField(section.label),
          escField(section.kind),
          escField(section.map_layout),
        }, "|"))
        for boardIdx, board in ipairs(section.boards or {}) do
          if type(board) == "table" then
            table.insert(lines, table.concat({
              "RBOARD",
              escField(slug),
              tostring(secIdx),
              tostring(boardIdx),
              escField(board.id),
              escField(board.label),
              escField(board.mark),
              escField(board.mob),
            }, "|"))
            for _, slot in ipairs(board.slots or {}) do
              if slotWorthSending(slot) then
                table.insert(lines, table.concat({
                  "RSLOT",
                  escField(slug),
                  tostring(secIdx),
                  tostring(boardIdx),
                  escField(slot.id),
                  escField(slot.label),
                  escField(slot.mark),
                  escField(slot.player_name),
                  escField(slot.class),
                  escField(slot.class_color),
                  escField(slot.role),
                  escField(slot.x),
                  escField(slot.y),
                  escField(slot.ring),
                  escField(slot.fixed),
                }, "|"))
              end
            end
          end
        end
      end
    end
    -- Fallback when sections were not exported: filled assignments only.
    if type(raid.sections) ~= "table" or #(raid.sections) == 0 then
      for _, a in ipairs(raid.assignments or {}) do
        if type(a) == "table" and a.slot_id and a.player_name and tostring(a.player_name) ~= "" then
          table.insert(lines, table.concat({
            "RASN",
            escField(slug),
            escField(a.slot_id),
            escField(a.label),
            escField(a.section_label),
            escField(a.board_label),
            escField(a.mark),
            escField(a.player_name),
            escField(a.class),
            escField(a.class_color),
            escField(a.role),
          }, "|"))
        end
      end
    end
  end
  return lines
end

local function splitPipe(line)
  local fields = {}
  local start = 1
  local len = #line
  while start <= len + 1 do
    local s, e = string.find(line, "|", start, true)
    if not s then
      table.insert(fields, string.sub(line, start))
      break
    end
    table.insert(fields, string.sub(line, start, s - 1))
    start = e + 1
  end
  return fields
end

local function decodeRaidLines(blob)
  local raids = {}
  local MAX_GROUP = 8
  local MAX_SEAT = 5
  local MAX_SEC = 40
  local MAX_BOARD = 40
  local MAX_SLOTS = 80

  local function ensureRaid(slug)
    local r = raids[slug]
    if not r then
      r = {
        raid_slug = slug,
        groups = {},
        bench = {},
        assignments = {},
        sections = {},
        has_sheet = false,
      }
      raids[slug] = r
    end
    return r
  end
  local function ensureGroup(raid, gi)
    if gi < 1 or gi > MAX_GROUP then
      return nil
    end
    while #(raid.groups) < gi do
      table.insert(raid.groups, {})
    end
    return raid.groups[gi]
  end
  local function ensureSection(raid, secIdx)
    if secIdx < 1 or secIdx > MAX_SEC then
      return nil
    end
    while #(raid.sections) < secIdx do
      table.insert(raid.sections, { id = "", label = "", boards = {} })
    end
    return raid.sections[secIdx]
  end
  local function ensureBoard(section, boardIdx)
    if not section or boardIdx < 1 or boardIdx > MAX_BOARD then
      return nil
    end
    section.boards = section.boards or {}
    while #(section.boards) < boardIdx do
      table.insert(section.boards, { id = "", label = "", slots = {} })
    end
    return section.boards[boardIdx]
  end

  for line in string.gmatch((blob or "") .. "\n", "([^\n]*)\n") do
    if line ~= "" then
      local fields = splitPipe(line)
      local kind = fields[1]
      local slug = fields[2]
      if kind and slug and slug ~= "" then
        local raid = ensureRaid(slug)
        if kind == "RMETA" then
          raid.title = fields[3] ~= "" and fields[3] or nil
          raid.event_start_at = fields[4] ~= "" and fields[4] or nil
          raid.version = fields[5] ~= "" and fields[5] or nil
          raid.updated_at = fields[6] ~= "" and fields[6] or nil
          raid.announced = fields[7] == "1"
          raid.has_sheet = fields[8] == "1"
          raid.member_locked = fields[9] == "1"
          raid.bug_trio_last = fields[10] ~= "" and fields[10] or nil
        elseif kind == "RGRP" then
          local gi = tonumber(fields[3]) or 1
          local si = tonumber(fields[4]) or 1
          if si >= 1 and si <= MAX_SEAT then
            local group = ensureGroup(raid, gi)
            if group then
              while #group < si do
                table.insert(group, nil)
              end
              group[si] = {
                name = fields[5],
                class = fields[6] ~= "" and fields[6] or nil,
                class_color = fields[7] ~= "" and fields[7] or nil,
                role = fields[8] ~= "" and fields[8] or nil,
              }
            end
          end
        elseif kind == "RBENCH" then
          if #(raid.bench) < 80 then
            table.insert(raid.bench, {
              name = fields[3],
              class = fields[4] ~= "" and fields[4] or nil,
              class_color = fields[5] ~= "" and fields[5] or nil,
              role = fields[6] ~= "" and fields[6] or nil,
            })
          end
        elseif kind == "RSEC" then
          local secIdx = tonumber(fields[3]) or 1
          local section = ensureSection(raid, secIdx)
          if section then
            section.id = fields[4] or ""
            section.label = fields[5] or ""
            section.kind = fields[6] ~= "" and fields[6] or nil
            section.map_layout = fields[7] ~= "" and fields[7] or nil
            section.boards = section.boards or {}
          end
        elseif kind == "RBOARD" then
          local secIdx = tonumber(fields[3]) or 1
          local boardIdx = tonumber(fields[4]) or 1
          local section = ensureSection(raid, secIdx)
          local board = ensureBoard(section, boardIdx)
          if board then
            board.id = fields[5] or ""
            board.label = fields[6] or ""
            board.mark = fields[7] ~= "" and fields[7] or nil
            board.mob = fields[8] ~= "" and fields[8] or nil
            board.slots = board.slots or {}
          end
        elseif kind == "RSLOT" then
          local secIdx = tonumber(fields[3]) or 1
          local boardIdx = tonumber(fields[4]) or 1
          local section = ensureSection(raid, secIdx)
          local board = ensureBoard(section, boardIdx)
          if board then
            board.slots = board.slots or {}
            if #(board.slots) < MAX_SLOTS then
              local slot = {
                id = fields[5],
                label = fields[6] ~= "" and fields[6] or fields[5],
                mark = fields[7] ~= "" and fields[7] or nil,
                player_name = fields[8] ~= "" and fields[8] or nil,
                class = fields[9] ~= "" and fields[9] or nil,
                class_color = fields[10] ~= "" and fields[10] or nil,
                role = fields[11] ~= "" and fields[11] or nil,
              }
              if fields[12] and fields[12] ~= "" then
                slot.x = tonumber(fields[12]) or fields[12]
              end
              if fields[13] and fields[13] ~= "" then
                slot.y = tonumber(fields[13]) or fields[13]
              end
              if fields[14] and fields[14] ~= "" then
                slot.ring = fields[14]
              end
              if fields[15] and fields[15] ~= "" then
                slot.fixed = fields[15]
              end
              table.insert(board.slots, slot)
            end
          end
        elseif kind == "RASN" then
          if #(raid.assignments) < 400 then
            table.insert(raid.assignments, {
              slot_id = fields[3],
              label = fields[4],
              section_label = fields[5],
              board_label = fields[6],
              mark = fields[7] ~= "" and fields[7] or nil,
              player_name = fields[8] ~= "" and fields[8] or nil,
              class = fields[9] ~= "" and fields[9] or nil,
              class_color = fields[10] ~= "" and fields[10] or nil,
              role = fields[11] ~= "" and fields[11] or nil,
            })
            raid.has_sheet = true
          end
        end
      end
    end
  end
  return raids
end

local function splitPeerBlob(blob)
  local raidLines, wlLines = {}, {}
  local mode = "legacy"
  for line in string.gmatch((blob or "") .. "\n", "([^\n]*)\n") do
    if line == "#RAID" then
      mode = "raid"
    elseif line == "#WL" then
      mode = "wl"
    elseif mode == "raid" then
      table.insert(raidLines, line)
    elseif mode == "wl" then
      table.insert(wlLines, line)
    elseif line ~= "" then
      -- Pre-raid payloads were wishlist-only.
      table.insert(wlLines, line)
    end
  end
  return table.concat(raidLines, "\n"), table.concat(wlLines, "\n")
end

local function buildWishlistLines(data)
  local lines = {}
  local wlLines = encodeByItemLines(data and data.wishlistByItem, data and data.items)
  if #wlLines > 0 then
    table.insert(lines, "#WL")
    for _, line in ipairs(wlLines) do
      table.insert(lines, line)
    end
  end
  return lines, #wlLines
end

local function buildRaidLines(data)
  local lines = {}
  local raidLines = encodeRaidLines(data and data.raids)
  if #raidLines > 0 then
    table.insert(lines, "#RAID")
    for _, line in ipairs(raidLines) do
      table.insert(lines, line)
    end
  end
  return lines, #raidLines
end

local function chunkString(s)
  local chunks = {}
  local i = 1
  while i <= #s do
    table.insert(chunks, string.sub(s, i, i + CHUNK_SIZE - 1))
    i = i + CHUNK_SIZE
  end
  return chunks
end

-- Pack sorted lines into batches that each fit under MAX_CHUNKS_PER_BATCH.
local function lineBatches(lines)
  local batches = {}
  local cur = {}
  local function flush()
    if #cur > 0 then
      table.insert(batches, table.concat(cur, "\n"))
      cur = {}
    end
  end
  for _, line in ipairs(lines) do
    table.insert(cur, line)
    local chunks = chunkString(table.concat(cur, "\n"))
    if #chunks > MAX_CHUNKS_PER_BATCH then
      table.remove(cur)
      flush()
      table.insert(cur, line)
      chunks = chunkString(table.concat(cur, "\n"))
      if #chunks > MAX_CHUNKS_PER_BATCH then
        -- Single oversized line — send alone (still may exceed; rare).
        flush()
        table.insert(batches, line)
        cur = {}
      end
    end
  end
  flush()
  return batches
end

function Sync.HasWishlistData()
  local data = db()
  if type(data) ~= "table" then
    return false
  end
  local byItem = data.wishlistByItem
  if type(byItem) ~= "table" then
    return false
  end
  for _ in pairs(byItem) do
    return true
  end
  return false
end

function Sync.HasRaidData()
  local data = db()
  if type(data) ~= "table" or type(data.raids) ~= "table" then
    return false
  end
  for _, raid in pairs(data.raids) do
    if type(raid) == "table" and raid.has_sheet then
      return true
    end
  end
  return false
end

function Sync.HasSyncableData()
  return Sync.HasRaidData() or Sync.HasWishlistData()
end

function Sync.HasSyncedPayload()
  local data = db()
  if type(data) ~= "table" then
    return false
  end
  if data.syncedAt and tostring(data.syncedAt) ~= "" then
    return true
  end
  if type(data.items) == "table" then
    for _ in pairs(data.items) do
      return true
    end
  end
  return Sync.HasSyncableData()
end

function Sync.LocalRevision()
  local data = db()
  return data and tostring(data.revision or "") or ""
end

function Sync.LocalSyncedAt()
  local data = db()
  return data and tostring(data.syncedAt or ""):gsub("|", "") or ""
end

function Sync.LocalRaidSyncedAt()
  local data = db()
  if not data then
    return ""
  end
  local stamp = data.raidSyncedAt or data.syncedAt or ""
  return tostring(stamp):gsub("|", "")
end

-- Helper syncedAt is ISO-8601; lexicographic compare works for same format.
local function syncedAtNewer(peer, localAt)
  peer = tostring(peer or "")
  localAt = tostring(localAt or "")
  if peer == "" then
    return false
  end
  if localAt == "" then
    return true
  end
  return peer > localAt
end

local function localRaidsAreLocked()
  local data = db()
  if type(data) ~= "table" or type(data.raids) ~= "table" then
    return true
  end
  for _, raid in pairs(data.raids) do
    if type(raid) == "table" and raid.has_sheet and not raid.member_locked then
      return false
    end
  end
  return true
end

local function raidsAreMemberLocked(raids)
  local any = false
  for _, raid in pairs(raids or {}) do
    if type(raid) == "table" and raid.has_sheet then
      any = true
      if not raid.member_locked then
        return false
      end
    end
  end
  return any
end

-- Wishlist announce/share/request — Officer / Headmaster only.
function Sync.Announce()
  if not Sync.CanUseWishlist() or not Sync.HasWishlistData() then
    return
  end
  local data = db()
  local n = 0
  for _ in pairs(data.wishlistByItem or {}) do
    n = n + 1
  end
  send("wl", string.format(
    "ANNOUNCE|%s|%s|%d",
    tostring(data.revision or ""),
    tostring(data.syncedAt or ""):gsub("|", ""),
    n
  ))
end

function Sync.AnnounceRaid()
  if not IsInGuild() or not Sync.HasRaidData() then
    return
  end
  local data = db()
  local raidN = 0
  for _, raid in pairs(data.raids or {}) do
    if type(raid) == "table" and raid.has_sheet then
      raidN = raidN + 1
    end
  end
  send("raid", string.format(
    "ANNOUNCE|%s|%s|%d",
    tostring(data.revision or ""),
    Sync.LocalRaidSyncedAt(),
    raidN
  ))
end

function Sync.Request(opts)
  opts = opts or {}
  local quiet = opts.quiet
  if not Sync.CanUseWishlist() then
    if not quiet then
      printMsg("Wishlist sync is for Officer / Headmaster guild ranks.")
    end
    return false
  end
  if not IsInGuild() then
    if not quiet then
      printMsg("Join the guild to sync wishlist data.")
    end
    return false
  end
  local now = GetTime()
  if now - lastReqAt.wl < 5 then
    if not quiet then
      printMsg("Request already sent — wait a moment.")
    end
    return false
  end
  lastReqAt.wl = now
  send("wl", "REQ|" .. Sync.LocalRevision() .. "|" .. Sync.LocalSyncedAt())
  if not quiet then
    printMsg("Requested wishlist sync from guild officers…")
  end
  return true
end

function Sync.RequestRaid(opts)
  opts = opts or {}
  local quiet = opts.quiet
  if not IsInGuild() then
    if not quiet then
      printMsg("Join the guild to sync raid sheets.")
    end
    return false
  end
  local now = GetTime()
  if now - lastReqAt.raid < 5 then
    return false
  end
  lastReqAt.raid = now
  send("raid", "REQ|" .. Sync.LocalRevision() .. "|" .. Sync.LocalRaidSyncedAt())
  if not quiet then
    printMsg("Requested raid sheet sync from guild…")
  end
  return true
end

local function sendBatch(kind, batches, batchIdx, rev, synced, targets)
  local blob = batches[batchIdx]
  local chunks = chunkString(blob)
  local numBatches = #batches
  send(kind, string.format(
    "BEGIN|%s|%s|%d|%d|%d",
    rev,
    synced,
    #chunks,
    batchIdx,
    numBatches
  ), targets)
  for i, chunk in ipairs(chunks) do
    after((i - 1) * CHUNK_GAP, function()
      -- Include batch index so the receiver never mis-routes chunks.
      send(kind, string.format("CHUNK|%d|%d|%s", batchIdx, i, chunk), targets)
    end)
  end
  after(#chunks * CHUNK_GAP + 0.2, function()
    send(kind, string.format("END|%s|%d|%d", rev, batchIdx, numBatches), targets)
    if batchIdx < numBatches then
      after(BATCH_GAP, function()
        sendBatch(kind, batches, batchIdx + 1, rev, synced, targets)
      end)
    else
      shareBusy[kind] = false
      shareTargets[kind] = nil
      local label = (kind == "raid") and "raid sheet" or "wishlist"
      local msg = string.format(
        "Shared %s with %d player(s) (%d batches, rev %s).",
        label,
        #targets,
        numBatches,
        string.sub(rev, 1, 8)
      )
      if not shareQuiet[kind] then
        printMsg(msg)
      end
      setSyncStatus(msg)
      shareQuiet[kind] = false
    end
  end)
end

function Sync.Share(toPlayer, opts)
  opts = opts or {}
  local quiet = opts.quiet
  if not Sync.CanUseWishlist() then
    if not quiet then
      printMsg("Wishlist sync is for Officer / Headmaster guild ranks.")
    end
    return false
  end
  if not Sync.HasWishlistData() then
    if not quiet then
      printMsg("No wishlist data to share. Run the Windows helper, then /reload.")
    end
    return false
  end
  if shareBusy.wl then
    if not quiet then
      printMsg("Wishlist share already in progress…")
    end
    return false
  end
  local now = GetTime()
  local targeted = toPlayer and tostring(toPlayer) ~= ""
  if not targeted and now - lastShareAt.wl < SHARE_COOLDOWN then
    if not quiet then
      printMsg(string.format("Share cooldown (%ds).", math.ceil(SHARE_COOLDOWN - (now - lastShareAt.wl))))
    end
    return false
  end
  local data = db()
  if type(data) ~= "table" then
    return false
  end
  local targets
  if targeted then
    if not Sync.SenderAllowedWishlistSync(toPlayer) then
      if not quiet then
        printMsg(string.format(
          "Refused wishlist sync — %s is not Officer/Headmaster on the guild roster.",
          tostring(toPlayer)
        ))
      end
      return false
    end
    targets = { toPlayer }
  else
    targets = listOnlineOfficers()
  end
  if #targets == 0 then
    if not quiet then
      printMsg("No online officers to share with.")
    end
    return false
  end
  local lines, wlCount = buildWishlistLines(data)
  if #lines == 0 then
    if not quiet then
      printMsg("Wishlist is empty — nothing to share.")
    end
    return false
  end
  local batches = lineBatches(lines)
  if #batches == 0 or #batches > MAX_BATCHES then
    if not quiet and #batches > MAX_BATCHES then
      printMsg("Wishlist still too large. Use the Windows helper instead.")
    end
    return false
  end
  if not targeted then
    lastShareAt.wl = now
  end
  shareBusy.wl = true
  shareQuiet.wl = quiet and true or false
  shareTargets.wl = targets
  local rev = tostring(data.revision or "")
  local synced = tostring(data.syncedAt or ""):gsub("|", "")
  setSyncStatus(string.format("sharing wishlist with %d officer(s)…", #targets))
  if not quiet then
    printMsg(string.format(
      "Sharing wishlist with %d officer(s) (%d lines, %d batches)…",
      #targets,
      wlCount,
      #batches
    ))
  end
  sendBatch("wl", batches, 1, rev, synced, targets)
  return true
end

function Sync.ShareRaid(toPlayer, opts)
  opts = opts or {}
  local quiet = opts.quiet
  if not Sync.HasRaidData() then
    if not quiet then
      printMsg("No raid sheet data to share. Run the Windows helper, then /reload.")
    end
    return false
  end
  if shareBusy.raid then
    return false
  end
  local now = GetTime()
  local targeted = toPlayer and tostring(toPlayer) ~= ""
  if not targeted and now - lastShareAt.raid < SHARE_COOLDOWN then
    return false
  end
  local data = db()
  if type(data) ~= "table" then
    return false
  end
  local targets = targeted and { toPlayer } or listOnlineGuildMembers()
  if #targets == 0 then
    return false
  end
  local lines, raidCount = buildRaidLines(data)
  if #lines == 0 then
    return false
  end
  local batches = lineBatches(lines)
  if #batches == 0 or #batches > MAX_BATCHES then
    return false
  end
  if not targeted then
    lastShareAt.raid = now
  end
  shareBusy.raid = true
  shareQuiet.raid = quiet and true or false
  shareTargets.raid = targets
  local rev = tostring(data.revision or "")
  local synced = Sync.LocalRaidSyncedAt()
  setSyncStatus(string.format("sharing raid with %d player(s)…", #targets))
  if not quiet then
    printMsg(string.format(
      "Sharing raid sheet with %d player(s) (%d lines, %d batches)…",
      #targets,
      raidCount,
      #batches
    ))
  end
  sendBatch("raid", batches, 1, rev, synced, targets)
  return true
end

local function applySync(kind, revision, syncedAt, blob, fromPlayer)
  local raidBlob, wlBlob = splitPeerBlob(blob)
  local raids = decodeRaidLines(raidBlob)
  local byItem, items = decodeByItem(wlBlob)
  local hasRaids = false
  for _ in pairs(raids) do
    hasRaids = true
    break
  end
  local hasWl = false
  for _ in pairs(byItem) do
    hasWl = true
    break
  end

  if kind == "wl" then
    hasRaids = false
    if not hasWl then
      return
    end
    if not Sync.CanUseWishlist() then
      return
    end
    if Sync.HasWishlistData() and not syncedAtNewer(syncedAt, Sync.LocalSyncedAt()) then
      return
    end
  elseif kind == "raid" then
    hasWl = false
    if not hasRaids then
      return
    end
    if Sync.HasRaidData() and not syncedAtNewer(syncedAt, Sync.LocalRaidSyncedAt()) then
      -- Prefer unlocked (officer) sheets over locked member sheets at same/older stamp.
      if raidsAreMemberLocked(raids) or not localRaidsAreLocked() then
        return
      end
    end
    if raidsAreMemberLocked(raids) and Sync.HasRaidData() and not localRaidsAreLocked() then
      return
    end
  else
    return
  end

  local data = beginPeerDB()
  if hasRaids then
    data.raids = Sync.SanitizeTree(raids)
    data.raidSyncedAt = syncedAt
    data.raidRevision = revision
  end
  if hasWl then
    data.wishlistByItem = Sync.SanitizeTree(byItem)
    data.items = data.items or {}
    for id, meta in pairs(items) do
      data.items[id] = data.items[id] or {}
      data.items[id].name = Sync.FixMojibake(meta.name or data.items[id].name)
    end
    data.revision = revision
    data.syncedAt = syncedAt
  end
  data.syncSource = "guild"
  data.syncFrom = fromPlayer
  local bits = {}
  if hasRaids then
    table.insert(bits, "raid")
  end
  if hasWl then
    table.insert(bits, "wishlist")
  end
  printMsg(string.format(
    "Auto-synced %s from %s (rev %s). Last synced: %s",
    table.concat(bits, "+"),
    fromPlayer or "?",
    string.sub(tostring(revision), 1, 8),
    tostring(syncedAt)
  ))
  setSyncStatus(string.format(
    "synced %s from %s",
    table.concat(bits, "+"),
    fromPlayer or "?"
  ), { quiet = true })
  -- Defer heavy UI rebuild so decode/store finishes without hanging the client.
  after(0.25, function()
    pcall(function()
      if GmbHLootTrackerUI and GmbHLootTrackerUI.OnDataUpdated then
        GmbHLootTrackerUI.OnDataUpdated()
      end
    end)
    setSyncStatus(string.format(
      "synced %s from %s",
      table.concat(bits, "+"),
      fromPlayer or "?"
    ))
  end)
end

local function requestRetry(kind, fromPlayer, reason)
  pending[kind] = nil
  if reason then
    printMsg(reason)
    setSyncStatus(reason)
  end
  if not fromPlayer or fromPlayer == "" then
    return
  end
  local now = GetTime()
  if now - (lastRetryAt[kind] or 0) < 25 then
    return
  end
  lastRetryAt[kind] = now
  after(2, function()
    lastReqAt[kind] = 0
    send(kind, "REQ|" .. Sync.LocalRevision() .. "|" .. (
      (kind == "wl") and Sync.LocalSyncedAt() or Sync.LocalRaidSyncedAt()
    ), { fromPlayer })
    setSyncStatus(string.format("retrying %s sync from %s…", kindLabel(kind), fromPlayer))
  end)
end

local function tryFinishPending(kind)
  local pend = pending[kind]
  if not pend then
    return
  end
  for b = 1, pend.numBatches do
    local batch = pend.batches[b]
    if not batch or not batch.done then
      return
    end
  end
  local buf = {}
  for b = 1, pend.numBatches do
    local batch = pend.batches[b]
    local parts = {}
    for i = 1, batch.total do
      if not batch.parts[i] then
        requestRetry(kind, pend.from, "Sync incomplete — missing chunk " .. i .. " in batch " .. b)
        return
      end
      parts[i] = batch.parts[i]
    end
    buf[b] = table.concat(parts)
  end
  local blob = table.concat(buf, "\n")
  local fromPlayer = pend.from
  local revision = pend.revision
  local syncedAt = pend.syncedAt
  pending[kind] = nil
  -- Apply off the addon-message thread so the client can breathe after the last END.
  setSyncStatus("applying " .. kindLabel(kind) .. "…", { quiet = true })
  after(0.2, function()
    local ok, err = pcall(function()
      applySync(kind, revision, syncedAt, blob, fromPlayer)
    end)
    if not ok then
      requestRetry(kind, fromPlayer, "Sync apply failed — retrying… (" .. tostring(err) .. ")")
    end
  end)
end

local function onKindAddonMessage(kind, message, channel, sender)
  if channel ~= "WHISPER" then
    return
  end
  local me = UnitName("player")
  if sender and me and namesEqual(sender, me) then
    return
  end

  if kind == "wl" then
    -- Local player must be allowed, and the peer must be on our guild roster
    -- with Officer / Headmaster (or equivalent) rank.
    if not Sync.CanUseWishlist() then
      return
    end
    if not Sync.SenderAllowedWishlistSync(sender) then
      return
    end
  else
    ensureGuildRoster()
    if not senderIsGuildMember(sender) then
      return
    end
  end

  if sender then
    Sync.MarkPeer(sender)
  end

  local cmd, rest = message:match("^([^|]+)|?(.*)$")
  if not cmd then
    return
  end

  local hasData = (kind == "wl") and Sync.HasWishlistData() or Sync.HasRaidData()
  local localRev = Sync.LocalRevision()
  local localSynced = (kind == "wl") and Sync.LocalSyncedAt() or Sync.LocalRaidSyncedAt()

  if cmd == "ANNOUNCE" then
    local rev, peerSynced = rest:match("^([^|]*)|([^|]*)|")
    if not rev then
      rev = rest:match("^([^|]*)|") or rest
      peerSynced = ""
    end
    if not hasData or syncedAtNewer(peerSynced, localSynced)
      or (peerSynced == "" and rev and rev ~= "" and rev ~= localRev)
    then
      if GetTime() - lastReqAt[kind] > 5 then
        lastReqAt[kind] = GetTime()
        send(kind, "REQ|" .. localRev .. "|" .. localSynced, { sender })
      end
    elseif hasData
      and rev and rev ~= "" and rev ~= localRev
      and syncedAtNewer(localSynced, peerSynced)
    then
      if kind == "wl" then
        if Sync.SenderAllowedWishlistSync(sender) then
          Sync.Share(sender, { quiet = true })
        end
      else
        Sync.ShareRaid(sender, { quiet = true })
      end
    end
    return
  end

  if cmd == "REQ" then
    if hasData and not shareBusy[kind] then
      local theirRev, theirSynced = rest:match("^([^|]*)|?(.*)$")
      theirRev = theirRev or ""
      theirSynced = theirSynced or ""
      if theirSynced ~= "" and syncedAtNewer(theirSynced, localSynced) then
        return
      end
      if theirRev == localRev and (theirSynced == "" or theirSynced == localSynced) then
        return
      end
      if kind == "wl" then
        -- Re-check guild roster / rank before answering a wishlist pull.
        if not Sync.SenderAllowedWishlistSync(sender) then
          return
        end
        Sync.Share(sender, { quiet = true })
      else
        Sync.ShareRaid(sender, { quiet = true })
      end
    end
    return
  end

  if cmd == "BEGIN" then
    local rev, synced, total, batchIdx, numBatches = rest:match(
      "^([^|]*)|([^|]*)|(%d+)|(%d+)|(%d+)$"
    )
    if not rev then
      rev, synced, total = rest:match("^([^|]*)|([^|]*)|(%d+)$")
      batchIdx, numBatches = 1, 1
    end
    total = tonumber(total) or 0
    batchIdx = tonumber(batchIdx) or 1
    numBatches = tonumber(numBatches) or 1
    if total < 1 or total > MAX_CHUNKS_PER_BATCH then
      return
    end
    if numBatches < 1 or numBatches > MAX_BATCHES then
      return
    end
    if batchIdx < 1 or batchIdx > numBatches then
      return
    end
    local pend = pending[kind]
    if not pend
      or pend.revision ~= rev
      or pend.from ~= sender
      or pend.numBatches ~= numBatches
    then
      pending[kind] = {
        revision = rev,
        syncedAt = synced,
        from = sender,
        numBatches = numBatches,
        batches = {},
        activeBatch = batchIdx,
      }
      pend = pending[kind]
      local msg = string.format(
        "Receiving %s from %s (%d batches)…",
        kind == "raid" and "raid sheet" or "wishlist",
        sender or "?",
        numBatches
      )
      if numBatches > 1 then
        printMsg(msg)
      end
      setSyncStatus(msg)
    else
      -- Same transfer: if previous active batch never finished, abort + retry.
      local prev = pend.activeBatch and pend.batches[pend.activeBatch]
      if prev and not prev.done and pend.activeBatch ~= batchIdx then
        requestRetry(
          kind,
          sender,
          string.format(
            "Sync incomplete — lost batch %d before batch %d started.",
            pend.activeBatch,
            batchIdx
          )
        )
        return
      end
    end
    pend = pending[kind]
    if not pend then
      return
    end
    pend.activeBatch = batchIdx
    pend.batches[batchIdx] = { total = total, parts = {}, done = false }
    setSyncStatus(Sync.GetLiveStatus(), { quiet = true })
    return
  end

  if cmd == "CHUNK" then
    local pend = pending[kind]
    if not pend then
      return
    end
    -- New: CHUNK|batchIdx|chunkIdx|data  Old: CHUNK|chunkIdx|data
    local batchIdx, idx, data = rest:match("^(%d+)|(%d+)|(.*)$")
    if batchIdx and idx then
      batchIdx = tonumber(batchIdx)
      idx = tonumber(idx)
    else
      idx, data = rest:match("^(%d+)|(.*)$")
      idx = tonumber(idx)
      batchIdx = pend.activeBatch
    end
    if not batchIdx or not idx then
      return
    end
    local target = pend.batches[batchIdx]
    if not target then
      -- Stale/out-of-order chunk — ignore rather than corrupting another batch.
      return
    end
    if data ~= nil then
      target.parts[idx] = data
      -- Text-only status; never refresh UI mid-chunk.
      if idx == 1 or (idx % 10) == 0 then
        setSyncStatus(Sync.GetLiveStatus(), { quiet = true })
      end
    end
    return
  end

  if cmd == "END" then
    local pend = pending[kind]
    if not pend then
      return
    end
    local rev, batchIdx, numBatches = rest:match("^([^|]*)|(%d+)|(%d+)$")
    if not rev then
      rev = rest
      batchIdx, numBatches = 1, pend.numBatches or 1
    end
    batchIdx = tonumber(batchIdx) or pend.activeBatch or 1
    if rev ~= pend.revision then
      pending[kind] = nil
      return
    end
    local batch = pend.batches[batchIdx]
    if not batch then
      requestRetry(kind, pend.from, "Sync incomplete — END for unknown batch " .. tostring(batchIdx))
      return
    end
    for i = 1, batch.total do
      if not batch.parts[i] then
        requestRetry(
          kind,
          pend.from,
          "Sync incomplete — missing chunk " .. i .. " (batch " .. batchIdx .. ")"
        )
        return
      end
    end
    batch.done = true
    if numBatches and tonumber(numBatches) > 1 then
      local msg = string.format("Received batch %d/%d…", batchIdx, tonumber(numBatches))
      printMsg(msg)
      setSyncStatus(msg, { quiet = true })
    else
      setSyncStatus(Sync.GetLiveStatus(), { quiet = true })
    end
    -- Yield one frame before concat/apply so END handler returns quickly.
    after(0.05, function()
      tryFinishPending(kind)
    end)
  end
end

local function onAddonMessage(prefix, message, channel, sender)
  if prefix == PRESENCE_PREFIX then
    onPresenceMessage(prefix, message, channel, sender)
    return
  end
  if prefix == PREFIX_WL then
    onKindAddonMessage("wl", message, channel, sender)
    return
  end
  if prefix == PREFIX_RAID then
    onKindAddonMessage("raid", message, channel, sender)
  end
end

function Sync.Register()
  if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX_WL)
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX_RAID)
    C_ChatInfo.RegisterAddonMessagePrefix(PRESENCE_PREFIX)
  end
  if GuildRoster then
    GuildRoster()
  end
  local f = CreateFrame("Frame")
  f:RegisterEvent("CHAT_MSG_ADDON")
  f:RegisterEvent("PLAYER_GUILD_UPDATE")
  f:RegisterEvent("PLAYER_ENTERING_WORLD")
  f:RegisterEvent("GROUP_ROSTER_UPDATE")
  if f.RegisterEvent then
    pcall(function() f:RegisterEvent("RAID_ROSTER_UPDATE") end)
  end

  local function runAutoSync()
    -- Wishlist: officers / headmasters only.
    if Sync.CanUseWishlist() then
      if Sync.HasWishlistData() then
        Sync.Announce()
      else
        Sync.Request({ quiet = true })
      end
    end
    -- Raid sheets: any guild member.
    if IsInGuild and IsInGuild() then
      if Sync.HasRaidData() then
        Sync.AnnounceRaid()
      else
        Sync.RequestRaid({ quiet = true })
      end
    end
  end

  function Sync.KickAutoSync()
    runAutoSync()
  end

  local function scheduleAutoSync()
    if autoSyncScheduled then
      return
    end
    autoSyncScheduled = true
    local function tick()
      runAutoSync()
      after(AUTO_SYNC_GAP, tick)
    end
    after(AUTO_SYNC_GAP, tick)
  end

  f:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_ADDON" then
      onAddonMessage(...)
    elseif event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_GUILD_UPDATE" then
      if GuildRoster then
        GuildRoster()
      end
      after(2, function()
        if inRaidPresenceContext() then
          Sync.AnnouncePresence(true)
          sendPresence(presencePayload("PING"), "RAID")
        end
      end)
      after(PRESENCE_ANNOUNCE_GAP, function()
        Sync.AnnouncePresence(true)
      end)
      after(1.5, function()
        runAutoSync()
      end)
      scheduleAutoSync()
    elseif event == "GROUP_ROSTER_UPDATE" or event == "RAID_ROSTER_UPDATE" then
      if inRaidPresenceContext() then
        Sync.AnnouncePresence(false)
      end
    end
  end)

  after(2, function()
    runAutoSync()
    scheduleAutoSync()
  end)
end
