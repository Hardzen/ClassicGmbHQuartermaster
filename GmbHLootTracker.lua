--[[ Classic GmbH Quartermaster — Wishlist-by-item style main window + slash helpers ]]

local ADDON_NAME = "ClassicGmbHQuartermaster"
local MAX_RESULTS = 12
local MAX_CANDIDATES = 80
local ROW_HEIGHT = 34
local TABLE_INNER_WIDTH = 860

-- Column widths matching website Wishlist-by-item table (approx).
local COL = {
  player = 198,
  class = 70,
  role = 78,
  prio = 36,
  lost = 36,
  naxx = 52,
  aq = 44,
  total = 52,
  last = 168,
  date = 78,
}

local function printMsg(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffGmbH|r " .. tostring(msg))
end

-- Helper writes HelperData.lua (AddOns folder). Never trust SavedVariables as the
-- primary source — Classic often loads GmbHLootTrackerDB = nil from SV and wipes data.
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

local function debugHelperState()
  local h = GmbHLootTrackerHelperData
  local s = GmbHLootTrackerDB
  local d = db()
  printMsg(string.format(
    "debug HelperData=%s syncedAt=%s | SV=%s syncedAt=%s | db()=%s",
    type(h),
    tostring(type(h) == "table" and h.syncedAt or "—"),
    type(s),
    tostring(type(s) == "table" and s.syncedAt or "—"),
    type(d)
  ))
  if type(h) ~= "table" then
    printMsg("HelperData did not load. Check for red Lua errors, then /reload after helper writes HelperData.lua")
  elseif type(d) ~= "table" or not d.syncedAt then
    printMsg("HelperData loaded but db() empty — report this.")
  else
    local n = 0
    if type(d.items) == "table" then
      for _ in pairs(d.items) do
        n = n + 1
      end
    end
    printMsg(string.format("OK items=%d revision=%s", n, tostring(d.revision or "?"):sub(1, 8)))
  end
end

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function formatSyncedAt(raw)
  if not raw or raw == "" then
    return "never"
  end
  -- ISO 8601 → "YYYY-MM-DD HH:MM UTC"
  local y, m, d, hh, mm = tostring(raw):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d)")
  if y then
    return string.format("%s-%s-%s %s:%s UTC", y, m, d, hh, mm)
  end
  return tostring(raw)
end

