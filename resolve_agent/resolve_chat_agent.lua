-- Resolve Chat Agent
-- Floating UIManager-based chat inside DaVinci Resolve Studio.

local title = "Resolve Chat Agent"

local function script_dir()
  local source = debug.getinfo(1, "S").source
  local dir = source:match("^@(.+[\\/])")
  return dir or ""
end

local ROOT = script_dir()
local BACKEND = ROOT .. "resolve_agent_backend.py"

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", [['"'"'"'"'"'"'"'"']]) .. "'"
end

local function trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function html_escape(text)
  return (tostring(text or ""):gsub("&", "&amp;")
    :gsub("<", "&lt;")
    :gsub(">", "&gt;")
    :gsub('"', "&quot;"))
end

local function json_escape(text)
  return (text:gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\b", "\\b")
    :gsub("\f", "\\f")
    :gsub("\n", "\\n")
    :gsub("\r", "\\r")
    :gsub("\t", "\\t"))
end

local function json_encode(value)
  local kind = type(value)
  if kind == "nil" then
    return "null"
  elseif kind == "number" or kind == "boolean" then
    return tostring(value)
  elseif kind == "string" then
    return '"' .. json_escape(value) .. '"'
  elseif kind == "table" then
    local is_array = true
    local max_index = 0
    for key, _ in pairs(value) do
      if type(key) ~= "number" then
        is_array = false
        break
      end
      if key > max_index then
        max_index = key
      end
    end

    local parts = {}
    if is_array then
      for i = 1, max_index do
        parts[#parts + 1] = json_encode(value[i])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end

    local keys = {}
    for key, _ in pairs(value) do
      keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(keys) do
      parts[#parts + 1] = json_encode(tostring(key)) .. ":" .. json_encode(value[key])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end

  error("Unsupported JSON type: " .. kind)
end

local function get_resolve()
  if Resolve then
    local ok, result = pcall(Resolve)
    if ok and result then
      return result
    end
  end
  if bmd and bmd.scriptapp then
    local ok, result = pcall(bmd.scriptapp, "Resolve")
    if ok and result then
      return result
    end
  end
  return nil
end

local resolve = get_resolve()

local function timecode_to_frames(tc, fps)
  if not tc or tc == "" then
    return 0
  end
  local hh, mm, ss, ff = tc:match("^(%d+):(%d+):(%d+):(%d+)$")
  if not hh then
    return 0
  end
  fps = tonumber(fps) or 24
  local total_seconds = (tonumber(hh) * 3600) + (tonumber(mm) * 60) + tonumber(ss)
  return math.floor(total_seconds * fps + tonumber(ff or 0) + 0.5)
end

local function get_timeline_context()
  if not resolve then
    return "Resolve API unavailable."
  end

  local pm = resolve:GetProjectManager()
  if not pm then
    return "Project manager unavailable."
  end

  local project = pm:GetCurrentProject()
  if not project then
    return "No project open."
  end

  local project_name = project:GetName() or "Untitled"
  local page = resolve.GetCurrentPage and resolve:GetCurrentPage() or "unknown"
  local timeline = project:GetCurrentTimeline()

  if not timeline then
    return table.concat({
      "Project: " .. project_name,
      "Current page: " .. tostring(page),
      "Timeline: none",
      "Timeline count: " .. tostring(project:GetTimelineCount() or 0),
    }, "\n")
  end

  local timeline_name = timeline:GetName() or "Untitled timeline"
  local start_tc = timeline:GetStartTimecode() or ""
  local current_tc = timeline.GetCurrentTimecode and timeline:GetCurrentTimecode() or ""
  local fps = timeline.GetSetting and timeline:GetSetting("timelineFrameRate") or "24"

  return table.concat({
    "Project: " .. project_name,
    "Current page: " .. tostring(page),
    "Timeline: " .. timeline_name,
    "Timeline start timecode: " .. start_tc,
    "Current timecode: " .. current_tc,
    "Timeline fps: " .. tostring(fps),
  }, "\n")
end

local function append_message(messages, role, content)
  messages[#messages + 1] = { role = role, content = content }
end

local function truncate_history(messages, keep_last)
  keep_last = keep_last or 20
  if #messages <= keep_last then
    return messages
  end

  local trimmed = {}
  for i = #messages - keep_last + 1, #messages do
    trimmed[#trimmed + 1] = messages[i]
  end
  return trimmed
end

local function write_request_file(messages, context)
  local path = os.tmpname() .. ".json"
  local file = assert(io.open(path, "w"))
  file:write(json_encode({
    messages = messages,
    context = context,
    temperature = 0.2,
    max_tokens = 700,
  }))
  file:close()
  return path
end

local function read_all(pipe)
  local chunks = {}
  while true do
    local chunk = pipe:read("*a")
    if not chunk or chunk == "" then
      break
    end
    chunks[#chunks + 1] = chunk
  end
  return table.concat(chunks)
end

local function run_backend(messages)
  local request_path = write_request_file(messages, get_timeline_context())
  local command = "/usr/bin/env python3 " .. shell_quote(BACKEND) .. " " .. shell_quote(request_path) .. " 2>&1"
  local pipe = io.popen(command, "r")
  if not pipe then
    os.remove(request_path)
    return false, "Не удалось запустить Python"
  end

  local output = read_all(pipe)
  pipe:close()
  os.remove(request_path)

  local error_start = output:find("@@ERROR_START@@", 1, true)
  if error_start then
    local error_body_start = output:find("\n", error_start, true)
    local error_end = output:find("\n@@ERROR_END@@", 1, true)
    local error_text = ""
    if error_body_start and error_end and error_end > error_body_start then
      error_text = output:sub(error_body_start + 1, error_end - 1)
    end
    return false, error_text ~= "" and error_text or "Unknown backend error"
  end

  local reply_start = output:find("@@REPLY_START@@", 1, true)
  local reply_end = output:find("@@REPLY_END@@", 1, true)
  if not reply_start or not reply_end then
    return false, "Bad backend response"
  end

  local reply_block_start = output:find("\n", reply_start, true)
  local reply_text = ""
  if reply_block_start and reply_end > reply_block_start then
    reply_text = output:sub(reply_block_start + 1, reply_end - 1)
  end

  return true, reply_text
end

local function render_messages(messages)
  local parts = {
    "<html><body style='font-family:Segoe UI, Arial; font-size:13px; margin:0; padding:12px; background:#0f131a; color:#e8eef7;'>",
  }

  for _, message in ipairs(messages) do
    local role = message.role or "assistant"
    local content = html_escape(message.content or "")
    local bg = "#1a2330"
    local border = "#2a3443"
    local label = "AGENT"

    if role == "user" then
      bg = "#1452d5"
      border = "#1452d5"
      label = "YOU"
    elseif role == "system" then
      bg = "#232a35"
      border = "#3a4555"
      label = "INFO"
    end

    parts[#parts + 1] = string.format(
      "<div style='margin:0 0 10px 0; padding:10px 12px; border:1px solid %s; background:%s; border-radius:12px;'>",
      border,
      bg
    )
    parts[#parts + 1] = string.format(
      "<div style='font-size:11px; letter-spacing:0.08em; color:#9fb0c7; margin-bottom:6px;'>%s</div>",
      label
    )
    parts[#parts + 1] = string.gsub(content, "\n", "<br>")
    parts[#parts + 1] = "</div>"
  end

  parts[#parts + 1] = "</body></html>"
  return table.concat(parts)
end

local fusion = fu
if not fusion and bmd and bmd.scriptapp then
  fusion = bmd.scriptapp("Fusion")
end

if not fusion or not fusion.UIManager then
  error("Fusion UIManager is not available. DaVinci Resolve Studio is required.")
end

local ui = fusion.UIManager
local disp = bmd.UIDispatcher(ui)

local messages = {
  { role = "system", content = "Напиши запрос, и я помогу работать внутри DaVinci Resolve." },
}

local status = "Ready"
local error_text = ""
local busy = false

local window = disp:AddWindow({
  ID = "ResolveChatAgent",
  WindowTitle = title,
  Geometry = { 100, 100, 980, 760 },
  ui:VGroup {
    ID = "Root",
    ui:HGroup {
      Weight = 0,
      ui:Label { Text = "Resolve Chat Agent" },
      ui:Label { ID = "Status", Text = status },
      ui:Label { ID = "Error", Text = "" },
    },
    ui:TextEdit {
      ID = "Transcript",
      ReadOnly = true,
      HTML = render_messages(messages),
    },
    ui:HGroup {
      Weight = 0,
      ui:LineEdit {
        ID = "Input",
        Text = "",
        PlaceholderText = "Напиши запрос для Resolve",
      },
      ui:Button { ID = "Send", Text = "Send" },
      ui:Button { ID = "Clear", Text = "Clear" },
    },
  },
})

local itm = window:GetItems()

local function update_view()
  itm.Transcript.HTML = render_messages(messages)
  itm.Status.Text = status
  itm.Error.Text = error_text
end

local function send_prompt()
  if busy then
    return
  end

  local prompt = trim(itm.Input.Text or "")
  if prompt == "" then
    return
  end

  busy = true
  status = "Thinking..."
  error_text = ""
  append_message(messages, "user", prompt)
  messages = truncate_history(messages, 20)
  itm.Input.Text = ""
  update_view()

  local ok, reply_or_error = run_backend(messages)
  if not ok then
    status = "Error"
    error_text = reply_or_error
    append_message(messages, "assistant", "Ошибка: " .. reply_or_error)
    messages = truncate_history(messages, 20)
    busy = false
    update_view()
    return
  end

  local reply = trim(reply_or_error)
  if reply ~= "" then
    append_message(messages, "assistant", reply)
  end

  messages = truncate_history(messages, 20)
  status = "Ready"
  busy = false
  update_view()
end

function window.On.Send.Clicked()
  send_prompt()
end

function window.On.Clear.Clicked()
  messages = {
    { role = "system", content = "Напиши запрос, и я помогу работать внутри DaVinci Resolve." },
  }
  status = "Ready"
  error_text = ""
  itm.Input.Text = ""
  update_view()
end

function window.On.ResolveChatAgent.Close()
  disp:ExitLoop()
end

window:Show()
disp:RunLoop()
window:Hide()
