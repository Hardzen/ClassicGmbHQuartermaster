--[[ AceComm facade for peer share (Gargul-style).

AceComm-3.0 + ChatThrottleLib:
  - auto-splits large payloads
  - paces SendAddonMessage (BULK) so Classic does not hang

LibDeflate (Gargul pattern):
  - CompressDeflate + EncodeForWoWAddonChannel before send
  - reverse on receive so AceComm only hauls a small wire payload
]]

local AceComm = LibStub and LibStub("AceComm-3.0", true)
if not AceComm then
  error("ClassicGmbHQuartermaster: AceComm-3.0 failed to load")
end

local LibDeflate = LibStub and LibStub("LibDeflate", true)

GmbHLootTrackerComm = GmbHLootTrackerComm or {}
local Comm = GmbHLootTrackerComm
AceComm:Embed(Comm)

function Comm.Ready()
  return Comm.SendCommMessage ~= nil
end

function Comm.CanCompress()
  return LibDeflate ~= nil
    and type(LibDeflate.CompressDeflate) == "function"
    and type(LibDeflate.EncodeForWoWAddonChannel) == "function"
end

--- Compress plaintext for AceComm (returns nil on failure).
function Comm.Compress(plain)
  if type(plain) ~= "string" or plain == "" or not Comm.CanCompress() then
    return nil
  end
  local ok, encoded = pcall(function()
    local compressed = LibDeflate:CompressDeflate(plain, { level = 5 })
    if not compressed then
      return nil
    end
    return LibDeflate:EncodeForWoWAddonChannel(compressed)
  end)
  if ok and type(encoded) == "string" and encoded ~= "" then
    return encoded
  end
  return nil
end

--- Decompress AceComm payload (returns nil on failure).
function Comm.Decompress(encoded)
  if type(encoded) ~= "string" or encoded == "" or not Comm.CanCompress() then
    return nil
  end
  local ok, plain = pcall(function()
    local compressed = LibDeflate:DecodeForWoWAddonChannel(encoded)
    if not compressed then
      return nil
    end
    return LibDeflate:DecompressDeflate(compressed)
  end)
  if ok and type(plain) == "string" then
    return plain
  end
  return nil
end
