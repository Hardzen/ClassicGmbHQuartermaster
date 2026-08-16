--[[ Guild peer sync.

GMBHWL — wishlist only, whispered to online Officer / Headmaster ranks.
GMBHRS — raid sheets, whispered to online guild members (all ranks).
]]

local PREFIX_WL = "GMBHWL"
local PREFIX_RAID = "GMBHRS"
local PRESENCE_PREFIX = "GMBHPR"
local CHUNK_SIZE = 180
local SHARE_COOLDOWN = 20
-- Per-batch chunk cap (addon message rate). Multiple batches cover the full list.
local MAX_CHUNKS_PER_BATCH = 40
local MAX_BATCHES = 80
-- Gargul/ChatThrottleLib paces ~0.08s; we stay conservative on whispers.
local CHUNK_GAP = 0.12
local BATCH_GAP = 1.5
local OUT_GAP = 0.08
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
local function aceSharePayload(kind, rev, synced, lines, toPlayer, quiet)
  local Comm = GmbHLootTrackerComm
  if not Comm or not Comm.SendCommMessage then
    return false
  end
  if type(lines) ~= "table" or #lines == 0 then
    return false
  end
  local blob = table.concat(lines, "\n")
  local wire = blob
  local cmd = "SYNC"
  if Comm.CanCompress and Comm.CanCompress() and Comm.Compress then
    local compressed = Comm.Compress(blob)
    if compressed then
      wire = compressed
      cmd = "SYNCZ"
    end
  end
  -- Raid must go compressed when LibDeflate is loaded (avoid fat plaintext AceComm).
  if kind == "raid" and cmd ~= "SYNCZ" then
    if not quiet then
      printMsg("Raid share needs LibDeflate (AceComm+Deflate). /reload after updating the addon.")
    end
    return false
  end
  local payload = string.format("%s|%s|%s\n%s", cmd, tostring(rev or ""), tostring(synced or ""), wire)
  shareBusy[kind] = true
  shareQuiet[kind] = quiet and true or false

  local finished = false
  local function done()
    if finished then
      return
    end
    finished = true
    shareBusy[kind] = false
    shareTargets[kind] = nil
    local msg = string.format(
      "Shared %s via AceComm%s (rev %s, %d→%d bytes).",
      kindLabel(kind),
      cmd == "SYNCZ" and "+Deflate" or "",
      string.sub(tostring(rev or ""), 1, 8),
      #blob,
      #wire
    )
    if not quiet then
      printMsg(msg)
    end
    setSyncStatus(msg)
    shareQuiet[kind] = false
  end

  local function onSent(_, sent, total)
    if total and sent and sent >= total then
      done()
    end
  end

  local prefix = (kind == "raid") and PREFIX_RAID or PREFIX_WL
  if toPlayer and tostring(toPlayer) ~= "" then
    setSyncStatus(string.format("sharing %s with %s…", kindLabel(kind), tostring(toPlayer)))
    if not quiet then
      printMsg(string.format(
        "Sharing %s with %s via AceComm%s (%d lines, %d bytes)…",
        kindLabel(kind),
        tostring(toPlayer),
        cmd == "SYNCZ" and "+Deflate" or "",
        #lines,
        #wire
      ))
    end
    Comm:SendCommMessage(prefix, payload, "WHISPER", toPlayer, "BULK", onSent)
    after(math.max(30, (#payload / 200) * 0.1 + 10), done)
    return true
  end

  local dist = preferredDist(kind)
  setSyncStatus(string.format("sharing %s on %s…", kindLabel(kind), dist))
  if not quiet then
    printMsg(string.format(
      "Sharing %s on %s via AceComm%s (%d lines, %d bytes)…",
      kindLabel(kind),
      dist,
      cmd == "SYNCZ" and "+Deflate" or "",
      #lines,
      #wire
    ))
  end
  Comm:SendCommMessage(prefix, payload, dist, nil, "BULK", onSent)
  after(math.max(30, (#payload / 200) * 0.1 + 10), done)
  return true
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

local after
after = function(seconds, fn)
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

-- Control messages (ANN/REQ): AceComm when available (RAID/PARTY/GUILD or whisper).
local outQueue = {}
local outPumping = false

local function pumpOutQueue()
  if outPumping then
    return
  end
  outPumping = true
  local function step()
    if #outQueue == 0 then
      outPumping = false
      return
    end
    local item = table.remove(outQueue, 1)
    pcall(sendOne, item.prefix, item.payload, item.target)
    after(OUT_GAP, step)
  end
  step()
end

local function send(kind, payload, targets)
  if not IsInGuild() then
    return false, "not in a guild"
  end
  -- Prefer AceComm: one group/guild message, or a single whisper.
  if GmbHLootTrackerComm and GmbHLootTrackerComm.SendCommMessage then
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

  if #payload > 250 then
    return false, "payload too large"
  end
  local prefix = (kind == "raid") and PREFIX_RAID or PREFIX_WL
  targets = targets or shareTargets[kind]
  if not targets or #targets == 0 then
    targets = (kind == "raid") and listRaidSyncTargets() or listOnlineOfficers()
  end
  if #targets == 0 then
    return false, (kind == "raid") and "no raid/guild targets" or "no online targets"
  end
  for _, target in ipairs(targets) do
    outQueue[#outQueue + 1] = {
      prefix = prefix,
      payload = payload,
      target = target,
    }
  end
  pumpOutQueue()
  return true
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
    -- Peer sync skips group roster / bench (keeps transfers smaller; HUD/assignments still sync).
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

-- Unlocked (officer/helper) raid sheets only — locked member copies must not become sync sources.
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

-- Newest syncedAt wins; equal stamps → lowest bare name (stable single sender).
function Sync.PickSyncAuthority(kind)
  local now = GetTime()
  local bestName, bestSynced = nil, ""
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
    elseif syncedAt == bestSynced and string.lower(name) < string.lower(bestName) then
      bestName = name
    end
  end

  local me = UnitName("player")
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
    if type(raid) == "table" and raid.has_sheet then
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
    local inRaid = (IsInRaid and IsInRaid()) or (IsInGroup and IsInGroup())
    printMsg(inRaid and "Requested raid sheet sync from the raid…" or "Requested raid sheet sync from guild…")
  end
  return true
end

local function sendBatch(kind, batches, batchIdx, rev, synced, targets, onComplete)
  local blob = batches[batchIdx]
  local chunks = chunkString(blob)
  local numBatches = #batches
  -- One recipient at a time (caller passes a single-target list).
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
      send(kind, string.format("CHUNK|%d|%d|%s", batchIdx, i, chunk), targets)
    end)
  end
  after(#chunks * CHUNK_GAP + 0.25, function()
    send(kind, string.format("END|%s|%d|%d", rev, batchIdx, numBatches), targets)
    if batchIdx < numBatches then
      after(BATCH_GAP, function()
        sendBatch(kind, batches, batchIdx + 1, rev, synced, targets, onComplete)
      end)
    elseif onComplete then
      onComplete()
    end
  end)
end

-- Gargul lesson: don't fan-out the same bulk payload to N whispers in parallel.
-- Finish the full transfer to target[i] before starting target[i+1].
local function sendBatchesSerial(kind, batches, rev, synced, targets, quiet)
  local ti = 1
  local function nextTarget()
    if ti > #targets then
      shareBusy[kind] = false
      shareTargets[kind] = nil
      local label = (kind == "raid") and "raid sheet" or "wishlist"
      local msg = string.format(
        "Shared %s with %d player(s) (%d batches, rev %s).",
        label,
        #targets,
        #batches,
        string.sub(rev, 1, 8)
      )
      if not quiet then
        printMsg(msg)
      end
      setSyncStatus(msg)
      shareQuiet[kind] = false
      return
    end
    local one = { targets[ti] }
    ti = ti + 1
    setSyncStatus(string.format(
      "sharing %s with %s (%d/%d)…",
      kindLabel(kind),
      tostring(one[1] or "?"),
      ti - 1,
      #targets
    ), { quiet = true })
    sendBatch(kind, batches, 1, rev, synced, one, function()
      after(0.4, nextTarget)
    end)
  end
  nextTarget()
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
  local lines, wlCount = buildWishlistLines(data)
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
  if GmbHLootTrackerComm and GmbHLootTrackerComm.SendCommMessage then
    return aceSharePayload("wl", rev, synced, lines, targeted and toPlayer or nil, quiet)
  end
  if #targets == 0 then
    if not quiet then
      printMsg("No online officers to share with.")
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
  shareBusy.wl = true
  shareQuiet.wl = quiet and true or false
  shareTargets.wl = targets
  setSyncStatus(string.format("sharing wishlist with %d officer(s)…", #targets))
  if not quiet then
    printMsg(string.format(
      "Sharing wishlist with %d officer(s) (%d lines, %d batches)…",
      #targets,
      wlCount,
      #batches
    ))
  end
  sendBatchesSerial("wl", batches, rev, synced, targets, quiet)
  return true
end

function Sync.ShareRaid(toPlayer, opts)
  opts = opts or {}
  local quiet = opts.quiet
  if not Sync.CanShareRaid() then
    if not quiet then
      printMsg("No unlocked raid sheet to share (run the Windows helper).")
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
  local lines, raidCount = buildRaidLines(data)
  if #lines == 0 then
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
  return aceSharePayload("raid", rev, synced, lines, targeted and toPlayer or nil, quiet)
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
    if Sync.HasRaidData() and not syncedAtNewer(syncedAt, Sync.LocalRaidSyncedAt()) then
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
    -- Names already fixed during decode; skip full-tree SanitizeTree (freezes Classic).
    data.raids = raids
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
          while #group < si do table.insert(group, nil) end
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
  return line == "" or line == "#RAID" or line == "#WL"
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

-- CHUNK path: stream chunks → lines without ever concatenating the full payload.
local function applyRaidFromBatches(revision, syncedAt, batches, numBatches, fromPlayer)
  setSyncStatus("applying raid…", { quiet = true })
  local raids, feedLine = newRaidDecoder()
  local bIdx, pIdx = 1, 1
  local carry = ""
  local needBatchSep = false
  local f = CreateFrame("Frame")
  f:SetScript("OnUpdate", function(self)
    local budget = APPLY_LINES_PER_FRAME
    while budget > 0 do
      -- Flush remaining carry when all chunks are consumed.
      if bIdx > numBatches then
        if carry ~= "" then
          if not skipRaidHeader(carry) then
            local ok, err = pcall(feedLine, carry)
            if not ok then
              self:SetScript("OnUpdate", nil)
              requestRetry("raid", fromPlayer, "Sync apply failed — retrying… (" .. tostring(err) .. ")")
              return
            end
          end
          carry = ""
        end
        self:SetScript("OnUpdate", nil)
        for b = 1, numBatches do
          if batches[b] then
            batches[b].parts = nil
          end
        end
        local ok, err = pcall(finishApply, "raid", revision, syncedAt, raids, {}, {}, fromPlayer)
        if not ok then
          requestRetry("raid", fromPlayer, "Sync apply failed — retrying… (" .. tostring(err) .. ")")
        end
        return
      end

      local batch = batches[bIdx]
      if not batch or type(batch.parts) ~= "table" then
        self:SetScript("OnUpdate", nil)
        requestRetry("raid", fromPlayer, "Sync incomplete — missing batch " .. bIdx)
        return
      end
      if pIdx > (tonumber(batch.total) or 0) then
        bIdx = bIdx + 1
        pIdx = 1
        needBatchSep = true
      else
        local piece = batch.parts[pIdx]
        batch.parts[pIdx] = nil
        pIdx = pIdx + 1
        if piece == nil then
          self:SetScript("OnUpdate", nil)
          requestRetry("raid", fromPlayer, "Sync incomplete — missing chunk in batch " .. bIdx)
          return
        end
        local text = carry
        if needBatchSep then
          text = text .. "\n"
          needBatchSep = false
        end
        text = text .. piece
        carry = ""
        local pos = 1
        local tlen = #text
        while budget > 0 and pos <= tlen do
          local nl = string.find(text, "\n", pos, true)
          if not nl then
            carry = string.sub(text, pos)
            break
          end
          local line = string.sub(text, pos, nl - 1)
          pos = nl + 1
          if not skipRaidHeader(line) then
            local ok, err = pcall(feedLine, line)
            if not ok then
              self:SetScript("OnUpdate", nil)
              requestRetry("raid", fromPlayer, "Sync apply failed — retrying… (" .. tostring(err) .. ")")
              return
            end
            budget = budget - 1
          end
        end
        if budget == 0 and pos <= tlen then
          carry = string.sub(text, pos)
        end
      end
    end
  end)
end

local function applySync(kind, revision, syncedAt, blob, fromPlayer)
  -- Always leave the CHAT_MSG_ADDON / AceComm stack before touching the blob.
  after(0.75, function()
    applySyncAsync(kind, revision, syncedAt, blob, fromPlayer)
  end)
end

requestRetry = function(kind, fromPlayer, reason)
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
  local fromPlayer = pend.from
  local revision = pend.revision
  local syncedAt = pend.syncedAt
  local batches = pend.batches
  local numBatches = pend.numBatches
  pending[kind] = nil
  setSyncStatus("applying " .. kindLabel(kind) .. "…", { quiet = true })

  if kind == "raid" then
    -- Never table.concat the full raid payload — stream chunks on later frames.
    after(1.25, function()
      applyRaidFromBatches(revision, syncedAt, batches, numBatches, fromPlayer)
    end)
    return
  end

  -- Wishlist is small; concat one batch per frame then apply.
  after(1.0, function()
    local buf = {}
    local b = 1
    local f = CreateFrame("Frame")
    f:SetScript("OnUpdate", function(self)
      if b > numBatches then
        self:SetScript("OnUpdate", nil)
        applySync(kind, revision, syncedAt, table.concat(buf, "\n"), fromPlayer)
        return
      end
      local batch = batches[b]
      if not batch then
        self:SetScript("OnUpdate", nil)
        requestRetry(kind, fromPlayer, "Sync incomplete — missing batch " .. b)
        return
      end
      local parts = {}
      for i = 1, batch.total do
        if not batch.parts[i] then
          self:SetScript("OnUpdate", nil)
          requestRetry(kind, fromPlayer, "Sync incomplete — missing chunk " .. i .. " in batch " .. b)
          return
        end
        parts[i] = batch.parts[i]
        batch.parts[i] = nil
      end
      buf[b] = table.concat(parts)
      b = b + 1
    end)
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
    -- Another sender mid-transfer: keep newer stamp, otherwise ignore interloper.
    if pend and pend.from and not namesEqual(pend.from, sender) then
      local incomplete = false
      for b = 1, pend.numBatches or 0 do
        local batch = pend.batches and pend.batches[b]
        if not batch or not batch.done then
          incomplete = true
          break
        end
      end
      if incomplete then
        if syncedAtNewer(synced, pend.syncedAt) then
          pending[kind] = nil
          pend = nil
        else
          return
        end
      end
    end
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
    if not pend or (pend.from and not namesEqual(pend.from, sender)) then
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
    if not pend or (pend.from and not namesEqual(pend.from, sender)) then
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
      -- Silent: usually a discarded interloper END.
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
  local Comm = GmbHLootTrackerComm
  if Comm and Comm.RegisterComm then
    local function onComm(prefix, message, distribution, sender)
      if prefix == PREFIX_WL then
        onKindAddonMessage("wl", message, distribution, sender)
      elseif prefix == PREFIX_RAID then
        onKindAddonMessage("raid", message, distribution, sender)
      end
    end
    Comm:RegisterComm(PREFIX_WL, onComm)
    Comm:RegisterComm(PREFIX_RAID, onComm)
  elseif C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX_WL)
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX_RAID)
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
      -- AceComm owns GMBHWL / GMBHRS; only presence (and legacy fallback) here.
      if prefix == PRESENCE_PREFIX then
        onPresenceMessage(prefix, message, channel, sender)
      elseif not (GmbHLootTrackerComm and GmbHLootTrackerComm.SendCommMessage) then
        onAddonMessage(prefix, message, channel, sender)
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