local function defaultRaid()
  local data = db()
  if not data or type(data.raids) ~= "table" then
    return "naxx"
  end

  -- Next raid = earliest sheet with event_start_at on/after today (UTC).
  -- If none upcoming, fall back to the latest announced/has_sheet raid.
  local today = date("!%Y-%m-%d")
  local upcoming = {}
  local past = {}
  for slug, raid in pairs(data.raids) do
    if type(raid) == "table" and raid.has_sheet then
      local startAt = tostring(raid.event_start_at or "")
      local day = startAt:match("^(%d%d%d%d%-%d%d%-%d%d)") or ""
      local row = {
        slug = string.lower(tostring(slug)),
        startAt = startAt,
        day = day,
        announced = raid.announced and true or false,
      }
      if day ~= "" and day >= today then
        table.insert(upcoming, row)
      else
        table.insert(past, row)
      end
    end
  end

  local function byStart(a, b)
    if a.startAt ~= b.startAt then
      return a.startAt < b.startAt
    end
    return a.slug < b.slug
  end

  if #upcoming > 0 then
    table.sort(upcoming, byStart)
    return upcoming[1].slug
  end

  if #past > 0 then
    table.sort(past, byStart)
    return past[#past].slug
  end

  if data.raids.naxx and data.raids.naxx.has_sheet then
    return "naxx"
  end
  if data.raids.aq40 and data.raids.aq40.has_sheet then
    return "aq40"
  end
  return "naxx"
end

-- Prefer the raid sheet for the instance you are currently inside.
local INSTANCE_ZONE_SLUG = {
  ["ahn'qiraj"] = "aq40",
  ["temple of ahn'qiraj"] = "aq40",
  ["the temple of ahn'qiraj"] = "aq40",
  ["naxxramas"] = "naxx",
}

local SUBZONE_BOSS = {
  -- Naxx rooms / wings (AQ40 has almost no useful subzones).
  ["maexxna's nest"] = { slug = "naxx", label = "Maexxna" },
  ["sapphiron's lair"] = { slug = "naxx", label = "Sapphiron" },
  ["kel'thuzad's chamber"] = { slug = "naxx", label = "Kel'Thuzad" },
  ["the horsemen's assembly"] = { slug = "naxx", label = "Four Horsemen" },
  ["the arachnid quarter"] = { slug = "naxx", label = "Anub'Rekhan" },
  ["the construct quarter"] = { slug = "naxx", label = "Patchwerk" },
  ["the plague quarter"] = { slug = "naxx", label = "Noth the Plaguebringer" },
  ["the military quarter"] = { slug = "naxx", label = "Instructor Razuvious" },
  ["the halls of reanimation"] = { slug = "naxx", label = "Patchwerk" },
  ["frostwyrm lair"] = { slug = "naxx", label = "Sapphiron" },
  ["the frostwyrm lair"] = { slug = "naxx", label = "Sapphiron" },
}

-- NPC name substring → section title (English client).
local BOSS_NAME_HINTS = {
  aq40 = {
    { "skeram", "Prophet Skeram" },
    { "lord kri", "Bug Trio" },
    { "princess yauj", "Bug Trio" },
    { "yauj", "Bug Trio" },
    { "vem", "Bug Trio" },
    { "sartura", "Battleguard Sartura" },
    { "fankriss", "Fankriss" },
    { "viscidus", "Viscidus" },
    { "huhuran", "Princess Huhuran" },
    { "ouro", "Ouro" },
    { "vek'lor", "Twin Emperors" },
    { "vek'nilash", "Twin Emperors" },
    { "veklor", "Twin Emperors" },
    { "veknilash", "Twin Emperors" },
    { "eye of c'thun", "C'Thun" },
    { "c'thun", "C'Thun" },
  },
  naxx = {
    { "anub'rekhan", "Anub'Rekhan" },
    { "anubrekhan", "Anub'Rekhan" },
    { "faerlina", "Grand Widow Faerlina" },
    { "maexxna", "Maexxna" },
    { "noth", "Noth the Plaguebringer" },
    { "heigan", "Heigan the Unclean" },
    { "loatheb", "Loatheb" },
    { "patchwerk", "Patchwerk" },
    { "grobbulus", "Grobbulus" },
    { "gluth", "Gluth" },
    { "thaddius", "Thaddius" },
    { "stalagg", "Thaddius" },
    { "feugen", "Thaddius" },
    { "razuvious", "Instructor Razuvious" },
    { "gothik", "Gothik the Harvester" },
    { "blaumeux", "Four Horsemen" },
    { "korth'azz", "Four Horsemen" },
    { "korthazz", "Four Horsemen" },
    { "zeliek", "Four Horsemen" },
    { "rivendare", "Four Horsemen" },
    { "mograine", "Four Horsemen" },
    { "sapphiron", "Sapphiron" },
    { "kel'thuzad", "Kel'Thuzad" },
    { "kelthuzad", "Kel'Thuzad" },
  },
}

local function normZone(s)
  return string.lower(tostring(s or "")):gsub("^%s+", ""):gsub("%s+$", "")
end

local function instanceRaidSlug()
  local inInstance, instanceType = IsInInstance()
  if not inInstance or (instanceType ~= "raid" and instanceType ~= "party") then
    -- Still allow zone-name match (some Classic builds report oddly).
  end
  local zone = normZone(GetRealZoneText and GetRealZoneText() or "")
  if INSTANCE_ZONE_SLUG[zone] then
    return INSTANCE_ZONE_SLUG[zone], zone
  end
  -- Fuzzy: "Something Ahn'Qiraj" / Temple…
  if string.find(zone, "ahn'qiraj", 1, true) or string.find(zone, "ahnqiraj", 1, true) then
    if not string.find(zone, "ruins", 1, true) then
      return "aq40", zone
    end
  end
  if string.find(zone, "naxx", 1, true) then
    return "naxx", zone
  end
  if GetInstanceInfo then
    local name = GetInstanceInfo()
    local iname = normZone(name)
    if INSTANCE_ZONE_SLUG[iname] then
      return INSTANCE_ZONE_SLUG[iname], iname
    end
    if string.find(iname, "ahn'qiraj", 1, true) and not string.find(iname, "ruins", 1, true) then
      return "aq40", iname
    end
    if string.find(iname, "naxx", 1, true) then
      return "naxx", iname
    end
  end
  return nil, zone
end

local function preferredRaidSlug()
  local inst = instanceRaidSlug()
  if inst then
    local data = db()
    local raid = data and data.raids and data.raids[inst]
    if type(raid) == "table" and raid.has_sheet then
      return inst
    end
  end
  return defaultRaid()
end

local function bossLabelFromUnitName(slug, unitName)
  local name = normZone(unitName)
  if name == "" then
    return nil
  end
  local hints = BOSS_NAME_HINTS[slug]
  if not hints then
    return nil
  end
  for _, row in ipairs(hints) do
    if string.find(name, row[1], 1, true) then
      return row[2]
    end
  end
  return nil
end

local function bossLabelFromSubzone(slug)
  local texts = {
    GetSubZoneText and GetSubZoneText() or "",
    GetMinimapZoneText and GetMinimapZoneText() or "",
  }
  for _, raw in ipairs(texts) do
    local key = normZone(raw)
    if key ~= "" then
      local hit = SUBZONE_BOSS[key]
      if hit and hit.slug == slug then
        return hit.label
      end
      -- Fuzzy wing names
      for sub, info in pairs(SUBZONE_BOSS) do
        if info.slug == slug and string.find(key, sub, 1, true) then
          return info.label
        end
      end
    end
  end
  return nil
end

local function detectBossSectionLabel(slug)
  slug = string.lower(tostring(slug or ""))
  -- HUD test override ( /gmbh target <boss> ) works outside the instance.
  if GmbHLootTrackerUI and GmbHLootTrackerUI.hudTestBoss and GmbHLootTrackerUI.hudTestSlug == slug then
    return GmbHLootTrackerUI.hudTestBoss
  end
  local inst = instanceRaidSlug()
  if not inst or inst ~= slug then
    return nil
  end
  -- Prefer concrete boss from target / mouseover / focus.
  local units = { "target", "focus", "mouseover" }
  for _, u in ipairs(units) do
    if UnitExists and UnitExists(u) then
      local label = bossLabelFromUnitName(slug, UnitName(u))
      if label then
        return label
      end
    end
  end
  -- Then subzone / minimap text (Naxx wings & rooms).
  local fromZone = bossLabelFromSubzone(slug)
  if fromZone then
    return fromZone
  end
  return nil
end

local function matchBossSectionLabel(bossSections, want)
  if not want or want == "" then
    return nil
  end
  local wantLow = string.lower(want)
  for _, section in ipairs(bossSections or {}) do
    local lab = tostring(section.label or "")
    local low = string.lower(lab)
    if low == wantLow then
      return lab
    end
  end
  for _, section in ipairs(bossSections or {}) do
    local lab = tostring(section.label or "")
    local low = string.lower(lab)
    if string.find(low, wantLow, 1, true) or string.find(wantLow, low, 1, true) then
      return lab
    end
  end
  return nil
end

local function raidData(slug)
  local data = db()
  if not data or not data.raids then
    return nil
  end
  slug = string.lower(slug or defaultRaid())
  return data.raids[slug]
end

-- After raidData/matchBossSectionLabel exist: resolve boss from target via hints + sheet titles.
local function detectBossSectionLabelResolved(slug)
  local hint = detectBossSectionLabel(slug)
  if hint then
    return hint
  end
  slug = string.lower(tostring(slug or ""))
  local inst = instanceRaidSlug()
  if not inst or inst ~= slug then
    return nil
  end
  local raid = raidData(slug)
  if type(raid) ~= "table" then
    return nil
  end
  local sections = {}
  for _, section in ipairs(raid.sections or {}) do
    if tostring(section.label or "") ~= "" then
      table.insert(sections, section)
    end
  end
  for _, a in ipairs(raid.assignments or {}) do
    local sec = tostring(a.section_label or "")
    if sec ~= "" then
      table.insert(sections, { label = sec })
    end
  end
  local units = { "target", "focus", "mouseover" }
  for _, u in ipairs(units) do
    if UnitExists and UnitExists(u) then
      local unitName = UnitName(u)
      if unitName and unitName ~= "" then
        local matched = matchBossSectionLabel(sections, unitName)
        if matched then
          return matched
        end
      end
    end
  end
  return nil
end

local function resolveHudTestBoss(query)
  query = trim(tostring(query or ""))
  if query == "" then
    return nil, nil
  end
  local qLow = string.lower(query)
  -- NPC-name hints first (cthun, sartura, patchwerk, …).
  for _, slug in ipairs({ "aq40", "naxx" }) do
    local label = bossLabelFromUnitName(slug, query)
    if label then
      return slug, label
    end
  end
  -- Exact / fuzzy match against sheet section titles.
  local slugOrder = { preferredRaidSlug(), "aq40", "naxx" }
  local seen = {}
  for _, slug in ipairs(slugOrder) do
    if slug and not seen[slug] then
      seen[slug] = true
      local raid = raidData(slug)
      if type(raid) == "table" and raid.has_sheet then
        local sections = {}
        if type(raid.sections) == "table" then
          for _, section in ipairs(raid.sections) do
            local lab = tostring(section.label or "")
            local low = string.lower(lab)
            if low ~= "" and low ~= "raid groups" and low ~= "groups"
              and not (low:find("general", 1, true) or low:find("utility", 1, true))
            then
              table.insert(sections, section)
            end
          end
        end
        for _, a in ipairs(raid.assignments or {}) do
          local sec = tostring(a.section_label or "")
          if sec ~= "" then
            local found = false
            for _, s in ipairs(sections) do
              if tostring(s.label) == sec then
                found = true
                break
              end
            end
            if not found then
              table.insert(sections, { label = sec })
            end
          end
        end
        local label = matchBossSectionLabel(sections, query)
        if label then
          return slug, label
        end
        for _, section in ipairs(sections) do
          local lab = tostring(section.label or "")
          if string.find(string.lower(lab), qLow, 1, true) then
            return slug, lab
          end
        end
      end
    end
  end
  return nil, nil
end

local function queryMatches(hay, q)
  if not hay or hay == "" then
    return false
  end
  return string.find(string.lower(hay), q, 1, true) ~= nil
end

local function searchItems(query)
  local data = db()
  local items = data and data.items or {}
  local q = string.lower(trim(query))
  if q == "" then
    return {}
  end
  local idQ = q:match("^#?(%d+)$")
  local hits = {}
  for itemId, meta in pairs(items) do
    local name = meta and meta.name or ""
    local match = false
    if idQ and tostring(itemId) == idQ then
      match = true
    elseif queryMatches(name, q) then
      match = true
    else
      for _, alias in ipairs((meta and meta.aliases) or {}) do
        if queryMatches(alias, q) then
          match = true
          break
        end
      end
    end
    if match then
      table.insert(hits, {
        itemId = tostring(itemId),
        name = name,
        catalog_key = meta and meta.catalog_key,
      })
    end
  end
  table.sort(hits, function(a, b)
    return string.lower(a.name) < string.lower(b.name)
  end)
  while #hits > MAX_RESULTS do
    table.remove(hits)
  end
  return hits
end

local function candidatesForItem(itemId)
  local data = db()
  if not data then
    return {}
  end
  local byItem = data.wishlistByItem
  local key = tostring(itemId)
  local rows = {}
  if byItem and byItem[key] then
    for _, row in ipairs(byItem[key]) do
      if not row.has_item then
        table.insert(rows, row)
      end
    end
  else
    -- Members: only own wishlists — find who has this item_id listed.
    for playerName, wl in pairs(data.wishlists or {}) do
      for _, item in ipairs(wl.items or {}) do
        if tostring(item.item_id or "") == key and not item.has_item then
          table.insert(rows, {
            name = playerName,
            realm = wl.realm,
            priority = item.priority,
            lost_rolls = item.lost_rolls or 0,
            has_item = false,
            on_wishlist = true,
          })
        end
      end
    end
  end

  -- Same order as website get_item_wishlist_candidates():
  -- on wishlist → lost-roll +1s → attendance (instance) DESC → total DESC → prio ASC → name
  local sortBy = "total_ids"
  local meta = data.items and data.items[key]
  if meta and meta.sort_by then
    sortBy = tostring(meta.sort_by)
  end

  local function onWishlist(row)
    if row.on_wishlist ~= nil then
      return row.on_wishlist and true or false
    end
    return row.priority ~= nil
  end

  local function attendance(row)
    if sortBy == "naxx_ids" then
      return tonumber(row.naxx_ids) or 0
    end
    if sortBy == "aq40_ids" then
      return tonumber(row.aq40_ids) or 0
    end
    return tonumber(row.total_ids) or 0
  end

  table.sort(rows, function(a, b)
    local aw = onWishlist(a) and 0 or 1
    local bw = onWishlist(b) and 0 or 1
    if aw ~= bw then
      return aw < bw
    end

    local al = tonumber(a.lost_rolls) or 0
    local bl = tonumber(b.lost_rolls) or 0
    local az = al > 0 and 0 or 1
    local bz = bl > 0 and 0 or 1
    if az ~= bz then
      return az < bz
    end
    if al ~= bl then
      return al > bl
    end

    local aa = attendance(a)
    local ba = attendance(b)
    if aa ~= ba then
      return aa > ba
    end

    local at = tonumber(a.total_ids) or 0
    local bt = tonumber(b.total_ids) or 0
    if at ~= bt then
      return at > bt
    end

    local pa = a.priority ~= nil and tonumber(a.priority) or 999
    local pb = b.priority ~= nil and tonumber(b.priority) or 999
    if pa ~= pb then
      return pa < pb
    end

    return string.lower(tostring(a.name or "")) < string.lower(tostring(b.name or ""))
  end)
  return rows
end

local function coloredText(hex, text)
  if hex and tostring(hex) ~= "" then
    local h = tostring(hex):gsub("^#", "")
    if #h >= 6 then
      return "|cff" .. string.sub(h, 1, 6) .. tostring(text) .. "|r"
    end
  end
  return tostring(text or "")
end

local CLASS_HEX = {
  warrior = "C79C6E",
  paladin = "F58CBA",
  hunter = "ABD473",
  rogue = "FFF569",
  priest = "FFFFFF",
  shaman = "0070DE",
  mage = "69CCF0",
  warlock = "9482C9",
  druid = "FF7D0A",
  deathknight = "C41F3B",
  monk = "00FF96",
  demonhunter = "A330C9",
  evoker = "33937F",
}

local function classHex(class)
  if not class then
    return nil
  end
  local raw = tostring(class)
  local token = string.upper(raw:gsub("%s+", ""):gsub("'", ""))
  if RAID_CLASS_COLORS and RAID_CLASS_COLORS[token] then
    local c = RAID_CLASS_COLORS[token]
    return string.format("%02X%02X%02X", (c.r or 1) * 255, (c.g or 1) * 255, (c.b or 1) * 255)
  end
  local key = string.lower(raw):gsub("%s+", ""):gsub("'", "")
  return CLASS_HEX[key]
end

local function playerColorHex(p)
  if not p then
    return nil
  end
  local cc = p.class_color or p.classColor
  if cc and tostring(cc) ~= "" then
    return tostring(cc):gsub("^#", "")
  end
  return classHex(p.class)
end

-- ITEM_QUALITY_COLORS-style hex (Classic). Index = quality 0..5.
local ITEM_QUALITY_HEX = {
  [0] = "9d9d9d", -- Poor
  [1] = "ffffff", -- Common
  [2] = "1eff00", -- Uncommon
  [3] = "0070dd", -- Rare
  [4] = "a335ee", -- Epic
  [5] = "ff8000", -- Legendary
}

local function qualityHex(quality)
  local q = tonumber(quality)
  if q and ITEM_QUALITY_HEX[q] then
    return ITEM_QUALITY_HEX[q]
  end
  return ITEM_QUALITY_HEX[4] -- raid loot default: epic
end

local function resolveItemInfo(itemId, fallbackName, fallbackQuality)
  local id = tonumber(itemId)
  if not id then
    return fallbackName, fallbackQuality, nil
  end
  local name, _, quality, _, _, _, _, _, _, texture = GetItemInfo(id)
  if name then
    return name, quality, texture
  end
  -- Kick Classic item cache so icons/names color up after GET_ITEM_INFO_RECEIVED.
  if C_Item and C_Item.RequestLoadItemDataByID then
    C_Item.RequestLoadItemDataByID(id)
  else
    GetItemInfo(id)
  end
  return fallbackName, fallbackQuality, nil
end

local function formatItemName(itemId, fallbackName, fallbackQuality)
  local name, quality = resolveItemInfo(itemId, fallbackName, fallbackQuality)
  if not name or tostring(name) == "" then
    return "—"
  end
  return coloredText(qualityHex(quality), name)
end

local function setItemIcon(tex, itemId, iconName)
  local icon
  local id = tonumber(itemId)
  if id then
    if GetItemIcon then
      icon = GetItemIcon(id)
    end
    if not icon then
      local _, _, _, _, _, _, _, _, _, texture = GetItemInfo(id)
      icon = texture
    end
    if not icon and C_Item and C_Item.RequestLoadItemDataByID then
      C_Item.RequestLoadItemDataByID(id)
    end
  end
  if not icon and iconName and tostring(iconName) ~= "" then
    local file = tostring(iconName):gsub("%.jpg$", ""):gsub("%.png$", "")
    icon = "Interface\\Icons\\" .. file
  end
  if icon then
    tex:SetTexture(icon)
    tex:Show()
  else
    tex:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
    if (itemId and tostring(itemId) ~= "") or (iconName and tostring(iconName) ~= "") then
      tex:Show()
    else
      tex:Hide()
    end
  end
end

local function formatPerfLine(cand)
  local bits = {}
  if cand.br ~= nil then
    table.insert(bits, "Br " .. tostring(math.floor(tonumber(cand.br) or 0)))
  end
  if cand.ov ~= nil then
    table.insert(bits, "Ov " .. tostring(math.floor(tonumber(cand.ov) or 0)))
  end
  local ilvl = tonumber(cand.ilvl)
  if ilvl then
    table.insert(bits, string.format("iLvl %.1f", ilvl))
  end
  if #bits == 0 then
    return ""
  end
  -- Match website: "Br 62 · Ov 68 - iLvl 79.0"
  if #bits == 3 then
    return bits[1] .. " · " .. bits[2] .. " - " .. bits[3]
  end
  return table.concat(bits, " · ")
end

-- ---------------------------------------------------------------------------
-- Main window (Wishlist by item layout) — Officer guild ranks only
-- ---------------------------------------------------------------------------

local UI = {}
GmbHLootTrackerUI = UI

local function setBackdrop(frame)
  if frame.SetBackdrop then
    frame:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8X8",
      edgeFile = "Interface\\Buttons\\WHITE8X8",
      edgeSize = 1,
      insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    frame:SetBackdropColor(0.09, 0.12, 0.18, 0.96)
    frame:SetBackdropBorderColor(0.22, 0.28, 0.38, 1)
  end
end

local function makeLabel(parent, text, size)
  local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  if size then
    fs:SetFont(fs:GetFont(), size)
  end
  fs:SetText(text or "")
  fs:SetTextColor(0.75, 0.80, 0.88)
  fs:SetJustifyH("LEFT")
  if fs.SetWordWrap then
    fs:SetWordWrap(false)
  end
  if fs.SetNonSpaceWrap then
    fs:SetNonSpaceWrap(false)
  end
  if fs.SetMaxLines then
    fs:SetMaxLines(1)
  end
  return fs
end

local MARK_ICON = {
  -- Compact size so icons sit inline ahead of names in narrow grid cells.
  skull = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_8:10:10:0:0|t",
  cross = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_7:10:10:0:0|t",
  square = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_6:10:10:0:0|t",
  moon = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_5:10:10:0:0|t",
  triangle = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_4:10:10:0:0|t",
  diamond = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_3:10:10:0:0|t",
  circle = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_2:10:10:0:0|t",
  star = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:10:10:0:0|t",
}

local function markIcon(mark)
  local key = string.lower(tostring(mark or ""))
  return MARK_ICON[key] or nil
end

local function markIconsText(marks)
  if not marks or #marks == 0 then
    return ""
  end
  local bits = {}
  for _, m in ipairs(marks) do
    local ic = markIcon(m)
    if ic then
      table.insert(bits, ic)
    end
  end
  return table.concat(bits, "")
end

-- Shared by GmbHLootTrackerRaidSheet.lua (loaded after this file).
GmbHLootTrackerUtil = {
  makeLabel = makeLabel,
  coloredText = coloredText,
  classHex = classHex,
  playerColorHex = playerColorHex,
  setBackdrop = setBackdrop,
  markIcon = markIcon,
  markIconsText = markIconsText,
  MARK_ICON = MARK_ICON,
}

local function makeTextButton(parent, label, width)
  local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  btn:SetSize(width or 80, 22)
  btn:SetText(label)
  return btn
end

function UI:RefreshOfficerControls()
  local officer = GmbHLootTrackerSync and GmbHLootTrackerSync.CanUseWishlist and GmbHLootTrackerSync.CanUseWishlist()
  if self.pushSyncBtn then
    if officer then
      self.pushSyncBtn:Show()
    else
      self.pushSyncBtn:Hide()
    end
  end
  if self.syncLabel and self.reloadBtn then
    local right = (officer and self.pushSyncBtn) or self.reloadBtn
    self.syncLabel:SetPoint("RIGHT", right, "LEFT", -8, 0)
  end
end

function UI:RefreshSyncLabel()
  if not self.syncLabel then
    return
  end
  self:RefreshOfficerControls()
  local data = db()
  local hasData = type(data) == "table" and data.syncedAt and tostring(data.syncedAt) ~= ""
  if not hasData and GmbHLootTrackerSync and GmbHLootTrackerSync.HasSyncedPayload then
    hasData = GmbHLootTrackerSync.HasSyncedPayload()
  end
  local rank = nil
  if GmbHLootTrackerSync then
    local _
    _, rank = GmbHLootTrackerSync.PlayerGuildRank()
  end
  local rankBit = rank and ("  ·  rank " .. rank) or ""
  local mine = (GmbHLootTrackerSync and GmbHLootTrackerSync.LocalVersion and GmbHLootTrackerSync.LocalVersion())
    or "?"
  local verBit = "  ·  v" .. tostring(mine)
  if GmbHLootTrackerSync and GmbHLootTrackerSync.HasNewerVersion then
    local newer, best, who = GmbHLootTrackerSync.HasNewerVersion()
    if newer then
      verBit = string.format(
        "  ·  v%s  ·  |cffffcc00update %s|r%s",
        tostring(mine),
        tostring(best),
        who and (" (via " .. tostring(who) .. ")") or ""
      )
    end
  end
  if self.titleLabel then
    self.titleLabel:SetText("Classic GmbH Quartermaster  |cff9aa7b8v" .. tostring(mine) .. "|r")
  end

  local live = GmbHLootTrackerSync and GmbHLootTrackerSync.GetLiveStatus and GmbHLootTrackerSync.GetLiveStatus()
  local liveBit = ""
  if live and live ~= "" then
    liveBit = "  ·  |cff66ccff" .. live .. "|r"
  end

  if not hasData then
    self.syncLabel:SetText(
      "Last synced: |cffffffffnever|r  ·  |cffff8040no data|r" .. rankBit .. verBit .. liveBit
    )
    return
  end

  data = db()
  local synced = formatSyncedAt(data and data.syncedAt)
  local rev = data and data.revision and string.sub(tostring(data.revision), 1, 8) or "—"
  local source = "local"
  if data.syncSource == "guild" then
    source = "guild" .. (data.syncFrom and (" via " .. tostring(data.syncFrom)) or "")
  elseif data.syncSource == "helper" or (data.user and data.user.id) then
    source = "helper"
  elseif data.syncSource then
    source = tostring(data.syncSource)
  end
  local raidStamp = data.raidSyncedAt and formatSyncedAt(data.raidSyncedAt) or nil
  local raidBit = ""
  if raidStamp and raidStamp ~= synced then
    raidBit = "  ·  raid " .. raidStamp
  end
  self.syncLabel:SetText(string.format(
    "Last synced: |cffffffff%s|r  ·  rev %s  ·  %s%s%s%s%s",
    synced,
    rev,
    source,
    raidBit,
    rankBit,
    verBit,
    liveBit
  ))
end

function UI.OnDataUpdated()
  -- Sync must never touch widgets. Sheet/wishlist render only when the player opens /gmbh.
  UI._dataDirty = true
end

function UI:EmptyHint()
  local data = db()
  local hasData = type(data) == "table" and data.syncedAt and tostring(data.syncedAt) ~= ""
  if not hasData then
    return (
      "No data loaded. 1) helper run  2) /reload  3) /gmbh debug  "
        .. "(reads Interface\\AddOns\\ClassicGmbHQuartermaster\\HelperData.lua)"
    )
  end
  return "Type an item name (e.g. Kingsfall) — results appear under the field."
end

local ADDON_CHECK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:11:11:0:0|t "

local function inRaidForChecks()
  if IsInRaid and IsInRaid() then
    return true
  end
  local inInstance, instanceType = IsInInstance()
  return inInstance and instanceType == "raid"
end

local function formatRaidPlayer(p)
  if not p or not p.name then
    return "|cff555555—|r"
  end
  local rawName = tostring(p.name)
  local name = coloredText(playerColorHex(p), rawName)
  local me = UnitName and UnitName("player")
  if me then
    local a = string.lower(rawName:match("^([^%-]+)") or rawName)
    local b = string.lower(tostring(me):match("^([^%-]+)") or tostring(me))
    if a == b then
      name = name .. " |cff66cc66(you)|r"
    end
  end
  -- Addon checkmarks only while actually in a raid.
  if inRaidForChecks()
    and GmbHLootTrackerSync
    and GmbHLootTrackerSync.HasAddon
    and GmbHLootTrackerSync.HasAddon(p.name)
  then
    return ADDON_CHECK .. name
  end
  return name
end

local function styleTabButton(btn, active)
  if not btn.SetBackdropColor then
    return
  end
  if active then
    btn:SetBackdropColor(0.18, 0.28, 0.42, 1)
    btn:SetBackdropBorderColor(0.45, 0.58, 0.78, 1)
    if btn.label then
      btn.label:SetTextColor(1, 1, 1)
    end
  else
    btn:SetBackdropColor(0.10, 0.12, 0.16, 1)
    btn:SetBackdropBorderColor(0.22, 0.28, 0.38, 1)
    if btn.label then
      btn.label:SetTextColor(0.65, 0.70, 0.78)
    end
  end
end

local function makeMainTab(parent, text, width)
  local btn = CreateFrame("Button", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  btn:SetSize(width or 110, 26)
  setBackdrop(btn)
  btn.label = makeLabel(btn, text, 12)
  btn.label:SetPoint("CENTER")
  styleTabButton(btn, false)
  return btn
end

function UI:RefreshWishlistTabVisibility()
  local canWl = GmbHLootTrackerSync and GmbHLootTrackerSync.CanUseWishlist and GmbHLootTrackerSync.CanUseWishlist()
  self:RefreshOfficerControls()
  if self.tabWishlist then
    if canWl then
      self.tabWishlist:Show()
    else
      self.tabWishlist:Hide()
      if self.mainTab == "wishlist" then
        self.mainTab = "raid"
      end
    end
  end
  if self.tabOptions and self.tabRaid then
    self.tabOptions:ClearAllPoints()
    if canWl and self.tabWishlist and self.tabWishlist:IsShown() then
      self.tabOptions:SetPoint("LEFT", self.tabWishlist, "RIGHT", 6, 0)
    else
      self.tabOptions:SetPoint("LEFT", self.tabRaid, "RIGHT", 6, 0)
    end
  end
end

function UI:SetMainTab(tab)
  self.mainTab = tab or "raid"
  local canWl = GmbHLootTrackerSync and GmbHLootTrackerSync.CanUseWishlist()
  self:RefreshWishlistTabVisibility()
  if self.mainTab == "wishlist" and not canWl then
    self.mainTab = "raid"
  end
  local mode = self.mainTab

  if self.tabRaid then
    styleTabButton(self.tabRaid, mode == "raid")
  end
  if self.tabWishlist then
    styleTabButton(self.tabWishlist, mode == "wishlist")
  end
  if self.tabOptions then
    styleTabButton(self.tabOptions, mode == "options")
  end

  if self.raidPanel then
    self.raidPanel:Hide()
  end
  if self.contentPanel then
    self.contentPanel:Hide()
  end
  if self.lockPanel then
    self.lockPanel:Hide()
  end
  if self.optionsPanel then
    self.optionsPanel:Hide()
  end

  if mode == "raid" then
    if self.raidPanel then
      self.raidPanel:Show()
    end
    self:ApplyInstanceBossView({ force = true })
    self:RenderRaidSheet()
    return
  end

  if mode == "options" then
    if self.optionsPanel then
      self.optionsPanel:Show()
    end
    self:RefreshOptionsPanel()
    return
  end

  -- Wishlist tab (Classic GmbH Officer / Headmaster only — tab is hidden otherwise).
  if not canWl then
    if self.raidPanel then
      self.raidPanel:Show()
    end
    self:ApplyInstanceBossView({ force = true })
    self:RenderRaidSheet()
    return
  end
  if self.contentPanel then
    self.contentPanel:Show()
  end
  if self.searchBox then
    self.searchBox:SetFocus()
  end
  if self.selectedItemId then
    self:RenderCandidates()
  else
    self:ShowEmpty(self:EmptyHint())
  end
end

function UI:SetRaidSlug(slug)
  self.raidSlug = string.lower(slug or defaultRaid())
  self:RenderRaidSheet()
end

local function isTankingSectionLabel(label, section)
  if section and tostring(section.id or "") == "general_tanks" then
    return true
  end
  local l = string.lower(tostring(label or ""))
  if l == "" then
    return false
  end
  if string.find(l, "tanking", 1, true) then
    return true
  end
  if string.find(l, "groupheal", 1, true) then
    return true
  end
  if string.find(l, "general tank", 1, true) then
    return true
  end
  return false
end

local function isGeneralSectionLabel(label, section)
  if isTankingSectionLabel(label, section) then
    return false
  end
  local l = string.lower(tostring(label or ""))
  if l == "" or l == "raid groups" then
    return false
  end
  if string.find(l, "buff", 1, true) then
    return true
  end
  if string.find(l, "debuff", 1, true) then
    return true
  end
  if string.find(l, "general", 1, true) then
    return true
  end
  if string.find(l, "utility", 1, true) then
    return true
  end
  if string.find(l, "consumable", 1, true) then
    return true
  end
  return false
end

local function shortTabLabel(label, maxLen)
  local text = tostring(label or "")
  maxLen = maxLen or 16
  if #text <= maxLen then
    return text
  end
  return string.sub(text, 1, maxLen - 1) .. "…"
end

function UI:CollectRaidSections(raid)
  local sections = raid.sections
  if type(sections) ~= "table" or #sections == 0 then
    sections = {}
    local bySec = {}
    for _, a in ipairs(raid.assignments or {}) do
      local sec = tostring(a.section_label or "Assignments")
      local board = tostring(a.board_label or "")
      bySec[sec] = bySec[sec] or {}
      bySec[sec][board] = bySec[sec][board] or {}
      table.insert(bySec[sec][board], a)
    end
    local secNames = {}
    for sec in pairs(bySec) do
      table.insert(secNames, sec)
    end
    table.sort(secNames)
    for _, sec in ipairs(secNames) do
      local boards = {}
      local boardNames = {}
      for b in pairs(bySec[sec]) do
        table.insert(boardNames, b)
      end
      table.sort(boardNames)
      for _, b in ipairs(boardNames) do
        local slots = {}
        for _, a in ipairs(bySec[sec][b]) do
          table.insert(slots, {
            id = a.slot_id,
            label = a.label,
            mark = a.mark,
            player_name = a.player_name,
            class = a.class,
            class_color = a.class_color,
            role = a.role,
          })
        end
        table.insert(boards, { label = b, slots = slots })
      end
      table.insert(sections, {
        id = "",
        label = sec,
        boards = boards,
      })
    end
  end

  local general = {}
  local tanking = {}
  local bosses = {}
  for _, section in ipairs(sections) do
    local label = tostring(section.label or "")
    local low = string.lower(label)
    if low == "raid groups" or low == "groups" then
      -- handled by Groups tab
    elseif isTankingSectionLabel(label, section) then
      table.insert(tanking, section)
    elseif isGeneralSectionLabel(label, section) then
      table.insert(general, section)
    else
      table.insert(bosses, section)
    end
  end
  return general, tanking, bosses
end

function UI:EnsureRaidNavTab(i)
  self.raidNavTabs = self.raidNavTabs or {}
  local btn = self.raidNavTabs[i]
  if btn then
    return btn
  end
  btn = makeMainTab(self.raidTabChild, "", 90)
  btn:SetScript("OnClick", function(selfBtn)
    if selfBtn.viewKey then
      UI:SetRaidView(selfBtn.viewKey)
    end
  end)
  self.raidNavTabs[i] = btn
  return btn
end

function UI:RebuildRaidNavTabs(generalSections, tankingSections, bossSections)
  if not self.raidTabChild then
    return
  end
  local row1 = {
    { key = "groups", label = "Groups" },
    { key = "general", label = "General" },
    { key = "tanking", label = "General Tanking" },
  }
  local row2 = {}
  for _, section in ipairs(bossSections or {}) do
    local label = tostring(section.label or "Boss")
    table.insert(row2, {
      key = "boss:" .. label,
      label = shortTabLabel(label, 15),
      full = label,
    })
  end

  local ROW_H = 26
  local GAP = 5
  local tabIdx = 0
  local maxW = 200

  local function placeRow(tabs, y)
    local x = 0
    for _, tab in ipairs(tabs) do
      tabIdx = tabIdx + 1
      local btn = self:EnsureRaidNavTab(tabIdx)
      local width = math.max(70, math.min(130, 10 + #tab.label * 7))
      btn:SetWidth(width)
      btn:ClearAllPoints()
      btn:SetPoint("TOPLEFT", self.raidTabChild, "TOPLEFT", x, y)
      btn.label:SetText(tab.label)
      btn.viewKey = tab.key
      btn.fullLabel = tab.full
      btn:Show()
      styleTabButton(btn, self.raidView == tab.key)
      x = x + width + GAP
    end
    if x > maxW then
      maxW = x
    end
  end

  placeRow(row1, 0)
  placeRow(row2, -(ROW_H + 2))

  for i = tabIdx + 1, #(self.raidNavTabs or {}) do
    self.raidNavTabs[i]:Hide()
  end
  self.raidTabChild:SetWidth(math.max(maxW + 4, 200))
  self.raidTabChild:SetHeight(ROW_H * 2 + 4)
  self.raidNavSpec = {
    general = generalSections or {},
    tanking = tankingSections or {},
    bosses = bossSections or {},
  }

  -- If current view is a missing boss tab, fall back.
  local ok = self.raidView == "groups"
    or self.raidView == "general"
    or self.raidView == "tanking"
  if not ok and self.raidView and string.sub(self.raidView, 1, 5) == "boss:" then
    local want = string.sub(self.raidView, 6)
    for _, section in ipairs(bossSections or {}) do
      if tostring(section.label or "") == want then
        ok = true
        break
      end
    end
  end
  if not ok then
    self.raidView = "tanking"
  end
end

function UI:SetRaidView(view, opts)
  opts = opts or {}
  self.raidView = view or "groups"
  if opts.fromZone then
    self.raidViewUserPinned = false
    self.raidViewFromZone = self.raidView
  else
    self.raidViewUserPinned = true
  end
  for _, btn in ipairs(self.raidNavTabs or {}) do
    if btn:IsShown() then
      styleTabButton(btn, btn.viewKey == self.raidView)
    end
  end
  if self.sortRaidBtn then
    if self.raidView == "groups" then
      self.sortRaidBtn:Show()
    else
      self.sortRaidBtn:Hide()
    end
  end
  self:RenderRaidSheet()
  -- If Test HUD is active, follow the boss/tab you just opened.
  if self.hudTestBoss then
    local label = nil
    local v = self.raidView or ""
    if string.sub(v, 1, 5) == "boss:" then
      label = string.sub(v, 6)
    elseif v == "tanking" then
      label = "General tanking"
    elseif v == "general" then
      label = "Buffs"
    end
    if label and label ~= "" then
      self.hudTestSlug = preferredRaidSlug()
      self.hudTestBoss = label
      if self.assignHud then
        self.assignHud._userHidden = false
      end
      self:RefreshAssignHud({ manual = true })
    end
  end
end

-- Inside AQ40/Naxx: select the boss tab for current wing / targeted boss.
function UI:ApplyInstanceBossView(opts)
  opts = opts or {}
  local slug = preferredRaidSlug()
  local inst = instanceRaidSlug()
  if not inst or inst ~= slug then
    return false
  end
  local want = detectBossSectionLabelResolved(slug)
  if not want then
    return false
  end
  local raid = raidData(slug)
  if not raid then
    return false
  end
  local _, _, bossSections = self:CollectRaidSections(raid)
  local label = matchBossSectionLabel(bossSections, want)
  if not label then
    return false
  end
  local view = "boss:" .. label
  if self.raidView == view then
    self.raidViewFromZone = view
    return false
  end
  if self.raidViewUserPinned and not opts.force then
    return false
  end
  self.raidView = view
  self.raidViewFromZone = view
  self.raidViewUserPinned = false
  return true
end

local function barePlayerName(name)
  local n = tostring(name or "")
  n = n:match("^([^%-]+)") or n
  return string.lower(n)
end

local function myPlayerKey()
  return barePlayerName(UnitName("player"))
end

local function shortBossTitle(label)
  local t = tostring(label or "boss")
  t = t:gsub("^Princess%s+", "")
  t = t:gsub("^The%s+", "")
  t = t:gsub("^Grand Widow%s+", "")
  t = t:gsub("^Instructor%s+", "")
  t = t:gsub("^Noth the%s+", "Noth ")
  t = t:gsub("^Heigan the%s+", "Heigan ")
  t = t:gsub("^Gothik the%s+", "Gothik ")
  t = t:gsub("%s+&%s+groupheal.*$", "")
  t = t:gsub("%s+&%s+healers.*$", "")
  return t
end

local function formatPersonalRole(slotLabel, bossLabel, boardLabel, markKey, healTankName, twinsSide, twinsLockName, twinsLockMark)
  local role = tostring(slotLabel or "Assignment")
  local boss = shortBossTitle(bossLabel)
  local mob = tostring(boardLabel or "")
  if mob == "" or mob == tostring(bossLabel or "") then
    mob = boss
  else
    mob = mob:gsub("^Skeram %- ", "Skeram ")
  end
  -- Twins: always use Left / Right / Bugs as the place name.
  if twinsSide and twinsSide ~= "" then
    if twinsSide == "Bugs" then
      mob = "Mutated Bugs"
    else
      mob = twinsSide .. " twin"
    end
  end
  local low = string.lower(role)
  local g = role:match("[Gg]%s*(%d+)") or role:match("group%s*(%d+)")
  local ic = markIcon(markKey)
  local lockIc = markIcon(twinsLockMark)
  local lockBit = ""
  if twinsLockName and twinsLockName ~= "" then
    if lockIc then
      lockBit = string.format(" · lock %s %s", lockIc, twinsLockName)
    else
      lockBit = " · lock " .. twinsLockName
    end
  end

  local function tankingLine(kind)
    if ic then
      return string.format("%s %s %s%s", kind, ic, mob, lockBit)
    end
    return string.format("%s %s%s", kind, mob, lockBit)
  end

  local function healLine()
    if low:match("^g%d+$") or string.find(low, "groupheal", 1, true) then
      local grp = role:match("[Gg]%s*(%d+)") or g
      if grp then
        return string.format("Groupheal G%s", grp)
      end
    end
    -- Twins: side + warrior tank + warlock lock tank.
    if twinsSide then
      local bits = { "Heal " .. mob }
      if healTankName and healTankName ~= "" then
        table.insert(bits, "tank " .. healTankName)
      end
      if twinsLockName and twinsLockName ~= "" then
        if lockIc then
          table.insert(bits, string.format("lock %s %s", lockIc, twinsLockName))
        else
          table.insert(bits, "lock " .. twinsLockName)
        end
      end
      return table.concat(bits, " · ")
    end
    -- Boss rows (Skeram etc.): heal the tank on that mark/mob.
    local target = (healTankName and healTankName ~= "") and healTankName or mob
    if ic then
      return string.format("Heal %s %s", ic, target)
    end
    return string.format("Heal %s", target)
  end

  if string.find(low, "dispel", 1, true) then
    if g then
      return string.format("Dispel group %s on %s", g, boss)
    end
    return "Dispel on " .. boss
  end
  if string.find(low, "backup tank", 1, true) or low == "backup" or low == "bt" then
    return tankingLine("Backup tanking")
  end
  if string.find(low, "lock tank", 1, true) or (string.find(low, "lock", 1, true) and string.find(low, "tank", 1, true)) then
    -- Lock tank themselves: no nested "lock Name" bit.
    if ic then
      return string.format("Lock tanking %s %s", ic, mob)
    end
    return "Lock tanking " .. mob
  end
  if low == "tank" or low == "mt" or low == "main tank" or low == "ot"
    or (string.find(low, "tank", 1, true) and not string.find(low, "heal", 1, true) and not string.find(low, "lock", 1, true))
  then
    return tankingLine("Tanking")
  end
  if string.find(low, "tank healer", 1, true) or string.find(low, "tank heal", 1, true)
    or string.find(low, "healer", 1, true) or low:match("^heal")
    or (string.find(low, "heal", 1, true) and not string.find(low, "kick", 1, true))
  then
    return healLine()
  end
  if low:match("^g%d+$") and string.find(string.lower(tostring(boardLabel or "")), "groupheal", 1, true) then
    return healLine()
  end
  if string.find(low, "kick", 1, true) then
    if mob ~= boss then
      return role .. " on " .. mob .. lockBit
    end
    return role .. " on " .. boss
  end
  if mob ~= boss or twinsSide then
    return role .. " on " .. mob .. lockBit
  end
  return role .. " on " .. boss
end

-- HUD assignment scope: "full" (default) or "mine". Saved per-character.
local function preferFullHudAssignments()
  local dbc = type(GmbHLootTrackerCharDB) == "table" and GmbHLootTrackerCharDB or nil
  if dbc and tostring(dbc.hudAssignments or "") == "mine" then
    return false
  end
  return true
end

-- Auto-open HUD in AQ40/Naxx on zone/target. Default on.
local function hudAutoShowEnabled()
  local dbc = type(GmbHLootTrackerCharDB) == "table" and GmbHLootTrackerCharDB or nil
  if dbc and dbc.hudAutoShow == false then
    return false
  end
  return true
end

local function canViewFullBossAssignments()
  return preferFullHudAssignments()
end

local function canViewCthunMarkRoster()
  return preferFullHudAssignments()
end

local CTHUN_MARK_ORDER = { "skull", "cross", "square", "moon", "triangle", "diamond", "circle", "star" }

local function cthunSlotMark(slot, board)
  local m = string.lower(tostring((slot and slot.mark) or ""))
  if m ~= "" and markIcon(m) then
    return m
  end
  local bm = string.lower(tostring((board and board.mark) or ""))
  if bm ~= "" and markIcon(bm) then
    return bm
  end
  local bid = string.lower(tostring((board and board.id) or ""))
  local wi = tonumber(bid:match("cthun_w(%d+)"))
  if wi and CTHUN_MARK_ORDER[wi] then
    return CTHUN_MARK_ORDER[wi]
  end
  local sid = string.lower(tostring((slot and slot.id) or ""))
  wi = tonumber(sid:match("cthun_w(%d+)"))
  if wi and CTHUN_MARK_ORDER[wi] then
    return CTHUN_MARK_ORDER[wi]
  end
  return nil
end

local function isCthunSection(section)
  if type(section) ~= "table" then
    return false
  end
  local id = string.lower(tostring(section.id or ""))
  if id == "cthun" then
    return true
  end
  local lab = string.lower(tostring(section.label or ""))
  return lab == "c'thun" or lab == "cthun"
end

local function isPatchwerkSection(section)
  if type(section) ~= "table" then
    return false
  end
  local id = string.lower(tostring(section.id or ""))
  if id == "patchwerk" then
    return true
  end
  local lab = string.lower(tostring(section.label or ""))
  return lab == "patchwerk"
end

local function isPatchwerkStackSlot(slot)
  if type(slot) ~= "table" then
    return false
  end
  local sid = string.lower(tostring(slot.id or ""))
  return sid:match("^pw_c%d+_") ~= nil
end

-- Members: only their raid target icon. Officers/RL: each mark + melee on it
-- (same 2-per-stack as the C'Thun map). Healers/casters stay off the mark lines.
function UI:CollectCthunHudLines(section, full)
  if type(section) ~= "table" then
    return {}
  end
  local me = myPlayerKey()
  local byMark = {}
  local farNames = {}
  local myMark = nil

  local function isFarSlot(slot, board)
    local ring = string.lower(tostring((slot and slot.ring) or ""))
    local bid = string.lower(tostring((board and board.id) or ""))
    local sid = string.lower(tostring((slot and slot.id) or ""))
    return ring == "outer_melee"
      or string.find(bid, "outer", 1, true)
      or string.find(sid, "out_m", 1, true)
  end

  local function isMeleeStackSlot(slot)
    if type(slot) ~= "table" then
      return false
    end
    local ring = string.lower(tostring(slot.ring or ""))
    if ring == "melee" then
      return true
    end
    if ring == "healer" or ring == "caster" or ring == "outer_melee" then
      return false
    end
    local sid = string.lower(tostring(slot.id or ""))
    if string.find(sid, "cthun_w", 1, true) and sid:match("_m%d+$") then
      return true
    end
    local lab = string.lower(tostring(slot.label or ""))
    return lab:match("^melee") ~= nil
  end

  for _, board in ipairs(section.boards or {}) do
    for _, slot in ipairs(board.slots or {}) do
      local who = slot.player_name and tostring(slot.player_name) or ""
      if who ~= "" then
        local mk = cthunSlotMark(slot, board)
        if isFarSlot(slot, board) then
          table.insert(farNames, {
            name = who,
            slot = slot,
            isMe = barePlayerName(who) == me,
          })
          if barePlayerName(who) == me then
            myMark = "far"
          end
        elseif mk then
          -- Full HUD lists melee stacks only; still remember your own wedge mark.
          if isMeleeStackSlot(slot) then
            byMark[mk] = byMark[mk] or {}
            table.insert(byMark[mk], {
              name = who,
              slot = slot,
              isMe = barePlayerName(who) == me,
            })
          end
          if barePlayerName(who) == me then
            myMark = mk
          end
        end
      end
    end
  end

  if not full then
    if myMark == "far" then
      return { "|cff888888Far ring|r" }
    end
    if myMark then
      local big = string.format(
        "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_%d:22:22:0:0|t",
        ({ star = 1, circle = 2, diamond = 3, triangle = 4, moon = 5, square = 6, cross = 7, skull = 8 })[myMark] or 0
      )
      if big:find("Icon_0", 1, true) then
        return { markIcon(myMark) }
      end
      return { big }
    end
    return {}
  end

  local lines = {}
  for _, mk in ipairs(CTHUN_MARK_ORDER) do
    local people = byMark[mk]
    if people and #people > 0 then
      local names = {}
      for _, p in ipairs(people) do
        local bit = coloredText(playerColorHex(p.slot), p.name)
        if p.isMe then
          bit = bit .. " |cff66cc66(you)|r"
        end
        table.insert(names, bit)
      end
      table.insert(lines, markIcon(mk) .. " " .. table.concat(names, "  "))
    end
  end
  if #farNames > 0 then
    local names = {}
    for _, p in ipairs(farNames) do
      local bit = coloredText(playerColorHex(p.slot), p.name)
      if p.isMe then
        bit = bit .. " |cff66cc66(you)|r"
      end
      table.insert(names, bit)
    end
    table.insert(lines, "|cff888888Far|r " .. table.concat(names, "  "))
  end
  return lines
end

local function isTankingSlot(slot)
  if type(slot) ~= "table" then
    return false
  end
  local role = string.lower(tostring(slot.role or ""))
  if role == "tank" or role == "offtank" or role == "ot" or role == "mt" then
    return true
  end
  -- Explicit non-tank role wins (Patchwerk matrix: pw_c2_mt… are healers, ids end in _mt).
  if role ~= "" then
    return false
  end
  local lab = string.lower(tostring(slot.label or ""))
  if lab == "" then
    return false
  end
  if lab == "tank" or lab == "mt" or lab == "ot" or lab == "main tank" or lab == "off tank" then
    return true
  end
  if string.find(lab, "lock tank", 1, true) or string.find(lab, "backup tank", 1, true) then
    return true
  end
  if string.find(lab, "tank", 1, true) and not string.find(lab, "heal", 1, true) then
    return true
  end
  -- Soaker seats without role (legacy payloads).
  if lab == "soaker 1" or lab == "soaker 2" or lab:match("^soaker%s*%d+$") then
    return true
  end
  local sid = string.lower(tostring(slot.id or ""))
  -- Patchwerk: only C1 on each row is the tank (pw_c1_mt / pw_c1_s1 / pw_c1_s2).
  if sid:match("^pw_c1_") then
    return true
  end
  if sid:match("^pw_c%d+_") then
    return false
  end
  if string.find(sid, "_t$", 1, false) or string.find(sid, "_lock", 1, true) or string.find(sid, "_bt", 1, true) then
    return true
  end
  -- Exact role suffixes only — do not match pw_c2_mt (healer on MT row).
  if sid:match("_mt$") and not sid:match("^pw_") then
    return true
  end
  if sid:match("_ot$") then
    return true
  end
  return false
end

local function shortBoardPrefix(boardLab, sectionLabel, role)
  boardLab = tostring(boardLab or "")
  if boardLab == "" or boardLab == tostring(sectionLabel or "") then
    return nil
  end
  if string.find(string.lower(role or ""), string.lower(boardLab), 1, true) then
    return nil
  end
  local shortBoard = boardLab
    :gsub("^Skeram %- ", "")
    :gsub("^Left twin.*", "Left")
    :gsub("^Right twin.*", "Right")
  if #shortBoard > 18 then
    return nil
  end
  return shortBoard
end

local function formatHudAssignmentLine(role, slot, me, markOverride)
  local who = slot.player_name and tostring(slot.player_name) or ""
  local nameBit
  if who ~= "" then
    nameBit = coloredText(playerColorHex(slot), who)
    if barePlayerName(who) == me then
      nameBit = nameBit .. " |cff66cc66(you)|r"
    end
  else
    nameBit = "|cff666666—|r"
  end
  local ic = markIcon(markOverride)
  if not ic then
    local RS = GmbHLootTrackerRaidSheet
    if RS and RS.SlotMarkKey then
      ic = markIcon(RS.SlotMarkKey(slot))
    else
      ic = markIcon(slot and slot.mark)
    end
  end
  if ic and who ~= "" then
    return string.format("%s: %s%s", role, ic, nameBit)
  end
  return string.format("%s: %s", role, nameBit)
end

-- Per-slot raid mark for HUD. Bug Trio kill-order can override the whole row.
local function hudSlotMark(slot, entry)
  entry = entry or {}
  if entry.markOverride and entry.mark then
    return entry.mark
  end
  local RS = GmbHLootTrackerRaidSheet
  if RS and RS.SlotMarkKey then
    local mk = RS.SlotMarkKey(slot)
    if mk then
      return mk
    end
  end
  local raw = slot and slot.mark
  if raw and tostring(raw) ~= "" then
    return raw
  end
  return nil
end

function UI:CollectPersonalAssignments(section, raid)
  if isCthunSection(section) then
    return self:CollectCthunHudLines(section, false)
  end
  local me = myPlayerKey()
  if me == "" or type(section) ~= "table" then
    return {}
  end
  local bossLabel = tostring(section.label or "boss")
  local lines = {}
  local seen = {}
  local RS = GmbHLootTrackerRaidSheet
  local boards = (RS and RS.HudBoards) and RS.HudBoards(section, raid) or nil
  if not boards then
    boards = {}
    for _, board in ipairs(section.boards or {}) do
      table.insert(boards, { board = board, mark = nil })
    end
  end
  for _, entry in ipairs(boards) do
    local board = entry.board
    local boardLab = tostring(board.mob or board.label or "")
    local boardId = string.lower(tostring(board.id or ""))
    local boardLabLow = string.lower(boardLab)
    local twinsSide = nil
    local twinsLockName, twinsLockMark = nil, nil
    if RS then
      -- Only Twin Emperors boards get Left/Right/lock labeling (not "Skeram Left").
      local lowSec = string.lower(tostring(section.label or "") .. " " .. tostring(section.id or ""))
      if string.find(lowSec, "twin", 1, true) then
        twinsSide = RS.TwinsSideLabel and RS.TwinsSideLabel(board) or nil
        if twinsSide and RS.TwinsLockTank then
          twinsLockName, twinsLockMark = RS.TwinsLockTank(board)
        end
      end
    end
    for _, slot in ipairs(board.slots or {}) do
      if slot.player_name and barePlayerName(slot.player_name) == me then
        local mark = hudSlotMark(slot, entry)
        -- Twins: marks live on tank/lock slots (fallback when HelperData omits slot.mark).
        if twinsSide and not mark then
          local sid = string.lower(tostring(slot.id or ""))
          mark = ({
            twin_l_t = "triangle", twin_l_lock = "diamond",
            twin_r_t = "square", twin_r_lock = "moon",
            twin_bugs_t = "circle",
          })[sid]
        end
        local healTank = nil
        local roleLow = string.lower(tostring(slot.label or ""))
        local isHeal = string.find(roleLow, "heal", 1, true)
          or string.find(roleLow, "healer", 1, true)
          or tostring(slot.role or "") == "healer"
          or (roleLow:match("^g%d+$") and string.find(boardLabLow, "groupheal", 1, true))
        if isHeal then
          if string.find(boardLabLow, "tank heal", 1, true)
            or boardId == "aq_theal" or boardId == "tank_healers"
          then
            local mk, tankName = nil, nil
            if RS and RS.TankHealerTarget then
              mk, tankName = RS.TankHealerTarget(section, slot)
            end
            if mk then
              mark = mk
            end
            healTank = tankName
          else
            -- Boss row (Skeram Left / Twins side / etc.): find the Tank seat on this board.
            for _, s in ipairs(board.slots or {}) do
              if isTankingSlot(s) and s.player_name and tostring(s.player_name) ~= "" then
                healTank = tostring(s.player_name)
                break
              end
            end
          end
        end
        local line = formatPersonalRole(
          slot.label,
          bossLabel,
          boardLab,
          mark,
          healTank,
          twinsSide,
          twinsLockName,
          twinsLockMark
        )
        if line and not seen[line] then
          seen[line] = true
          table.insert(lines, line)
        end
      end
    end
  end
  return lines
end

function UI:CollectAllBossAssignments(section, raid)
  if isCthunSection(section) then
    return self:CollectCthunHudLines(section, true)
  end
  if type(section) ~= "table" then
    return {}
  end
  local me = myPlayerKey()
  local tankLines = {}
  local otherLines = {}
  local sectionLabel = tostring(section.label or "")
  local patchwerk = isPatchwerkSection(section)

  local RS = GmbHLootTrackerRaidSheet
  local boards = (RS and RS.HudBoards) and RS.HudBoards(section, raid) or nil
  if not boards then
    boards = {}
    for _, board in ipairs(section.boards or {}) do
      table.insert(boards, { board = board, mark = nil })
    end
  end

  -- Patchwerk: keep matrix order (MT + 4 heals, Soaker1 + 4, Soaker2 + 4).
  if patchwerk then
    local lines = {}
    for _, entry in ipairs(boards) do
      local board = entry.board
      for _, slot in ipairs(board.slots or {}) do
        if isPatchwerkStackSlot(slot) then
          local role = tostring(slot.label or "?")
          local mark = hudSlotMark(slot, nil)
          table.insert(lines, formatHudAssignmentLine(role, slot, me, mark))
        end
      end
    end
    return lines
  end

  for _, entry in ipairs(boards) do
    local board = entry.board
    local boardLab = tostring(board.label or "")
    for _, slot in ipairs(board.slots or {}) do
      local role = tostring(slot.label or "?")
      local prefix = shortBoardPrefix(boardLab, sectionLabel, role)
      if prefix then
        role = prefix .. " · " .. role
      end
      local who = slot.player_name and tostring(slot.player_name) or ""
      local tanking = isTankingSlot(slot)
      if tanking or who ~= "" then
        -- Per-slot icons (Twins lock vs tank, Anub guards, KT tanks, …).
        -- Bug Trio kill-order is the only board-wide override, and only on tanks.
        local mark
        if entry.markOverride and tanking then
          mark = entry.mark
        else
          mark = hudSlotMark(slot, nil)
        end
        local line = formatHudAssignmentLine(role, slot, me, mark)
        if tanking then
          table.insert(tankLines, line)
        else
          table.insert(otherLines, line)
        end
      end
    end
  end

  local lines = {}
  for _, line in ipairs(tankLines) do
    table.insert(lines, line)
  end
  for _, line in ipairs(otherLines) do
    table.insert(lines, line)
  end
  return lines
end

function UI:GetPersonalBossAssignmentLines()
  local testBoss = self.hudTestBoss
  local testSlug = self.hudTestSlug
  local inst = instanceRaidSlug()
  if not testBoss and not inst then
    return nil, nil, false
  end
  -- Always prefer the instance you are standing in (not "next upcoming" defaultRaid).
  local slug = testSlug or inst or preferredRaidSlug()
  local raid = raidData(slug)
  if not raid or not raid.has_sheet then
    return nil, nil, false
  end
  -- Locked member sheets still show HUD for targeted bosses (assignments may be empty).
  local want = testBoss or detectBossSectionLabelResolved(slug)
  if not want and self.raidView and string.sub(tostring(self.raidView), 1, 5) == "boss:" then
    want = string.sub(self.raidView, 6)
  end
  if not want and self.raidView == "tanking" then
    want = "General tanking"
  end
  if not want and self.raidView == "general" then
    want = "Buffs"
  end
  local full = canViewFullBossAssignments()
  if not want then
    return {}, nil, full
  end
  if raid.member_locked and not testBoss then
    -- Still open HUD so targeting a boss does something visible.
    return {
      "|cffcc8844Raid sheet not announced yet — assignments hidden.|r",
    }, want, full
  end
  local generalSections, tankingSections, bossSections = self:CollectRaidSections(raid)
  local allSections = {}
  for _, s in ipairs(tankingSections or {}) do
    table.insert(allSections, s)
  end
  for _, s in ipairs(generalSections or {}) do
    table.insert(allSections, s)
  end
  for _, s in ipairs(bossSections or {}) do
    table.insert(allSections, s)
  end
  local label = matchBossSectionLabel(allSections, want)
  if not label then
    return {}, want, full
  end
  local section = nil
  for _, s in ipairs(allSections) do
    if tostring(s.label or "") == label then
      section = s
      break
    end
  end
  if not section then
    return {}, label, full
  end
  if isCthunSection(section) then
    local cthunFull = canViewCthunMarkRoster()
    return self:CollectCthunHudLines(section, cthunFull), label, cthunFull
  end
  if full then
    return self:CollectAllBossAssignments(section, raid), label, true
  end
  return self:CollectPersonalAssignments(section, raid), label, false
end

-- UI prefs (HUD position, etc.) live in per-character SV so they survive reload
-- even when account SV is nil / overwritten by peer sync data.
local function charDB()
  if type(GmbHLootTrackerCharDB) ~= "table" then
    GmbHLootTrackerCharDB = {}
  end
  -- One-time migrate from older account-SV location.
  if GmbHLootTrackerCharDB.assignHud == nil
    and type(GmbHLootTrackerDB) == "table"
    and type(GmbHLootTrackerDB.assignHud) == "table"
  then
    GmbHLootTrackerCharDB.assignHud = GmbHLootTrackerDB.assignHud
  end
  return GmbHLootTrackerCharDB
end

function UI:GetHudAssignmentsMode()
  return preferFullHudAssignments() and "full" or "mine"
end

local HUD_SCALE_MIN = 0.75
local HUD_SCALE_MAX = 2.0
local HUD_SCALE_STEP = 0.25

-- Keep resize hit-targets roughly constant on screen when HUD scale is small.
local function refreshHudResizeHandles(frame)
  if not frame then
    return
  end
  local scale = frame:GetScale() or 1
  if scale < 0.01 then
    scale = 1
  end
  local gripSize = math.max(18, math.floor(28 / scale + 0.5))
  local edgeThick = math.max(10, math.floor(16 / scale + 0.5))
  local cornerClear = gripSize + 6
  if frame.resizeGrip then
    frame.resizeGrip:SetSize(gripSize, gripSize)
  end
  if frame.resizeBottom then
    frame.resizeBottom:SetHeight(edgeThick)
    frame.resizeBottom:ClearAllPoints()
    frame.resizeBottom:SetPoint("BOTTOMLEFT", 4, 0)
    frame.resizeBottom:SetPoint("BOTTOMRIGHT", -cornerClear, 0)
  end
  if frame.resizeRight then
    frame.resizeRight:SetWidth(edgeThick)
    frame.resizeRight:ClearAllPoints()
    -- Stay below the close button so the light-blue edge never covers the X.
    frame.resizeRight:SetPoint("TOPRIGHT", 0, -24)
    frame.resizeRight:SetPoint("BOTTOMRIGHT", 0, cornerClear)
  end
  if frame.close then
    frame.close:SetFrameLevel((frame:GetFrameLevel() or 0) + 20)
  end
end

local function clampHudScale(scale)
  scale = tonumber(scale) or 1
  if scale < HUD_SCALE_MIN then
    return HUD_SCALE_MIN
  end
  if scale > HUD_SCALE_MAX then
    return HUD_SCALE_MAX
  end
  -- Snap to 0.05 so saved values stay tidy.
  return math.floor(scale * 20 + 0.5) / 20
end

function UI:GetHudScale()
  local dbc = charDB()
  return clampHudScale(dbc and dbc.hudScale)
end

function UI:ApplyHudScale(frame)
  frame = frame or self.assignHud
  if not frame or not frame.SetScale then
    return
  end
  frame:SetScale(self:GetHudScale())
  refreshHudResizeHandles(frame)
end

function UI:SetHudScale(scale, quiet)
  local dbc = charDB()
  dbc.hudScale = clampHudScale(scale)
  self:ApplyHudScale()
  self:RefreshOptionsPanel()
  if self.RefreshAssignHud then
    self:RefreshAssignHud()
  end
  if not quiet then
    printMsg(string.format("HUD size: %d%%", math.floor(self:GetHudScale() * 100 + 0.5)))
  end
end

function UI:ResetHudSize()
  local f = self.assignHud
  if f then
    f._userSized = nil
  end
  local dbChar = charDB()
  local saved = type(dbChar.assignHud) == "table" and dbChar.assignHud or nil
  if saved then
    saved.userSized = nil
    saved.w = nil
    saved.h = nil
  end
  self:SetHudScale(1, true)
  if self.RefreshAssignHud then
    self:RefreshAssignHud()
  end
  printMsg("HUD size reset.")
end

function UI:NudgeHudScale(delta)
  self:SetHudScale(self:GetHudScale() + (tonumber(delta) or 0))
end

function UI:SetHudAssignmentsMode(mode)
  local dbc = charDB()
  if mode == "mine" then
    dbc.hudAssignments = "mine"
  else
    dbc.hudAssignments = "full"
  end
  self:RefreshOptionsPanel()
  if self.RefreshAssignHud then
    self:RefreshAssignHud()
  end
  printMsg(mode == "mine"
    and "HUD: only your assignments."
    or "HUD: full assignments.")
end

function UI:IsHudAutoShowEnabled()
  return hudAutoShowEnabled()
end

function UI:SetHudAutoShow(enabled)
  charDB().hudAutoShow = enabled and true or false
  self:RefreshOptionsPanel()
  if enabled then
    self:RefreshAssignHud()
    printMsg("Assignment HUD auto-show on (pops up in AQ40/Naxx).")
  else
    printMsg("Assignment HUD auto-show off. Use /gmbh hud or Test HUD to open it.")
  end
end

function UI:RefreshOptionsPanel()
  if not self.optionsPanel then
    return
  end
  local full = preferFullHudAssignments()
  if self.optHudMineBtn then
    styleTabButton(self.optHudMineBtn, not full)
  end
  if self.optHudFullBtn then
    styleTabButton(self.optHudFullBtn, full)
  end
  if self.optHudHint then
    self.optHudHint:SetText(full
      and "Assignment HUD shows every filled role for the current boss."
      or "Assignment HUD shows only roles assigned to you.")
  end
  local autoOn = hudAutoShowEnabled()
  if self.optHudAutoOnBtn then
    styleTabButton(self.optHudAutoOnBtn, autoOn)
  end
  if self.optHudAutoOffBtn then
    styleTabButton(self.optHudAutoOffBtn, not autoOn)
  end
  if self.optHudScaleLabel then
    self.optHudScaleLabel:SetText(string.format("%d%%", math.floor(self:GetHudScale() * 100 + 0.5)))
  end
  local scale = self:GetHudScale()
  if self.optHudScaleSmaller then
    if scale > HUD_SCALE_MIN then
      self.optHudScaleSmaller:Enable()
    else
      self.optHudScaleSmaller:Disable()
    end
  end
  if self.optHudScaleLarger then
    if scale < HUD_SCALE_MAX then
      self.optHudScaleLarger:Enable()
    else
      self.optHudScaleLarger:Disable()
    end
  end
  local mapShown = not charDB().minimapHidden
  if self.optMinimapShowBtn then
    styleTabButton(self.optMinimapShowBtn, mapShown)
  end
  if self.optMinimapHideBtn then
    styleTabButton(self.optMinimapHideBtn, not mapShown)
  end
end

local function saveAssignHudPosition(frame)
  if not frame then
    return
  end
  local dbChar = charDB()
  local prev = type(dbChar.assignHud) == "table" and dbChar.assignHud or nil
  -- Prefer screen coords while visible. Hidden frames often report nil GetLeft/GetTop
  -- on Classic — never overwrite a good saved position with defaults in that case.
  local left = frame:GetLeft()
  local top = frame:GetTop()
  if left and top then
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
  elseif prev and prev.x ~= nil and prev.y ~= nil then
    left = tonumber(prev.x) or 0
    top = tonumber(prev.y) or 180
  else
    local point, _, relPoint, x, y = frame:GetPoint(1)
    left = x or 0
    top = y or 180
    frame:ClearAllPoints()
    frame:SetPoint(point or "TOPLEFT", UIParent, relPoint or "BOTTOMLEFT", left, top)
  end
  local w = frame:GetWidth()
  local h = frame:GetHeight()
  local userSized = frame._userSized and true or false
  if not userSized and prev and prev.userSized and prev.w and prev.h then
    userSized = true
    w = tonumber(prev.w) or w
    h = tonumber(prev.h) or h
  end
  dbChar.assignHud = {
    point = "TOPLEFT",
    relPoint = "BOTTOMLEFT",
    x = left,
    y = top,
    hidden = frame._userHidden and true or false,
    userSized = userSized or nil,
    w = userSized and w or nil,
    h = userSized and h or nil,
  }
end

local function applyAssignHudPosition(frame)
  if not frame then
    return
  end
  local saved = charDB().assignHud
  frame:ClearAllPoints()
  if type(saved) == "table" and saved.x ~= nil and saved.y ~= nil then
    frame:SetPoint(
      saved.point or "TOPLEFT",
      UIParent,
      saved.relPoint or "BOTTOMLEFT",
      tonumber(saved.x) or 0,
      tonumber(saved.y) or 180
    )
    frame._userHidden = saved.hidden and true or false
    if saved.userSized and saved.w and saved.h then
      frame._userSized = true
      frame:SetWidth(math.max(120, tonumber(saved.w) or 340))
      frame:SetHeight(math.max(48, tonumber(saved.h) or 72))
    end
  else
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 180)
  end
end

local function applyAssignHudContentWidth(frame, width)
  if not frame or not frame.body then
    return
  end
  local bodyW = math.max(80, (tonumber(width) or frame:GetWidth() or 340) - 40)
  frame.body:SetWidth(bodyW)
  if frame.scrollChild then
    frame.scrollChild:SetWidth(bodyW)
  end
end

function UI:EnsureAssignHud()
  if self.assignHud then
    return self.assignHud
  end
  local f = CreateFrame("Frame", "GmbHLootTrackerAssignHud", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  f:SetSize(340, 72)
  f:SetFrameStrata("MEDIUM")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  -- Do not use SetUserPlaced — Classic layout cache fights addon-saved SetPoint.
  f:SetUserPlaced(false)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(selfFrame)
    if selfFrame.IsProtected and selfFrame:IsProtected() then
      return
    end
    selfFrame:StartMoving()
    selfFrame._dragging = true
  end)
  f:SetScript("OnDragStop", function(selfFrame)
    selfFrame:StopMovingOrSizing()
    selfFrame._dragging = nil
    saveAssignHudPosition(selfFrame)
  end)
  setBackdrop(f)
  if f.SetBackdropColor then
    f:SetBackdropColor(0.04, 0.07, 0.12, 0.55)
    f:SetBackdropBorderColor(0.35, 0.55, 0.75, 0.55)
  end

  applyAssignHudPosition(f)

  f.title = makeLabel(f, "Your assignment", 11)
  f.title:SetPoint("TOPLEFT", 10, -8)
  f.title:SetTextColor(0.70, 0.82, 0.95)

  f.close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  f.close:SetSize(22, 22)
  f.close:SetPoint("TOPRIGHT", -4, -2)
  f.close:EnableMouse(true)
  f.close:SetScript("OnClick", function()
    f._userHidden = true
    saveAssignHudPosition(f)
    f:Hide()
  end)
  f.title:SetPoint("TOPRIGHT", f.close, "TOPLEFT", -4, 0)

  local scroll = CreateFrame("ScrollFrame", nil, f)
  scroll:SetPoint("TOPLEFT", 10, -26)
  scroll:SetPoint("BOTTOMRIGHT", -12, 10)
  local child = CreateFrame("Frame", nil, scroll)
  child:SetSize(300, 40)
  scroll:SetScrollChild(child)
  f.scroll = scroll
  f.scrollChild = child

  -- Multi-line body (do not use makeLabel — it forces MaxLines=1 for grid cells).
  f.body = child:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.body:SetFont(f.body:GetFont(), 12)
  f.body:SetPoint("TOPLEFT", 0, 0)
  f.body:SetWidth(300)
  f.body:SetJustifyH("LEFT")
  f.body:SetJustifyV("TOP")
  f.body:SetTextColor(1, 1, 1)
  if f.body.SetWordWrap then
    f.body:SetWordWrap(true)
  end
  if f.body.SetNonSpaceWrap then
    f.body:SetNonSpaceWrap(true)
  end
  if f.body.SetMaxLines then
    f.body:SetMaxLines(40)
  end

  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function(_, delta)
    -- Alt+wheel resizes the HUD; plain wheel scrolls long assignment lists.
    if IsAltKeyDown and IsAltKeyDown() then
      if GmbHLootTrackerUI and GmbHLootTrackerUI.NudgeHudScale then
        GmbHLootTrackerUI:NudgeHudScale(delta > 0 and HUD_SCALE_STEP or -HUD_SCALE_STEP)
      end
      return
    end
    local cur = scroll:GetVerticalScroll() or 0
    local max = math.max(0, (child:GetHeight() or 0) - (scroll:GetHeight() or 0))
    scroll:SetVerticalScroll(math.max(0, math.min(max, cur - delta * 18)))
  end)

  -- Shared resize loop: "both" (corner), "height" (bottom), "width" (right).
  local function beginHudResize(mode)
    if f.IsProtected and f:IsProtected() then
      return
    end
    f._resizing = true
    f._dragging = true
    f:SetScript("OnUpdate", function(selfFrame)
      if not IsMouseButtonDown("LeftButton") then
        selfFrame:SetScript("OnUpdate", nil)
        selfFrame._resizing = nil
        selfFrame._dragging = nil
        selfFrame._userSized = true
        saveAssignHudPosition(selfFrame)
        return
      end
      local left = selfFrame:GetLeft()
      local top = selfFrame:GetTop()
      if not left or not top then
        return
      end
      local mx, my = GetCursorPosition()
      local uiScale = UIParent:GetEffectiveScale() or 1
      mx, my = mx / uiScale, my / uiScale
      local frameScale = selfFrame:GetScale() or 1
      if frameScale < 0.01 then
        frameScale = 1
      end
      if mode == "height" or mode == "both" then
        local h = math.max(48, math.min(700, (top - my) / frameScale))
        selfFrame:SetHeight(h)
      end
      if mode == "width" or mode == "both" then
        local w = math.max(120, math.min(900, (mx - left) / frameScale))
        selfFrame:SetWidth(w)
        applyAssignHudContentWidth(selfFrame, w)
      end
    end)
  end

  -- Bottom edge: drag to change height only.
  local bottomEdge = CreateFrame("Button", nil, f)
  bottomEdge:SetHeight(10)
  bottomEdge:SetPoint("BOTTOMLEFT", 4, 0)
  bottomEdge:SetPoint("BOTTOMRIGHT", -28, 0)
  bottomEdge:SetFrameLevel((f:GetFrameLevel() or 0) + 4)
  bottomEdge:EnableMouse(true)
  local edgeTex = bottomEdge:CreateTexture(nil, "OVERLAY")
  edgeTex:SetPoint("BOTTOMLEFT", 0, 2)
  edgeTex:SetPoint("BOTTOMRIGHT", 0, 2)
  edgeTex:SetHeight(2)
  edgeTex:SetTexture("Interface\\Buttons\\WHITE8X8")
  edgeTex:SetVertexColor(0.45, 0.62, 0.82, 0.55)
  bottomEdge:SetScript("OnEnter", function()
    edgeTex:SetVertexColor(0.65, 0.82, 0.98, 0.95)
  end)
  bottomEdge:SetScript("OnLeave", function()
    edgeTex:SetVertexColor(0.45, 0.62, 0.82, 0.55)
  end)
  bottomEdge:SetScript("OnMouseDown", function(_, button)
    if button and button ~= "LeftButton" then
      return
    end
    beginHudResize("height")
  end)
  f.resizeBottom = bottomEdge

  -- Right edge: drag to change width only (important when HUD scale is small).
  local rightEdge = CreateFrame("Button", nil, f)
  rightEdge:SetWidth(10)
  rightEdge:SetPoint("TOPRIGHT", 0, -24)
  rightEdge:SetPoint("BOTTOMRIGHT", 0, 28)
  rightEdge:SetFrameLevel((f:GetFrameLevel() or 0) + 4)
  rightEdge:EnableMouse(true)
  local rightTex = rightEdge:CreateTexture(nil, "OVERLAY")
  rightTex:SetPoint("TOPRIGHT", -2, 0)
  rightTex:SetPoint("BOTTOMRIGHT", -2, 0)
  rightTex:SetWidth(2)
  rightTex:SetTexture("Interface\\Buttons\\WHITE8X8")
  rightTex:SetVertexColor(0.45, 0.62, 0.82, 0.55)
  rightEdge:SetScript("OnEnter", function()
    rightTex:SetVertexColor(0.65, 0.82, 0.98, 0.95)
  end)
  rightEdge:SetScript("OnLeave", function()
    rightTex:SetVertexColor(0.45, 0.62, 0.82, 0.55)
  end)
  rightEdge:SetScript("OnMouseDown", function(_, button)
    if button and button ~= "LeftButton" then
      return
    end
    beginHudResize("width")
  end)
  f.resizeRight = rightEdge

  -- Bottom-right corner: click and drag to resize width + height.
  local grip = CreateFrame("Button", nil, f)
  grip:SetSize(18, 18)
  grip:SetPoint("BOTTOMRIGHT", -1, 1)
  grip:SetFrameLevel((f:GetFrameLevel() or 0) + 6)
  grip:EnableMouse(true)
  grip:RegisterForClicks("LeftButtonUp", "LeftButtonDown")
  local gripTex = grip:CreateTexture(nil, "OVERLAY")
  gripTex:SetAllPoints()
  gripTex:SetTexture("Interface\\Buttons\\WHITE8X8")
  gripTex:SetVertexColor(0.55, 0.72, 0.90, 0.85)
  -- Simple corner chevron using two thin lines.
  local line1 = grip:CreateTexture(nil, "ARTWORK")
  line1:SetTexture("Interface\\Buttons\\WHITE8X8")
  line1:SetVertexColor(0.15, 0.22, 0.32, 1)
  line1:SetSize(10, 2)
  line1:SetPoint("BOTTOMRIGHT", -3, 5)
  local line2 = grip:CreateTexture(nil, "ARTWORK")
  line2:SetTexture("Interface\\Buttons\\WHITE8X8")
  line2:SetVertexColor(0.15, 0.22, 0.32, 1)
  line2:SetSize(6, 2)
  line2:SetPoint("BOTTOMRIGHT", -3, 9)
  grip:SetScript("OnEnter", function(btn)
    if btn.SetAlpha then
      btn:SetAlpha(1)
    end
  end)
  grip:SetScript("OnLeave", function(btn)
    if btn.SetAlpha then
      btn:SetAlpha(0.85)
    end
  end)
  grip:SetAlpha(0.85)
  grip:SetScript("OnMouseDown", function(_, button)
    if button and button ~= "LeftButton" then
      return
    end
    beginHudResize("both")
  end)
  f.resizeGrip = grip
  refreshHudResizeHandles(f)
  -- Resize edge is created later and would otherwise sit on top of the X.
  if f.close then
    f.close:SetFrameLevel((f:GetFrameLevel() or 0) + 20)
  end

  f:Hide()
  self.assignHud = f
  self:ApplyHudScale(f)
  return f
end

function UI:RefreshAssignHud(opts)
  opts = opts or {}
  local f = self:EnsureAssignHud()
  -- Never re-anchor while the player is dragging or corner-resizing.
  if f._dragging or f._resizing then
    return
  end
  local wasShown = f:IsShown() and true or false
  self:ApplyHudScale(f)
  local inst = instanceRaidSlug()
  if not inst and not self.hudTestBoss then
    f:Hide()
    return
  end
  -- Targeting a boss should reopen the HUD even if it was hidden via /gmbh hud,
  -- unless Options → Auto show is Off.
  local slug = self.hudTestSlug or inst
  if hudAutoShowEnabled() and slug and detectBossSectionLabelResolved(slug) then
    f._userHidden = false
  end
  if f._userHidden then
    f:Hide()
    return
  end
  if not hudAutoShowEnabled() and not opts.manual and not wasShown then
    f:Hide()
    return
  end
  local lines, bossLabel, full = self:GetPersonalBossAssignmentLines()
  if lines == nil then
    f:Hide()
    return
  end
  -- No boss context yet (not targeting / wrong wing) → keep HUD closed.
  if not bossLabel and not self.hudTestBoss then
    f:Hide()
    return
  end
  -- Keep screen position across SetWidth/SetHeight (Classic can drop anchors).
  local keepLeft, keepTop = f:GetLeft(), f:GetTop()
  local title = bossLabel and shortBossTitle(bossLabel) or "Assignment"
  if self.hudTestBoss then
    title = title .. "  ·  test"
  end
  local isCthun = bossLabel and (string.lower(tostring(bossLabel)):find("c.?thun", 1) ~= nil)
  if full and isCthun then
    f.title:SetText(title .. "  ·  marks")
  elseif full then
    f.title:SetText(title .. "  ·  all")
  elseif isCthun then
    f.title:SetText(title .. "  ·  your mark")
  else
    f.title:SetText(title)
  end

  local userSized = f._userSized and true or false
  if not userSized then
    if full and isCthun then
      f:SetWidth(420)
    elseif full then
      f:SetWidth(380)
    elseif isCthun then
      f:SetWidth(160)
    else
      f:SetWidth(340)
    end
  end
  applyAssignHudContentWidth(f, f:GetWidth())

  if not lines or #lines == 0 then
    f.body:SetText(full
      and "|cff888888No filled assignments for this boss.|r"
      or (isCthun and "|cff888888No mark assigned.|r" or "|cff888888No personal assignment for this boss.|r"))
    f.body:SetHeight(20)
    f.scrollChild:SetHeight(20)
    if not userSized then
      f:SetHeight(56)
    end
  else
    f.body:SetText(table.concat(lines, "\n"))
    local lineH = full and 14 or (isCthun and 22 or 16)
    local contentH = math.max(20, #lines * lineH)
    f.body:SetHeight(contentH)
    f.scrollChild:SetHeight(contentH)
    if not userSized then
      f:SetHeight(math.min(full and 320 or 120, 34 + contentH))
    end
  end
  if f.scroll then
    f.scroll:SetVerticalScroll(0)
  end
  if keepLeft and keepTop then
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", keepLeft, keepTop)
  elseif not f._posApplied then
    applyAssignHudPosition(f)
    f._posApplied = true
  end
  f:Show()
end

function UI:ToggleAssignHud()
  local f = self:EnsureAssignHud()
  if f:IsShown() then
    f._userHidden = true
    saveAssignHudPosition(f)
    f:Hide()
    printMsg("Assignment HUD hidden. /gmbh hud to show again.")
  else
    f._userHidden = false
    f._posApplied = false
    saveAssignHudPosition(f)
    self:RefreshAssignHud({ manual = true })
    if not f:IsShown() then
      printMsg("Assignment HUD: enter AQ40/Naxx, or /gmbh target <boss> to test.")
    else
      printMsg("Assignment HUD shown (drag to move, corner to resize).")
    end
  end
end

function UI:SetHudTestTarget(query)
  query = trim(tostring(query or ""))
  local low = string.lower(query)
  if query == "" or low == "clear" or low == "off" or low == "none" or low == "stop" then
    self.hudTestSlug = nil
    self.hudTestBoss = nil
    printMsg("HUD test target cleared.")
    self:RefreshAssignHud()
    return
  end
  if low == "boss" then
    printMsg("Usage: /gmbh target <boss>  e.g. /gmbh target cthun  ·  /gmbh target clear")
    return
  end
  -- Allow "/gmbh target boss cthun"
  local stripped = low:match("^boss%s+(.+)$")
  if stripped then
    query = stripped
    low = stripped
  end
  local slug, label = resolveHudTestBoss(query)
  if not label then
    printMsg("Unknown boss. Examples: cthun, twins, sartura, huhuran, patchwerk, kelthuzad")
    return
  end
  self.hudTestSlug = slug
  self.hudTestBoss = label
  local f = self:EnsureAssignHud()
  f._userHidden = false
  self:RefreshAssignHud({ manual = true })
  printMsg(string.format(
    "HUD test: %s (%s). /gmbh target clear to stop.",
    label,
    slug
  ))
end

function UI:ClearRaidScroll()
  for _, row in ipairs(self.raidRows or {}) do
    row:Hide()
  end
  for _, row in ipairs(self.raidGridRows or {}) do
    row:Hide()
  end
  for _, g in ipairs(self.raidGroups or {}) do
    g:Hide()
  end
  for _, btn in ipairs(self.hudTestBtns or {}) do
    btn:Hide()
  end
  if self.benchLabel then
    self.benchLabel:Hide()
  end
  if self.cthunArena then
    self.cthunArena:Hide()
    for _, chip in ipairs(self.cthunArena.chips or {}) do
      chip:Hide()
    end
  end
end

function UI:EnsureHudTestBtn(i)
  self.hudTestBtns = self.hudTestBtns or {}
  local btn = self.hudTestBtns[i]
  if btn then
    return btn
  end
  btn = CreateFrame("Button", nil, self.raidScrollChild, "UIPanelButtonTemplate")
  btn:SetSize(110, 22)
  btn:SetText("Test HUD")
  btn:SetScript("OnClick", function(selfBtn)
    local label = selfBtn.bossLabel or ""
    if GmbHLootTrackerUI and GmbHLootTrackerUI.SetHudTestTarget then
      GmbHLootTrackerUI:SetHudTestTarget(label)
    end
  end)
  self.hudTestBtns[i] = btn
  return btn
end

function UI:EnsureCthunArena()
  if self.cthunArena then
    return self.cthunArena
  end
  local f = CreateFrame("Frame", nil, self.raidScrollChild, BackdropTemplateMixin and "BackdropTemplate" or nil)
  -- Match source image aspect (1024×753).
  local W, H = 760, math.floor(760 * 753 / 1024)
  f:SetSize(W, H)
  setBackdrop(f)
  if f.SetBackdropColor then
    f:SetBackdropColor(0.05, 0.06, 0.10, 1)
    f:SetBackdropBorderColor(0.35, 0.22, 0.48, 0.85)
  end

  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(f)
  bg:SetTexture("Interface\\AddOns\\ClassicGmbHQuartermaster\\Textures\\cthun_map")
  bg:SetTexCoord(0, 1, 135 / 1024, (135 + 753) / 1024)
  f.bg = bg

  f.chips = {}
  f.glow = nil
  f.boss = makeLabel(f, "", 1)
  f.boss:Hide()
  f.throne = makeLabel(f, "", 1)
  f.throne:Hide()
  f.entrance = makeLabel(f, "", 1)
  f.entrance:Hide()

  self.cthunArena = f
  return f
end

function UI:EnsureCthunChip(i)
  self.cthunArena = self:EnsureCthunArena()
  local chips = self.cthunArena.chips
  local chip = chips[i]
  if chip then
    return chip
  end
  chip = CreateFrame("Frame", nil, self.cthunArena, BackdropTemplateMixin and "BackdropTemplate" or nil)
  -- Match empty boxes on the map art.
  chip:SetSize(78, 16)
  setBackdrop(chip)
  if chip.SetBackdropColor then
    chip:SetBackdropColor(0.10, 0.11, 0.14, 0.92)
    chip:SetBackdropBorderColor(0.35, 0.38, 0.45, 0.9)
  end
  chip.text = makeLabel(chip, "", 9)
  chip.text:SetPoint("LEFT", chip, "LEFT", 3, 0)
  chip.text:SetPoint("RIGHT", chip, "RIGHT", -3, 0)
  chip.text:SetJustifyH("CENTER")
  chips[i] = chip
  return chip
end

function UI:EnsureRaidRow(i)
  self.raidRows = self.raidRows or {}
  local row = self.raidRows[i]
  if row then
    return row
  end
  row = CreateFrame("Frame", nil, self.raidScrollChild)
  row:SetHeight(16)
  row:SetPoint("LEFT", self.raidScrollChild, "LEFT", 4, 0)
  row:SetPoint("RIGHT", self.raidScrollChild, "RIGHT", -4, 0)
  row.text = makeLabel(row, "", 11)
  row.text:SetPoint("LEFT", row, "LEFT", 0, 0)
  row.text:SetPoint("RIGHT", row, "RIGHT", 0, 0)
  self.raidRows[i] = row
  return row
end

function UI:EnsureRaidGridRow(i, colCount)
  self.raidGridRows = self.raidGridRows or {}
  local row = self.raidGridRows[i]
  if not row then
    row = CreateFrame("Frame", nil, self.raidScrollChild)
    row:SetHeight(18)
    row.cells = {}
    self.raidGridRows[i] = row
  end
  colCount = colCount or 4
  while #row.cells < colCount do
    local cell = makeLabel(row, "", 11)
    table.insert(row.cells, cell)
  end
  for ci = 1, #row.cells do
    if ci <= colCount then
      row.cells[ci]:Show()
    else
      row.cells[ci]:Hide()
      row.cells[ci]:SetText("")
    end
  end
  row.colCount = colCount
  return row
end

function UI:RenderRaidSheet()
  if not self.raidPanel then
    return
  end
  local slug = preferredRaidSlug()
  local raid = raidData(slug)
  self.raidSlug = slug
  self.raidView = self.raidView or "groups"

  self:ClearRaidScroll()

  if not raid then
    self.raidMeta:SetText("No upcoming raid sheet. Run the Windows helper, then /reload.")
    if self.raidTabChild then
      for _, btn in ipairs(self.raidNavTabs or {}) do
        btn:Hide()
      end
    end
    return
  end

  local title = raid.title or string.upper(slug)
  local bits = { title }
  if raid.version then
    table.insert(bits, "v" .. tostring(raid.version))
  end
  if raid.announced then
    table.insert(bits, "|cff66cc66announced|r")
  else
    table.insert(bits, "|cffcc8844not announced|r")
  end
  if raid.event_start_at and tostring(raid.event_start_at) ~= "" then
    local raw = tostring(raid.event_start_at)
    local y, m, d, hh, mm = raw:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d)")
    if y then
      table.insert(bits, string.format("%s-%s-%s %s:%s UTC", y, m, d, hh, mm))
    else
      table.insert(bits, raw)
    end
  end
  self.raidMeta:SetText(table.concat(bits, "  ·  "))

  local generalSections, tankingSections, bossSections = self:CollectRaidSections(raid)
  self:RebuildRaidNavTabs(generalSections, tankingSections, bossSections)

  -- Restyle after possible raidView fallback inside RebuildRaidNavTabs.
  for _, btn in ipairs(self.raidNavTabs or {}) do
    if btn:IsShown() then
      styleTabButton(btn, btn.viewKey == self.raidView)
    end
  end

  if raid.member_locked or not raid.has_sheet then
    local row = self:EnsureRaidRow(1)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", self.raidScrollChild, "TOPLEFT", 4, -4)
    if raid.member_locked then
      row.text:SetText("Raid sheet not announced yet — hidden until officers announce.")
    else
      row.text:SetText("No sheet for this raid yet.")
    end
    row.text:SetTextColor(0.85, 0.75, 0.55)
    row:Show()
    self.raidScrollChild:SetHeight(40)
    return
  end

  if self.raidView == "groups" then
    self:RenderRaidGroupsView(raid)
  elseif self.raidView == "tanking" then
    if self.sortRaidBtn then
      self.sortRaidBtn:Hide()
    end
    self:RenderRaidAssignmentsView(raid, tankingSections, "General tanking")
  elseif self.raidView == "general" then
    if self.sortRaidBtn then
      self.sortRaidBtn:Hide()
    end
    self:RenderRaidAssignmentsView(raid, generalSections, "General assignments")
  elseif self.raidView and string.sub(self.raidView, 1, 5) == "boss:" then
    if self.sortRaidBtn then
      self.sortRaidBtn:Hide()
    end
    local want = string.sub(self.raidView, 6)
    local matched = {}
    for _, section in ipairs(bossSections) do
      if tostring(section.label or "") == want then
        table.insert(matched, section)
      end
    end
    self:RenderRaidAssignmentsView(raid, matched, want)
  else
    self:RenderRaidGroupsView(raid)
  end
end

local function canEditRaidGroups()
  if not IsInRaid or not IsInRaid() then
    return false, "Join a raid first."
  end
  if InCombatLockdown and InCombatLockdown() then
    return false, "Leave combat before sorting raid groups."
  end
  if UnitAffectingCombat and UnitAffectingCombat("player") then
    return false, "Leave combat before sorting raid groups."
  end
  local lead = (IsRaidLeader and IsRaidLeader())
    or (UnitIsGroupLeader and UnitIsGroupLeader("player"))
  local assist = (IsRaidOfficer and IsRaidOfficer())
    or (UnitIsGroupAssistant and UnitIsGroupAssistant("player"))
  if not lead and not assist then
    return false, "Need Raid Leader or Assist to sort groups."
  end
  if not SetRaidSubgroup then
    return false, "SetRaidSubgroup is not available."
  end
  return true
end

-- Anyone in the raid currently in combat (MRT refuses to sort in that case).
local function raidCombatBlockers()
  local n = GetNumGroupMembers and GetNumGroupMembers() or 0
  local blocked = {}
  for i = 1, n do
    local unit = "raid" .. i
    if UnitAffectingCombat and UnitAffectingCombat(unit) then
      local name = UnitName(unit)
      if name and name ~= "" then
        table.insert(blocked, name)
      end
    end
  end
  if #blocked == 0 then
    return nil
  end
  return table.concat(blocked, ", ")
end

-- Flat 40-slot list like MRT Raid Groups: (g-1)*5 + seat → roster name.
-- Prefer exact seat order from the sheet so KeepPos can rebuild G1–G8 layout.
local function buildMrtStyleGroupList(raid)
  local list = {}
  local rosterBare = {}
  local n = GetNumGroupMembers and GetNumGroupMembers() or 0
  for i = 1, n do
    local name = GetRaidRosterInfo(i)
    if name then
      rosterBare[barePlayerName(name)] = name
    end
  end
  for gi = 1, 8 do
    local seats = raid.groups and raid.groups[gi] or {}
    for seat = 1, 5 do
      local idx = (gi - 1) * 5 + seat
      local cell = seats[seat]
      local sheetName = nil
      if type(cell) == "table" then
        sheetName = cell.name or cell.player_name
      elseif type(cell) == "string" then
        sheetName = cell
      end
      if sheetName and tostring(sheetName) ~= "" then
        local rosterName = rosterBare[barePlayerName(sheetName)]
        if rosterName then
          list[idx] = rosterName
        end
      end
    end
  end
  return list
end

function UI:StopRaidSort(msg)
  if self._raidSortFrame then
    self._raidSortFrame:UnregisterEvent("GROUP_ROSTER_UPDATE")
    self._raidSortFrame:SetScript("OnEvent", nil)
    self._raidSortFrame:SetScript("OnUpdate", nil)
  end
  self._raidSortBusy = false
  self._raidSortNeedGroup = nil
  self._raidSortNeedPos = nil
  self._raidSortLocked = nil
  self._raidSortGroupsReady = false
  self._raidSortGroupWithRL = 0
  if self.sortRaidBtn then
    self.sortRaidBtn:Enable()
    self.sortRaidBtn:SetText("Sort raid")
  end
  if msg then
    printMsg(msg)
  end
end

-- MRT RaidGroups:ApplyGroups + ProcessRoster (KeepPosInGroup on).
-- 1) Move players into the correct subgroups (SetRaidSubgroup / SwapRaidSubgroup).
-- 2) Fix seat order inside each group via a 3-way swap bridge.
function UI:SortRaidFromSheet()
  if self._raidSortBusy then
    printMsg("Raid sort already running…")
    return
  end
  local ok, why = canEditRaidGroups()
  if not ok then
    printMsg(why)
    return
  end
  local combat = raidCombatBlockers()
  if combat then
    printMsg("Players in combat — wait: " .. combat)
    return
  end
  local slug = preferredRaidSlug()
  local raid = raidData(slug)
  if not raid or not raid.groups then
    printMsg("No raid-sheet groups loaded. Run the helper, then /reload.")
    return
  end
  if raid.member_locked or not raid.has_sheet then
    printMsg("Raid sheet not available (locked or missing).")
    return
  end

  local list = buildMrtStyleGroupList(raid)
  local rlName, _, rlGroup = GetRaidRosterInfo(1)
  local needGroup = {}
  local needPosInGroup = {}
  local isRLfound = false
  local listed = 0

  for i = 1, 8 do
    local pos = 1
    for j = 1, 5 do
      local name = list[(i - 1) * 5 + j]
      if name and rlName and barePlayerName(name) == barePlayerName(rlName) then
        needGroup[name] = i
        needPosInGroup[name] = pos
        pos = pos + 1
        isRLfound = true
        listed = listed + 1
        break
      end
    end
    for j = 1, 5 do
      local name = list[(i - 1) * 5 + j]
      if name and (not rlName or barePlayerName(name) ~= barePlayerName(rlName)) then
        needGroup[name] = i
        needPosInGroup[name] = pos
        pos = pos + 1
        listed = listed + 1
      end
    end
  end

  if listed == 0 then
    printMsg("No sheet players are in this raid yet.")
    return
  end

  self._raidSortBusy = true
  self._raidSortNeedGroup = needGroup
  self._raidSortNeedPos = needPosInGroup
  self._raidSortLocked = {}
  self._raidSortGroupsReady = false
  self._raidSortGroupWithRL = isRLfound and 0 or (rlGroup or 0)
  self._raidSortMoved = 0
  self._raidSortPasses = 0

  if self.sortRaidBtn then
    self.sortRaidBtn:Disable()
    self.sortRaidBtn:SetText("Sorting…")
  end
  printMsg(string.format(
    "Sorting raid to sheet groups (MRT-style, %d players, keep seat order)…",
    listed
  ))

  if not self._raidSortFrame then
    self._raidSortFrame = CreateFrame("Frame")
  end
  self._raidSortFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
  self._raidSortFrame:SetScript("OnEvent", function(_, event)
    if event == "GROUP_ROSTER_UPDATE" and UI._raidSortBusy then
      UI:_RaidSortProcess()
    end
  end)
  -- Kick immediately; further steps wait for roster events (like MRT).
  self:_RaidSortProcess()
end

function UI:_RaidSortProcess()
  if not self._raidSortBusy then
    return
  end
  local ok, why = canEditRaidGroups()
  if not ok then
    self:StopRaidSort(why)
    return
  end
  local combat = raidCombatBlockers()
  if combat then
    self:StopRaidSort("Combat started — sort aborted: " .. combat)
    return
  end

  local needGroup = self._raidSortNeedGroup
  local needPosInGroup = self._raidSortNeedPos
  local lockedUnit = self._raidSortLocked
  if not needGroup then
    return
  end

  self._raidSortPasses = (self._raidSortPasses or 0) + 1
  if self._raidSortPasses > 200 then
    self:StopRaidSort("Raid sort stopped (too many passes — try again).")
    return
  end

  local currentGroup = {}
  local currentPos = {}
  local nameToID = {}
  local groupSize = { 0, 0, 0, 0, 0, 0, 0, 0 }

  local function resolveNeedKey(rosterName)
    if needGroup[rosterName] then
      return rosterName
    end
    local bare = barePlayerName(rosterName)
    for key in pairs(needGroup) do
      if barePlayerName(key) == bare then
        return key
      end
    end
    if rosterName:find("%-", 1, true) then
      local short = rosterName:match("^([^%-]+)")
      if short and needGroup[short] then
        return short
      end
    end
    return rosterName
  end

  -- Mirror MRT ProcessRoster roster scan (subgroup size = seat index in group).
  local n = GetNumGroupMembers and GetNumGroupMembers() or 0
  for i = 1, n do
    local name, _, subgroup = GetRaidRosterInfo(i)
    if name and subgroup and subgroup >= 1 and subgroup <= 8 then
      local key = resolveNeedKey(name)
      currentGroup[key] = subgroup
      nameToID[key] = i
      groupSize[subgroup] = groupSize[subgroup] + 1
      currentPos[key] = groupSize[subgroup]
    end
  end

  if not self._raidSortGroupsReady then
    local waitForGroup = false
    for unit, group in pairs(needGroup) do
      local cur = currentGroup[unit]
      if cur and cur ~= group then
        if (groupSize[group] or 0) < 5 then
          local id = nameToID[unit]
          if id then
            SetRaidSubgroup(id, group)
            groupSize[cur] = (groupSize[cur] or 0) - 1
            groupSize[group] = (groupSize[group] or 0) + 1
            self._raidSortMoved = (self._raidSortMoved or 0) + 1
            waitForGroup = true
          end
        end
      end
    end
    if waitForGroup then
      return
    end

    local setToSwap = {}
    local waitForSwap = false
    if SwapRaidSubgroup then
      for unit, group in pairs(needGroup) do
        if not setToSwap[unit] and currentGroup[unit] and currentGroup[unit] ~= group then
          local unitToSwap = nil
          for unit2, group2 in pairs(currentGroup) do
            if not setToSwap[unit2] and group2 == group and needGroup[unit2] ~= group2 then
              unitToSwap = unit2
              break
            end
          end
          if unitToSwap and nameToID[unit] and nameToID[unitToSwap] then
            SwapRaidSubgroup(nameToID[unit], nameToID[unitToSwap])
            self._raidSortMoved = (self._raidSortMoved or 0) + 1
            waitForSwap = true
            setToSwap[unit] = true
            setToSwap[unitToSwap] = true
          end
        end
      end
    end
    if waitForSwap then
      return
    end

    self._raidSortGroupsReady = true
  end

  -- Phase 2: seat order inside groups (MRT KeepPosInGroup / 3-way bridge swap).
  do
    local setToSwap = {}
    local waitForSwap = false
    local groupWithRL = self._raidSortGroupWithRL or 0
    if SwapRaidSubgroup then
      for unit, pos in pairs(needPosInGroup or {}) do
        local wantPos = pos
        if currentGroup[unit] == groupWithRL then
          wantPos = pos + 1
        end
        if not lockedUnit[unit]
          and currentPos[unit]
          and currentPos[unit] ~= wantPos
          and nameToID[unit]
          and nameToID[unit] ~= 1
          and not setToSwap[unit]
        then
          local unitToSwapBridge = nil
          for unit2, group2 in pairs(currentGroup) do
            if group2 ~= currentGroup[unit]
              and nameToID[unit2]
              and nameToID[unit2] ~= 1
              and not setToSwap[unit2]
            then
              unitToSwapBridge = unit2
              break
            end
          end

          local unitToSwap = nil
          for unit2, pos2 in pairs(currentPos) do
            if currentGroup[unit2] == currentGroup[unit]
              and pos2 == wantPos
              and nameToID[unit2]
              and nameToID[unit2] ~= 1
              and not setToSwap[unit2]
            then
              unitToSwap = unit2
              break
            end
          end

          if unitToSwap and unitToSwapBridge then
            lockedUnit[unit] = true
            SwapRaidSubgroup(nameToID[unit], nameToID[unitToSwapBridge])
            SwapRaidSubgroup(nameToID[unitToSwapBridge], nameToID[unitToSwap])
            SwapRaidSubgroup(nameToID[unit], nameToID[unitToSwapBridge])
            self._raidSortMoved = (self._raidSortMoved or 0) + 1
            waitForSwap = true
            setToSwap[unit] = true
            setToSwap[unitToSwap] = true
            setToSwap[unitToSwapBridge] = true
          end
        end
      end
    end
    if waitForSwap then
      return
    end
  end

  self:StopRaidSort(string.format(
    "Raid sort done (%d moves) — groups match the sheet.",
    self._raidSortMoved or 0
  ))
end

-- Back-compat name used by older OnUpdate hook (if any).
function UI:_RaidSortTick()
  self:_RaidSortProcess()
end

function UI:RenderRaidGroupsView(raid)
  local sortTop = -2
  if self.sortRaidBtn then
    self.sortRaidBtn:ClearAllPoints()
    self.sortRaidBtn:SetPoint("TOPLEFT", self.raidScrollChild, "TOPLEFT", 4, sortTop)
    self.sortRaidBtn:Show()
    sortTop = sortTop - 28
  end
  local groups = raid.groups or {}
  local y = sortTop
  for i = 1, 8 do
    local box = self.raidGroups[i]
    local seats = groups[i] or {}
    local col = ((i - 1) % 4)
    local row = math.floor((i - 1) / 4)
    local GROUP_W, GROUP_H, GAP = 200, 118, 10
    box:ClearAllPoints()
    box:SetPoint(
      "TOPLEFT",
      self.raidScrollChild,
      "TOPLEFT",
      4 + col * (GROUP_W + GAP),
      sortTop - row * (GROUP_H + GAP)
    )
    box.title:SetText("G" .. i)
    for s = 1, 5 do
      box.seats[s]:SetText(formatRaidPlayer(seats[s]))
      box.seats[s]:SetTextColor(1, 1, 1)
    end
    box:Show()
    y = math.min(y, sortTop - (row + 1) * (GROUP_H + GAP))
  end

  self.benchLabel:ClearAllPoints()
  self.benchLabel:SetPoint("TOPLEFT", self.raidScrollChild, "TOPLEFT", 4, y - 4)
  self.benchLabel:SetPoint("RIGHT", self.raidScrollChild, "RIGHT", -4, 0)
  local bench = raid.bench or {}
  if #bench == 0 then
    self.benchLabel:SetText("Bench: (empty)")
  else
    local names = {}
    for _, p in ipairs(bench) do
      table.insert(names, formatRaidPlayer(p))
    end
    self.benchLabel:SetText("Bench: " .. table.concat(names, "  "))
  end
  self.benchLabel:SetTextColor(1, 1, 1)
  self.benchLabel:Show()
  self.raidScrollChild:SetHeight(math.max(280, -y + 60))
end

function UI:OnPeerPresence()
  if self.frame and self.frame:IsShown() and self.syncLabel then
    self:RefreshSyncLabel()
  end
  if not self.frame or not self.frame:IsShown() then
    return
  end
  if self.mainTab ~= "raid" then
    return
  end
  if (self.raidView or "groups") ~= "groups" then
    return
  end
  -- Rebuilding the Groups tab during AceComm apply freezes Classic.
  local live = GmbHLootTrackerSync and GmbHLootTrackerSync.GetLiveStatus and GmbHLootTrackerSync.GetLiveStatus()
  if live and live ~= "" then
    return
  end
  self:RenderRaidSheet()
end

function UI:RenderRaidAssignmentsView(raid, sections, heading)
  if GmbHLootTrackerRaidSheet and GmbHLootTrackerRaidSheet.Render then
    GmbHLootTrackerRaidSheet.Render(self, raid, sections or {}, heading)
    return
  end
  local row = self:EnsureRaidRow(1)
  row:ClearAllPoints()
  row:SetPoint("TOPLEFT", self.raidScrollChild, "TOPLEFT", 4, -4)
  row:SetPoint("RIGHT", self.raidScrollChild, "RIGHT", -4, 0)
  row.text:SetText("Raid sheet renderer missing — update addon files.")
  row.text:SetTextColor(0.85, 0.75, 0.55)
  row:Show()
  self.raidScrollChild:SetHeight(40)
end


function UI:ClearCandidateRows()
  for _, row in ipairs(self.candidateRows or {}) do
    row:Hide()
  end
end

function UI:ShowEmpty(msg)
  self.emptyLabel:SetText(msg or "")
  self.emptyLabel:Show()
  self:ClearCandidateRows()
  self.resultHeader:Hide()
  if self.colHead then
    self.colHead:Hide()
  end
  self.scroll:Hide()
end

function UI:SelectItem(hit)
  if not hit then
    return
  end
  self.selectedItemId = hit.itemId
  self.selectedItemName = hit.name
  self.searchBox:SetText(hit.name or "")
  self.searchBox:ClearFocus()
  self:HideSearchResults()
  self:RenderCandidates()
end

-- Shift-click bag / chat item link → search (when wishlist window is open).
function UI:FillFromItemLink(link)
  if not link or type(link) ~= "string" then
    return false
  end
  if not self.frame or not self.frame:IsShown() then
    return false
  end
  if self.mainTab ~= "wishlist" then
    return false
  end
  if self.lockPanel and self.lockPanel:IsShown() then
    return false
  end
  if not self.searchBox then
    return false
  end

  local itemId = link:match("item:(%d+)")
  local name = link:match("%[(.-)%]")
  if not itemId and (not name or name == "") then
    return false
  end

  local data = db()
  local meta = itemId and data and data.items and data.items[tostring(itemId)]
  if meta then
    self:SelectItem({
      itemId = tostring(itemId),
      name = meta.name,
      catalog_key = meta.catalog_key,
    })
    return true
  end

  local q = name
  if (not q or q == "") and itemId then
    q = "#" .. tostring(itemId)
  end
  if not q or q == "" then
    return false
  end

  -- Avoid re-entrant OnTextChanged loops while we drive the box.
  self.searchBox:SetScript("OnTextChanged", nil)
  self.searchBox:SetText(q)
  self.searchBox:SetScript("OnTextChanged", function()
    UI:OnSearchChanged()
  end)
  self:OnSearchChanged()

  local hits = searchItems(q)
  if itemId then
    for _, hit in ipairs(hits) do
      if tostring(hit.itemId) == tostring(itemId) then
        self:SelectItem(hit)
        return true
      end
    end
  end
  if #hits == 1 then
    self:SelectItem(hits[1])
  end
  return true
end

local chatEditInsertLinkHooked = false

local function hookShiftClickItemLinks()
  if chatEditInsertLinkHooked then
    return
  end
  chatEditInsertLinkHooked = true
  if type(ChatEdit_InsertLink) ~= "function" then
    return
  end
  local orig = ChatEdit_InsertLink
  ChatEdit_InsertLink = function(text, ...)
    if UI:FillFromItemLink(text) then
      return true
    end
    return orig(text, ...)
  end
end


function UI:HideSearchResults()
  self.searchResults:Hide()
  for _, row in ipairs(self.searchRows) do
    row:Hide()
  end
end

function UI:RenderSearchResults(hits)
  if not hits or #hits == 0 then
    self:HideSearchResults()
    if trim(self.searchBox:GetText()) ~= "" then
      self:ShowEmpty(
        "No catalog matches. Run the Windows helper (writes HelperData.lua under AddOns), then /reload."
      )
    else
      self:ShowEmpty(self:EmptyHint())
    end
    return
  end
  self.emptyLabel:Hide()
  for i, row in ipairs(self.searchRows) do
    local hit = hits[i]
    if hit then
      row.hit = hit
      setItemIcon(row.icon, hit.itemId, nil)
      row.label:SetText(string.format(
        "%s  |cff888888#%s|r",
        formatItemName(hit.itemId, hit.name, 4),
        hit.itemId
      ))
      row:Show()
    else
      row:Hide()
    end
  end
  self.searchResults:SetHeight(8 + math.min(#hits, MAX_RESULTS) * 22)
  self.searchResults:Show()
end

function UI:EnsureCandidateRow(i)
  local row = self.candidateRows[i]
  if row then
    return row
  end
  row = CreateFrame("Frame", nil, self.scrollChild)
  row:SetHeight(ROW_HEIGHT)
  row:SetWidth(TABLE_INNER_WIDTH)

  local x = 0
  row.playerName = makeLabel(row, "", 11)
  row.playerName:SetPoint("TOPLEFT", row, "TOPLEFT", x, -2)
  row.playerName:SetWidth(COL.player)
  row.playerName:SetTextColor(1, 0.82, 0.2)

  row.perf = makeLabel(row, "", 10)
  row.perf:SetPoint("TOPLEFT", row.playerName, "BOTTOMLEFT", 0, -1)
  row.perf:SetWidth(COL.player)
  row.perf:SetTextColor(0.55, 0.72, 0.92)

  x = x + COL.player + 4
  row.class = makeLabel(row, "", 11)
  row.class:SetPoint("LEFT", row, "LEFT", x, 0)
  row.class:SetWidth(COL.class)
  row.class:SetTextColor(0.92, 0.94, 0.97)

  x = x + COL.class + 4
  row.role = makeLabel(row, "", 11)
  row.role:SetPoint("LEFT", row, "LEFT", x, 0)
  row.role:SetWidth(COL.role)
  row.role:SetTextColor(0.92, 0.94, 0.97)

  x = x + COL.role + 4
  row.prio = makeLabel(row, "", 12)
  row.prio:SetPoint("LEFT", row, "LEFT", x, 0)
  row.prio:SetWidth(COL.prio)
  row.prio:SetTextColor(1, 1, 1)

  x = x + COL.prio + 4
  row.lost = makeLabel(row, "", 11)
  row.lost:SetPoint("LEFT", row, "LEFT", x, 0)
  row.lost:SetWidth(COL.lost)
  row.lost:SetTextColor(0.92, 0.94, 0.97)

  x = x + COL.lost + 4
  row.naxx = makeLabel(row, "", 11)
  row.naxx:SetPoint("LEFT", row, "LEFT", x, 0)
  row.naxx:SetWidth(COL.naxx)
  row.naxx:SetTextColor(0.92, 0.94, 0.97)

  x = x + COL.naxx + 4
  row.aq = makeLabel(row, "", 11)
  row.aq:SetPoint("LEFT", row, "LEFT", x, 0)
  row.aq:SetWidth(COL.aq)
  row.aq:SetTextColor(0.92, 0.94, 0.97)

  x = x + COL.aq + 4
  row.total = makeLabel(row, "", 11)
  row.total:SetPoint("LEFT", row, "LEFT", x, 0)
  row.total:SetWidth(COL.total)
  row.total:SetTextColor(0.92, 0.94, 0.97)

  x = x + COL.total + 4
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(16, 16)
  row.icon:SetPoint("LEFT", row, "LEFT", x, 0)

  row.last = makeLabel(row, "", 11)
  row.last:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
  row.last:SetWidth(COL.last - 20)
  row.last:SetTextColor(0.92, 0.94, 0.97)

  x = x + COL.last + 4
  row.date = makeLabel(row, "", 11)
  row.date:SetPoint("LEFT", row, "LEFT", x, 0)
  row.date:SetWidth(COL.date)
  row.date:SetTextColor(0.75, 0.80, 0.88)

  self.candidateRows[i] = row
  return row
end

function UI:RenderCandidates()
  local itemId = self.selectedItemId
  if not itemId then
    self:ShowEmpty(self:EmptyHint())
    return
  end
  local rows = candidatesForItem(itemId)
  local onWl = 0
  for _, r in ipairs(rows) do
    if r.on_wishlist then
      onWl = onWl + 1
    end
  end
  self.resultHeader:SetText(string.format(
    "%s  |cff888888#%s|r  —  %d candidates (%d on wishlist)",
    formatItemName(itemId, self.selectedItemName or "?", 4),
    itemId,
    #rows,
    onWl
  ))
  self.resultHeader:Show()
  self.emptyLabel:Hide()
  self:ClearCandidateRows()

  if #rows == 0 then
    self.emptyLabel:SetText("No eligible wishlist candidates for this item.")
    self.emptyLabel:Show()
    self.colHead:Hide()
    self.scroll:Hide()
    return
  end

  local contentHeight = 4
  for i, cand in ipairs(rows) do
    if i > MAX_CANDIDATES then
      break
    end
    local row = self:EnsureCandidateRow(i)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", self.scrollChild, "TOPLEFT", 4, -((i - 1) * ROW_HEIGHT) - 2)

    local display = cand.name
    if (not display or display == "") and cand.player_name then
      display = cand.player_name
      if cand.realm and tostring(cand.realm) ~= "" then
        display = display .. "-" .. tostring(cand.realm)
      end
    end
    row.playerName:SetText(coloredText(cand.class_color, tostring(display or "?")))
    row.perf:SetText(formatPerfLine(cand))
    row.class:SetText(tostring(cand.class or "—"))
    row.role:SetText(tostring(cand.role or "—"))
    if cand.priority ~= nil and tostring(cand.priority) ~= "" then
      row.prio:SetText(tostring(cand.priority))
      row.prio:SetTextColor(1, 1, 1)
    else
      row.prio:SetText("—")
      row.prio:SetTextColor(0.55, 0.62, 0.72)
    end
    row.lost:SetText(tostring(tonumber(cand.lost_rolls) or 0))
    row.naxx:SetText(tostring(tonumber(cand.naxx_ids) or 0))
    row.aq:SetText(tostring(tonumber(cand.aq40_ids) or 0))
    row.total:SetText(tostring(tonumber(cand.total_ids) or 0))
    local lastName = cand.last_item
    if lastName and tostring(lastName) ~= "" then
      setItemIcon(row.icon, cand.last_item_id, cand.last_icon)
      row.last:SetText(formatItemName(cand.last_item_id, lastName, cand.last_quality))
    else
      row.icon:Hide()
      row.last:SetText("—")
    end
    row.date:SetText(tostring(cand.last_date or "—"))
    row:Show()
    contentHeight = contentHeight + ROW_HEIGHT
  end
  self.scrollChild:SetHeight(math.max(contentHeight, 40))
  self.scrollChild:SetWidth(TABLE_INNER_WIDTH + 8)
  self.colHead:Show()
  self.scroll:Show()
end

function UI:OnSearchChanged()
  local q = trim(self.searchBox:GetText())
  if q == "" then
    self.selectedItemId = nil
    self.selectedItemName = nil
    self:HideSearchResults()
    self:ShowEmpty(self:EmptyHint())
    return
  end
  -- Exact #id shortcut
  local idOnly = q:match("^#?(%d+)$")
  if idOnly then
    local meta = db() and db().items and db().items[idOnly]
    if meta then
      self:RenderSearchResults({
        { itemId = idOnly, name = meta.name, catalog_key = meta.catalog_key },
      })
      return
    end
  end
  self:RenderSearchResults(searchItems(q))
end

function UI:Toggle()
  if self.frame and self.frame:IsShown() then
    self.frame:Hide()
  else
    self:Show()
  end
end

local function minimapButtonAngle()
  local dbc = charDB()
  local a = tonumber(dbc.minimapAngle)
  if not a then
    a = -0.65 -- default lower-left of minimap
  end
  return a
end

local function updateMinimapButtonPosition(btn)
  if not btn or not Minimap then
    return
  end
  local angle = minimapButtonAngle()
  local radius = ((Minimap:GetWidth() or 140) / 2) + 5
  btn:ClearAllPoints()
  btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local MINIMAP_ICON_PATH = "Interface\\AddOns\\ClassicGmbHQuartermaster\\Textures\\minimap_icon"
local LDB_OBJECT_NAME = "ClassicGmbHQuartermaster"

local function registerMinimapCollectors()
  -- LibDataBroker launcher → SlideBar (and similar collectors) pick this up automatically.
  local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
  if LDB and not UI._ldbObject then
    UI._ldbObject = LDB:NewDataObject(LDB_OBJECT_NAME, {
      type = "launcher",
      icon = MINIMAP_ICON_PATH,
      label = "Classic GmbH Quartermaster",
      tocname = ADDON_NAME,
      OnClick = function(_, button)
        if button == "RightButton" then
          UI:ToggleAssignHud()
          return
        end
        UI:Create()
        UI:Toggle()
      end,
      OnTooltipShow = function(tt)
        if not tt or not tt.AddLine then
          return
        end
        tt:AddLine("Classic GmbH Quartermaster", 0.95, 0.88, 0.55)
        tt:AddLine("Left-click: open window", 0.75, 0.80, 0.88)
        tt:AddLine("Right-click: toggle assignment HUD", 0.75, 0.80, 0.88)
      end,
    })
  end

  -- Direct SlideBar registration (Norganna bar with the yellow edge).
  local SlideBar = LibStub and LibStub("SlideBar", true)
  if SlideBar and SlideBar.AddButton and not UI._slideBarRegistered then
    SlideBar.AddButton(
      LDB_OBJECT_NAME,
      MINIMAP_ICON_PATH,
      60,
      "GmbHLootTrackerSlideBarButton",
      true,
      UI._ldbObject
    )
    UI._slideBarRegistered = true
  end

  -- MinimapButtonBag (MBB) include list, if present.
  if type(MBB_RegisterButton) == "function" and not UI._mbbRegistered then
    MBB_RegisterButton("GmbHLootTrackerMinimapButton")
    UI._mbbRegistered = true
  elseif type(MBB_Include) == "table" and not UI._mbbRegistered then
    local name = "GmbHLootTrackerMinimapButton"
    local found = false
    for _, n in ipairs(MBB_Include) do
      if n == name then
        found = true
        break
      end
    end
    if not found then
      table.insert(MBB_Include, name)
    end
    UI._mbbRegistered = true
    if type(MBB_AddButton) == "function" then
      MBB_AddButton(name)
    elseif type(MBB_GatherIcons) == "function" then
      MBB_GatherIcons()
    end
  end
end

function UI:EnsureMinimapButton()
  registerMinimapCollectors()
  if self.minimapBtn then
    updateMinimapButtonPosition(self.minimapBtn)
    if charDB().minimapHidden then
      self.minimapBtn:Hide()
    else
      self.minimapBtn:Show()
    end
    return self.minimapBtn
  end
  if not Minimap then
    return nil
  end

  local btn = CreateFrame("Button", "GmbHLootTrackerMinimapButton", Minimap)
  btn:SetSize(32, 32)
  btn:SetFrameStrata("MEDIUM")
  btn:SetFrameLevel((Minimap:GetFrameLevel() or 0) + 8)
  btn:SetMovable(true)
  btn:EnableMouse(true)
  btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  btn:RegisterForDrag("LeftButton")
  btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  -- Discord bot logo (circular TGA), LibDBIcon-style centering in the ring.
  local icon = btn:CreateTexture(nil, "BACKGROUND")
  icon:SetTexture(MINIMAP_ICON_PATH)
  icon:SetSize(20, 20)
  icon:SetPoint("CENTER", 0, 0)
  if icon.SetTexCoord then
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
  end
  btn.icon = icon

  local border = btn:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT", 0, 0)

  btn:SetScript("OnEnter", function(selfBtn)
    GameTooltip:SetOwner(selfBtn, "ANCHOR_LEFT")
    GameTooltip:AddLine("Classic GmbH Quartermaster", 0.95, 0.88, 0.55)
    GameTooltip:AddLine("Left-click: open window", 0.75, 0.80, 0.88)
    GameTooltip:AddLine("Right-click: toggle assignment HUD", 0.75, 0.80, 0.88)
    GameTooltip:AddLine("Drag: move around minimap", 0.55, 0.62, 0.72)
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)

  btn:SetScript("OnClick", function(_, button)
    if button == "RightButton" then
      UI:ToggleAssignHud()
      return
    end
    UI:Create()
    UI:Toggle()
  end)

  btn:SetScript("OnDragStart", function(selfBtn)
    selfBtn._dragging = true
    selfBtn:LockHighlight()
    selfBtn:SetScript("OnUpdate", function(b)
      local mx, my = GetCursorPosition()
      local cx, cy = Minimap:GetCenter()
      local scale = Minimap:GetEffectiveScale() or 1
      if not cx or not cy or scale < 0.01 then
        return
      end
      mx, my = mx / scale, my / scale
      local angle = (math.atan2 and math.atan2(my - cy, mx - cx)) or math.atan(my - cy, mx - cx)
      charDB().minimapAngle = angle
      updateMinimapButtonPosition(b)
    end)
  end)
  btn:SetScript("OnDragStop", function(selfBtn)
    selfBtn._dragging = nil
    selfBtn:UnlockHighlight()
    selfBtn:SetScript("OnUpdate", nil)
    updateMinimapButtonPosition(selfBtn)
  end)

  self.minimapBtn = btn
  updateMinimapButtonPosition(btn)
  if charDB().minimapHidden then
    btn:Hide()
  else
    btn:Show()
  end
  registerMinimapCollectors()
  return btn
end

function UI:SetMinimapButtonShown(shown)
  charDB().minimapHidden = not shown
  self:EnsureMinimapButton()
  self:RefreshOptionsPanel()
  printMsg(shown and "Minimap button shown." or "Minimap button hidden. /gmbh minimap to show.")
end

function UI:Show()
  self:Create()
  self._dataDirty = false
  self:RefreshOfficerControls()
  self:RefreshSyncLabel()
  self.frame:Show()
  self.raidViewUserPinned = false
  -- Default: raid sheet for everyone. Wishlist is opt-in via tab.
  -- Always rebuild from current DB here — this is the only place sync data is painted.
  self:SetMainTab(self.mainTab or "raid")
end

function UI:Create()
  if self.frame then
    return
  end

  local f = CreateFrame("Frame", "GmbHLootTrackerFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  f:SetSize(1080, 660)
  f:SetPoint("CENTER")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetFrameStrata("DIALOG")
  f:Hide()
  setBackdrop(f)
  tinsert(UISpecialFrames, "GmbHLootTrackerFrame")

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -14)
  local addonVer = (GmbHLootTrackerSync and GmbHLootTrackerSync.LocalVersion and GmbHLootTrackerSync.LocalVersion())
    or "?"
  title:SetText("Classic GmbH Quartermaster  |cff9aa7b8v" .. tostring(addonVer) .. "|r")
  title:SetTextColor(0.95, 0.96, 0.98)
  self.titleLabel = title

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -4, -4)

  local reloadBtn = makeTextButton(f, "Reload", 70)
  reloadBtn:SetPoint("TOPRIGHT", -12, -32)
  reloadBtn:SetScript("OnClick", function()
    if GmbHLootTrackerSync and GmbHLootTrackerSync.KickAutoSync then
      GmbHLootTrackerSync.KickAutoSync()
    end
    ReloadUI()
  end)
  self.reloadBtn = reloadBtn

  local pushBtn = makeTextButton(f, "Push sync", 90)
  pushBtn:SetPoint("RIGHT", reloadBtn, "LEFT", -6, 0)
  pushBtn:SetScript("OnClick", function()
    if GmbHLootTrackerSync and GmbHLootTrackerSync.PushSync then
      GmbHLootTrackerSync.PushSync()
    end
  end)
  pushBtn:Hide()
  self.pushSyncBtn = pushBtn

  self.syncLabel = makeLabel(f, "Last synced: —", 11)
  self.syncLabel:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
  self.syncLabel:SetPoint("RIGHT", reloadBtn, "LEFT", -8, 0)
  self.syncLabel:SetJustifyH("LEFT")
  self.syncLabel:SetTextColor(0.55, 0.62, 0.72)

  -- Main tabs: Raid | Wishlist | Options
  local tabRaid = makeMainTab(f, "Raid sheet", 110)
  tabRaid:SetPoint("TOPLEFT", 16, -58)
  tabRaid:SetScript("OnClick", function()
    UI:SetMainTab("raid")
  end)
  self.tabRaid = tabRaid

  local tabWishlist = makeMainTab(f, "Wishlist", 100)
  tabWishlist:SetPoint("LEFT", tabRaid, "RIGHT", 6, 0)
  tabWishlist:SetScript("OnClick", function()
    UI:SetMainTab("wishlist")
  end)
  self.tabWishlist = tabWishlist

  local tabOptions = makeMainTab(f, "Options", 90)
  tabOptions:SetPoint("LEFT", tabWishlist, "RIGHT", 6, 0)
  tabOptions:SetScript("OnClick", function()
    UI:SetMainTab("options")
  end)
  self.tabOptions = tabOptions
  self:RefreshWishlistTabVisibility()

  -- ---- Raid sheet panel (all ranks) — next upcoming raid only ----
  local raidPanel = CreateFrame("Frame", nil, f, BackdropTemplateMixin and "BackdropTemplate" or nil)
  raidPanel:SetPoint("TOPLEFT", 16, -92)
  raidPanel:SetPoint("BOTTOMRIGHT", -16, 16)
  setBackdrop(raidPanel)
  self.raidPanel = raidPanel

  self.raidMeta = makeLabel(raidPanel, "", 11)
  self.raidMeta:SetPoint("TOPLEFT", 12, -10)
  self.raidMeta:SetPoint("RIGHT", raidPanel, "RIGHT", -14, 0)
  self.raidMeta:SetTextColor(0.70, 0.76, 0.85)

  -- Two rows: Groups | General | General Tanking  /  boss tabs
  local tabScroll = CreateFrame("ScrollFrame", "GmbHLootTrackerRaidTabs", raidPanel)
  tabScroll:SetPoint("TOPLEFT", 12, -32)
  tabScroll:SetPoint("RIGHT", raidPanel, "RIGHT", -14, 0)
  tabScroll:SetHeight(58)
  local tabChild = CreateFrame("Frame", nil, tabScroll)
  tabChild:SetSize(900, 58)
  tabScroll:SetScrollChild(tabChild)
  tabScroll:EnableMouseWheel(true)
  tabScroll:SetScript("OnMouseWheel", function(self, delta)
    local maxX = math.max(0, (tabChild:GetWidth() or 0) - (self:GetWidth() or 0))
    local cur = self:GetHorizontalScroll() or 0
    self:SetHorizontalScroll(math.max(0, math.min(maxX, cur - delta * 40)))
  end)
  self.raidTabScroll = tabScroll
  self.raidTabChild = tabChild
  self.raidNavTabs = {}

  local raidScroll = CreateFrame("ScrollFrame", "GmbHLootTrackerRaidScroll", raidPanel, "UIPanelScrollFrameTemplate")
  raidScroll:SetPoint("TOPLEFT", 12, -96)
  raidScroll:SetPoint("BOTTOMRIGHT", -32, 12)
  local raidChild = CreateFrame("Frame", nil, raidScroll)
  raidChild:SetSize(1000, 500)
  raidScroll:SetScrollChild(raidChild)
  self.raidScroll = raidScroll
  self.raidScrollChild = raidChild
  self.raidRows = {}

  -- Sort raid sits under the Groups tab content (repositioned in RenderRaidGroupsView).
  local sortRaidBtn = makeTextButton(raidChild, "Sort raid", 100)
  sortRaidBtn:SetPoint("TOPLEFT", raidChild, "TOPLEFT", 4, -2)
  sortRaidBtn:SetScript("OnClick", function()
    UI:SortRaidFromSheet()
  end)
  sortRaidBtn:Hide()
  self.sortRaidBtn = sortRaidBtn

  self.raidGroups = {}
  local GROUP_W, GROUP_H = 200, 118
  for i = 1, 8 do
    local box = CreateFrame("Frame", nil, raidChild, BackdropTemplateMixin and "BackdropTemplate" or nil)
    box:SetSize(GROUP_W, GROUP_H)
    setBackdrop(box)
    if box.SetBackdropColor then
      box:SetBackdropColor(0.07, 0.09, 0.14, 0.95)
      box:SetBackdropBorderColor(0.20, 0.26, 0.36, 1)
    end
    box.title = makeLabel(box, "G" .. i, 12)
    box.title:SetPoint("TOPLEFT", 8, -6)
    box.title:SetTextColor(0.85, 0.88, 0.95)
    box.seats = {}
    for s = 1, 5 do
      local seat = makeLabel(box, "", 11)
      seat:SetPoint("TOPLEFT", 8, -22 - (s - 1) * 16)
      seat:SetPoint("RIGHT", box, "RIGHT", -8, 0)
      box.seats[s] = seat
    end
    box:Hide()
    self.raidGroups[i] = box
  end

  self.benchLabel = makeLabel(raidChild, "", 11)
  self.benchLabel:SetTextColor(0.75, 0.80, 0.88)
  self.benchLabel:Hide()

  self.raidView = "groups"
  self.raidSlug = defaultRaid()

  -- ---- Options (HUD prefs) ----
  local optionsPanel = CreateFrame("Frame", nil, f, BackdropTemplateMixin and "BackdropTemplate" or nil)
  optionsPanel:SetPoint("TOPLEFT", 16, -92)
  optionsPanel:SetPoint("BOTTOMRIGHT", -16, 16)
  setBackdrop(optionsPanel)
  optionsPanel:Hide()
  self.optionsPanel = optionsPanel

  local optTitle = makeLabel(optionsPanel, "Assignment HUD", 14)
  optTitle:SetPoint("TOPLEFT", 18, -20)
  optTitle:SetTextColor(0.95, 0.88, 0.55)

  local optSub = makeLabel(optionsPanel, "What the floating HUD shows for the current boss:", 12)
  optSub:SetPoint("TOPLEFT", optTitle, "BOTTOMLEFT", 0, -10)
  optSub:SetTextColor(0.70, 0.76, 0.85)

  local optMine = makeMainTab(optionsPanel, "Only my assignments", 160)
  optMine:SetPoint("TOPLEFT", optSub, "BOTTOMLEFT", 0, -16)
  optMine:SetScript("OnClick", function()
    UI:SetHudAssignmentsMode("mine")
  end)
  self.optHudMineBtn = optMine

  local optFull = makeMainTab(optionsPanel, "Full assignments", 140)
  optFull:SetPoint("LEFT", optMine, "RIGHT", 8, 0)
  optFull:SetScript("OnClick", function()
    UI:SetHudAssignmentsMode("full")
  end)
  self.optHudFullBtn = optFull

  local optHint = makeLabel(optionsPanel, "", 11)
  optHint:SetPoint("TOPLEFT", optMine, "BOTTOMLEFT", 0, -14)
  optHint:SetPoint("RIGHT", optionsPanel, "RIGHT", -18, 0)
  optHint:SetTextColor(0.60, 0.66, 0.74)
  self.optHudHint = optHint

  local optAutoTitle = makeLabel(optionsPanel, "Auto show", 12)
  optAutoTitle:SetPoint("TOPLEFT", optHint, "BOTTOMLEFT", 0, -22)
  optAutoTitle:SetTextColor(0.70, 0.76, 0.85)

  local optAutoOn = makeMainTab(optionsPanel, "On", 70)
  optAutoOn:SetPoint("TOPLEFT", optAutoTitle, "BOTTOMLEFT", 0, -12)
  optAutoOn:SetScript("OnClick", function()
    UI:SetHudAutoShow(true)
  end)
  self.optHudAutoOnBtn = optAutoOn

  local optAutoOff = makeMainTab(optionsPanel, "Off", 70)
  optAutoOff:SetPoint("LEFT", optAutoOn, "RIGHT", 8, 0)
  optAutoOff:SetScript("OnClick", function()
    UI:SetHudAutoShow(false)
  end)
  self.optHudAutoOffBtn = optAutoOff

  local optAutoHint = makeLabel(
    optionsPanel,
    "On: HUD pops up in AQ40/Naxx when you target a boss. Off: only /gmbh hud or Test HUD.",
    11
  )
  optAutoHint:SetPoint("TOPLEFT", optAutoOn, "BOTTOMLEFT", 0, -14)
  optAutoHint:SetPoint("RIGHT", optionsPanel, "RIGHT", -18, 0)
  optAutoHint:SetTextColor(0.60, 0.66, 0.74)
  self.optHudAutoHint = optAutoHint

  local optSizeTitle = makeLabel(optionsPanel, "HUD size", 12)
  optSizeTitle:SetPoint("TOPLEFT", optAutoHint, "BOTTOMLEFT", 0, -22)
  optSizeTitle:SetTextColor(0.70, 0.76, 0.85)

  local optSmaller = makeMainTab(optionsPanel, "Smaller", 80)
  optSmaller:SetPoint("TOPLEFT", optSizeTitle, "BOTTOMLEFT", 0, -12)
  optSmaller:SetScript("OnClick", function()
    UI:NudgeHudScale(-HUD_SCALE_STEP)
  end)
  self.optHudScaleSmaller = optSmaller

  local optScaleLabel = makeLabel(optionsPanel, "100%", 13)
  optScaleLabel:SetPoint("LEFT", optSmaller, "RIGHT", 12, 0)
  optScaleLabel:SetTextColor(0.95, 0.88, 0.55)
  self.optHudScaleLabel = optScaleLabel

  local optLarger = makeMainTab(optionsPanel, "Larger", 80)
  optLarger:SetPoint("LEFT", optScaleLabel, "RIGHT", 12, 0)
  optLarger:SetScript("OnClick", function()
    UI:NudgeHudScale(HUD_SCALE_STEP)
  end)
  self.optHudScaleLarger = optLarger

  local optReset = makeMainTab(optionsPanel, "Reset", 70)
  optReset:SetPoint("LEFT", optLarger, "RIGHT", 8, 0)
  optReset:SetScript("OnClick", function()
    UI:ResetHudSize()
  end)
  self.optHudScaleReset = optReset

  local optSizeHint = makeLabel(
    optionsPanel,
    "Bottom edge = height, right edge = width, corner = both. Handles stay large when HUD is small.",
    11
  )
  optSizeHint:SetPoint("TOPLEFT", optSmaller, "BOTTOMLEFT", 0, -14)
  optSizeHint:SetPoint("RIGHT", optionsPanel, "RIGHT", -18, 0)
  optSizeHint:SetTextColor(0.60, 0.66, 0.74)

  local optMapTitle = makeLabel(optionsPanel, "Minimap button", 12)
  optMapTitle:SetPoint("TOPLEFT", optSizeHint, "BOTTOMLEFT", 0, -22)
  optMapTitle:SetTextColor(0.70, 0.76, 0.85)

  local optMapShow = makeMainTab(optionsPanel, "Show", 70)
  optMapShow:SetPoint("TOPLEFT", optMapTitle, "BOTTOMLEFT", 0, -12)
  optMapShow:SetScript("OnClick", function()
    UI:SetMinimapButtonShown(true)
  end)
  self.optMinimapShowBtn = optMapShow

  local optMapHide = makeMainTab(optionsPanel, "Hide", 70)
  optMapHide:SetPoint("LEFT", optMapShow, "RIGHT", 8, 0)
  optMapHide:SetScript("OnClick", function()
    UI:SetMinimapButtonShown(false)
  end)
  self.optMinimapHideBtn = optMapHide

  local optMapHint = makeLabel(
    optionsPanel,
    "Circle button uses the Discord bot logo. Left-click opens the window; drag around the minimap.",
    11
  )
  optMapHint:SetPoint("TOPLEFT", optMapShow, "BOTTOMLEFT", 0, -14)
  optMapHint:SetPoint("RIGHT", optionsPanel, "RIGHT", -18, 0)
  optMapHint:SetTextColor(0.60, 0.66, 0.74)

  -- ---- Wishlist lock (non-officers) ----
  local lockPanel = CreateFrame("Frame", nil, f, BackdropTemplateMixin and "BackdropTemplate" or nil)
  lockPanel:SetPoint("TOPLEFT", 16, -92)
  lockPanel:SetPoint("BOTTOMRIGHT", -16, 16)
  setBackdrop(lockPanel)
  lockPanel:Hide()
  local lockLabel = makeLabel(lockPanel, "", 13)
  lockLabel:SetPoint("TOPLEFT", 18, -24)
  lockLabel:SetPoint("RIGHT", lockPanel, "RIGHT", -18, 0)
  lockLabel:SetTextColor(0.85, 0.75, 0.55)
  self.lockPanel = lockPanel
  self.lockLabel = lockLabel

  -- ---- Wishlist content (officers) ----
  local contentPanel = CreateFrame("Frame", nil, f)
  contentPanel:SetPoint("TOPLEFT", 16, -92)
  contentPanel:SetPoint("BOTTOMRIGHT", -16, 16)
  contentPanel:Hide()
  self.contentPanel = contentPanel

  local card = CreateFrame("Frame", nil, contentPanel, BackdropTemplateMixin and "BackdropTemplate" or nil)
  card:SetAllPoints()
  setBackdrop(card)

  local hint = makeLabel(card,
    "Shift-click an item in your bags to search. Helper → HelperData.lua → /reload. Raid sheets auto-sync for guild; wishlist for officers only.",
    11)
  hint:SetPoint("TOPLEFT", 14, -12)
  hint:SetPoint("RIGHT", card, "RIGHT", -14, 0)
  hint:SetTextColor(0.55, 0.62, 0.72)

  local searchLabel = makeLabel(card, "SEARCH ITEM", 11)
  searchLabel:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -14)
  searchLabel:SetTextColor(0.70, 0.76, 0.85)

  local searchBox = CreateFrame("EditBox", "GmbHLootTrackerSearchBox", card, "InputBoxTemplate")
  searchBox:SetAutoFocus(false)
  searchBox:SetHeight(28)
  searchBox:SetPoint("TOPLEFT", searchLabel, "BOTTOMLEFT", 4, -8)
  searchBox:SetPoint("RIGHT", card, "RIGHT", -18, 0)
  searchBox:SetFontObject(GameFontHighlight)
  searchBox:SetScript("OnTextChanged", function()
    UI:OnSearchChanged()
  end)
  searchBox:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
    UI.frame:Hide()
  end)
  searchBox:SetScript("OnEnterPressed", function()
    local hits = searchItems(searchBox:GetText())
    if hits[1] then
      UI:SelectItem(hits[1])
    end
  end)
  self.searchBox = searchBox

  local under = makeLabel(card, "Item name or #item ID…", 11)
  under:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", -2, -6)
  under:SetTextColor(0.45, 0.52, 0.62)

  local results = CreateFrame("Frame", nil, card, BackdropTemplateMixin and "BackdropTemplate" or nil)
  results:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", -4, -4)
  results:SetPoint("RIGHT", searchBox, "RIGHT", 4, 0)
  results:SetFrameStrata("FULLSCREEN_DIALOG")
  results:Hide()
  setBackdrop(results)
  if results.SetBackdropColor then
    results:SetBackdropColor(0.07, 0.09, 0.14, 0.98)
  end
  self.searchResults = results
  self.searchRows = {}
  for i = 1, MAX_RESULTS do
    local row = CreateFrame("Button", nil, results)
    row:SetHeight(22)
    row:SetPoint("TOPLEFT", results, "TOPLEFT", 6, -4 - (i - 1) * 22)
    row:SetPoint("RIGHT", results, "RIGHT", -6, 0)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.label = makeLabel(row, "", 12)
    row.label:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.label:SetPoint("RIGHT")
    row.label:SetTextColor(0.92, 0.94, 0.97)
    row:SetScript("OnClick", function(self)
      if self.hit then
        UI:SelectItem(self.hit)
      end
    end)
    row:Hide()
    self.searchRows[i] = row
  end

  self.emptyLabel = makeLabel(card, "", 12)
  self.emptyLabel:SetPoint("TOPLEFT", under, "BOTTOMLEFT", 0, -16)
  self.emptyLabel:SetPoint("RIGHT", card, "RIGHT", -14, 0)
  self.emptyLabel:SetTextColor(0.55, 0.62, 0.72)

  self.resultHeader = makeLabel(card, "", 13)
  self.resultHeader:SetPoint("TOPLEFT", under, "BOTTOMLEFT", 0, -14)
  self.resultHeader:SetPoint("RIGHT", card, "RIGHT", -14, 0)
  self.resultHeader:SetTextColor(0.95, 0.96, 0.98)
  self.resultHeader:Hide()

  local colHead = CreateFrame("Frame", nil, card)
  colHead:SetPoint("TOPLEFT", self.resultHeader, "BOTTOMLEFT", 0, -8)
  colHead:SetSize(TABLE_INNER_WIDTH, 16)
  colHead:Hide()
  local headers = {
    { "PLAYER", COL.player },
    { "CLASS", COL.class },
    { "ROLE", COL.role },
    { "PRIO", COL.prio },
    { "LOST", COL.lost },
    { "NAXX", COL.naxx },
    { "AQ", COL.aq },
    { "TOTAL", COL.total },
    { "LAST ITEM", COL.last },
    { "DATE", COL.date },
  }
  local hx = 0
  for _, h in ipairs(headers) do
    local fs = makeLabel(colHead, h[1], 10)
    fs:SetPoint("LEFT", colHead, "LEFT", hx, 0)
    fs:SetWidth(h[2])
    fs:SetTextColor(0.50, 0.56, 0.66)
    hx = hx + h[2] + 4
  end
  self.colHead = colHead

  local scroll = CreateFrame("ScrollFrame", "GmbHLootTrackerScroll", card, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", colHead, "BOTTOMLEFT", 0, -6)
  scroll:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -32, 12)
  local child = CreateFrame("Frame", nil, scroll)
  child:SetSize(TABLE_INNER_WIDTH + 8, 40)
  scroll:SetScrollChild(child)
  scroll:Hide()
  self.scroll = scroll
  self.scrollChild = child
  self.candidateRows = {}

  self.mainTab = "raid"
  self.raidSlug = defaultRaid()
  self.frame = f
  self:RefreshOfficerControls()
