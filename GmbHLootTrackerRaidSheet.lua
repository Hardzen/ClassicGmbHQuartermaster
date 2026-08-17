--[[ Classic GmbH Quartermaster — raid sheet section layouts (website-style). ]]

local U = GmbHLootTrackerUtil or {}
local coloredText = U.coloredText or function(_, t) return tostring(t or "") end
local classHex = U.classHex or function() return nil end
local playerColorHex = U.playerColorHex or function(p)
  return p and classHex(p.class) or nil
end

local MARK_ORDER = { "skull", "cross", "square", "moon", "triangle", "diamond", "circle", "star" }
local MARK_ICON = U.MARK_ICON or {
  skull = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_8:10:10:0:0|t",
  cross = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_7:10:10:0:0|t",
  square = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_6:10:10:0:0|t",
  moon = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_5:10:10:0:0|t",
  triangle = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_4:10:10:0:0|t",
  diamond = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_3:10:10:0:0|t",
  circle = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_2:10:10:0:0|t",
  star = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:10:10:0:0|t",
}

-- Fallback board marks when sync has no board.mark yet (boss/pack boards).
-- Twins: marks live on tank/lock SLOTS only — not on the boss boards.
local BOARD_MARK_FALLBACK = {
  sker_middle = "skull", sker_left = "cross", sker_right = "square",
  kri = "skull", yauj = "cross", vem = "square",
  sart = "triangle",
  sart_rg1 = "skull", sart_rg2 = "cross", sart_rg3 = "square",
  fank = "skull", visc = "skull", huhu = "skull",
  cthun_w1 = "skull", cthun_w2 = "cross", cthun_w3 = "square", cthun_w4 = "moon",
  cthun_w5 = "triangle", cthun_w6 = "diamond", cthun_w7 = "circle", cthun_w8 = "star",
  hm_blaumeux = "square", hm_zeliek = "moon", hm_thane = "skull", hm_mograine = "cross",
  spore_1 = "skull", spore_4 = "moon", spore_5 = "triangle", spore_6 = "diamond",
  thad_stalag = "skull", thad_feugen = "cross",
  kt_stack_g2 = "circle", kt_stack_g3 = "star", kt_stack_g4 = "diamond", kt_stack_g5 = "square",
}

-- Slot marks when HelperData omits slot.mark (Twins: tanks/locks are marked, not bosses).
local SLOT_MARK_FALLBACK = {
  twin_l_t = "triangle", twin_l_lock = "diamond",
  twin_r_t = "square", twin_r_lock = "moon",
  twin_bugs_t = "circle",
  sker_middle_tank = "skull", sker_left_tank = "cross", sker_right_tank = "square",
  kri_t = "skull", yauj_t = "cross", vem_t = "square",
  sart_t = "triangle", sart_rg1_t = "skull", sart_rg2_t = "cross", sart_rg3_t = "square",
  fank_t = "skull", visc_t = "skull", huhu_t = "skull",
  faer_mt = "circle", faer_f1 = "skull", faer_f2 = "cross",
  faer_w1 = "moon", faer_w2 = "square", faer_w3 = "triangle", faer_w4 = "diamond",
  anub_cg1 = "skull", anub_cg2 = "cross",
  noth_w1 = "skull", noth_w2 = "cross", noth_c1 = "skull", noth_c2 = "cross", noth_c3 = "square",
  hm_bl_t1 = "square", hm_ze_t1 = "moon", hm_th_t1 = "skull", hm_mo_t1 = "cross",
  kt_t1 = "star", kt_t2 = "circle", kt_t3 = "diamond", kt_t4 = "square",
  kt_sh_moon = "moon", kt_sh_tri = "triangle", kt_sh_cross = "cross",
  raz_u1_mark = "skull", raz_u2_mark = "cross", raz_u3_mark = "moon", raz_u4_mark = "square",
  thad_stalag_mark = "skull", thad_feugen_mark = "cross",
  stun_1 = "skull", stun_2 = "cross", stun_3 = "square", stun_4 = "moon",
}

local SECTION_ID_FROM_LABEL = {
  ["buffs & debuffs"] = "buffs",
  ["general tanking & groupheal"] = "general_tanks",
  ["general tanking & healers"] = "general_tanks",
  ["prophet skeram"] = "skeram",
  ["bug trio"] = "bugtrio",
  ["battleguard sartura"] = "sartura",
  ["fankriss"] = "fankriss",
  ["viscidus"] = "viscidus",
  ["princess huhuran"] = "huhuran",
  ["twin emperors"] = "twins",
  ["c'thun"] = "cthun",
  ["anub'rekhan"] = "anub",
  ["grand widow faerlina"] = "faerlina",
  ["maexxna"] = "maexxna",
  ["noth the plaguebringer"] = "noth",
  ["heigan the unclean"] = "heigan",
  ["loatheb"] = "loatheb",
  ["patchwerk"] = "patchwerk",
  ["grobbulus"] = "grobbulus",
  ["gluth"] = "gluth",
  ["thaddius"] = "thaddius",
  ["instructor razuvious"] = "razuvious",
  ["gothik the harvester"] = "gothik",
  ["four horsemen"] = "horsemen",
  ["sapphiron"] = "sapphiron",
  ["kel'thuzad"] = "kelthuzad",
}

local function markIcon(mark)
  if U.markIcon then
    local ic = U.markIcon(mark)
    if ic then
      return ic
    end
  end
  local key = string.lower(tostring(mark or ""))
  return MARK_ICON[key] or tostring(mark or "")
end

local function sortMarks(marks)
  table.sort(marks, function(a, b)
    local ia, ib = 99, 99
    for i, key in ipairs(MARK_ORDER) do
      if key == a then
        ia = i
      end
      if key == b then
        ib = i
      end
    end
    return ia < ib
  end)
  return marks
end

local function slotText(slot, opts)
  opts = opts or {}
  if not slot then
    return "|cff555555Empty|r"
  end
  local text
  if slot.fixed ~= nil and tostring(slot.fixed) ~= "" then
    text = "|cffc9b27a" .. tostring(slot.fixed) .. "|r"
  elseif slot.player_name and tostring(slot.player_name) ~= "" then
    local pname = tostring(slot.player_name)
    text = coloredText(playerColorHex(slot), pname)
    -- Tag the viewer so they spot themselves on the sheet.
    local me = UnitName and UnitName("player")
    if me then
      local a = string.lower((pname:match("^([^%-]+)") or pname))
      local b = string.lower((tostring(me):match("^([^%-]+)") or tostring(me)))
      if a == b then
        text = text .. " |cff66cc66(you)|r"
      end
    end
  else
    text = "|cff555555Empty|r"
  end
  -- Twins (and similar): mark lives on the tank/lock slot — show it on the player cell.
  if opts.showMark then
    local mk = nil
    local raw = string.lower(tostring(slot.mark or ""))
    if raw ~= "" and MARK_ICON[raw] then
      mk = raw
    else
      local sid = string.lower(tostring(slot.id or ""))
      mk = SLOT_MARK_FALLBACK[sid]
    end
    if mk then
      -- No space: texture escape already pads; keeps icon on the same line as the name.
      text = markIcon(mk) .. text
    end
  end
  return text
end

local function slotFilled(slot)
  return slot and (
    (slot.player_name and tostring(slot.player_name) ~= "")
    or (slot.fixed ~= nil and tostring(slot.fixed) ~= "")
  )
end

local function boardMatches(board, pats)
  local id = string.lower(tostring(board.id or ""))
  local label = string.lower(tostring(board.label or ""))
  local sid = ""
  if board.slots and board.slots[1] then
    sid = string.lower(tostring(board.slots[1].id or ""))
  end
  for _, pat in ipairs(pats) do
    if (id ~= "" and string.find(id, pat, 1, true))
      or (label ~= "" and string.find(label, pat, 1, true))
      or (sid ~= "" and string.find(sid, pat, 1, true))
    then
      return true
    end
  end
  return false
end

local function findBoard(section, pats)
  for _, board in ipairs(section.boards or {}) do
    if boardMatches(board, pats) then
      return board
    end
  end
  return nil
end

