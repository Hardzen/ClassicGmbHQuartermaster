--[[ Guild peer sync.

GMBHWL — wishlist only, whispered to online Officer / Headmaster ranks.
GMBHRS — raid assignment sheets (one AceComm stream; do not multiplex).
GMBHGP — groups+bench only (separate prefix so it cannot smash the GMBHRS spool).
]]

local PREFIX_WL = "GMBHWL"
local PREFIX_RAID = "GMBHRS"
local PREFIX_GROUPS = "GMBHGP"
local PRESENCE_PREFIX = "GMBHPR"
local SHARE_COOLDOWN = 20
local APPLY_LINES_PER_FRAME = 4
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

-- Wishlist UI/sync only in Classic GmbH (not other guilds using the addon).
Sync.WISHLIST_GUILD = "classic gmbh"

-- bareName(lower) → { t = GetTime(), ver = "1.6.9" }
local peers = {}
local lastPresenceAnnounce = 0
local presenceRefreshAt = 0
local warnedNewerVersion = nil

-- AceComm-only bulk transfer (no BEGIN/CHUNK/END pending state).
local lastShareAt = { wl = 0, raid = 0 }
local lastReqAt = { wl = 0, raid = 0 }
local lastRetryAt = { wl = 0, raid = 0 }
local shareBusy = { wl = false, raid = false }
local shareQuiet = { wl = false, raid = false }
local shareTargets = { wl = nil, raid = nil }
-- Recent ANNOUNCE offers: kind → bareName → { syncedAt, rev, at }
local peerOffer = { wl = {}, raid = {} }
local OFFER_TTL = 300
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