end

-- ---------------------------------------------------------------------------
-- Slash helpers (chat)
-- ---------------------------------------------------------------------------

local function cmdStatus()
  local data = db()
  if not data then
    printMsg("No data. Run the Windows helper, then /reload.")
  else
    printMsg(string.format(
      "Last synced: %s  rev=%s  officer=%s",
      formatSyncedAt(data.syncedAt),
      string.sub(tostring(data.revision or "?"), 1, 8),
      tostring(data.user and data.user.can_sync and true or false)
    ))
    if data.raidSyncedAt then
      printMsg("Raid sheet synced: " .. formatSyncedAt(data.raidSyncedAt))
    end
    if data.syncSource or data.syncFrom then
      printMsg(string.format(
        "Source: %s%s",
        tostring(data.syncSource or "—"),
        data.syncFrom and (" via " .. tostring(data.syncFrom)) or ""
      ))
    end
  end
  local live = GmbHLootTrackerSync and GmbHLootTrackerSync.GetLiveStatus and GmbHLootTrackerSync.GetLiveStatus()
  if live and live ~= "" then
    printMsg("Sync status: " .. live)
  else
    printMsg("Sync status: idle")
  end
  if GmbHLootTrackerSync and GmbHLootTrackerSync.SyncAuthorityStatus then
    printMsg(GmbHLootTrackerSync.SyncAuthorityStatus("raid"))
    if GmbHLootTrackerSync.CanUseWishlist and GmbHLootTrackerSync.CanUseWishlist() then
      printMsg(GmbHLootTrackerSync.SyncAuthorityStatus("wl"))
    end
  end
  if UI.frame and UI.RefreshSyncLabel then
    UI:RefreshSyncLabel()
  end