local function boardById(section, bid)
  bid = string.lower(tostring(bid or ""))
  for _, board in ipairs(section.boards or {}) do
    local id = string.lower(tostring(board.id or ""))
    if id == bid or (bid ~= "" and string.sub(id, -#bid) == bid) then
      return board
    end
  end
  return nil
end

local function slotById(section, sid)
  sid = tostring(sid or "")
  for _, board in ipairs(section.boards or {}) do
    for _, slot in ipairs(board.slots or {}) do
      if tostring(slot.id or "") == sid then
        return slot
      end
    end
  end
  return nil
end

local function slotMarkKey(slot)
  if not slot then
    return nil
  end
  local m = string.lower(tostring(slot.mark or ""))
  if m ~= "" and MARK_ICON[m] then
    return m
  end
  local sid = string.lower(tostring(slot.id or ""))
  if SLOT_MARK_FALLBACK[sid] then
    return SLOT_MARK_FALLBACK[sid]
  end
  local lab = string.lower(tostring(slot.label or ""))
  for _, key in ipairs(MARK_ORDER) do
    if lab == key then
      return key
    end
  end
  -- Id suffix: goth_gh_skull, cthun_w1_m1 still prefer slot.mark / fallback above.
  for _, key in ipairs(MARK_ORDER) do
    if sid == key or string.sub(sid, -(#key + 1)) == "_" .. key then
      return key
    end
  end
  local id = tostring(slot.id or "")
  local n = id:match("_tank_(%d+)$") or id:match("_bt_(%d+)$")
    or id:match("^tank_(%d+)$") or id:match("^stun_(%d+)$")
    or id:match("^sunder_%d+_(%d+)$")
  if n then
    return MARK_ORDER[tonumber(n)]
  end
  return nil
end

local function boardMarkKey(board)
  local m = string.lower(tostring(board.mark or ""))
  if m ~= "" and MARK_ICON[m] then
    return m
  end
  local id = string.lower(tostring(board.id or ""))
  if BOARD_MARK_FALLBACK[id] then
    return BOARD_MARK_FALLBACK[id]
  end
  -- Do not pull twin tank marks up as a "boss" mark.
  if string.find(id, "twin_", 1, true) then
    return nil
  end
  local lab = string.lower(tostring(board.mob or board.label or ""))
  if string.find(lab, "twin", 1, true)
    or (string.find(lab, "bug", 1, true) and string.find(lab, "mutat", 1, true))
  then
    return nil
  end
  for _, slot in ipairs(board.slots or {}) do
    local sm = slotMarkKey(slot)
    if sm then
      return sm
    end
  end
  return nil
end

local function sectionIdOf(section)
  local id = string.lower(tostring(section.id or ""))
  if id ~= "" then
    return id
  end
  local label = string.lower(tostring(section.label or ""))
  return SECTION_ID_FROM_LABEL[label] or label
end

local function marksText(marks)
  if not marks or #marks == 0 then
    return "-"
  end
  local bits = {}
  for _, m in ipairs(marks) do
    table.insert(bits, markIcon(m))
  end
  return table.concat(bits, "")
end

local function newCtx(ui)
  local ctx = {
    ui = ui,
    y = -2,
    lineIdx = 0,
    gridIdx = 0,
  }

  function ctx:addLine(text, r, g, b, indent)
    self.lineIdx = self.lineIdx + 1
    local row = self.ui:EnsureRaidRow(self.lineIdx)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", self.ui.raidScrollChild, "TOPLEFT", 4 + (indent or 0), self.y)
    row:SetPoint("RIGHT", self.ui.raidScrollChild, "RIGHT", -4, 0)
    row:SetHeight(16)
    row.text:SetText(text or "")
    -- White vertex colour so embedded |cff class colours render correctly.
    if text and string.find(tostring(text), "|cff", 1, true) then
      row.text:SetTextColor(1, 1, 1)
    else
      row.text:SetTextColor(r or 0.85, g or 0.88, b or 0.92)
    end
    row:Show()
    self.y = self.y - 16
  end

  function ctx:addGrid(values, widths, opts)
    opts = opts or {}
    self.gridIdx = self.gridIdx + 1
    local row = self.ui:EnsureRaidGridRow(self.gridIdx, #values)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", self.ui.raidScrollChild, "TOPLEFT", 4 + (opts.indent or 0), self.y)
    row:SetWidth(opts.width or 880)
    row:SetHeight(opts.height or 18)
    local x = 0
    for i, val in ipairs(values) do
      local cell = row.cells[i]
      local w = widths[i] or 110
      cell:ClearAllPoints()
      cell:SetPoint("LEFT", row, "LEFT", x, 0)
      cell:SetWidth(w)
      cell:SetHeight(opts.height or 18)
      if cell.SetWordWrap then
        cell:SetWordWrap(false)
      end
      if cell.SetNonSpaceWrap then
        cell:SetNonSpaceWrap(false)
      end
      if cell.SetMaxLines then
        cell:SetMaxLines(1)
      end
      cell:SetJustifyV("MIDDLE")
      cell:SetText(val or "")
      if opts.header then
        cell:SetTextColor(0.72, 0.80, 0.92)
      else
        -- Keep vertex white so |cff class colours are visible.
        cell:SetTextColor(1, 1, 1)
      end
      x = x + w + 4
    end
    row:Show()
    self.y = self.y - (opts.height or 18)
  end

  function ctx:title(text)
    self:addLine("|cffffd100" .. tostring(text or "") .. "|r", 1, 0.85, 0.3, 0)
  end

  function ctx:subhead(text)
    self:addLine("|cff9eb6d4" .. tostring(text or "") .. "|r", 0.62, 0.72, 0.85, 0)
  end

  function ctx:note(text)
    if text and tostring(text) ~= "" then
      self:addLine("|cff888888" .. tostring(text) .. "|r", 0.55, 0.58, 0.62, 0)
    end
  end

  function ctx:gap(px)
    self.y = self.y - (px or 6)
  end

  function ctx:addHudTestButton(bossLabel)
    if not self.ui.EnsureHudTestBtn then
      return
    end
    self.hudBtnIdx = (self.hudBtnIdx or 0) + 1
    self:gap(6)
    local btn = self.ui:EnsureHudTestBtn(self.hudBtnIdx)
    btn.bossLabel = tostring(bossLabel or "")
    btn:SetText("Test HUD")
    btn:ClearAllPoints()
    btn:SetPoint("TOPLEFT", self.ui.raidScrollChild, "TOPLEFT", 4, self.y)
    btn:Show()
    self.y = self.y - 28
  end

  function ctx:finish()
    self.ui.raidScrollChild:SetHeight(math.max(80, -self.y + 20))
  end

  return ctx
end

--------------------------------------------------------------------
-- Buffs / General tanking
--------------------------------------------------------------------

local function renderBuffs(ctx, section)
  ctx:title(section.label or "Buffs & Debuffs")
  if section.why then
    ctx:note(section.why)
  end
  local fort = findBoard(section, { "fort" })
  local ai = findBoard(section, { "ai", "arcane", "intellect" })
  local motw = findBoard(section, { "motw", "mark of the wild", "wild" })
  local pi = findBoard(section, { "pi", "power infusion", "infusion" })
  local dm = findBoard(section, { "detect" })
  local chains = findBoard(section, { "innervate", "soulstone", "chain" })
  local deb = findBoard(section, { "debuff" })

  local fortSlots = (fort and fort.slots) or {}
  local aiSlots = (ai and ai.slots) or {}
  local motwSlots = (motw and motw.slots) or {}
  local n = math.max(#fortSlots, #aiSlots, #motwSlots, 8)
  local widths = { 64, 118, 130, 130 }
  -- Left column = buffs; debuffs sit to the right in unused space.
  local colTop = ctx.y
  local DEB_X = 470

  ctx:addGrid({ "", "Fortitude", "Arcane Intellect", "Mark of the Wild" }, widths, { header = true, height = 16 })
  for i = 1, n do
    ctx:addGrid({
      "Group " .. i,
      slotText(fortSlots[i]),
      slotText(aiSlots[i]),
      slotText(motwSlots[i]),
    }, widths, { height = 17 })
  end
  ctx:gap(6)

  local piSlots = (pi and pi.slots) or {}
  if #piSlots > 0 then
    ctx:subhead("Power Infusion")
    local pairCount = math.floor(#piSlots / 2)
    for i = 0, pairCount - 1 do
      local src = piSlots[i * 2 + 1]
      local dst = piSlots[i * 2 + 2]
      if slotFilled(src) or i < 2 then
        ctx:addLine(string.format("%s  >>  %s", slotText(src), slotText(dst)), 0.85, 0.88, 0.92, 10)
      end
    end
    ctx:gap(4)
  end

  local dmSlots = (dm and dm.slots) or {}
  if #dmSlots > 0 then
    ctx:subhead("Detect Magic")
    local bits = {}
    for _, slot in ipairs(dmSlots) do
      local mk = slotMarkKey(slot) or string.lower(tostring(slot.label or ""))
      table.insert(bits, string.format("%s %s", markIcon(mk), slotText(slot)))
    end
    ctx:addLine(table.concat(bits, "   "), 0.85, 0.88, 0.92, 10)
    ctx:gap(4)
  end

  local chainSlots = (chains and chains.slots) or {}
  if #chainSlots >= 2 then
    ctx:subhead("Innervate")
    ctx:addLine(string.format("%s  >>  %s", slotText(chainSlots[1]), slotText(chainSlots[2])), 0.85, 0.88, 0.92, 10)
    if #chainSlots >= 4 then
      ctx:subhead("Soulstones")
      for i = 3, #chainSlots, 2 do
        ctx:addLine(string.format("%s  >>  %s", slotText(chainSlots[i]), slotText(chainSlots[i + 1])), 0.85, 0.88, 0.92, 10)
      end
    end
    ctx:gap(4)
  end

  local leftBottom = ctx.y

  if deb and deb.slots and #deb.slots > 0 then
    ctx.y = colTop
    ctx:addLine("|cff9eb6d4Debuffs|r", 0.62, 0.72, 0.85, DEB_X)
    local debW = { 130, 120 }
    for _, slot in ipairs(deb.slots) do
      local left = tostring(slot.label or slot.id or "?")
      local mk = slotMarkKey(slot)
      if mk then
        left = markIcon(mk) .. " " .. left
      end
      ctx:addGrid({ left, slotText(slot) }, debW, { indent = DEB_X, height = 16, width = 280 })
    end
    local rightBottom = ctx.y
    ctx.y = math.min(leftBottom, rightBottom)
  end
  ctx:gap(8)
end

local function renderTanking(ctx, section)
  local title = tostring(section.label or "General tanking")
  if string.find(string.lower(title), "tanking", 1, true) then
    title = "General tanking"
  end
  ctx:title(title)
  if section.why then
    ctx:note(section.why)
  end

  local tanksBoard, healBoard, shamBoard, focusBoard, meleeBoard, stunBoard, sunderBoard, lipBoard
  for _, board in ipairs(section.boards or {}) do
    local id = string.lower(tostring(board.id or ""))
    local label = string.lower(tostring(board.label or ""))
    if id == "theal_focus" or string.find(label, "focus", 1, true) then
      focusBoard = board
    elseif id == "theal_melee" or (string.find(label, "melee", 1, true) and string.find(label, "heal", 1, true)) then
      meleeBoard = board
    elseif id == "stun_rot" or string.find(label, "stun", 1, true) then
      stunBoard = board
    elseif id == "sunder_armor" or string.find(label, "sunder", 1, true) then
      sunderBoard = board
    elseif id == "lip_skitter" or string.find(label, "skitter", 1, true) or string.find(label, "lip", 1, true) then
      lipBoard = board
    elseif boardMatches(board, { "groupheal" }) or (string.find(label, "shaman", 1, true) and string.find(label, "group", 1, true)) then
      shamBoard = board
    elseif id == "tank_healers" or id == "aq_theal" or string.find(label, "tank heal", 1, true)
      or (string.find(label, "dedicated tank healer", 1, true)) then
      healBoard = board
    elseif (string.find(id, "tank", 1, true) or string.find(label, "tank", 1, true))
      and not string.find(id, "heal", 1, true)
      and not string.find(label, "heal", 1, true)
    then
      tanksBoard = board
    end
  end
  tanksBoard = tanksBoard or (section.boards or {})[1]

  local byMark = {}
  for _, slot in ipairs((tanksBoard and tanksBoard.slots) or {}) do
    local m = slotMarkKey(slot) or "none"
    byMark[m] = byMark[m] or { tank = nil, backup = nil }
    local lab = string.lower(tostring(slot.label or ""))
    local sid = string.lower(tostring(slot.id or ""))
    if string.find(lab, "backup", 1, true) or lab == "bt" or string.find(sid, "_bt_", 1, true) then
      byMark[m].backup = slot
    else
      byMark[m].tank = slot
    end
  end
  local marks = {}
  for _, m in ipairs(MARK_ORDER) do
    if byMark[m] then
      table.insert(marks, m)
    end
  end
  for m, _ in pairs(byMark) do
    local known = false
    for _, om in ipairs(MARK_ORDER) do
      if om == m then
        known = true
        break
      end
    end
    if not known then
      table.insert(marks, m)
    end
  end

  local healSlots = (healBoard and healBoard.slots) or {}
  local isNaxx = focusBoard or meleeBoard or stunBoard or (#healSlots > 8)

  if isNaxx then
    local shamSlots, priestSlots, druidSlots = {}, {}, {}
    for _, s in ipairs(healSlots) do
      local sid = string.lower(tostring(s.id or ""))
      local lab = string.lower(tostring(s.label or ""))
      if string.find(sid, "priest", 1, true) or string.find(lab, "priest", 1, true) then
        table.insert(priestSlots, s)
      elseif string.find(sid, "druid", 1, true) or string.find(lab, "druid", 1, true) then
        table.insert(druidSlots, s)
      else
        table.insert(shamSlots, s)
      end
    end
    local threeCol = #priestSlots > 0 or #druidSlots > 0
    if threeCol then
      local w = { 50, 100, 100, 100, 100 }
      ctx:addGrid({ "Target", "Tank", "Sham", "Priest", "Druid" }, w, { header = true, height = 16 })
      for i, m in ipairs(marks) do
        local row = byMark[m] or {}
        ctx:addGrid({
          markIcon(m),
          slotText(row.tank),
          slotText(shamSlots[i]),
          slotText(priestSlots[i]),
          slotText(druidSlots[i]),
        }, w, { height = 17 })
      end
    else
      local w = { 50, 110, 140 }
      ctx:addGrid({ "Target", "Tank", "Tank healers" }, w, { header = true, height = 16 })
      for i, m in ipairs(marks) do
        local row = byMark[m] or {}
        ctx:addGrid({ markIcon(m), slotText(row.tank), slotText(shamSlots[i]) }, w, { height = 17 })
      end
    end

    local function listBoard(board, head)
      if not board or not board.slots or #board.slots == 0 then
        return
      end
      ctx:gap(6)
      ctx:subhead(head or board.label or board.id)
      local bits = {}
      for _, s in ipairs(board.slots) do
        local mk = slotMarkKey(s)
        local left = mk and (markIcon(mk) .. " ") or ""
        table.insert(bits, left .. slotText(s))
      end
      -- wrap into lines of ~4
      local line = {}
      for i, bit in ipairs(bits) do
        table.insert(line, bit)
        if #line == 4 or i == #bits then
          ctx:addLine(table.concat(line, "   "), 0.85, 0.88, 0.92, 8)
          line = {}
        end
      end
    end
    listBoard(focusBoard, "Focus tank healers")
    listBoard(meleeBoard, "Melee & ranged healers")
    listBoard(stunBoard, "Stun rotation")
    listBoard(sunderBoard, "Sunder Armor")
    listBoard(lipBoard, "LIP + AoE Taunt Skitterers")
  else
    local shamSlots = (shamBoard and shamBoard.slots) or {}
    local leftW = { 50, 110, 110, 140 }
    ctx:addGrid({ "Target", "Tank", "Backup tank", "Tank healers" }, leftW, { header = true, height = 16 })
    for i, m in ipairs(marks) do
      local row = byMark[m] or {}
      ctx:addGrid({
        markIcon(m),
        slotText(row.tank),
        slotText(row.backup),
        slotText(healSlots[i]),
      }, leftW, { height = 17 })
    end
    if #shamSlots > 0 then
      ctx:gap(6)
      ctx:subhead("Groupheal")
      local shamW = { 40, 120 }
      ctx:addGrid({ "Heal", "Shaman" }, shamW, { header = true, height = 16, indent = 8 })
      for i, slot in ipairs(shamSlots) do
        local lab = tostring(slot.label or "")
        if lab == "" or lab == tostring(slot.id or "") then
          lab = "G" .. i
        end
        ctx:addGrid({ lab, slotText(slot) }, shamW, { height = 16, indent = 8 })
      end
    end
  end
  ctx:gap(8)
end

--------------------------------------------------------------------
-- Website-style Mob | Mark | role columns (AQ40 bosses, etc.)
--------------------------------------------------------------------

local function bugTrioBoardKey(board)
  local id = string.lower(tostring(board.id or ""))
  if id == "kri" or id == "yauj" or id == "vem" then
    return id
  end
  local lab = string.lower(tostring(board.mob or board.label or ""))
  if lab == "kri" or lab == "yauj" or lab == "vem" then
    return lab
  end
  -- Infer from slot ids (older HelperData has no board.id).
  for _, slot in ipairs(board.slots or {}) do
    local sid = string.lower(tostring(slot.id or ""))
    local pref = sid:match("^([a-z]+)_")
    if pref == "kri" or pref == "yauj" or pref == "vem" then
      return pref
    end
  end
  return id ~= "" and id or lab
end

local function orderBugTrioBoards(boards, lastId)
  -- Keep non-last bosses in schema order; put "last" kill at the bottom (website/Excel).
  lastId = string.lower(tostring(lastId or ""))
  if lastId == "" or (lastId ~= "kri" and lastId ~= "yauj" and lastId ~= "vem") then
    return boards
  end
  local head, tail = {}, {}
  for _, b in ipairs(boards or {}) do
    local key = bugTrioBoardKey(b)
    if key == lastId then
      table.insert(tail, b)
    else
      table.insert(head, b)
    end
  end
  for _, b in ipairs(tail) do
    table.insert(head, b)
  end
  return head
end

local function renderAssignTable(ctx, section, raid)
  local sid = sectionIdOf(section)
  ctx:title(section.label or sid)
  local bugLast = string.lower(tostring((raid and raid.bug_trio_last) or ""))
  local isBugTrio = sid == "bugtrio"
  local boards = section.boards or {}
  if isBugTrio and bugLast ~= "" then
    boards = orderBugTrioBoards(boards, bugLast)
    ctx:note("Killing order: " .. bugLast .. " last")
  elseif section.why then
    ctx:note(section.why)
  end

  local bugKillMarks = nil
  if isBugTrio and bugLast ~= "" then
    bugKillMarks = { "skull", "cross", "square" }
  end

  local densest = boards[1]
  for _, b in ipairs(boards) do
    if #(b.slots or {}) > #((densest and densest.slots) or {}) then
      densest = b
    end
  end
  local densestSlots = (densest and densest.slots) or {}
  local labelCounts = {}
  for _, s in ipairs(densestSlots) do
    local lab = tostring(s.label or s.id or "")
    labelCounts[lab] = (labelCounts[lab] or 0) + 1
  end
  local seenLabelIdx = {}
  local columns = {}
  for i, s in ipairs(densestSlots) do
    local lab = tostring(s.label or s.id or "")
    local dup = (labelCounts[lab] or 0) > 1
    seenLabelIdx[lab] = (seenLabelIdx[lab] or 0) + 1
    local header = lab
    if dup and not string.match(header, "%d$") then
      header = header .. " " .. seenLabelIdx[lab]
    end
    table.insert(columns, {
      header = header,
      title = lab,
      matchIds = dup and { tostring(s.id or "") } or nil,
      matchLabel = dup and nil or lab,
      slotId = tostring(s.id or ""),
    })
  end

  if sid == "twins" then
    local filtered = {}
    for _, c in ipairs(columns) do
      local keep = true
      if string.match(string.lower(c.title or c.header or ""), "^healer%s*%d+") then
        keep = false
        for _, board in ipairs(boards) do
          local slot = nil
          if c.matchIds then
            for _, id in ipairs(c.matchIds) do
              for _, s in ipairs(board.slots or {}) do
                if tostring(s.id or "") == id then
                  slot = s
                  break
                end
              end
              if slot then
                break
              end
            end
          end
          if not slot and c.matchLabel then
            for _, s in ipairs(board.slots or {}) do
              if tostring(s.label or s.id or "") == c.matchLabel then
                slot = s
                break
              end
            end
          end
          if not slot then
            local m = string.match(c.slotId or "", "_h(%d+)$") or string.match(c.title or "", "(%d+)%s*$")
            if m then
              for _, s in ipairs(board.slots or {}) do
                local id = tostring(s.id or "")
                if id == "twin_l_h" .. m or id == "twin_r_h" .. m then
                  slot = s
                  break
                end
              end
            end
          end
          if slotFilled(slot) then
            keep = true
            break
          end
        end
      end
      if keep then
        table.insert(filtered, c)
      end
    end
    columns = filtered
  end

  local hasMark = bugKillMarks ~= nil
  if not hasMark then
    for _, b in ipairs(boards) do
      -- Twins: marks are on tank/lock slots, not the boss board.
      if sid == "twins" then
        for _, s in ipairs(b.slots or {}) do
          if slotMarkKey(s) then
            hasMark = true
            break
          end
        end
      elseif boardMarkKey(b) then
        hasMark = true
      else
        for _, s in ipairs(b.slots or {}) do
          if slotMarkKey(s) then
            hasMark = true
            break
          end
        end
      end
      if hasMark then
        break
      end
    end
  end

  -- Cap columns for readable width (Twins need all filled healer cols — website shows ≤10).
  local maxCols = 7
  if sid == "twins" then
    maxCols = 14
  elseif sid == "huhuran" or sid == "viscidus" then
    maxCols = 10
  end
  if #columns > maxCols then
    local trimmed = {}
    for i = 1, maxCols do
      trimmed[i] = columns[i]
    end
    columns = trimmed
  end

  -- Twins: no Mark-by-boss column — icons sit on Tank / Lock tank cells (website Mark col still aggregates slot marks).
  local showMarkCol = hasMark and sid ~= "twins"
  local showSlotMarks = sid == "twins"

  local widths = { (sid == "twins") and 100 or 130 }
  local headers = { "Mob" }
  if showMarkCol then
    table.insert(widths, 44)
    table.insert(headers, "Mark")
  end
  local used = widths[1] + (showMarkCol and 48 or 0)
  local avail = math.max(400, 860 - used)
  local colW = math.max(56, math.floor(avail / math.max(1, #columns)))
  if sid == "twins" then
    colW = math.max(52, math.min(colW, 78))
  end
  for _, c in ipairs(columns) do
    local w = colW
    if showSlotMarks then
      local lab = string.lower(tostring(c.header or c.title or ""))
      if lab == "tank" or string.find(lab, "lock", 1, true) or string.find(lab, "backup", 1, true) then
        w = math.max(colW, 96)
      end
    end
    table.insert(widths, w)
    local head = c.header
    -- Shorten twin healer headers so more fit.
    local hn = string.match(tostring(head or ""), "^Healer%s*(%d+)$")
    if hn then
      head = "H" .. hn
    end
    table.insert(headers, head)
  end
  ctx:addGrid(headers, widths, { header = true, height = 16, width = 900 })

  for rowIdx, board in ipairs(boards) do
    local byId, byLabel = {}, {}
    for _, s in ipairs(board.slots or {}) do
      if s.id then
        byId[tostring(s.id)] = s
      end
      byLabel[tostring(s.label or s.id or "")] = s
    end
    local marks = {}
    local markSeen = {}
    local function pushMark(m)
      if not m or markSeen[m] then
        return
      end
      markSeen[m] = true
      table.insert(marks, m)
    end
    if bugKillMarks and bugKillMarks[rowIdx] then
      pushMark(bugKillMarks[rowIdx])
    elseif sid == "twins" then
      -- Only tank/lock slot marks (never board/boss).
      for _, s in ipairs(board.slots or {}) do
        pushMark(slotMarkKey(s))
      end
      sortMarks(marks)
    else
      pushMark(boardMarkKey(board))
      for _, s in ipairs(board.slots or {}) do
        pushMark(slotMarkKey(s))
        local raw = string.lower(tostring(s.mark or ""))
        if raw ~= "" and MARK_ICON[raw] then
          pushMark(raw)
        end
      end
      sortMarks(marks)
    end
    local mob = tostring(board.mob or board.label or board.id or "?")
    if sid == "twins" then
      if string.find(string.lower(mob), "left", 1, true) then
        mob = "Left twin"
      elseif string.find(string.lower(mob), "right", 1, true) then
        mob = "Right twin"
      elseif string.find(string.lower(mob), "bug", 1, true) then
        mob = "Mutated Bugs"
      end
    end
    local boardKey = bugTrioBoardKey(board)
    if isBugTrio and bugLast ~= "" and boardKey == bugLast then
      mob = mob .. " |cff66cc66(last)|r"
    end
    local values = { mob }
    if showMarkCol then
      table.insert(values, marksText(marks))
    end
    for _, c in ipairs(columns) do
      local slot = nil
      if c.matchIds then
        for _, id in ipairs(c.matchIds) do
          if id and byId[id] then
            slot = byId[id]
            break
          end
        end
      elseif c.matchLabel then
        slot = byLabel[c.matchLabel]
      end
      if not slot and sid == "twins" then
        local m = string.match(c.slotId or "", "_h(%d+)$") or string.match(c.title or "", "(%d+)%s*$")
        if m then
          -- Prefer this board's side (left/right), then the other.
          local bid = string.lower(tostring(board.id or board.label or ""))
          if string.find(bid, "right", 1, true) or string.find(bid, "vek.lor", 1, true) or string.find(bid, "vek'lor", 1, true) then
            slot = byId["twin_r_h" .. m] or byId["twin_l_h" .. m]
          else
            slot = byId["twin_l_h" .. m] or byId["twin_r_h" .. m]
          end
        end
      end
      table.insert(values, slotText(slot, { showMark = showSlotMarks }))
    end
    ctx:addGrid(values, widths, { height = 17, width = 900 })
  end
  ctx:gap(8)
end

--------------------------------------------------------------------
-- Naxx specialty layouts (compact website structure)
--------------------------------------------------------------------

local function renderAnub(ctx, section)
  ctx:title(section.label or "Anub'Rekhan")
  ctx:note("SPIDER WING")
  local w = { 120, 40, 120 }
  ctx:addGrid({ "Mob", "Mark", "Tank" }, w, { header = true, height = 16 })
  local rows = {
    { "anub_mt", "Anub'Rekhan" },
    { "anub_cg1", "Crypt Guard" },
    { "anub_cg2", "Crypt Guard" },
  }
  for _, r in ipairs(rows) do
    local s = slotById(section, r[1])
    ctx:addGrid({ r[2], markIcon(slotMarkKey(s) or "-"), slotText(s) }, w, { height = 17 })
  end
  local note = slotById(section, "anub_sunder_note")
  ctx:gap(4)
  ctx:note((note and note.fixed) or "Warriors in G3 + G4 SUNDER ARMOR on Anub'Rekhan first!")
  ctx:gap(8)
end

local function renderFaerlina(ctx, section)
  ctx:title(section.label or "Grand Widow Faerlina")
  ctx:subhead("Faerlina Trash — Acolyte interrupts")
  local marks = { "skull", "cross", "square", "moon" }
  local markRow = { "Mark" }
  for _, m in ipairs(marks) do
    table.insert(markRow, markIcon(m))
  end
  local w = { 90, 100, 100, 100, 100 }
  ctx:addGrid(markRow, w, { header = true, height = 16 })
  local rows = {
    { "Counterspell", "faer_cs" },
    { "Pummel", "faer_pm" },
    { "Kick", "faer_kk" },
    { "Earthshock", "faer_es" },
  }
  for _, r in ipairs(rows) do
    local vals = { r[1] }
    for i = 1, 4 do
      table.insert(vals, slotText(slotById(section, r[2] .. i)))
    end
    ctx:addGrid(vals, w, { height = 17 })
  end
  local trashNote = slotById(section, "faer_trash_note")
  ctx:note((trashNote and trashNote.fixed) or "SHAMANS Earthshock (r1) them!!")
  ctx:gap(6)

  ctx:subhead("Faerlina")
  local bw = { 100, 40, 110, 110, 40 }
  ctx:addGrid({ "Mob", "Mark", "Tank", "Backup / MC", "#" }, bw, { header = true, height = 16 })
  local mt = slotById(section, "faer_mt")
  ctx:addGrid({
    "Faerlina",
    markIcon(slotMarkKey(mt) or "circle"),
    slotText(mt),
    "Backup",
    "",
  }, bw, { height = 17 })
  local wMarks = { "moon", "square", "triangle", "diamond" }
  for i = 1, 4 do
    local tank = slotById(section, "faer_w" .. i)
    local mc = slotById(section, "faer_w" .. i .. "_mc")
    local num = slotById(section, "faer_w" .. i .. "_n")
    ctx:addGrid({
      "Worshipper",
      markIcon(wMarks[i]),
      slotText(tank),
      slotText(mc),
      (num and num.fixed) or (i .. "."),
    }, bw, { height = 17 })
  end
  ctx:gap(8)
end

local function renderMaexxna(ctx, section)
  ctx:title(section.label or "Maexxna")
  ctx:subhead("Maexxna 2-Phase")
  local w = { 80, 100, 280, 140, 120 }
  ctx:addGrid({ "Mob", "Tank", "Tank Healers", "Cocoon Heal", "Cocoon DPS" }, w, { header = true, height = 16 })
  local th = {}
  for i = 1, 6 do
    table.insert(th, slotText(slotById(section, "maex_th" .. i)))
  end
  local coc = { slotText(slotById(section, "maex_coc1")), slotText(slotById(section, "maex_coc2")) }
  local cdps = { slotText(slotById(section, "maex_cdps1")), slotText(slotById(section, "maex_cdps2")) }
  ctx:addGrid({
    "Maexxna",
    slotText(slotById(section, "maex_mt")),
    table.concat(th, " "),
    table.concat(coc, " "),
    table.concat(cdps, " "),
  }, w, { height = 34 })
  ctx:gap(8)
end

local function renderNoth(ctx, section)
  ctx:title(section.label or "Noth the Plaguebringer")
  ctx:note("PLAGUE WING")
  local w = { 120, 40, 110 }
  ctx:addGrid({ "Mob", "Mark", "Tank" }, w, { header = true, height = 16 })
  local mobs = {
    { "noth_mt", "Noth" },
    { "noth_w1", "Plagued Warr. 1" },
    { "noth_w2", "Plagued Warr. 2" },
    { "noth_c1", "Plagued Cham. 1" },
    { "noth_c2", "Plagued Cham. 2" },
    { "noth_c3", "Plagued Cham. 3" },
  }
  for _, m in ipairs(mobs) do
    local s = slotById(section, m[1])
    ctx:addGrid({ m[2], markIcon(slotMarkKey(s) or "-"), slotText(s) }, w, { height = 17 })
  end
  ctx:gap(4)
  local tp = slotById(section, "noth_tp")
  local tpNote = slotById(section, "noth_tp_note")
  ctx:subhead("After teleport")
  ctx:addLine(slotText(tp) .. (tpNote and tpNote.fixed and ("  ·  " .. tostring(tpNote.fixed)) or ""), 0.85, 0.88, 0.92, 8)
  ctx:subhead("Disease")
  ctx:addLine(slotText(slotById(section, "noth_dis1")) .. "   " .. slotText(slotById(section, "noth_dis2")), 0.85, 0.88, 0.92, 8)
  ctx:subhead("Remove Curse of the Plaguebringer")
  local curses = {
    { "noth_c12", "Group 1+2" },
    { "noth_c34", "Group 3+4" },
    { "noth_c56", "Group 5+6" },
    { "noth_c78", "Group 7+8" },
    { "noth_call", "ALL Groups" },
    { "noth_cbak", "Backup" },
  }
  local cw = { 120, 120 }
  for _, c in ipairs(curses) do
    ctx:addGrid({ c[2], slotText(slotById(section, c[1])) }, cw, { height = 16, indent = 8 })
  end
  ctx:gap(8)
end

local function renderHeigan(ctx, section)
  ctx:title(section.label or "Heigan the Unclean")
  local w = { 80, 40, 100, 160, 160, 160 }
  ctx:addGrid({ "Mob", "Mark", "Tank", "Remove Fever", "Backup", "Backup" }, w, { header = true, height = 16 })
  ctx:addGrid({
    "Heigan",
    "-",
    slotText(slotById(section, "heig_mt")),
    slotText(slotById(section, "heig_d1a")) .. " " .. slotText(slotById(section, "heig_d1b")),
    slotText(slotById(section, "heig_d2a")) .. " " .. slotText(slotById(section, "heig_d2b")),
    slotText(slotById(section, "heig_d3a")) .. " " .. slotText(slotById(section, "heig_d3b")),
  }, w, { height = 17 })
  ctx:gap(8)
end

local function renderLoatheb(ctx, section)
  ctx:title(section.label or "Loatheb")
  local mt = slotById(section, "loath_mt")
  local healNote = slotById(section, "loath_heal_note")
  local sporeNote = slotById(section, "loath_spore_note")
  ctx:addLine("MT: " .. slotText(mt), 0.85, 0.88, 0.92, 0)
  ctx:note((healNote and healNote.fixed) or "Healing rotation is called by raidlead. Wait for your name to be called.")
  ctx:note((sporeNote and sporeNote.fixed) or "Spore groups: adjust in case of people without WBs")
  ctx:gap(4)
  for i = 1, 6 do
    local board = boardById(section, "spore_" .. i)
    if board then
      local bits = {}
      for _, s in ipairs(board.slots or {}) do
        table.insert(bits, slotText(s))
      end
      local mk = boardMarkKey(board)
      ctx:addLine(
        string.format("%s %s: %s", markIcon(mk or ""), tostring(board.label or ("Spore " .. i)), table.concat(bits, "  ")),
        0.85,
        0.88,
        0.92,
        0
      )
    end
  end
  ctx:gap(8)
end

local function renderPatchwerk(ctx, section)
  ctx:title(section.label or "Patchwerk")
  ctx:note("ABOMINATION WING")
  local roles = {
    { "mt", "MT" },
    { "s1", "Soaker 1" },
    { "s2", "Soaker 2" },
  }
  local w = { 80, 100, 100, 100, 100, 100 }
  ctx:addGrid({ "Role", "C1", "C2", "C3", "C4", "C5" }, w, { header = true, height = 16 })
  for _, role in ipairs(roles) do
    local vals = { role[2] }
    for c = 1, 5 do
      table.insert(vals, slotText(slotById(section, "pw_c" .. c .. "_" .. role[1])))
    end
    ctx:addGrid(vals, w, { height = 17 })
  end
  local note = slotById(section, "pw_chainheal")
  if note and note.fixed then
    ctx:note(tostring(note.fixed))
  end
  ctx:gap(8)
end

local function renderGrobbulus(ctx, section)
  ctx:title(section.label or "Grobbulus")
  local w = { 120, 40, 110, 120, 110, 120 }
  ctx:addGrid({ "Mob", "Mark", "Tank", "Remove Disease", "Backup", "Healers DPS" }, w, { header = true, height = 16 })
  ctx:addGrid({
    "Grobbulus",
    "-",
    slotText(slotById(section, "grob_mt")),
    slotText(slotById(section, "grob_h1")),
    slotText(slotById(section, "grob_h2")),
    "",
  }, w, { height = 17 })
  ctx:addGrid({
    "Fallout Slime(s)",
    markIcon("skull"),
    slotText(slotById(section, "grob_slime")),
    "",
    "",
    "",
  }, w, { height = 17 })
  ctx:gap(8)
end

local function renderGluth(ctx, section)
  ctx:title(section.label or "Gluth")
  local mt = slotById(section, "gluth_mt")
  ctx:addLine("Gluth  ·  Tank: " .. slotText(mt), 0.85, 0.88, 0.92, 0)
  if mt and mt.player_name then
    ctx:note("ALL OTHER HEALERS ONLY HEAL SINGLETARGET " .. string.upper(tostring(mt.player_name)) .. " !!")
  end
  ctx:subhead("Collect Zombie Chow")
  local w = { 80, 110, 110, 110 }
  ctx:addGrid({ "", "Left", "Middle", "Right" }, w, { header = true, height = 16 })
  ctx:addGrid({
    "Earthbind",
    slotText(slotById(section, "gluth_eb_l")),
    slotText(slotById(section, "gluth_eb_m")),
    slotText(slotById(section, "gluth_eb_r")),
  }, w, { height = 17 })
  ctx:addGrid({
    "Kite",
    slotText(slotById(section, "gluth_kite_l")),
    slotText(slotById(section, "gluth_kite_m")),
    slotText(slotById(section, "gluth_kite_r")),
  }, w, { height = 17 })
  ctx:addGrid({
    "Heal",
    slotText(slotById(section, "gluth_hl")),
    slotText(slotById(section, "gluth_hm")),
    slotText(slotById(section, "gluth_hr")),
  }, w, { height = 17 })
  ctx:gap(8)
end

local function renderThaddius(ctx, section)
  ctx:title(section.label or "Thaddius")
  local rw = slotById(section, "thad_rw")
  if rw and rw.fixed then
    ctx:note(tostring(rw.fixed))
  end
  local w = { 90, 40, 110, 120 }
  ctx:addGrid({ "Mob", "Mark", "Tank", "Throw taunt" }, w, { header = true, height = 16 })
  ctx:addGrid({
    "Thaddius",
    "-",
    slotText(slotById(section, "thad_mt")),
    "",
  }, w, { height = 17 })
  for _, bid in ipairs({ "thad_stalag", "thad_feugen" }) do
    local board = boardById(section, bid)
    local slots = (board and board.slots) or {}
    ctx:addGrid({
      tostring(board and board.label or bid),
      markIcon(boardMarkKey(board) or slotMarkKey(slots[1]) or "-"),
      slotText(slots[2] or slots[1]),
      slotText(slots[3] or slots[2]),
    }, w, { height = 17 })
  end
  ctx:gap(4)
  ctx:subhead("Phase 1 positioning")
  for _, bid in ipairs({ "thad_left", "thad_right" }) do
    local board = boardById(section, bid)
    if board then
      local bits = {}
      for _, s in ipairs(board.slots or {}) do
        table.insert(bits, slotText(s))
      end
      ctx:addLine(
        string.format("%s (%s): %s", tostring(board.label or bid), tostring(board.why or ""), table.concat(bits, "  ")),
        0.85,
        0.88,
        0.92,
        8
      )
    end
  end
  ctx:gap(8)
end

local function renderRazuvious(ctx, section)
  ctx:title(section.label or "Instructor Razuvious")
  local lip = boardById(section, "raz_lip")
  if lip then
    ctx:subhead("LIP AoE Taunt")
    local bits = {}
    for _, s in ipairs(lip.slots or {}) do
      table.insert(bits, slotText(s))
    end
    ctx:addLine(table.concat(bits, "   "), 0.85, 0.88, 0.92, 8)
  end
  ctx:subhead("Understudies")
  local w = { 40, 100, 100, 100 }
  ctx:addGrid({ "Mark", "Tank", "MC", "Backup MC" }, w, { header = true, height = 16 })
  for i = 1, 4 do
    local mark = slotById(section, "raz_u" .. i .. "_mark")
    local tank = slotById(section, "raz_u" .. i .. "_tank")
    local mc = slotById(section, "raz_u" .. i .. "_mc")
    local bak = slotById(section, "raz_u" .. i .. "_bak")
    ctx:addGrid({
      markIcon(slotMarkKey(mark) or (mark and mark.fixed) or MARK_ORDER[i] or "-"),
      slotText(tank),
      slotText(mc),
      slotText(bak),
    }, w, { height = 17 })
  end
  ctx:gap(8)
end

local function renderGothik(ctx, section)
  ctx:title(section.label or "Gothik the Harvester")
  local boss = boardById(section, "goth_boss")
  if boss then
    local slots = boss.slots or {}
    ctx:addLine("Living: " .. slotText(slots[1]) .. "   Undead: " .. slotText(slots[2]), 0.85, 0.88, 0.92, 0)
  end
  local function tankSide(bid, head)
    local board = boardById(section, bid)
    if not board then
      return
    end
    ctx:subhead(head or board.label)
    local bits = {}
    for _, s in ipairs(board.slots or {}) do
      table.insert(bits, markIcon(slotMarkKey(s) or "") .. " " .. slotText(s))
    end
    ctx:addLine(table.concat(bits, "   "), 0.85, 0.88, 0.92, 8)
  end
  tankSide("goth_living_tanks", "Living side tanks")
  tankSide("goth_undead_tanks", "Undead side tanks")
  tankSide("goth_mid_tanks", "Mid tanks")
  for _, bid in ipairs({ "goth_undead", "goth_living", "goth_nova" }) do
    local board = boardById(section, bid)
    if board then
      ctx:subhead(board.label or bid)
      local bits = {}
      for _, s in ipairs(board.slots or {}) do
        if slotFilled(s) then
          table.insert(bits, slotText(s))
        end
      end
      if #bits > 0 then
        ctx:addLine(table.concat(bits, "  "), 0.85, 0.88, 0.92, 8)
      else
        for _, s in ipairs(board.slots or {}) do
          ctx:addLine(tostring(s.label or "?") .. ": " .. slotText(s), 0.85, 0.88, 0.92, 12)
        end
      end
    end
  end
  ctx:gap(8)
end

local function renderBoardGroups(ctx, section, opts)
  opts = opts or {}
  ctx:title(section.label or sectionIdOf(section))
  if section.why then
    ctx:note(section.why)
  end
  if opts.blurb then
    ctx:note(opts.blurb)
  end
  for _, board in ipairs(section.boards or {}) do
    local mk = boardMarkKey(board)
    local head = tostring(board.label or board.id or "Board")
    if mk then
      head = markIcon(mk) .. " " .. head
    end
    ctx:subhead(head)
    if board.why and tostring(board.why) ~= "" then
      ctx:note(board.why)
    end
    local bits = {}
    for _, s in ipairs(board.slots or {}) do
      local lab = tostring(s.label or "")
      if lab ~= "" and not opts.hideLabels then
        table.insert(bits, lab .. ": " .. slotText(s))
      else
        table.insert(bits, slotText(s))
      end
    end
    -- chunk lines
    local line = {}
    for i, bit in ipairs(bits) do
      table.insert(line, bit)
      if #line >= (opts.perLine or 3) or i == #bits then
        ctx:addLine(table.concat(line, "   "), 0.85, 0.88, 0.92, 8)
        line = {}
      end
    end
  end
  ctx:gap(8)
end

local function renderPlain(ctx, section, heading, solo)
  local secLabel = tostring(section.label or "")
  local showTitle = true
  if solo and heading and heading ~= "" and secLabel == tostring(heading) then
    ctx:title(heading)
    showTitle = false
  elseif heading and heading ~= "" and secLabel == tostring(heading) then
    showTitle = false
  end
  if showTitle and secLabel ~= "" then
    ctx:title(secLabel)
  end
  for _, board in ipairs(section.boards or {}) do
    local blabel = tostring(board.label or "")
    if blabel ~= "" then
      ctx:subhead(blabel)
    end
    for _, slot in ipairs(board.slots or {}) do
      ctx:addLine(string.format("%s: %s", tostring(slot.label or "?"), slotText(slot)), 0.82, 0.86, 0.92, 12)
    end
  end
  ctx:gap(4)
end

--------------------------------------------------------------------
-- C'Thun arena — uses Textures/cthun_map.tga and sheet slot coords
--------------------------------------------------------------------

-- Coords from aq40_schema — percent of C'Thun map image.
local MARK_ORDER = { "skull", "cross", "square", "moon", "triangle", "diamond", "circle" }
local GROUP_ROLES = { "melee1", "melee2", "healer", "caster" }

-- Distances from center (50, 50) for each role
local ROLE_DISTANCES = {
    melee1 = 20.24,
    melee2 = 16.82,
    healer = 32.00,
    caster = 43.46,
}

-- Direction angles (in degrees) for each raid mark spoke
local MARK_ANGLES = {
    skull    = -110.5,
    cross    = -69.5,
    square   = -20.5,
    moon     = 20.5,
    triangle = 69.5,
    diamond  = 110.5,
    circle   = 159.5,
}

GROUP_POSITIONS = {}

for _, mark in ipairs(MARK_ORDER) do
    GROUP_POSITIONS[mark] = {}
    local rad = math.rad(MARK_ANGLES[mark])
    local cosA, sinA = math.cos(rad), math.sin(rad)

    for _, role in ipairs(GROUP_ROLES) do
        local dist = ROLE_DISTANCES[role]
        
        -- Compute (x, y) relative to center (50, 50)
        GROUP_POSITIONS[mark][role] = {
            x = math.floor((50 + dist * cosA) * 100 + 0.5) / 100,
            y = math.floor((50 + dist * sinA) * 100 + 0.5) / 100
        }
    end
end

-- Distances from center (50, 50) for each slot tier
local ROLE_DISTANCES = {
    m1     = 20.24,
    m2     = 16.82,
    heal   = 32.00,
    caster = 43.46,
}

-- Mappings for mark names and polar angles in degrees
local WEDGE_CONFIG = {
    w1 = { mark = "skull",    angle = -110.5 },
    w2 = { mark = "cross",   angle = -69.5  },
    w3 = { mark = "square",  angle = -20.5  },
    w4 = { mark = "moon",    angle = 20.5   },
    w5 = { mark = "triangle",angle = 69.5   },
    w6 = { mark = "diamond", angle = 110.5  },
    w7 = { mark = "circle",  angle = 159.5  },
    w8 = { mark = "star",    angle = -159.5 },
}

-- Map slot suffix to internal position metadata
local ROLE_TYPES = {
    m1     = "melee",
    m2     = "melee",
    heal   = "healer",
    caster = "caster",
}

local CTHUN_SLOT_POS = {}

-- 1. Programmatically generate C'Thun inner wedge positions
for wKey, config in pairs(WEDGE_CONFIG) do
    local rad = math.rad(config.angle)
    local cosA, sinA = math.cos(rad), math.sin(rad)

    for rKey, dist in pairs(ROLE_DISTANCES) do
        local slotId = string.format("cthun_%s_%s", wKey, rKey)
        local x = math.floor((50 + dist * cosA) * 100 + 0.5) / 100
        local y = math.floor((50 + dist * sinA) * 100 + 0.5) / 100

        CTHUN_SLOT_POS[slotId] = { x, y, config.mark, ROLE_TYPES[rKey] }
    end
end

-- 2. Add fixed outer melee positions
local OUTER_MELEE = {
    ["cthun_out_m1"] = { 50.00, 1.50 },
    ["cthun_out_m2"] = { 84.29, 15.71 },
    ["cthun_out_m3"] = { 98.50, 50.00 },
    ["cthun_out_m4"] = { 84.29, 84.29 },
    ["cthun_out_m5"] = { 50.00, 98.50 },
    ["cthun_out_m6"] = { 15.71, 84.29 },
    ["cthun_out_m7"] = { 1.50, 50.00 },
    ["cthun_out_m8"] = { 15.71, 15.71 },
}

for slotId, coords in pairs(OUTER_MELEE) do
    CTHUN_SLOT_POS[slotId] = { coords[1], coords[2], "", "outer_melee" }
end

local function cthunShortName(name)
  local n = tostring(name or "")
  if #n > 9 then
    return string.sub(n, 1, 8) .. "…"
  end
  return n
end

local function renderCthun(ctx, section)
  ctx:title(section.label or "C'Thun")
  if section.why then
    ctx:note(section.why)
  end
  ctx:gap(2)

  local ui = ctx.ui
  if not ui or not ui.EnsureCthunArena then
    ctx:addLine("C'Thun arena UI missing — update addon.", 0.85, 0.55, 0.45, 0)
    return
  end

  -- Same aspect as the map image (1024×753).
  local MAP_W = 760
  local MAP_H = math.floor(MAP_W * 753 / 1024)
  local arena = ui:EnsureCthunArena()
  arena:ClearAllPoints()
  local scrollW = (ui.raidScrollChild and ui.raidScrollChild:GetWidth()) or 1000
  local leftPad = math.max(8, math.floor((scrollW - MAP_W) / 2))
  arena:SetPoint("TOPLEFT", ui.raidScrollChild, "TOPLEFT", leftPad, ctx.y)
  arena:SetSize(MAP_W, MAP_H)
  if arena.bg then
    arena.bg:SetTexture("Interface\\AddOns\\ClassicGmbHQuartermaster\\Textures\\cthun_map")
    arena.bg:SetTexCoord(0, 1, 135 / 1024, (135 + 753) / 1024)
    arena.bg:Show()
  end
  if arena.glow then
    arena.glow:Hide()
  end
  if arena.boss then
    arena.boss:Hide()
  end
  arena:Show()

  -- Index sheet slots by id for fill.
  local byId = {}
  for _, board in ipairs(section.boards or {}) do
    for _, slot in ipairs(board.slots or {}) do
      if slot.id then
        byId[tostring(slot.id)] = slot
      end
    end
  end

  local chipIdx = 0
  -- Walk fixed map positions so empty boxes still show.
  local order = {}
  for sid in pairs(CTHUN_SLOT_POS) do
    table.insert(order, sid)
  end
  table.sort(order)

  for _, sid in ipairs(order) do
    local pos = CTHUN_SLOT_POS[sid]
    local slot = byId[sid]
    -- Prefer live sheet x/y when present (same map).
    local xPct = (slot and tonumber(slot.x)) or pos[1]
    local yPct = (slot and tonumber(slot.y)) or pos[2]

    chipIdx = chipIdx + 1
    local chip = ui:EnsureCthunChip(chipIdx)
    local px = (xPct / 100) * MAP_W
    local py = (yPct / 100) * MAP_H
    chip:ClearAllPoints()
    chip:SetPoint("CENTER", arena, "TOPLEFT", px, -py)

    local name = slot and slot.player_name and tostring(slot.player_name) or ""
    local ring = tostring(pos[4] or "")
    local mk = tostring(pos[3] or "")
    if slot and slot.mark and tostring(slot.mark) ~= "" then
      mk = string.lower(tostring(slot.mark))
    end
    -- One raid mark per melee stack (on m1), matching the map template.
    local isStackMark = ring == "melee" and string.find(sid, "_m1", 1, true) ~= nil
    local markBit = ""
    if isStackMark and mk ~= "" and MARK_ICON[mk] then
      markBit = markIcon(mk)
    end

    if name ~= "" then
      chip.text:SetText(markBit .. coloredText(playerColorHex(slot), cthunShortName(name)))
      chip.text:SetTextColor(1, 1, 1)
      if chip.SetBackdropColor then
        chip:SetBackdropColor(0.08, 0.09, 0.12, 0.55)
        chip:SetBackdropBorderColor(0.40, 0.44, 0.52, 0.55)
      end
    elseif markBit ~= "" then
      chip.text:SetText(markBit)
      chip.text:SetTextColor(1, 1, 1)
      if chip.SetBackdropColor then
        chip:SetBackdropColor(0.10, 0.11, 0.14, 0.40)
        chip:SetBackdropBorderColor(0.30, 0.32, 0.38, 0.45)
      end
    else
      chip.text:SetText("")
      if chip.SetBackdropColor then
        chip:SetBackdropColor(0.12, 0.13, 0.16, 0.35)
        chip:SetBackdropBorderColor(0.30, 0.32, 0.38, 0.45)
      end
    end
    chip:SetSize(isStackMark and 86 or 76, 15)
    chip:Show()
  end

  for i = chipIdx + 1, #(arena.chips or {}) do
    arena.chips[i]:Hide()
  end

  ctx.y = ctx.y - MAP_H - 10
  ctx:gap(4)
end

--------------------------------------------------------------------
-- Dispatch
--------------------------------------------------------------------

local SPECIAL = {
  buffs = renderBuffs,
  general_tanks = renderTanking,
  cthun = renderCthun,
  anub = renderAnub,
  faerlina = renderFaerlina,
  maexxna = renderMaexxna,
  noth = renderNoth,
  heigan = renderHeigan,
  loatheb = renderLoatheb,
  patchwerk = renderPatchwerk,
  grobbulus = renderGrobbulus,
  gluth = renderGluth,
  thaddius = renderThaddius,
  razuvious = renderRazuvious,
  gothik = renderGothik,
}

local ASSIGN_TABLE_IDS = {
  skeram = true,
  bugtrio = true,
  sartura = true,
  fankriss = true,
  viscidus = true,
  huhuran = true,
  twins = true,
}

local function renderSection(ctx, section, raid, heading, solo)
  local sid = sectionIdOf(section)
  local mapLayout = string.lower(tostring(section.map_layout or ""))

  if SPECIAL[sid] then
    SPECIAL[sid](ctx, section, raid)
    return
  end
  if ASSIGN_TABLE_IDS[sid] or section.kind == "table" then
    -- Don't use assign-table for buffs/tanks (handled above).
    if sid ~= "buffs" and sid ~= "general_tanks" then
      renderAssignTable(ctx, section, raid)
      return
    end
  end
  if mapLayout == "cthun" or sid == "cthun" then
    renderCthun(ctx, section)
    return
  end
  if mapLayout == "horsemen" or sid == "horsemen" then
    renderBoardGroups(ctx, section, { blurb = "Corner tanks + heal stacks (arena map on website)", perLine = 2 })
    return
  end
  if mapLayout == "sapphiron" or sid == "sapphiron" then
    renderBoardGroups(ctx, section, { blurb = "Icebolt / amp / groups (arena map on website)", perLine = 4, hideLabels = true })
    return
  end
  if mapLayout == "kelthuzad" or sid == "kelthuzad" then
    renderBoardGroups(ctx, section, { blurb = "KT stacks / shackles / frost blast (arena map on website)", perLine = 3 })
    return
  end
  if section.kind == "split" then
    renderBoardGroups(ctx, section, { perLine = 3 })
    return
  end
  renderPlain(ctx, section, heading, solo)
end

GmbHLootTrackerRaidSheet = {}
GmbHLootTrackerRaidSheet.SlotMarkKey = slotMarkKey

-- HUD must use the same kill-order + skull/cross/square as the sheet table.
-- markOverride: Bug Trio kill-order remaps the whole row. Otherwise HUD uses
-- per-slot marks (Twins tank vs lock, Naxx crypt guards, KT tanks, …).
function GmbHLootTrackerRaidSheet.HudBoards(section, raid)
  if type(section) ~= "table" then
    return {}
  end
  local sid = sectionIdOf(section)
  local boards = section.boards or {}
  local bugLast = string.lower(tostring((raid and raid.bug_trio_last) or ""))
  local marksByIdx = nil
  if sid == "bugtrio" and bugLast ~= "" then
    boards = orderBugTrioBoards(boards, bugLast)
    marksByIdx = { "skull", "cross", "square" }
  end
  local out = {}
  for i, board in ipairs(boards) do
    local mark = nil
    local markOverride = false
    if marksByIdx and marksByIdx[i] then
      mark = marksByIdx[i]
      markOverride = true
    else
      mark = boardMarkKey(board)
    end
    table.insert(out, { board = board, mark = mark, markOverride = markOverride })
  end
  return out
end

-- Pair tank-healer seats to the same mark/tank as the General Tanking sheet grid.
function GmbHLootTrackerRaidSheet.TankHealerTarget(section, slot)
  if type(section) ~= "table" or type(slot) ~= "table" then
    return nil, nil
  end
  local tanksBoard, healBoard
  for _, board in ipairs(section.boards or {}) do
    local id = string.lower(tostring(board.id or ""))
    local label = string.lower(tostring(board.label or ""))
    if id == "tank_healers" or id == "aq_theal" or string.find(label, "tank heal", 1, true)
      or string.find(label, "dedicated tank healer", 1, true)
    then
      healBoard = board
    elseif (string.find(id, "tank", 1, true) or string.find(label, "tank", 1, true))
      and not string.find(id, "heal", 1, true)
      and not string.find(label, "heal", 1, true)
    then
      tanksBoard = board
    end
  end
  if not healBoard or not tanksBoard then
    return nil, nil
  end
  local healIdx = nil
  for i, s in ipairs(healBoard.slots or {}) do
    if s == slot or tostring(s.id or "") == tostring(slot.id or "") then
      healIdx = i
      break
    end
  end
  if not healIdx then
    return nil, nil
  end
  local byMark = {}
  for _, s in ipairs(tanksBoard.slots or {}) do
    local m = slotMarkKey(s) or "none"
    byMark[m] = byMark[m] or { tank = nil, backup = nil }
    local lab = string.lower(tostring(s.label or ""))
    local sid = string.lower(tostring(s.id or ""))
    if string.find(lab, "backup", 1, true) or lab == "bt" or string.find(sid, "_bt_", 1, true) then
      byMark[m].backup = s
    else
      byMark[m].tank = s
    end
  end
  local marks = {}
  for _, m in ipairs(MARK_ORDER) do
    if byMark[m] then
      table.insert(marks, m)
    end
  end
  local m = marks[healIdx]
  if not m then
    return nil, nil
  end
  local tankSlot = byMark[m] and byMark[m].tank
  local tankName = tankSlot and tankSlot.player_name and tostring(tankSlot.player_name) or nil
  return m, tankName
end

-- Twin Emperors: Left / Right / Bugs from board id/label.
function GmbHLootTrackerRaidSheet.TwinsSideLabel(board)
  if type(board) ~= "table" then
    return nil
  end
  local id = string.lower(tostring(board.id or ""))
  local lab = string.lower(tostring(board.mob or board.label or ""))
  -- Require twin_ board ids so "Skeram Left" never matches.
  if string.find(id, "twin_", 1, true) or id == "twin_left" or id == "twin_right" or id == "twin_bugs" then
    if string.find(id, "left", 1, true) or string.find(lab, "left", 1, true)
      or string.find(lab, "vek.nilash", 1, true) or string.find(lab, "vek'nilash", 1, true)
    then
      return "Left"
    end
    if string.find(id, "right", 1, true) or string.find(lab, "right", 1, true)
      or string.find(lab, "vek.lor", 1, true) or string.find(lab, "vek'lor", 1, true)
    then
      return "Right"
    end
    if string.find(id, "bug", 1, true) or string.find(lab, "bug", 1, true) then
      return "Bugs"
    end
  end
  return nil
end

-- Warlock lock-tank name (+ mark) on the same twin side board.
function GmbHLootTrackerRaidSheet.TwinsLockTank(board)
  if type(board) ~= "table" then
    return nil, nil
  end
  for _, s in ipairs(board.slots or {}) do
    local lab = string.lower(tostring(s.label or ""))
    local sid = string.lower(tostring(s.id or ""))
    if string.find(lab, "lock", 1, true) or string.find(sid, "_lock", 1, true) then
      local name = s.player_name and tostring(s.player_name) or nil
      return name, slotMarkKey(s) or s.mark
    end
  end
  return nil, nil
end

function GmbHLootTrackerRaidSheet.Render(ui, raid, sections, heading)
  local ctx = newCtx(ui)
  sections = sections or {}
  if #sections == 0 then
    ctx:addLine("No assignments in this tab.", 0.85, 0.75, 0.55, 0)
    ctx:finish()
    return
  end
  local solo = #sections == 1
  for _, section in ipairs(sections) do
    renderSection(ctx, section, raid, heading, solo)
    -- Boss tabs are one section each — offer HUD test under the assignments.
    if solo then
      ctx:addHudTestButton(section.label or heading)
    end
  end
  ctx:finish()
end
