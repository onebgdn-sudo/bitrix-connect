local M = {}

local function encode_value(value)
  local kind = type(value)
  if kind == "nil" then
    return "null"
  elseif kind == "number" then
    return tostring(value)
  elseif kind == "boolean" then
    return value and "true" or "false"
  elseif kind == "string" then
    return string.format("%q", value)
  elseif kind == "table" then
    local is_array = true
    local max_index = 0
    for key, _ in pairs(value) do
      if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
        is_array = false
        break
      end
      if key > max_index then
        max_index = key
      end
    end

    if is_array then
      local parts = {}
      for i = 1, max_index do
        parts[#parts + 1] = encode_value(value[i])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end

    local parts = {}
    local keys = {}
    for key, _ in pairs(value) do
      keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)
    for _, key in ipairs(keys) do
      parts[#parts + 1] = encode_value(tostring(key)) .. ":" .. encode_value(value[key])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end

  error("Unsupported JSON type: " .. kind)
end

local function decode_error(message, pos)
  error(message .. " at position " .. tostring(pos))
end

local function skip_ws(text, pos)
  while true do
    local char = text:sub(pos, pos)
    if char == "" then
      return pos
    end
    if char == " " or char == "\t" or char == "\r" or char == "\n" then
      pos = pos + 1
    else
      return pos
    end
  end
end

local parse_value

local function parse_string(text, pos)
  pos = pos + 1
  local out = {}
  while true do
    local char = text:sub(pos, pos)
    if char == "" then
      decode_error("Unterminated string", pos)
    end
    if char == '"' then
      return table.concat(out), pos + 1
    end
    if char == "\\" then
      local esc = text:sub(pos + 1, pos + 1)
      if esc == '"' or esc == "\\" or esc == "/" then
        out[#out + 1] = esc
        pos = pos + 2
      elseif esc == "b" then
        out[#out + 1] = "\b"
        pos = pos + 2
      elseif esc == "f" then
        out[#out + 1] = "\f"
        pos = pos + 2
      elseif esc == "n" then
        out[#out + 1] = "\n"
        pos = pos + 2
      elseif esc == "r" then
        out[#out + 1] = "\r"
        pos = pos + 2
      elseif esc == "t" then
        out[#out + 1] = "\t"
        pos = pos + 2
      elseif esc == "u" then
        local hex = text:sub(pos + 2, pos + 5)
        if #hex ~= 4 or not hex:match("^%x%x%x%x$") then
          decode_error("Invalid unicode escape", pos)
        end
        out[#out + 1] = utf8.char(tonumber(hex, 16))
        pos = pos + 6
      else
        decode_error("Invalid escape sequence", pos)
      end
    else
      out[#out + 1] = char
      pos = pos + 1
    end
  end
end

local function parse_number(text, pos)
  local start_pos = pos
  local char = text:sub(pos, pos)
  if char == "-" then
    pos = pos + 1
  end

  while text:sub(pos, pos):match("%d") do
    pos = pos + 1
  end

  if text:sub(pos, pos) == "." then
    pos = pos + 1
    while text:sub(pos, pos):match("%d") do
      pos = pos + 1
    end
  end

  local exp = text:sub(pos, pos)
  if exp == "e" or exp == "E" then
    pos = pos + 1
    local sign = text:sub(pos, pos)
    if sign == "+" or sign == "-" then
      pos = pos + 1
    end
    while text:sub(pos, pos):match("%d") do
      pos = pos + 1
    end
  end

  local number = tonumber(text:sub(start_pos, pos - 1))
  if number == nil then
    decode_error("Invalid number", start_pos)
  end
  return number, pos
end

local function parse_array(text, pos)
  pos = pos + 1
  local result = {}
  pos = skip_ws(text, pos)
  if text:sub(pos, pos) == "]" then
    return result, pos + 1
  end

  while true do
    local value
    value, pos = parse_value(text, pos)
    result[#result + 1] = value
    pos = skip_ws(text, pos)
    local char = text:sub(pos, pos)
    if char == "]" then
      return result, pos + 1
    end
    if char ~= "," then
      decode_error("Expected ',' or ']'", pos)
    end
    pos = skip_ws(text, pos + 1)
  end
end

local function parse_object(text, pos)
  pos = pos + 1
  local result = {}
  pos = skip_ws(text, pos)
  if text:sub(pos, pos) == "}" then
    return result, pos + 1
  end

  while true do
    if text:sub(pos, pos) ~= '"' then
      decode_error("Expected object key", pos)
    end
    local key
    key, pos = parse_string(text, pos)
    pos = skip_ws(text, pos)
    if text:sub(pos, pos) ~= ":" then
      decode_error("Expected ':' after object key", pos)
    end
    pos = skip_ws(text, pos + 1)
    local value
    value, pos = parse_value(text, pos)
    result[key] = value
    pos = skip_ws(text, pos)
    local char = text:sub(pos, pos)
    if char == "}" then
      return result, pos + 1
    end
    if char ~= "," then
      decode_error("Expected ',' or '}'", pos)
    end
    pos = skip_ws(text, pos + 1)
  end
end

parse_value = function(text, pos)
  pos = skip_ws(text, pos)
  local char = text:sub(pos, pos)
  if char == '"' then
    return parse_string(text, pos)
  elseif char == "{" then
    return parse_object(text, pos)
  elseif char == "[" then
    return parse_array(text, pos)
  elseif char == "-" or char:match("%d") then
    return parse_number(text, pos)
  elseif text:sub(pos, pos + 3) == "true" then
    return true, pos + 4
  elseif text:sub(pos, pos + 4) == "false" then
    return false, pos + 5
  elseif text:sub(pos, pos + 3) == "null" then
    return nil, pos + 4
  end
  decode_error("Unexpected token", pos)
end

function M.encode(value)
  return encode_value(value)
end

function M.decode(text)
  local value, pos = parse_value(text, 1)
  pos = skip_ws(text, pos)
  if pos <= #text then
    decode_error("Trailing characters", pos)
  end
  return value
end

return M