end

local function cmdGroups(slug)
  local raid = raidData(slug)
  if not raid then
    printMsg("No raid data.")
    return
  end
  if raid.member_locked then
    printMsg(tostring(slug or defaultRaid()) .. " is locked until announced.")
    return
  end
  for gi, group in ipairs(raid.groups or {}) do
    local names = {}
    for _, seat in ipairs(group or {}) do
      if seat and seat.name then
        table.insert(names, seat.name)
      end
    end
    printMsg(string.format("G%d: %s", gi, table.concat(names, ", ")))
  end
end

local function cmdAssign(slug)
  local raid = raidData(slug)
  if not raid then
    printMsg("No raid data.")
    return
  end
  if raid.member_locked then
    printMsg("Locked until announced.")
    return
  end
  for _, a in ipairs(raid.assignments or {}) do
    if a.player_name then
      printMsg(string.format(
        "%s / %s / %s: %s",
        tostring(a.section_label or ""),
        tostring(a.board_label or ""),
        tostring(a.label or a.slot_id or ""),
        tostring(a.player_name)
      ))
    end
  end
end

local function cmdWl(name)
  if GmbHLootTrackerSync and not GmbHLootTrackerSync.CanUseWishlist() then
    printMsg("Wishlist is limited to Classic GmbH Officer / Headmaster ranks.")
    return
  end
  local data = db()
  if not data or not data.wishlists then
    printMsg("No wishlist data.")
    return
  end
  name = trim(name)
  if name == "" then
    name = UnitName("player") or ""
  end
  local entry = data.wishlists[name]
  if not entry then
    for k, v in pairs(data.wishlists) do
      if string.lower(k) == string.lower(name) then
        entry = v
        name = k
        break
      end
    end
  end
  if not entry then
    printMsg("No wishlist for " .. tostring(name))
    return
  end
  printMsg(string.format("%s (%s) role=%s", name, tostring(entry.realm or "?"), tostring(entry.loot_role or "?")))
  for _, item in ipairs(entry.items or {}) do
    printMsg(string.format(
      "  #%d %s (%s)%s",
      tonumber(item.priority) or 0,
      tostring(item.name or "?"),
      tostring(item.item_id or "?"),
      item.has_item and " [HAS]" or ""
    ))
  end
