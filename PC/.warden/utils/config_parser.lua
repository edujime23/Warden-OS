-- config_parser.lua
-- Supports inline comments, math expressions, and size suffixes (k/m/g/t).

local M = {}

local function strip_inline_comment(s)
  return (s:gsub("%s*[#;].*$", "")) -- remove trailing comment
end

local function safe_eval(expr)
  -- allow digits, whitespace, parentheses, and basic math ops
  if not expr:match("^[%s%(%)]*[%d%.%s%+%-%*/%%%^%(%)]*[%s%(%)]*$") then return nil end
  local chunk, err = load("return " .. expr, "=(cfg)", "t", {}) -- empty env
  if not chunk then return nil end
  local ok, val = pcall(chunk)
  if ok and type(val) == "number" then return val end
  return nil
end

local function parse_size(token)
  local s = token:lower():gsub("_",""):gsub("%s+","")
  local num, unit = s:match("^(%d+%.?%d*)([kmgt]i?b?)$")
  if not num then return nil end
  local n = tonumber(num)
  local mult = 1
  if unit:sub(1,1) == "k" then mult = 1024
  elseif unit:sub(1,1) == "m" then mult = 1024^2
  elseif unit:sub(1,1) == "g" then mult = 1024^3
  elseif unit:sub(1,1) == "t" then mult = 1024^4
  end
  return math.floor(n * mult + 0.5)
end

local function autoConvert(value)
  value = strip_inline_comment(value):match("^%s*(.-)%s*$")
  if value == "true"  then return true end
  if value == "false" then return false end

  -- quoted string
  if value:sub(1,1) == '"' and value:sub(-1) == '"' then
    return value:sub(2, -2)
  end

  -- size with suffix (32kb, 4m, 1g, 1gib)
  local sized = parse_size(value); if sized then return sized end

  -- plain number
  local num = tonumber(value); if num ~= nil then return num end

  -- math expressions (2^15, (4*1024)^2, etc.)
  local eval = safe_eval(value); if eval ~= nil then return eval end

  return value
end

function M.parse(path)
  if not fs.exists(path) then
    return nil, "File not found: " .. path
  end

  local f, err = fs.open(path, "r")
  if not f then return nil, "Could not open: " .. tostring(err) end

  local settings = {}
  local first = true
  while true do
    local line = f.readLine()
    if line == nil then break end

    -- Strip potential BOM on first line and trailing CRs
    if first then
      first = false
      -- remove UTF-8 BOM if present
      if line:sub(1,3) == string.char(0xEF,0xBB,0xBF) then
        line = line:sub(4)
      end
    end
    line = line:gsub("\r$", "")

    -- Trim and skip empties/comments
    line = line:match("^%s*(.-)%s*$")
    if line ~= "" and not line:match("^[#;]") then
      local eq = line:find("=")
      if eq then
        local key = line:sub(1, eq-1):match("^%s*(.-)%s*$")
        local val = line:sub(eq+1)
        if key ~= "" then
          settings[key] = autoConvert(val)
        end
      end
    end
  end

  f.close()
  return settings
end

return M