function Sync.GetLiveStatus()
  for _, kind in ipairs({ "raid", "wl" }) do
    if shareBusy[kind] then
      local targets = shareTargets[kind]
      if targets and #targets > 0 then
        return string.format("sharing %s with %d player(s)…", kindLabel(kind), #targets)
      end
      -- AceComm GUILD/RAID/PARTY blast has no whisper target list — keep setSyncStatus text.
      if syncStatusText and syncStatusText ~= "" and (GetTime() - syncStatusAt) < 60 then
        return syncStatusText
      end
      return string.format("sharing %s…", kindLabel(kind))
    end
  end
  if syncStatusText and syncStatusText ~= "" and (GetTime() - syncStatusAt) < 12 then
    return syncStatusText
  end
  return nil
end

local function stampNewer(peer, localAt)
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

local function tableHasKeys(t)
  if type(t) ~= "table" then
    return false
  end
  for _ in pairs(t) do
    return true
  end
  return false
end

local function raidsHaveSheet(raids)
  if type(raids) ~= "table" then
    return false
  end
  for _, raid in pairs(raids) do
    if type(raid) == "table" and raid.has_sheet then
      return true
    end
  end
  return false
end

local function raidHasAssignments(raids)
  if type(raids) ~= "table" then
    return false
  end
  for _, raid in pairs(raids) do
    if type(raid) == "table" then
      if type(raid.sections) == "table" and #(raid.sections) > 0 then
        return true
      end
      if type(raid.assignments) == "table" and #(raid.assignments) > 0 then
        return true
      end
    end
  end
  return false
end

-- Groups payload must not wipe boss slots; assignment payload must not wipe G1–G8.
local function patchGroupsInto(data, incoming)
  if type(data) ~= "table" then
    return
  end
  data.raids = data.raids or {}
  for slug, src in pairs(incoming or {}) do
    if type(src) == "table" and slug and slug ~= "" then
      local dest = data.raids[slug]
      if type(dest) ~= "table" then
        dest = {
          raid_slug = slug,
          groups = {},
          bench = {},
          assignments = {},
          sections = {},
          has_sheet = src.has_sheet and true or false,
          announced = src.announced and true or false,
        }
        data.raids[slug] = dest
      end
      dest.groups = src.groups or dest.groups
      dest.bench = src.bench or dest.bench
      if src.announced ~= nil then
        dest.announced = src.announced
      end
      if src.has_sheet then
        dest.has_sheet = true
      end
      if src.title then
        dest.title = src.title
      end
    end
  end
end

local function patchAssignmentsInto(data, incoming)
  if type(data) ~= "table" then
    return
  end
  data.raids = data.raids or {}
  for slug, src in pairs(incoming or {}) do
    if type(src) == "table" and slug and slug ~= "" then
      local dest = data.raids[slug]
      if type(dest) ~= "table" then
        dest = {
          raid_slug = slug,
          groups = {},
          bench = {},
          assignments = {},
          sections = {},
        }
        data.raids[slug] = dest
      end
      if src.title then dest.title = src.title end
      if src.event_start_at then dest.event_start_at = src.event_start_at end
      if src.version then dest.version = src.version end
      if src.updated_at then dest.updated_at = src.updated_at end
      if src.announced ~= nil then dest.announced = src.announced end
      if src.has_sheet then dest.has_sheet = true end
      if src.member_locked ~= nil then dest.member_locked = src.member_locked end
      if src.bug_trio_last then dest.bug_trio_last = src.bug_trio_last end
      if type(src.sections) == "table" and #(src.sections) > 0 then
        dest.sections = src.sections
      end
      if type(src.assignments) == "table" and #(src.assignments) > 0 then
        dest.assignments = src.assignments
      end
    end
  end
end

-- HelperData is preferred for UI, but peer sync writes GmbHLootTrackerDB.
-- Officers often have a raid-only HelperData.lua — overlay peer wishlist/raids from SV.
local function overlayPeerFromSV(h, s)
  if type(h) ~= "table" or type(s) ~= "table" then
    return
  end
  if tableHasKeys(s.wishlistByItem) then
    local helperHasWl = tableHasKeys(h.wishlistByItem)
    if (not helperHasWl) or stampNewer(s.syncedAt, h.syncedAt) then
      h.wishlistByItem = s.wishlistByItem
      if type(s.items) == "table" then
        h.items = h.items or {}
        for id, meta in pairs(s.items) do
          if type(meta) == "table" then
            h.items[id] = h.items[id] or {}
            if meta.name then
              h.items[id].name = meta.name
            end
          end
        end
      end
      if s.syncedAt and tostring(s.syncedAt) ~= "" then
        h.syncedAt = s.syncedAt
      end
      if s.revision and tostring(s.revision) ~= "" then
        h.revision = s.revision
      end
      if s.syncSource then
        h.syncSource = s.syncSource
      end
      if s.syncFrom then
        h.syncFrom = s.syncFrom
      end
    end
  end
  if type(s.raids) == "table" then
    -- Merge; never replace the whole table (groups-only SV would wipe helper slots).
    patchGroupsInto(h, s.raids)
    if raidHasAssignments(s.raids) then
      local helperHasAssign = raidHasAssignments(h.raids)
      local sRaidAt = s.raidSyncedAt or s.syncedAt or ""
      local hRaidAt = h.raidSyncedAt or h.syncedAt or ""
      if (not helperHasAssign) or stampNewer(sRaidAt, hRaidAt) then
        patchAssignmentsInto(h, s.raids)
        h.raidSyncedAt = s.raidSyncedAt or sRaidAt
        if s.raidRevision then
          h.raidRevision = s.raidRevision
        end
      end
    end
  end
end

local function db()
  if GmbHLootTracker_GetDB then
    return GmbHLootTracker_GetDB()
  end
  local h = GmbHLootTrackerHelperData
  if type(h) == "table" and h.syncedAt and tostring(h.syncedAt) ~= "" then
    if type(GmbHLootTrackerDB) == "table" then
      overlayPeerFromSV(h, GmbHLootTrackerDB)
    end
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
  local s = GmbHLootTrackerDB
  if type(h) == "table" and h.syncedAt and tostring(h.syncedAt) ~= "" then
    if type(s) == "table" then
      overlayPeerFromSV(h, s)
    end
    return h
  end
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

local function isClassicGmbhGuild(guildName)
  if not guildName then
    return false
  end
  local key = string.lower(tostring(guildName)):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  return key == Sync.WISHLIST_GUILD
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
  local guildName, rankName = Sync.PlayerGuildRank()
  if not isClassicGmbhGuild(guildName) then
    return false
  end
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

function Sync.MarkPeer(name, version, opts)
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
  if not (opts and opts.quiet) then
    notifyPresenceUi()
  end
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

-- Everyone in the current raid/party (connected), excluding self.
local function listRaidMembers()
  local me = UnitName("player")
  local out = {}
  local seen = {}
  local function add(name, connected)
    if not name or name == "" or namesEqual(name, me) then
      return
    end
    if connected == false then
      return
    end
    local key = string.lower(bareName(name))
    if seen[key] then
      return
    end
    seen[key] = true
    table.insert(out, name)
  end

  if IsInRaid and IsInRaid() then
    local n = (GetNumGroupMembers and GetNumGroupMembers()) or 0
    for i = 1, n do
      local unit = "raid" .. i
      local name = UnitName(unit)
      local connected = true
      if UnitIsConnected then
        connected = UnitIsConnected(unit) and true or false
      end
      add(name, connected)
    end
  elseif IsInGroup and IsInGroup() then
    for i = 1, 4 do
      local unit = "party" .. i
      if UnitExists and UnitExists(unit) then
        local name = UnitName(unit)
        local connected = true
        if UnitIsConnected then
          connected = UnitIsConnected(unit) and true or false
        end
        add(name, connected)
      end
    end
  end
  return out
end

-- Raid sheet peer sync: prefer raid/party roster; guild-wide only when not grouped.
local function listRaidSyncTargets()
  if (IsInRaid and IsInRaid()) or (IsInGroup and IsInGroup()) then
    local members = listRaidMembers()
    if #members > 0 then
      return members
    end
  end
  return listOnlineGuildMembers()
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

local function preferredDist(kind)
  if kind == "raid" then
    if IsInRaid and IsInRaid() then
      return "RAID"
    end
    if IsInGroup and IsInGroup() then
      return "PARTY"
    end
    return "GUILD"
  end
  -- Wishlist: guild channel; non-officers ignore on receive.
  return "GUILD"
end

-- Must be declared before aceSharePayload (otherwise `after` resolves to a nil global).
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

local function aceSend(kind, payload, distribution, target, prio)
  local Comm = GmbHLootTrackerComm
  if not Comm or not Comm.SendCommMessage then
    return false
  end
  local prefix = (kind == "raid") and PREFIX_RAID or PREFIX_WL
  prio = prio or "NORMAL"
  if distribution == "WHISPER" then
    if not target or target == "" then
      return false
    end
    Comm:SendCommMessage(prefix, payload, "WHISPER", target, prio)
  else
    Comm:SendCommMessage(prefix, payload, distribution, nil, prio)
  end
  return true
end

-- AceComm bulk share (Gargul-style): LibDeflate + AceComm BULK. No BEGIN/CHUNK/END.
-- opts.tag = "groups" → SYNCZG (tiny G1–G8+bench). opts.skipBusy = true for that send.
local function aceSharePayload(kind, rev, synced, lines, toPlayer, quiet, opts)
  opts = opts or {}
  local Comm = GmbHLootTrackerComm
  if not Comm or not Comm.SendCommMessage then
    return false
  end
  if type(lines) ~= "table" or #lines == 0 then
    return false
  end
  local blob = table.concat(lines, "\n")
  local wire = blob
  local groups = opts.tag == "groups"
  local cmd = groups and "SYNCG" or "SYNC"
  if Comm.CanCompress and Comm.CanCompress() and Comm.Compress then
    local compressed = Comm.Compress(blob)
    if compressed then
      wire = compressed
      cmd = groups and "SYNCZG" or "SYNCZ"
    end
  end
  -- Raid must go compressed when LibDeflate is loaded (avoid fat plaintext AceComm).
  if kind == "raid" and cmd ~= "SYNCZ" and cmd ~= "SYNCZG" then
    if not quiet then
      printMsg("Raid share needs LibDeflate (AceComm+Deflate). /reload after updating the addon.")
    end
    return false
  end
  local payload = string.format("%s|%s|%s\n%s", cmd, tostring(rev or ""), tostring(synced or ""), wire)
  local prefix = opts.prefix
    or ((kind == "raid") and PREFIX_RAID or PREFIX_WL)
  if not opts.skipBusy then
    shareBusy[kind] = true
    shareQuiet[kind] = quiet and true or false
  end

  local finished = false
  local function done()
    if finished then
      return
    end
    finished = true
    if not opts.skipBusy then
      shareBusy[kind] = false
      shareTargets[kind] = nil
      shareQuiet[kind] = false
    end
    local deflate = (cmd == "SYNCZ" or cmd == "SYNCZG")
    local what = groups and "groups+bench" or kindLabel(kind)
    local msg = string.format(
      "Shared %s via AceComm%s (rev %s, %d→%d bytes).",
      what,
      deflate and "+Deflate" or "",
      string.sub(tostring(rev or ""), 1, 8),
      #blob,
      #wire
    )
    if not quiet then
      printMsg(msg)
    end
    if not opts.skipBusy then
      setSyncStatus(msg)
    end
  end

  local function onSent(_, sent, total)
    if total and sent and sent >= total then
      done()
    end
  end

  local deflateBit = (cmd == "SYNCZ" or cmd == "SYNCZG") and "+Deflate" or ""
  local what = groups and "groups+bench" or kindLabel(kind)
  if toPlayer and tostring(toPlayer) ~= "" then
    if not opts.skipBusy then
      shareTargets[kind] = { toPlayer }
    end
    if not quiet then
      printMsg(string.format(
        "Sharing %s with %s via AceComm%s (%d lines, %d bytes)…",
        what,
        tostring(toPlayer),
        deflateBit,
        #lines,
        #wire
      ))
    end
    Comm:SendCommMessage(prefix, payload, "WHISPER", toPlayer, "BULK", onSent)
    after(math.max(8, (#payload / 200) * 0.1 + 4), done)
    return true
  end

  if not opts.skipBusy then
    shareTargets[kind] = nil
    setSyncStatus(string.format("sharing %s on %s…", what, preferredDist(kind)))
  end
  if not quiet then
    printMsg(string.format(
      "Sharing %s on %s via AceComm%s (%d lines, %d bytes)…",
      what,
      preferredDist(kind),
      deflateBit,
      #lines,
      #wire
    ))
  end
  Comm:SendCommMessage(prefix, payload, preferredDist(kind), nil, "BULK", onSent)
  after(math.max(8, (#payload / 200) * 0.1 + 4), done)
  return true
end

-- Control messages (ANN/REQ): AceComm only (BULK share uses aceSharePayload).
local function send(kind, payload, targets)
  if not IsInGuild() then
    return false, "not in a guild"
  end
  if not (GmbHLootTrackerComm and GmbHLootTrackerComm.SendCommMessage) then
    return false, "AceComm required"
  end
  if targets and #targets == 1 then
    return aceSend(kind, payload, "WHISPER", targets[1], "NORMAL") and true or false
  end
  if not targets or #targets == 0 then
    return aceSend(kind, payload, preferredDist(kind), nil, "NORMAL") and true or false
  end
  -- Explicit multi-target list: whisper each via AceComm (CTL-paced internally).
  for _, target in ipairs(targets) do
    aceSend(kind, payload, "WHISPER", target, "NORMAL")
  end
  return true
end

-- Peer share: on-wishlist players with officer table columns (IDs, class, last loot).
-- Row wire (colon fields):
--   v1: prio:name:lost
--   v2: prio:name:lost:naxx:aq:total:class:role:color:lastId:lastName:lastDate:lastQ
-- Item name may be "Name#sort_by" so receivers keep instance ID sorting.
local function scrubPeerField(v)
  return tostring(v or ""):gsub("[:%^%|\n\r#]", "")
end

local function encodeByItemLines(byItem, items)
  local lines = {}
  for itemId, rows in pairs(byItem or {}) do
    local name = ""
    local sortBy = ""
    local meta = items and items[tostring(itemId)]
    if type(meta) == "table" then
      if meta.name then
        name = tostring(meta.name)
      end
      if meta.sort_by then
        sortBy = tostring(meta.sort_by)
      end
    end
    name = scrubPeerField(name)
    sortBy = scrubPeerField(sortBy)
    local header = name
    if sortBy ~= "" then
      header = name .. "#" .. sortBy
    end
    local parts = { tostring(itemId), header }
    local any = false
    for _, r in ipairs(rows) do
      if not r.has_item then
        local onList = r.on_wishlist
        if onList == nil then
          onList = r.priority ~= nil
        end
        if onList then
          local pname = scrubPeerField(r.name or r.player_name)
          if pname ~= "" then
            local naxx = tonumber(r.naxx_ids) or 0
            local aq = tonumber(r.aq40_ids) or 0
            local total = tonumber(r.total_ids)
            if total == nil then
              total = naxx + aq
            end
            table.insert(parts, string.format(
              "%s:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s",
              tostring(tonumber(r.priority) or 0),
              pname,
              tostring(tonumber(r.lost_rolls) or 0),
              tostring(naxx),
              tostring(aq),
              tostring(total),
              scrubPeerField(r.class),
              scrubPeerField(r.role),
              scrubPeerField(r.class_color):gsub("^#", ""),
              scrubPeerField(r.last_item_id),
              scrubPeerField(r.last_item),
              scrubPeerField(r.last_date),
              scrubPeerField(r.last_quality)
            ))
            any = true
          end
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
      local header = fields[2] or ""
      if itemId then
        local name, sortBy = header:match("^(.-)#([^#]*)$")
        if not name then
          name = header
          sortBy = nil
        end
        if name ~= "" or sortBy then
          items[itemId] = items[itemId] or {}
          if name ~= "" then
            items[itemId].name = name
          end
          if sortBy and sortBy ~= "" then
            items[itemId].sort_by = sortBy
          end
        end
        local rows = {}
        for i = 3, #fields do
          local bits = {}
          local rest = fields[i]
          while true do
            local a, b = rest:match("^([^:]*):(.*)$")
            if not a then
              table.insert(bits, rest)
              break
            end
            table.insert(bits, a)
            rest = b
          end
          if #bits >= 3 and bits[2] ~= "" then
            local naxxN = tonumber(bits[4]) or 0
            local aqN = tonumber(bits[5]) or 0
            local totalN = tonumber(bits[6])
            if totalN == nil then
              totalN = naxxN + aqN
            end
            local row = {
              name = bits[2],
              priority = tonumber(bits[1]) or 0,
              lost_rolls = tonumber(bits[3]) or 0,
              naxx_ids = naxxN,
              aq40_ids = aqN,
              total_ids = totalN,
              has_item = false,
              on_wishlist = true,
            }
            if bits[7] and bits[7] ~= "" then
              row.class = bits[7]
            end
            if bits[8] and bits[8] ~= "" then
              row.role = bits[8]
            end
            if bits[9] and bits[9] ~= "" then
              row.class_color = bits[9]
            end
            if bits[10] and bits[10] ~= "" then
              row.last_item_id = tonumber(bits[10]) or bits[10]
            end
            if bits[11] and bits[11] ~= "" then
              row.last_item = bits[11]
            end
            if bits[12] and bits[12] ~= "" then
              row.last_date = bits[12]
            end
            if bits[13] and bits[13] ~= "" then
              row.last_quality = tonumber(bits[13]) or bits[13]
            end
            table.insert(rows, row)
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
    -- Never peer-sync drafts — only announced sheets leave the officer machine.
    if type(raid) == "table" and raid.has_sheet and raid.announced then
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
    -- Groups/bench go in a separate tiny AceComm payload (encodeGroupLines).
    -- Bundling them into the assignment blob made Classic hang on AceComm concat/Deflate.
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

-- Tiny Groups+Bench wire (RMETA + filled seats only). Separate from boss slots
-- so AceComm never concatenates the full sheet just to show G1–G8.
local function encodeGroupLines(raids)
  local lines = {}
  if type(raids) ~= "table" then
    return lines
  end
  local slugs = {}
  for slug, raid in pairs(raids) do
    if type(raid) == "table" and raid.has_sheet and raid.announced then
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
      if gi > 8 then
        break
      end
      if type(group) == "table" then
        for si = 1, 5 do
          local seat = group[si]
          if type(seat) == "table" then
            local seatName = seat.name or seat.player_name
            if seatName and tostring(seatName) ~= "" then
              table.insert(lines, table.concat({
                "RGRP",
                escField(slug),
                tostring(gi),
                tostring(si),
                escField(seatName),
                escField(seat.class),
                escField(seat.class_color),
                escField(seat.role),
              }, "|"))
            end
          end
        end
      end
    end
    local benchCount = 0
    for _, seat in ipairs(raid.bench or {}) do
      if benchCount >= 80 then
        break
      end
      if type(seat) == "table" then
        local seatName = seat.name or seat.player_name
        if seatName and tostring(seatName) ~= "" then
          benchCount = benchCount + 1
          table.insert(lines, table.concat({
            "RBENCH",
            escField(slug),
            escField(seatName),
            escField(seat.class),
            escField(seat.class_color),
            escField(seat.role),
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
              -- Never table.insert(nil): Lua 5.1 #t ignores nil holes → infinite while.
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

local function buildGroupLines(data)
  local lines = {}
  local groupLines = encodeGroupLines(data and data.raids)
  if #groupLines > 0 then
    table.insert(lines, "#GRPS")
    for _, line in ipairs(groupLines) do
      table.insert(lines, line)
    end
  end
  return lines, #groupLines
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
  return stampNewer(peer, localAt)
end

local function localRaidsAreLocked()
  local data = db()
  if type(data) ~= "table" or type(data.raids) ~= "table" then
    return true
  end
  for _, raid in pairs(data.raids) do
    if type(raid) == "table" and raid.has_sheet and raid.announced and not raid.member_locked then
      return false
    end
  end
  return true
end

local function raidsAreMemberLocked(raids)
  local any = false
  for _, raid in pairs(raids or {}) do
    if type(raid) == "table" and raid.has_sheet and raid.announced then
      any = true
      if not raid.member_locked then
        return false
      end
    end
  end
  return any
end

-- Announced + unlocked (officer/helper) sheets only — drafts and locked copies are not sync sources.
function Sync.CanShareRaid()
  return Sync.HasRaidData() and not localRaidsAreLocked()
end

local function noteOffer(kind, who, syncedAt, rev)
  who = bareName(who)
  if who == "" then
    return
  end
  peerOffer[kind] = peerOffer[kind] or {}
  peerOffer[kind][who] = {
    syncedAt = tostring(syncedAt or ""),
    rev = tostring(rev or ""),
    at = GetTime(),
  }
end

-- Newest syncedAt wins. Equal stamps → prefer self (so a fresh helper pull still
-- broadcasts), else lowest bare name among peers (stable single sender).
function Sync.PickSyncAuthority(kind)
  local now = GetTime()
  local bestName, bestSynced = nil, ""
  local me = UnitName("player")
  local function consider(name, syncedAt)
    name = bareName(name)
    syncedAt = tostring(syncedAt or "")
    if name == "" then
      return
    end
    if bestName == nil then
      bestName, bestSynced = name, syncedAt
      return
    end
    if syncedAtNewer(syncedAt, bestSynced) then
      bestName, bestSynced = name, syncedAt
    elseif syncedAt == bestSynced then
      if namesEqual(name, me) then
        bestName = name
      elseif (not namesEqual(bestName, me)) and string.lower(name) < string.lower(bestName) then
        bestName = name
      end
    end
  end

  local canOffer = false
  if kind == "wl" then
    canOffer = Sync.CanUseWishlist() and Sync.HasWishlistData()
    if canOffer then
      consider(me, Sync.LocalSyncedAt())
      noteOffer("wl", me, Sync.LocalSyncedAt(), Sync.LocalRevision())
    end
  else
    canOffer = Sync.CanShareRaid()
    if canOffer then
      consider(me, Sync.LocalRaidSyncedAt())
      noteOffer("raid", me, Sync.LocalRaidSyncedAt(), Sync.LocalRevision())
    end
  end

  for name, offer in pairs(peerOffer[kind] or {}) do
    if offer and (now - (offer.at or 0)) <= OFFER_TTL then
      -- Raid: only unlocked offers are recorded as shareable; still rank all offers by stamp.
      consider(name, offer.syncedAt)
    end
  end
  return bestName, bestSynced
end

function Sync.IsSyncAuthority(kind)
  local who = Sync.PickSyncAuthority(kind)
  if not who then
    return false
  end
  return namesEqual(who, UnitName("player"))
end

-- Anyone with shareable data may relay (A→B→C). Authority only gates unsolicited group blasts.
function Sync.CanRelay(kind)
  if kind == "wl" then
    return Sync.CanUseWishlist() and Sync.HasWishlistData()
  end
  return Sync.CanShareRaid()
end

-- Authority answers first; other masters stagger so usually one REQ winner.
local function relayReplyDelay(kind)
  if Sync.IsSyncAuthority(kind) then
    return 0.2
  end
  local me = string.lower(bareName(UnitName("player") or "z"))
  local h = 0
  for i = 1, #me do
    h = h + string.byte(me, i) * i
  end
  return 0.85 + (h % 28) * 0.12
end

local function scheduleRelayShare(kind, toPlayer)
  if not toPlayer or toPlayer == "" or not Sync.CanRelay(kind) then
    return
  end
  local delay = relayReplyDelay(kind)
  after(delay, function()
    if shareBusy[kind] or not Sync.CanRelay(kind) then
      return
    end
    if kind == "wl" then
      if not Sync.SenderAllowedWishlistSync(toPlayer) then
        return
      end
      Sync.Share(toPlayer, { quiet = true })
    else
      Sync.ShareRaid(toPlayer, { quiet = true })
    end
  end)
end

function Sync.SyncAuthorityStatus(kind)
  local who, stamp = Sync.PickSyncAuthority(kind)
  if not who then
    return "no sync authority yet"
  end
  local mine = namesEqual(who, UnitName("player"))
  local relay = Sync.CanRelay(kind)
  return string.format(
    "%s authority: %s%s (synced %s)%s",
    kindLabel(kind),
    who,
    mine and " (you)" or "",
    stamp ~= "" and stamp or "—",
    relay and " · you can relay" or ""
  )
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
  local synced = tostring(data.syncedAt or ""):gsub("|", "")
  local rev = tostring(data.revision or "")
  noteOffer("wl", UnitName("player"), synced, rev)
  send("wl", string.format("ANNOUNCE|%s|%s|%d", rev, synced, n))
end

function Sync.AnnounceRaid()
  -- Only unlocked sheets advertise as a sync source (avoids member↔officer races).
  if not IsInGuild() or not Sync.CanShareRaid() then
    return
  end
  local data = db()
  local raidN = 0
  for _, raid in pairs(data.raids or {}) do
    if type(raid) == "table" and raid.has_sheet and raid.announced then
      raidN = raidN + 1
    end
  end
  local synced = Sync.LocalRaidSyncedAt()
  local rev = tostring(data.revision or "")
  noteOffer("raid", UnitName("player"), synced, rev)
  send("raid", string.format("ANNOUNCE|%s|%s|%d", rev, synced, raidN))
end

function Sync.Request(opts)
  opts = opts or {}
  local quiet = opts.quiet
  if not Sync.CanUseWishlist() then
    if not quiet then
      printMsg("Wishlist sync is for Classic GmbH Officer / Headmaster ranks.")
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
    local inRaid = (IsInRaid and IsInRaid()) or (IsInGroup and IsInGroup())
    printMsg(inRaid and "Requested raid sheet sync from the raid…" or "Requested raid sheet sync from guild…")
  end
  return true
end

function Sync.Share(toPlayer, opts)
  opts = opts or {}
  local quiet = opts.quiet
  if not Sync.CanUseWishlist() then
    if not quiet then
      printMsg("Wishlist sync is for Classic GmbH Officer / Headmaster ranks.")
    end
    return false
  end
  if not Sync.HasWishlistData() then
    if not quiet then
      printMsg("No wishlist data to share. Run the Windows helper, then /reload.")
    end
    return false
  end
  -- Only the elected authority answers broadcast pulls (targeted share still allowed).
  local targeted = toPlayer and tostring(toPlayer) ~= ""
  if not targeted and not Sync.IsSyncAuthority("wl") then
    if not quiet then
      printMsg(Sync.SyncAuthorityStatus("wl") .. " — not sharing.")
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
  end
  local lines = buildWishlistLines(data)
  if #lines == 0 then
    if not quiet then
      printMsg("Wishlist is empty — nothing to share.")
    end
    return false
  end
  if not targeted then
    lastShareAt.wl = now
  end
  local rev = tostring(data.revision or "")
  local synced = tostring(data.syncedAt or ""):gsub("|", "")
  -- Wishlist sync is AceComm only (same path as raid). No BEGIN/CHUNK/END.
  if not (GmbHLootTrackerComm and GmbHLootTrackerComm.SendCommMessage) then
    if not quiet then
      printMsg("Wishlist share needs AceComm. Update/reinstall Classic GmbH Quartermaster.")
    end
    return false
  end
  return aceSharePayload("wl", rev, synced, lines, targeted and toPlayer or nil, quiet)
end

function Sync.ShareRaid(toPlayer, opts)
  opts = opts or {}
  local quiet = opts.quiet
  if not Sync.CanShareRaid() then
    if not quiet then
      printMsg("No announced raid sheet to share (announce on the website, then run the helper).")
    end
    return false
  end
  local targeted = toPlayer and tostring(toPlayer) ~= ""
  -- Multi-master: any unlocked copy can targeted-share / answer REQ.
  -- Untargeted group blast stays authority-only (avoids N× AceComm storms).
  if not targeted and not Sync.IsSyncAuthority("raid") then
    if not quiet then
      printMsg(Sync.SyncAuthorityStatus("raid") .. " — not broadcasting (relay via whisper/REQ still OK).")
    end
    return false
  end
  if shareBusy.raid then
    return false
  end
  local now = GetTime()
  if not targeted and now - lastShareAt.raid < SHARE_COOLDOWN then
    return false
  end
  local data = db()
  if type(data) ~= "table" then
    return false
  end
  local groupLines = buildGroupLines(data)
  local lines = buildRaidLines(data)
  if #groupLines == 0 and #lines == 0 then
    if not quiet then
      printMsg("Nothing to share — raid sheet is not announced yet.")
    end
    return false
  end
  if not targeted then
    lastShareAt.raid = now
  end
  local rev = tostring(data.revision or "")
  local synced = Sync.LocalRaidSyncedAt()
  -- Raid sync is AceComm + LibDeflate only (Gargul-style). No BEGIN/CHUNK/END.
  if not (GmbHLootTrackerComm and GmbHLootTrackerComm.SendCommMessage) then
    if not quiet then
      printMsg("Raid share needs AceComm. Update/reinstall Classic GmbH Quartermaster.")
    end
    return false
  end
  if not (GmbHLootTrackerComm.CanCompress and GmbHLootTrackerComm.CanCompress()) then
    if not quiet then
      printMsg("Raid share needs LibDeflate. Update/reinstall Classic GmbH Quartermaster.")
    end
    return false
  end
  local dest = targeted and toPlayer or nil
  -- Groups+bench first: tiny AceComm message (often one packet). Does not use shareBusy.
  if #groupLines > 0 then
    aceSharePayload("raid", rev, synced, groupLines, dest, quiet, {
      tag = "groups",
      skipBusy = true,
      prefix = PREFIX_GROUPS,
    })
  end
  if #lines == 0 then
    return true
  end
  return aceSharePayload("raid", rev, synced, lines, dest, quiet)
end

local requestRetry -- forward decl (used by apply paths)

local function finishApply(kind, revision, syncedAt, raids, byItem, items, fromPlayer)
  local hasRaids = false
  for _ in pairs(raids or {}) do
    hasRaids = true
    break
  end
  local hasWl = false
  for _ in pairs(byItem or {}) do
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
    local incomingAssign = raidHasAssignments(raids)
    local localAssign = raidHasAssignments((db() or {}).raids)
    -- Groups share uses the same stamp as assignments. Do not skip a sheet
    -- that actually has sections just because groups already applied.
    if Sync.HasRaidData() and not syncedAtNewer(syncedAt, Sync.LocalRaidSyncedAt()) then
      if not incomingAssign then
        return
      end
      if localAssign then
        if raidsAreMemberLocked(raids) or not localRaidsAreLocked() then
          return
        end
      end
    end
    if raidsAreMemberLocked(raids) and Sync.HasRaidData() and not localRaidsAreLocked() then
      return
    end
  else
    return
  end

  local function applyPeerFields(data)
    if type(data) ~= "table" then
      return
    end
    if hasRaids then
      -- Merge slots into existing raids so groups+bench from GMBHGP survive.
      patchAssignmentsInto(data, raids)
      data.raidSyncedAt = syncedAt
      data.raidRevision = revision
    end
    if hasWl then
      data.wishlistByItem = byItem
      data.items = data.items or {}
      for id, meta in pairs(items or {}) do
        data.items[id] = data.items[id] or {}
        data.items[id].name = Sync.FixMojibake(meta.name or data.items[id].name)
      end
      data.revision = revision
      data.syncedAt = syncedAt
    end
    data.syncSource = "guild"
    data.syncFrom = fromPlayer
  end

  -- Persist in SV, and mirror into live HelperData so GetDB (which prefers HelperData)
  -- shows peer wishlist to officers who only have a raid-only HelperData.lua.
  applyPeerFields(beginPeerDB())
  if type(GmbHLootTrackerHelperData) == "table" then
    applyPeerFields(GmbHLootTrackerHelperData)
  end
  local bits = {}
  if hasRaids then
    table.insert(bits, "raid")
  end
  if hasWl then
    table.insert(bits, "wishlist")
  end
  setSyncStatus(string.format(
    "synced %s from %s — open /gmbh to view",
    table.concat(bits, "+"),
    fromPlayer or "?"
  ), { quiet = true })
  -- Leave UI alone (Gargul-style). Data is in SV; render only when the player opens /gmbh.
  after(1.0, function()
    printMsg(string.format(
      "Auto-synced %s from %s (rev %s). Open /gmbh to load the sheet.",
      table.concat(bits, "+"),
      fromPlayer or "?",
      string.sub(tostring(revision), 1, 8)
    ))
  end)
  -- Become a relay source so the next player can pull from us (A→B→C).
  after(2.5, function()
    if hasRaids and Sync.CanShareRaid() then
      noteOffer("raid", UnitName("player"), Sync.LocalRaidSyncedAt(), Sync.LocalRevision())
      Sync.AnnounceRaid()
    end
    if hasWl and Sync.CanUseWishlist() and Sync.HasWishlistData() then
      noteOffer("wl", UnitName("player"), Sync.LocalSyncedAt(), Sync.LocalRevision())
      Sync.Announce()
    end
  end)
end

local function finishApplyGroups(revision, syncedAt, raids, fromPlayer)
  local any = false
  for _ in pairs(raids or {}) do
    any = true
    break
  end
  if not any then
    return
  end
  patchGroupsInto(beginPeerDB(), raids)
  if type(GmbHLootTrackerHelperData) == "table" then
    patchGroupsInto(GmbHLootTrackerHelperData, raids)
  end
  local data = beginPeerDB()
  if type(data) == "table" then
    -- Do not set raidSyncedAt here — that stamp belongs to the assignment blob.
    -- Stamping it on groups made finishApply treat the sheet as already current.
    data.syncSource = "guild"
    data.syncFrom = fromPlayer
  end
  setSyncStatus(
    "synced groups+bench from " .. tostring(fromPlayer or "?") .. " — open /gmbh to view",
    { quiet = true }
  )
end

-- Stream-decode across frames. Never build a full lines[] table (that alone freezes Classic).
local function newRaidDecoder()
  local raids = {}
  local MAX_GROUP, MAX_SEAT, MAX_SEC, MAX_BOARD, MAX_SLOTS = 8, 5, 40, 40, 80
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
    if gi < 1 or gi > MAX_GROUP then return nil end
    while #(raid.groups) < gi do table.insert(raid.groups, {}) end
    return raid.groups[gi]
  end
  local function ensureSection(raid, secIdx)
    if secIdx < 1 or secIdx > MAX_SEC then return nil end
    while #(raid.sections) < secIdx do
      table.insert(raid.sections, { id = "", label = "", boards = {} })
    end
    return raid.sections[secIdx]
  end
  local function ensureBoard(section, boardIdx)
    if not section or boardIdx < 1 or boardIdx > MAX_BOARD then return nil end
    section.boards = section.boards or {}
    while #(section.boards) < boardIdx do
      table.insert(section.boards, { id = "", label = "", slots = {} })
    end
    return section.boards[boardIdx]
  end
  -- No FixMojibake here — too expensive on the apply path.
  local function feedLine(line)
    local fields = splitPipe(line)
    local rowKind, slug = fields[1], fields[2]
    if not rowKind or not slug or slug == "" then return end
    local raid = ensureRaid(slug)
    if rowKind == "RMETA" then
      raid.title = fields[3] ~= "" and fields[3] or nil
      raid.event_start_at = fields[4] ~= "" and fields[4] or nil
      raid.version = fields[5] ~= "" and fields[5] or nil
      raid.updated_at = fields[6] ~= "" and fields[6] or nil
      raid.announced = fields[7] == "1"
      raid.has_sheet = fields[8] == "1"
      raid.member_locked = fields[9] == "1"
      raid.bug_trio_last = fields[10] ~= "" and fields[10] or nil
    elseif rowKind == "RGRP" then
      local gi, si = tonumber(fields[3]) or 1, tonumber(fields[4]) or 1
      if si >= 1 and si <= MAX_SEAT then
        local group = ensureGroup(raid, gi)
        if group then
          -- Never table.insert(nil): Lua 5.1 #t ignores nil holes → infinite while.
          group[si] = {
            name = fields[5],
            class = fields[6] ~= "" and fields[6] or nil,
            class_color = fields[7] ~= "" and fields[7] or nil,
            role = fields[8] ~= "" and fields[8] or nil,
          }
        end
      end
    elseif rowKind == "RBENCH" then
      if #(raid.bench) < 80 then
        table.insert(raid.bench, {
          name = fields[3],
          class = fields[4] ~= "" and fields[4] or nil,
          class_color = fields[5] ~= "" and fields[5] or nil,
          role = fields[6] ~= "" and fields[6] or nil,
        })
      end
    elseif rowKind == "RSEC" then
      local section = ensureSection(raid, tonumber(fields[3]) or 1)
      if section then
        section.id = fields[4] or ""
        section.label = fields[5] or ""
        section.kind = fields[6] ~= "" and fields[6] or nil
        section.map_layout = fields[7] ~= "" and fields[7] or nil
        section.boards = section.boards or {}
      end
    elseif rowKind == "RBOARD" then
      local section = ensureSection(raid, tonumber(fields[3]) or 1)
      local board = ensureBoard(section, tonumber(fields[4]) or 1)
      if board then
        board.id = fields[5] or ""
        board.label = fields[6] or ""
        board.mark = fields[7] ~= "" and fields[7] or nil
        board.mob = fields[8] ~= "" and fields[8] or nil
        board.slots = board.slots or {}
      end
    elseif rowKind == "RSLOT" then
      local section = ensureSection(raid, tonumber(fields[3]) or 1)
      local board = ensureBoard(section, tonumber(fields[4]) or 1)
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
          if fields[12] and fields[12] ~= "" then slot.x = tonumber(fields[12]) or fields[12] end
          if fields[13] and fields[13] ~= "" then slot.y = tonumber(fields[13]) or fields[13] end
          if fields[14] and fields[14] ~= "" then slot.ring = fields[14] end
          if fields[15] and fields[15] ~= "" then slot.fixed = fields[15] end
          table.insert(board.slots, slot)
        end
      end
    elseif rowKind == "RASN" then
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
  return raids, feedLine
end

local function skipRaidHeader(line)
  return line == "" or line == "#RAID" or line == "#WL" or line == "#GRPS"
end

-- Groups+bench: tiny text. Parse immediately (no OnUpdate stream, no GMBHRS spool).
local function applyGroupsAsync(revision, syncedAt, blob, fromPlayer)
  setSyncStatus("applying groups+bench…", { quiet = true })
  blob = blob or ""
  local grpStart = string.find(blob, "#GRPS\n", 1, true)
  if grpStart then
    blob = string.sub(blob, grpStart + 6)
  end
  local raids, feedLine = newRaidDecoder()
  local n = 0
  for line in string.gmatch(blob .. "\n", "([^\n]*)\n") do
    n = n + 1
    if n > 200 then
      break
    end
    if not skipRaidHeader(line) then
      local ok = pcall(feedLine, line)
      if not ok then
        requestRetry("raid", fromPlayer, "Group sync apply failed — retrying…")
        return
      end
    end
  end
  local ok, err = pcall(finishApplyGroups, revision, syncedAt, raids, fromPlayer)
  if not ok then
    requestRetry("raid", fromPlayer, "Group sync apply failed — retrying… (" .. tostring(err) .. ")")
  end
end

-- Decode raid lines from a single blob across frames (AceComm path).
local function applySyncAsync(kind, revision, syncedAt, blob, fromPlayer)
  setSyncStatus("applying " .. kindLabel(kind) .. "…", { quiet = true })
  blob = blob or ""

  if kind == "wl" then
    after(0.3, function()
      local _, wlBlob = splitPeerBlob(blob)
      local byItem, items = decodeByItem(wlBlob)
      finishApply(kind, revision, syncedAt, {}, byItem, items, fromPlayer)
    end)
    return
  end

  -- Prefer #RAID body if present; otherwise treat whole blob as raid lines.
  local raidBlob = blob
  local raidStart = string.find(blob, "#RAID\n", 1, true)
  if raidStart then
    local afterHdr = raidStart + 6
    local wlStart = string.find(blob, "\n#WL\n", afterHdr, true)
    if wlStart then
      raidBlob = string.sub(blob, afterHdr, wlStart - 1)
    else
      raidBlob = string.sub(blob, afterHdr)
    end
  end

  local raids, feedLine = newRaidDecoder()
  local pos, len = 1, #raidBlob
  local f = CreateFrame("Frame")
  f:SetScript("OnUpdate", function(self)
    local budget = APPLY_LINES_PER_FRAME
    while budget > 0 and pos <= len do
      local nl = string.find(raidBlob, "\n", pos, true)
      local line
      if nl then
        line = string.sub(raidBlob, pos, nl - 1)
        pos = nl + 1
      else
        line = string.sub(raidBlob, pos)
        pos = len + 1
      end
      if not skipRaidHeader(line) then
        local ok, err = pcall(feedLine, line)
        if not ok then
          self:SetScript("OnUpdate", nil)
          requestRetry(kind, fromPlayer, "Sync apply failed — retrying… (" .. tostring(err) .. ")")
          return
        end
      end
      budget = budget - 1
    end
    if pos > len then
      self:SetScript("OnUpdate", nil)
      local ok, err = pcall(finishApply, kind, revision, syncedAt, raids, {}, {}, fromPlayer)
      if not ok then
        requestRetry(kind, fromPlayer, "Sync apply failed — retrying… (" .. tostring(err) .. ")")
      end
    end
  end)
end

local function applySync(kind, revision, syncedAt, blob, fromPlayer)
  -- Always leave the AceComm stack before touching the blob.
  after(0.75, function()
    applySyncAsync(kind, revision, syncedAt, blob, fromPlayer)
  end)
end

requestRetry = function(kind, fromPlayer, reason)
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

local function onKindAddonMessage(kind, message, channel, sender)
  if channel ~= "WHISPER" and channel ~= "RAID" and channel ~= "PARTY" and channel ~= "GUILD" then
    return
  end
  local me = UnitName("player")
  if sender and me and namesEqual(sender, me) then
    return
  end

  local cmd, rest = message:match("^([^|]+)|?(.*)$")
  if not cmd then
    return
  end
  local bulk = cmd == "SYNCZ" or cmd == "SYNC" or cmd == "SYNCZG" or cmd == "SYNCG"

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
    if not bulk then
      ensureGuildRoster()
    end
    if not senderIsGuildMember(sender) then
      return
    end
  end

  if sender then
    Sync.MarkPeer(sender, nil, bulk and { quiet = true } or nil)
  end

  -- Tiny groups+bench payload (not the full raid sheet).
  if cmd == "SYNCZG" or cmd == "SYNCG" then
    local rev, synced, wire = rest:match("^([^|]*)|([^\n]*)\n(.*)$")
    if not rev or not wire then
      return
    end
    setSyncStatus(
      "receiving groups+bench from " .. tostring(sender or "?") .. " (AceComm+Deflate)…",
      { quiet = true }
    )
    after(0.2, function()
      local blob = wire
      if cmd == "SYNCZG" then
        local Comm = GmbHLootTrackerComm
        if not (Comm and Comm.Decompress) then
          printMsg("Received compressed groups but LibDeflate is missing — update the addon.")
          return
        end
        blob = Comm.Decompress(wire)
        if not blob then
          printMsg("Failed to decompress groups from " .. tostring(sender or "?"))
          return
        end
      end
      applyGroupsAsync(rev, synced, blob, sender)
    end)
    return
  end

  -- AceComm bulk payload. SYNCZ = LibDeflate (preferred); SYNC = legacy plaintext.
  if cmd == "SYNCZ" or cmd == "SYNC" then
    local rev, synced, wire = rest:match("^([^|]*)|([^\n]*)\n(.*)$")
    if not rev or not wire then
      return
    end
    setSyncStatus(string.format(
      "receiving %s from %s (AceComm%s)…",
      kindLabel(kind),
      tostring(sender or "?"),
      cmd == "SYNCZ" and "+Deflate" or ""
    ), { quiet = true })
    -- Leave AceComm reassembly frame before decompress/apply.
    after(1.0, function()
      local blob = wire
      if cmd == "SYNCZ" then
        local Comm = GmbHLootTrackerComm
        if not (Comm and Comm.Decompress) then
          printMsg("Received compressed sync but LibDeflate is missing — update the addon.")
          return
        end
        blob = Comm.Decompress(wire)
        if not blob then
          printMsg("Failed to decompress sync from " .. tostring(sender or "?"))
          return
        end
      end
      printMsg(string.format(
        "Receiving %s from %s via AceComm%s…",
        kind == "raid" and "raid sheet" or "wishlist",
        sender or "?",
        cmd == "SYNCZ" and "+Deflate" or ""
      ))
      applySync(kind, rev, synced, blob, sender)
    end)
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
    noteOffer(kind, sender, peerSynced, rev)
    if not hasData or syncedAtNewer(peerSynced, localSynced)
      or (peerSynced == "" and rev and rev ~= "" and rev ~= localRev)
    then
      if GetTime() - lastReqAt[kind] > 5 then
        lastReqAt[kind] = GetTime()
        send(kind, "REQ|" .. localRev .. "|" .. localSynced, { sender })
      end
    elseif hasData
      and Sync.CanRelay(kind)
      and rev and rev ~= "" and rev ~= localRev
      and syncedAtNewer(localSynced, peerSynced)
    then
      -- Multi-master: any relay with newer data can push (staggered).
      scheduleRelayShare(kind, sender)
    end
    return
  end

  if cmd == "REQ" then
    if hasData and Sync.CanRelay(kind) and not shareBusy[kind] then
      local theirRev, theirSynced = rest:match("^([^|]*)|?(.*)$")
      theirRev = theirRev or ""
      theirSynced = theirSynced or ""
      if theirSynced ~= "" and syncedAtNewer(theirSynced, localSynced) then
        return
      end
      if theirRev == localRev and (theirSynced == "" or theirSynced == localSynced) then
        return
      end
      -- Multi-master REQ answer (authority first, others staggered).
      scheduleRelayShare(kind, sender)
    end
    return
  end

  -- Legacy BEGIN/CHUNK/END ignored (AceComm SYNC/SYNCZ only).
end

function Sync.Register()
  local Comm = GmbHLootTrackerComm
  if Comm and Comm.RegisterComm then
    local function onComm(prefix, message, distribution, sender)
      if prefix == PREFIX_WL then
        onKindAddonMessage("wl", message, distribution, sender)
      elseif prefix == PREFIX_RAID then
        onKindAddonMessage("raid", message, distribution, sender)
      elseif prefix == PREFIX_GROUPS then
        onKindAddonMessage("raid", message, distribution, sender)
      end
    end
    Comm:RegisterComm(PREFIX_WL, onComm)
    Comm:RegisterComm(PREFIX_RAID, onComm)
    Comm:RegisterComm(PREFIX_GROUPS, onComm)
  end
  if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
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
    if Sync.CanUseWishlist() then
      if Sync.HasWishlistData() then
        Sync.Announce()
      else
        Sync.Request({ quiet = true })
      end
    end
    if IsInGuild and IsInGuild() then
      if Sync.CanShareRaid() then
        Sync.AnnounceRaid()
      elseif not Sync.HasRaidData() then
        Sync.RequestRaid({ quiet = true })
      else
        -- Locked member sheet only: pull newer unlocked data, never announce as source.
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
      local prefix, message, channel, sender = ...
      -- AceComm owns GMBHWL / GMBHRS; presence only on raw addon messages.
      if prefix == PRESENCE_PREFIX then
        onPresenceMessage(prefix, message, channel, sender)
      end
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