end

local function cmdNeed(itemIdRaw)
  if GmbHLootTrackerSync and not GmbHLootTrackerSync.CanUseWishlist() then
    printMsg("Wishlist is limited to Classic GmbH Officer / Headmaster ranks.")
    return
  end
  local itemId = tostring(tonumber(itemIdRaw) or trim(itemIdRaw) or "")
  local rows = candidatesForItem(itemId)
  if #rows == 0 then
    printMsg("No wishlist need for item " .. itemId)
    return
  end
  local meta = db() and db().items and db().items[itemId]
  printMsg(string.format("Need %s (#%s):", meta and meta.name or "item", itemId))
  for _, row in ipairs(rows) do
    printMsg(string.format(
      "  prio %d  %s  lost=%d",
      tonumber(row.priority) or 0,
      tostring(row.name or "?"),
      tonumber(row.lost_rolls) or 0
    ))
  end
end

local function usage()
  printMsg("Commands: /gmbh | hud | minimap | hudscale <%> | target <boss> | debug | status | push | groups | sort | assign | wl | need")
end

SLASH_GMBH1 = "/gmbh"
SlashCmdList["GMBH"] = function(msg)
  msg = string.lower(trim(msg or ""))
  if msg == "" then
    UI:Create()
    UI:Toggle()
    return
  end
  if msg == "help" then
    usage()
    return
  end
  if msg == "status" or msg == "sync" then
    cmdStatus()
    return
  end
  if msg == "push" or msg == "pushsync" or msg == "share" then
    if GmbHLootTrackerSync and GmbHLootTrackerSync.PushSync then
      GmbHLootTrackerSync.PushSync()
    end
    return
  end
  if msg == "hud" or msg == "assignhud" or msg == "myassign" then
    UI:ToggleAssignHud()
    return
  end
  if msg == "minimap" or msg == "mapbtn" or msg == "mm" then
    local hidden = charDB().minimapHidden and true or false
    UI:SetMinimapButtonShown(hidden)
    return
  end
  if msg == "debug" then
    debugHelperState()
    return
  end
  local cmd, rest = msg:match("^(%S+)%s*(.-)$")
  if cmd == "hudscale" or cmd == "hudsize" or cmd == "scale" then
    rest = trim(rest or "")
    if rest == "" or rest == "show" then
      printMsg(string.format(
        "HUD size: %d%% (Options tab, Alt+wheel on HUD, or /gmbh hudscale 75-200)",
        math.floor(UI:GetHudScale() * 100 + 0.5)
      ))
      return
    end
    if rest == "reset" or rest == "default" then
      UI:ResetHudSize()
      return
    end
    local pct = tonumber((rest:gsub("%%", "")))
    if not pct then
      printMsg("Usage: /gmbh hudscale <percent>  e.g. /gmbh hudscale 125  ·  corner-drag HUD to resize")
      return
    end
    -- Accept 0.75–2.0 as scale or 75–200 as percent.
    if pct <= HUD_SCALE_MAX + 0.01 then
      UI:SetHudScale(pct)
    else
      UI:SetHudScale(pct / 100)
    end
    return
  end
  if cmd == "target" or cmd == "hudtarget" or cmd == "testhud" then
    UI:SetHudTestTarget(rest)
  elseif cmd == "groups" or cmd == "group" then
    cmdGroups(rest ~= "" and rest or nil)
  elseif cmd == "sort" or cmd == "sortgroups" or cmd == "sortraid" then
    UI:SortRaidFromSheet()
  elseif cmd == "assign" or cmd == "assignments" then
    cmdAssign(rest ~= "" and rest or nil)
  elseif cmd == "wl" or cmd == "wishlist" then
    cmdWl(rest)
  elseif cmd == "need" then
    cmdNeed(rest)
  elseif cmd == "ui" or cmd == "show" then
    UI:Create()
    UI:Show()
  else
    usage()
  end
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:RegisterEvent("PLAYER_LOGIN")
boot:RegisterEvent("GET_ITEM_INFO_RECEIVED")
boot:RegisterEvent("ZONE_CHANGED")
boot:RegisterEvent("ZONE_CHANGED_INDOORS")
boot:RegisterEvent("ZONE_CHANGED_NEW_AREA")
boot:RegisterEvent("PLAYER_ENTERING_WORLD")
boot:RegisterEvent("PLAYER_TARGET_CHANGED")
boot:SetScript("OnEvent", function(_, event, arg1)
  if event == "GET_ITEM_INFO_RECEIVED" then
    if UI.frame and UI.frame:IsShown() and UI.selectedItemId then
      UI:RenderCandidates()
    end
    return
  end
  if event == "ZONE_CHANGED" or event == "ZONE_CHANGED_INDOORS"
    or event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD"
    or event == "PLAYER_TARGET_CHANGED"
  then
    -- Personal assignment HUD follows instance/boss even if main window is closed.
    UI:RefreshAssignHud()

    if UI.frame and UI.frame:IsShown() and (not UI.mainTab or UI.mainTab == "raid") then
      local force = event ~= "PLAYER_TARGET_CHANGED"
      if event == "PLAYER_TARGET_CHANGED" then
        local slug = instanceRaidSlug()
        if slug and UnitExists and UnitExists("target") and bossLabelFromUnitName(slug, UnitName("target")) then
          force = true
        else
          force = false
        end
      else
        UI.raidViewUserPinned = false
      end
      if force then
        if UI:ApplyInstanceBossView({ force = true }) then
          UI:RenderRaidSheet()
        elseif event ~= "PLAYER_TARGET_CHANGED" then
          UI:RenderRaidSheet()
        end
      elseif event == "PLAYER_TARGET_CHANGED" then
        if UI:ApplyInstanceBossView({ force = true }) then
          UI:RenderRaidSheet()
        end
      end
    end
    return
  end
  if event == "ADDON_LOADED" and arg1 ~= ADDON_NAME then
    return
  end
  if event == "ADDON_LOADED" then
    -- Prefer HelperData; do not copy into SV (SV nil load must not matter).
    -- Do not SanitizeTree(HelperData) here — a full walk freezes Classic on large sheets.
    debugHelperState()
    return
  end
  if event ~= "PLAYER_LOGIN" then
    return
  end
  if GmbHLootTrackerSync then
    GmbHLootTrackerSync.Register()
  end
  hookShiftClickItemLinks()
  UI:Create()
  UI:EnsureMinimapButton()
  UI:RefreshAssignHud()
  -- Layout is fully ready one frame later; re-pin HUD if SV position exists.
  if C_Timer and C_Timer.After then
    C_Timer.After(0, function()
      if UI.assignHud and not UI.assignHud._dragging then
        applyAssignHudPosition(UI.assignHud)
        UI.assignHud._posApplied = true
        UI:RefreshAssignHud()
      end
      UI:EnsureMinimapButton()
    end)
    -- SlideBar / MBB may finish later than us — re-register once more.
    C_Timer.After(1, function()
      UI:EnsureMinimapButton()
    end)
  end
  local data = db()
  if type(data) == "table" and data.syncedAt then
    printMsg("Helper data ready. /gmbh opens Raid sheet (all) + Wishlist (officers).")
  else
    printMsg("No HelperData. Run helper, /reload, then /gmbh debug")
  end
end)
