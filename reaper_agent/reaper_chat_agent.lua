-- REAPER Agent chat window
-- Planner/executor architecture with strict JSON plans.

local title = "REAPER Agent"
local AGENT_VERSION = "2026-06-03.1206"

local function script_dir()
  local source = debug.getinfo(1, "S").source
  local dir = source:match("^@(.+[\\/])")
  return dir or ""
end

local ROOT = script_dir()
local BACKEND = ROOT .. "reaper_agent_backend.py"
local VOICE_STT = ROOT .. "voice_stt.py"
local json = dofile(ROOT .. "reaper_json.lua")
local registry = dofile(ROOT .. "reaper_tool_registry.lua")

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", [['"'"'"'"'"'"'"'"']]) .. "'"
end

local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function get_project_context()
  local snapshot = registry.get_project_state()
  return snapshot
end

local function write_request_file(payload)
  local path = os.tmpname() .. ".json"
  local file = assert(io.open(path, "w"))
  file:write(json.encode(payload))
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

local function friendly_error_text(error_value)
  if type(error_value) == "table" then
    return error_value.message
      or error_value.error
      or error_value.name
      or "Не удалось выполнить действие."
  end

  local text = trim(error_value or "")
  if text == "" then
    return "Не удалось выполнить действие."
  end
  if text:sub(1, 1) == "{" or text:sub(1, 1) == "[" then
    return "Не удалось проверить результат действия."
  end
  return text
end

local function run_backend(payload)
  local request_path = write_request_file(payload)
  local command = "python3 " .. shell_quote(BACKEND) .. " " .. shell_quote(request_path) .. " 2>&1"
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

  local ok, decoded = pcall(json.decode, output)
  if not ok then
    return false, "Bad backend response"
  end
  return true, decoded
end

local function run_voice_stt()
  local command = "python3 " .. shell_quote(VOICE_STT) .. " 2>&1"
  local pipe = io.popen(command, "r")
  if not pipe then
    return false, "Не удалось запустить распознавание голоса"
  end

  local output = read_all(pipe)
  pipe:close()

  local error_start = output:find("@@VOICE_ERROR_START@@", 1, true)
  if error_start then
    local error_body_start = output:find("\n", error_start, true)
    local error_end = output:find("\n@@VOICE_ERROR_END@@", 1, true)
    local error_text = ""
    if error_body_start and error_end and error_end > error_body_start then
      error_text = output:sub(error_body_start + 1, error_end - 1)
    end
    return false, error_text ~= "" and error_text or "Unknown voice error"
  end

  local text_start = output:find("@@VOICE_TEXT_START@@", 1, true)
  local text_end = output:find("@@VOICE_TEXT_END@@", 1, true)
  if not text_start or not text_end then
    return false, "Bad voice response"
  end

  local body_start = output:find("\n", text_start, true)
  local voice_text = ""
  if body_start and text_end > body_start then
    voice_text = trim(output:sub(body_start + 1, text_end - 1))
  end
  return true, voice_text
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

local function is_confirmation(text)
  local normalized = trim(text):lower()
  return normalized == "да"
    or normalized == "yes"
    or normalized == "ok"
    or normalized == "ок"
    or normalized == "подтверждаю"
    or normalized == "confirm"
    or normalized == "выполняй"
end

local function clone_table(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = clone_table(item)
  end
  return out
end

local function registry_tools()
  return registry.get_tool_metadata()
end

local function registry_tool_map()
  local map = {}
  for _, tool in ipairs(registry_tools()) do
    map[tool.name] = tool
  end
  return map
end

local function tool_name_set(names)
  local set = {}
  for _, name in ipairs(names or {}) do
    set[name] = true
  end
  return set
end

local function tool_names_from_metadata(metadata)
  local names = {}
  for _, tool in ipairs(metadata or {}) do
    names[#names + 1] = tool.name
  end
  return names
end

local function category_tool_names(categories)
  local names = {}
  local want = tool_name_set(categories or {})
  for _, tool in ipairs(registry_tools()) do
    if want[tool.category] then
      names[#names + 1] = tool.name
    end
  end
  return names
end

local function has_token(text, token)
  return trim(text):lower():find(token:lower(), 1, true) ~= nil
end

local function matches_known_plugin(text)
  local catalog = registry.get_plugin_catalog() or {}
  local normalized = trim(text or ""):lower()
  for _, plugin in ipairs(catalog) do
    if plugin.display_name and normalized:find(trim(plugin.display_name):lower(), 1, true) then
      return true
    end
    if plugin.exact_reaper_fx_name and normalized:find(trim(plugin.exact_reaper_fx_name):lower(), 1, true) then
      return true
    end
    for _, alias in ipairs(plugin.aliases or {}) do
      if normalized:find(trim(alias):lower(), 1, true) then
        return true
      end
    end
  end
  return false
end

local function extract_plugin_query(text)
  local normalized = trim(text or "")
  if normalized == "" then
    return ""
  end

  local cleaned = normalized
  local create_with_plugin = cleaned:match("^[Сс][Дд]елай%s+[Тт]рек%s+с%s+(.+)$")
    or cleaned:match("^[Сс][Дд]елай%s+[Дд]орожку%s+с%s+(.+)$")
    or cleaned:match("^[Сс][Оо]здай%s+[Тт]рек%s+с%s+(.+)$")
    or cleaned:match("^[Сс][Оо]здай%s+[Дд]орожку%s+с%s+(.+)$")
    or cleaned:match("^[Сс][Дд]елай%s+[Тт]рек%s+[Ww]ith%s+(.+)$")
    or cleaned:match("^[Сс][Оо]здай%s+[Тт]рек%s+[Ww]ith%s+(.+)$")
    or cleaned:match("^[Сс][Дд]елай%s+[Дд]орожку%s+[Ww]ith%s+(.+)$")
    or cleaned:match("^[Сс][Оо]здай%s+[Дд]орожку%s+[Ww]ith%s+(.+)$")
  if create_with_plugin then
    cleaned = create_with_plugin
  end
  local after_add_plugin = cleaned:match("[Дд]обавь%s+(.+)%s+[Нн]а%s+выбранный%s+трек")
    or cleaned:match("[Дд]обавь%s+(.+)%s+[Нн]а%s+этот%s+трек")
    or cleaned:match("[Вв]ставь%s+(.+)%s+[Нн]а%s+выбранный%s+трек")
    or cleaned:match("[Вв]ставь%s+(.+)%s+[Нн]а%s+этот%s+трек")
    or cleaned:match("[Пп]оставь%s+(.+)%s+[Нн]а%s+выбранный%s+трек")
    or cleaned:match("[Пп]оставь%s+(.+)%s+[Нн]а%s+этот%s+трек")
    or cleaned:match("[Зз]акинь%s+(.+)%s+[Нн]а%s+выбранный%s+трек")
    or cleaned:match("[Зз]акинь%s+(.+)%s+[Нн]а%s+этот%s+трек")
    or cleaned:match("[Дд]обавь%s+[Нн]а%s+выбранный%s+трек%s+(.+)")
    or cleaned:match("[Дд]обавь%s+[Нн]а%s+этот%s+трек%s+(.+)")
    or cleaned:match("[Вв]ставь%s+[Нн]а%s+выбранный%s+трек%s+(.+)")
    or cleaned:match("[Вв]ставь%s+[Нн]а%s+этот%s+трек%s+(.+)")
    or cleaned:match("[Пп]оставь%s+[Нн]а%s+выбранный%s+трек%s+(.+)")
    or cleaned:match("[Пп]оставь%s+[Нн]а%s+этот%s+трек%s+(.+)")
    or cleaned:match("[Зз]акинь%s+[Нн]а%s+выбранный%s+трек%s+(.+)")
    or cleaned:match("[Зз]акинь%s+[Нн]а%s+этот%s+трек%s+(.+)")
    or cleaned:match("[Нн]а%s+выбранный%s+трек%s+[Пп]оставь%s+(.+)")
    or cleaned:match("[Нн]а%s+выбранный%s+трек%s+[Дд]обавь%s+(.+)")
    or cleaned:match("[Нн]а%s+выбранный%s+трек%s+[Вв]ставь%s+(.+)")
    or cleaned:match("[Нн]а%s+выбранный%s+трек%s+[Зз]акинь%s+(.+)")
    or cleaned:match("[Нн]а%s+этот%s+трек%s+[Пп]оставь%s+(.+)")
    or cleaned:match("[Нн]а%s+этот%s+трек%s+[Дд]обавь%s+(.+)")
    or cleaned:match("[Нн]а%s+этот%s+трек%s+[Вв]ставь%s+(.+)")
    or cleaned:match("[Нн]а%s+этот%s+трек%s+[Зз]акинь%s+(.+)")
  if after_add_plugin then
    cleaned = after_add_plugin
  end
  local with_plugin = cleaned:match("%s[Сс]%s+(.+)$")
    or cleaned:match("%swith%s+(.+)$")
  if with_plugin and (
      has_token(cleaned, "трек")
      or has_token(cleaned, "дорож")
      or has_token(cleaned, "track")
      or has_token(cleaned, "еще одну")
      or has_token(cleaned, "ещё одну")
      or has_token(cleaned, "еще один")
      or has_token(cleaned, "ещё один")
    ) then
    cleaned = with_plugin
  end
  cleaned = cleaned:gsub("^[Оо]ткрой%s+", "")
  cleaned = cleaned:gsub("^open%s+", "")
  cleaned = cleaned:gsub("^[Зз]апусти%s+", "")
  cleaned = cleaned:gsub("^load%s+", "")
  cleaned = cleaned:gsub("^[Дд]обавь%s+", "")
  cleaned = cleaned:gsub("^[Зз]акинь%s+", "")
  cleaned = cleaned:gsub("^[Вв]ставь%s+", "")
  cleaned = cleaned:gsub("^[Дд]обавить%s+", "")
  cleaned = cleaned:gsub("^[Вв]ставить%s+", "")
  cleaned = cleaned:gsub("^[Пп]лагин%s+", "")
  cleaned = cleaned:gsub("^[Пп]лагином%s+", "")
  cleaned = cleaned:gsub("^[Пп]лагин%s+на%s+трек%s+", "")
  cleaned = cleaned:gsub("^[Пп]оставь%s+", "")
  cleaned = cleaned:gsub("^[Мм]ожно%s+еще%s+", "")
  cleaned = cleaned:gsub("^[Мм]ожно%s+ещё%s+", "")
  cleaned = cleaned:gsub("^[Мм]ожно%s+", "")
  cleaned = cleaned:gsub("^[Ии]нструмент%s+", "")
  cleaned = cleaned:gsub("^[Ии]нструментом%s+", "")
  cleaned = cleaned:gsub("^[Оо]ткрыть%s+", "")
  cleaned = cleaned:gsub("^[Вв]%s+н[её]м%s+", "")
  cleaned = cleaned:gsub("^[Вв]%s+н[её]й%s+", "")
  cleaned = cleaned:gsub("^[Нн]а%s+н[её]м%s+", "")
  cleaned = cleaned:gsub("^[Нн]а%s+н[её]й%s+", "")

  cleaned = cleaned:gsub("^[Нн]а%s+выбранный%s+трек%s+", "")
  cleaned = cleaned:gsub("^[Нн]а%s+трек%s+", "")
  cleaned = cleaned:gsub("^[Вв]%s+трек%s+", "")
  cleaned = cleaned:gsub("^[Нн]овую%s+дорожку%s+с%s+", "")
  cleaned = cleaned:gsub("^[Нн]овый%s+трек%s+с%s+", "")
  cleaned = cleaned:gsub("^[Дд]орожку%s+с%s+", "")
  cleaned = cleaned:gsub("^[Тт]рек%s+с%s+", "")
  cleaned = cleaned:gsub("^[Ее]ще%s+одну%s+с%s+", "")
  cleaned = cleaned:gsub("^[Ее]щё%s+одну%s+с%s+", "")
  cleaned = cleaned:gsub("^[Ее]ще%s+один%s+с%s+", "")
  cleaned = cleaned:gsub("^[Ее]щё%s+один%s+с%s+", "")
  cleaned = cleaned:gsub("^[Сс]%s+", "")
  cleaned = cleaned:gsub("^[Пп]лагин%s+", "")
  cleaned = cleaned:gsub("%s+[Пп]ожалуйста$", "")
  cleaned = cleaned:gsub("%s+please$", "")

  cleaned = trim(cleaned)
  return cleaned
end

local function wants_new_plugin_track(text)
  local normalized = trim(text or ""):lower()
  if has_token(normalized, "на выбранный трек") or has_token(normalized, "на этот трек") then
    return false
  end
  if has_token(normalized, "новую дорожку с")
    or has_token(normalized, "новую дорожку with")
    or has_token(normalized, "новый трек с")
    or has_token(normalized, "новый трек with")
    or has_token(normalized, "track with") then
    return true
  end
  if has_token(normalized, "еще одну с")
    or has_token(normalized, "ещё одну с")
    or has_token(normalized, "еще один с")
    or has_token(normalized, "ещё один с")
    or has_token(normalized, "another one with") then
    return true
  end
  if not (has_token(normalized, "трек") or has_token(normalized, "дорож")) then
    return false
  end
  return has_token(normalized, "создай")
    or has_token(normalized, "сделай")
    or has_token(normalized, "добавь")
    or has_token(normalized, "еще")
    or has_token(normalized, "ещё")
end

local function likely_midi_create_command(text)
  local lowered = trim(text or ""):lower()
  if (has_token(lowered, ",") or has_token(lowered, " и "))
    and (
      has_token(lowered, "добавь")
      or has_token(lowered, "вставь")
      or has_token(lowered, "открой")
      or has_token(lowered, "плагин")
      or matches_known_plugin(lowered)
    ) then
    return false
  end
  return (has_token(lowered, "миди") or has_token(lowered, "midi"))
    and (
      has_token(lowered, "сделай")
      or has_token(lowered, "создай")
      or has_token(lowered, "добавь")
      or has_token(lowered, "сгенерируй")
      or has_token(lowered, "напиши")
      or has_token(lowered, "парт")
      or has_token(lowered, "клип")
    )
end

local function likely_plugin_command(text, query)
  local normalized = trim(text or ""):lower()
  local cleaned_query = trim(query or "")
  if cleaned_query == "" then
    return false
  end
  if (has_token(normalized, "миди") or has_token(normalized, "midi"))
    and (has_token(normalized, ",") or has_token(normalized, " и ")) then
    return false
  end
  if likely_midi_create_command(normalized) then
    return false
  end

  if wants_new_plugin_track(normalized) then
    return true
  end
  if matches_known_plugin(normalized) or matches_known_plugin(cleaned_query) then
    return true
  end
  if has_token(normalized, "открой")
    or has_token(normalized, "open")
    or has_token(normalized, "load")
    or has_token(normalized, "запусти")
    or has_token(normalized, "плагин")
    or has_token(normalized, "plugin")
    or has_token(normalized, "instrument")
    or has_token(normalized, "инструмент") then
    return true
  end
  if has_token(normalized, "добавь")
    or has_token(normalized, "вставь")
    or has_token(normalized, "закинь")
    or has_token(normalized, "поставь") then
    return not (has_token(cleaned_query, "трек") or has_token(cleaned_query, "дорож"))
  end
  return false
end

local function build_plugin_fallback_plan(user_text)
  local query = extract_plugin_query(user_text)
  if query == "" then
    return nil
  end

  local selected = get_project_context().selected_track
  local steps = {}
  if wants_new_plugin_track(user_text) or (not selected and not (get_project_context().last_created_track and get_project_context().last_created_track.id)) then
    steps[#steps + 1] = {
      step_id = 1,
      tool = "create_track",
      args = { name = query ~= "" and query or "Instrument" },
      save_as = "target_track",
    }
    steps[#steps + 1] = {
      step_id = 2,
      tool = "insert_fx",
      args = {
        track_ref = "target_track",
        fx_name = query,
      },
    }
  else
    steps[#steps + 1] = {
      step_id = 1,
      tool = "insert_fx",
      args = {
        track_ref = selected and "selected" or "last_created",
        fx_name = query,
      },
    }
  end

  return {
    intent = "plugin_fallback",
    requires_confirmation = false,
    steps = steps,
    user_message = wants_new_plugin_track(user_text) and ("Создан трек с " .. query .. ".") or ("Открыл " .. query .. "."),
  }
end

local function build_simple_midi_plan(user_text)
  if not likely_midi_create_command(user_text) then
    return nil
  end

  local project_state = get_project_context()
  local has_selected = project_state.selected_track and project_state.selected_track.id
  local has_last_created = project_state.last_created_track and project_state.last_created_track.id

  local steps = {}
  local track_ref = "selected"
  if has_selected then
    track_ref = "selected"
  elseif has_last_created then
    track_ref = "last_created"
  else
    steps[#steps + 1] = {
      step_id = 1,
      tool = "create_track",
      args = { name = "MIDI" },
      save_as = "midi_track",
    }
    track_ref = "midi_track"
  end

  local next_step_id = #steps + 1
  steps[#steps + 1] = {
    step_id = next_step_id,
    tool = "create_midi_item",
    args = {
      track_ref = track_ref,
      bars = 4,
    },
    save_as = "midi_item",
  }
  steps[#steps + 1] = {
    step_id = next_step_id + 1,
    tool = "write_midi_notes",
    args = {
      item_ref = "midi_item",
      notes = {
        { start_qn = 0, end_qn = 0.5, pitch = 60, velocity = 96 },
        { start_qn = 1, end_qn = 1.5, pitch = 62, velocity = 96 },
        { start_qn = 2, end_qn = 2.5, pitch = 64, velocity = 96 },
        { start_qn = 3, end_qn = 3.5, pitch = 67, velocity = 96 },
        { start_qn = 4, end_qn = 4.5, pitch = 60, velocity = 92 },
        { start_qn = 5, end_qn = 5.5, pitch = 62, velocity = 92 },
        { start_qn = 6, end_qn = 6.5, pitch = 64, velocity = 92 },
        { start_qn = 7, end_qn = 7.5, pitch = 69, velocity = 92 },
        { start_qn = 8, end_qn = 8.5, pitch = 60, velocity = 96 },
        { start_qn = 9, end_qn = 9.5, pitch = 62, velocity = 96 },
        { start_qn = 10, end_qn = 10.5, pitch = 64, velocity = 96 },
        { start_qn = 11, end_qn = 11.5, pitch = 67, velocity = 96 },
        { start_qn = 12, end_qn = 12.5, pitch = 60, velocity = 92 },
        { start_qn = 13, end_qn = 13.5, pitch = 62, velocity = 92 },
        { start_qn = 14, end_qn = 14.5, pitch = 64, velocity = 92 },
        { start_qn = 15, end_qn = 15.5, pitch = 69, velocity = 92 },
      },
    },
  }

  return {
    intent = "simple_midi_fallback",
    requires_confirmation = false,
    steps = steps,
    user_message = "Создал простую MIDI-партию.",
  }
end

local function build_simple_midi_edit_plan(user_text)
  local text = trim(user_text or ""):lower()
  local wants_midi_target = has_token(text, "миди")
    or has_token(text, "midi")
    or has_token(text, "парт")
    or has_token(text, "эту")
  local wants_edit = has_token(text, "измени")
    or has_token(text, "поменяй")
    or has_token(text, "переделай")
    or has_token(text, "квантиз")
    or has_token(text, "подровняй")

  if not wants_midi_target or not wants_edit then
    return nil
  end

  return {
    intent = "simple_midi_edit_fallback",
    requires_confirmation = false,
    steps = {
      {
        step_id = 1,
        tool = "quantize_midi",
        args = { grid_qn = 0.25 },
      },
    },
    user_message = "Подровнял MIDI-партию.",
  }
end

local SYSTEM_TOOL_NAMES = {
  "get_project_state",
  "verify_project_state",
  "validate_tool_args",
  "dry_run_plan",
  "undo_agent_plan",
}

local function select_tools_for_router(router_result, user_text)
  local categories = router_result and router_result.domains or {}
  local tool_map = registry_tool_map()
  local selected = {}
  local seen = {}

  local function add(name)
    if name and tool_map[name] and not seen[name] then
      seen[name] = true
      selected[#selected + 1] = tool_map[name]
    end
  end

  for _, name in ipairs(SYSTEM_TOOL_NAMES) do
    add(name)
  end

  for _, name in ipairs(router_result and router_result.candidate_tools_hint or {}) do
    add(name)
  end

  for _, name in ipairs(category_tool_names(categories)) do
    add(name)
  end

  local text = trim(user_text or ""):lower()
  if has_token(text, "на неё")
    or has_token(text, "на этот трек")
    or has_token(text, "туда")
    or has_token(text, "на выбранный")
    or has_token(text, "в нем")
    or has_token(text, "в ней")
    or has_token(text, "на нем")
    or has_token(text, "на ней") then
    add("resolve_track")
    add("get_selected_tracks")
    add("get_last_created_track")
    add("resolve_pronoun_reference")
    add("resolve_target_from_dialog_context")
  end

  if has_token(text, "создай") or has_token(text, "добавь") or has_token(text, "переименуй") then
    add("get_track_list")
    add("resolve_track")
  end

  if has_token(text, "открой") or has_token(text, "open") or has_token(text, "запусти") or has_token(text, "load") or has_token(text, "плагин") or has_token(text, "plugin") or has_token(text, "instrument") or matches_known_plugin(text) then
    add("resolve_fx")
    add("insert_fx")
    add("get_selected_tracks")
    add("get_last_created_track")
  end

  if has_token(text, "снимок") or has_token(text, "верси") or has_token(text, "rollback") or has_token(text, "checkpoint") then
    add("create_project_snapshot")
    add("list_project_snapshots")
    add("create_auto_backup_before_execution")
  end

  if has_token(text, "groove") or has_token(text, "swing") or has_token(text, "тайминг") or has_token(text, "humanize") or has_token(text, "квантиз") then
    add("quantize_with_strength")
    add("loosen_midi_performance")
    add("set_swing_amount")
  end

  if has_token(text, "аккорд") or has_token(text, "тональ") or has_token(text, "harmony") or has_token(text, "reharmon") then
    add("create_chord_track")
    add("generate_chord_progression_by_style")
    add("transpose_project_to_key")
  end

  if has_token(text, "свед") or has_token(text, "lufs") or has_token(text, "clipping") or has_token(text, "mono") or has_token(text, "meter") then
    add("measure_integrated_lufs")
    add("measure_true_peak")
    add("check_headroom")
    add("create_mix_quality_report")
  end

  if has_token(text, "delivery") or has_token(text, "стем") or has_token(text, "акапел") or has_token(text, "instrumental") or has_token(text, "zip") then
    add("prepare_stems_for_client")
    add("prepare_instrumental_export")
    add("prepare_acapella_export")
    add("zip_delivery_package")
  end

  return selected
end

local function select_tools_by_names(names)
  local tool_map = registry_tool_map()
  local selected = {}
  local seen = {}
  for _, name in ipairs(names or {}) do
    if name and tool_map[name] and not seen[name] then
      seen[name] = true
      selected[#selected + 1] = tool_map[name]
    end
  end
  return selected
end

local function run_router(messages)
  local request_payload = {
    mode = "route",
    user_text = "",
    messages = truncate_history(messages, 12),
    project_state = get_project_context(),
  }
  for i = #messages, 1, -1 do
    if messages[i].role == "user" then
      request_payload.user_text = messages[i].content or ""
      break
    end
  end
  local ok, result = run_backend(request_payload)
  if not ok then
    return false, result
  end
  return true, result
end

local function resolve_plan_value(value, refs, project_state)
  if type(value) == "string" then
    if refs[value] then
      return refs[value]
    end
    if value == "selected" and project_state and project_state.selected_track then
      return { track_id = project_state.selected_track.id, track_name = project_state.selected_track.name }
    end
    if value == "last_created" and project_state and project_state.last_created_track then
      return { track_id = project_state.last_created_track.id, track_name = project_state.last_created_track.name }
    end
  elseif type(value) == "table" then
    return clone_table(value)
  end
  return value
end

local function resolve_step_args(step, refs, project_state)
  local args = clone_table(step.args or {})
  if args.track_ref then
    local resolved = resolve_plan_value(args.track_ref, refs, project_state)
    if type(resolved) == "table" then
      if resolved.track_id and not args.track_id then
        args.track_id = resolved.track_id
      end
      if resolved.track_name and not args.track_name then
        args.track_name = resolved.track_name
      end
      if resolved.id and not args.track_id then
        args.track_id = resolved.id
      end
      if resolved.name and not args.track_name then
        args.track_name = resolved.name
      end
    elseif type(resolved) == "string" and not args.track_id and not args.track_name then
      args.track_id = resolved
    end
  end
  if args.fx_ref then
    local resolved_fx = resolve_plan_value(args.fx_ref, refs, project_state)
    if type(resolved_fx) == "table" then
      args.fx_name = args.fx_name or resolved_fx.fx_name or resolved_fx.name or resolved_fx.exact_reaper_fx_name
      args.query = args.query or resolved_fx.query or resolved_fx.fx_name or resolved_fx.name
    elseif type(resolved_fx) == "string" then
      args.fx_name = args.fx_name or resolved_fx
      args.query = args.query or resolved_fx
    end
  end
  if args.item_ref then
    local resolved_item = resolve_plan_value(args.item_ref, refs, project_state)
    if type(resolved_item) == "table" then
      args.take_id = args.take_id or resolved_item.take_id or resolved_item.take
      args.track_id = args.track_id or resolved_item.track_id
    elseif type(resolved_item) == "string" then
      args.take_id = args.take_id or resolved_item
    end
  end
  if args.notes_ref then
    local resolved_notes = resolve_plan_value(args.notes_ref, refs, project_state)
    if type(resolved_notes) == "table" and resolved_notes.notes then
      args.notes = args.notes or resolved_notes.notes
    end
  end
  return args
end

local function validate_step_dependencies(plan)
  local steps = plan.steps or {}
  local index_by_id = {}
  for idx, step in ipairs(steps) do
    if index_by_id[step.step_id] then
      return false, "duplicate step_id " .. tostring(step.step_id)
    end
    index_by_id[step.step_id] = idx
  end
  local visiting = {}
  local visited = {}
  local function visit(step_id)
    if visiting[step_id] then
      return false, "cyclic dependency involving " .. tostring(step_id)
    end
    if visited[step_id] then
      return true
    end
    visiting[step_id] = true
    local step = steps[index_by_id[step_id]]
    for _, dep in ipairs(step.depends_on or {}) do
      if not index_by_id[dep] then
        return false, "unknown dependency " .. tostring(dep)
      end
      local ok, err = visit(dep)
      if not ok then
        return false, err
      end
    end
    visiting[step_id] = nil
    visited[step_id] = true
    return true
  end
  for step_id, _ in pairs(index_by_id) do
    local ok, err = visit(step_id)
    if not ok then
      return false, err
    end
  end
  return true
end

local function normalize_step_id(value, fallback)
  local numeric = tonumber(value)
  if numeric then
    return math.floor(numeric)
  end
  return fallback
end

local function normalize_plan_steps(plan)
  if type(plan) ~= "table" or type(plan.steps) ~= "table" then
    return
  end

  local seen = {}
  for idx, step in ipairs(plan.steps) do
    local step_id = normalize_step_id(step.step_id, idx)
    while seen[step_id] do
      step_id = step_id + 1
    end
    seen[step_id] = true
    step.step_id = step_id

    if type(step.depends_on) == "table" then
      local normalized_depends = {}
      for _, dep in ipairs(step.depends_on) do
        local dep_id = tonumber(dep)
        if dep_id then
          normalized_depends[#normalized_depends + 1] = math.floor(dep_id)
        elseif type(dep) == "number" then
          normalized_depends[#normalized_depends + 1] = dep
        end
      end
      step.depends_on = normalized_depends
    else
      step.depends_on = {}
    end
  end
end

local function validate_plan_locally(plan, selected_tools)
  if type(plan) ~= "table" then
    return false, "Plan is not an object"
  end
  if type(plan.steps) ~= "table" then
    if plan.recipe then
      local expanded = registry.expand_recipe(plan.recipe, plan.recipe_args or {})
      if type(expanded) ~= "table" then
        return false, "Unknown recipe: " .. tostring(plan.recipe)
      end
      plan.steps = {}
      for i, step in ipairs(expanded) do
        plan.steps[#plan.steps + 1] = {
          step_id = i,
          tool = step.tool,
          args = step.args or {},
          depends_on = step.depends_on or {},
          save_as = step.save_as,
          preconditions = step.preconditions or {},
          postconditions = step.postconditions or {},
        }
      end
    else
      return false, "Plan steps are missing"
    end
  end
  if plan.recipe and (not plan.steps or #plan.steps == 0) then
    return false, "Plan steps are missing"
  end
  normalize_plan_steps(plan)

  local allowed = {}
  for _, tool in ipairs(selected_tools or {}) do
    allowed[tool.name] = tool
  end

  local seen_save_as = {}
  for _, step in ipairs(plan.steps) do
    if type(step.step_id) ~= "number" then
      return false, "step_id must be numeric"
    end
    if type(step.tool) ~= "string" or step.tool == "" then
      return false, "step tool is missing"
    end
    if not allowed[step.tool] then
      return false, "tool not allowed: " .. tostring(step.tool)
    end
    if step.save_as then
      if seen_save_as[step.save_as] then
        return false, "duplicate save_as: " .. tostring(step.save_as)
      end
      seen_save_as[step.save_as] = true
    end

    local meta = allowed[step.tool]
    local required = (((meta or {}).json_schema or {}).required) or {}
    local args = step.args or {}
    for _, key in ipairs(required) do
      if args[key] == nil then
        local ref_key = key:gsub("_id$", "_ref")
        if not (key == "track_id" and args.track_ref)
          and not (key == "fx_name" and (args.fx_ref or args.query))
          and not (key == "notes" and args.notes_ref)
          and not (ref_key ~= key and args[ref_key]) then
          return false, "missing required arg: " .. tostring(key) .. " for " .. tostring(step.tool)
        end
      end
    end
  end

  local ok, err = validate_step_dependencies(plan)
  if not ok then
    return false, err
  end

  return true
end

local function plan_state_new(plan)
  local total = #(plan.steps or {})
  local pending = {}
  for i = 1, total do
    pending[#pending + 1] = i
  end
  return {
    plan_id = "plan_" .. tostring(os.time()),
    status = "running",
    current_step = 0,
    steps_total = total,
    completed_steps = {},
    failed_steps = {},
    pending_steps = pending,
    results = {},
  }
end

local function store_step_result(plan_state, step, result)
  if step.save_as and result and result.ok then
    local payload = result.result or {}
    local value = clone_table(payload)
    if payload.track and payload.track.id then
      value.track_id = payload.track.id
      value.track_name = payload.track.name
    end
  if payload.fx and payload.fx.name then
      value.fx_name = payload.fx.name
      value.fx_id = payload.fx.index
    end
    if payload.best_match and payload.best_match.exact_reaper_fx_name then
      value.fx_name = payload.best_match.exact_reaper_fx_name
      value.plugin_name = payload.best_match.display_name
      value.plugin_vendor = payload.best_match.vendor
    end
    if payload.item and payload.item.id then
      value.item_id = payload.item.id
      value.take_id = payload.item.take
    end
    plan_state.results[step.save_as] = value
  end
end

local function has_step_dependency(plan, failed_step_id, candidate_step)
  for _, dep in ipairs(candidate_step.depends_on or {}) do
    if dep == failed_step_id then
      return true
    end
  end
  return false
end

local function verification_checks_for_step(step, result)
  local payload = {}
  local data = result and result.result or {}

  if step.tool == "create_track" then
    if data.track and data.track.id then
      payload.track_exists = { { track_id = data.track.id } }
      if data.selected then
        payload.selected_track = { { track_id = data.track.id } }
      end
    end
  elseif step.tool == "find_track" then
    if data.track and data.track.id then
      payload.track_exists = { { track_id = data.track.id } }
    end
  elseif step.tool == "select_track" then
    if data.track and data.track.id then
      payload.selected_track = { { track_id = data.track.id } }
    end
  elseif step.tool == "rename_track" then
    if data.track and data.track.id then
      payload.track_exists = { { track_id = data.track.id } }
    end
  elseif step.tool == "insert_fx" then
    if data.track and data.track.id and data.fx and data.fx.name then
      payload.fx_inserted = { { track_id = data.track.id, fx_name = data.fx.name } }
    end
  elseif step.tool == "resolve_fx" then
    if data.best_match and data.best_match.exact_reaper_fx_name then
      payload.fx_inserted = { { query = data.best_match.exact_reaper_fx_name } }
    end
  elseif step.tool == "create_midi_item" then
    if data.track and data.track.id then
      payload.midi_item_created = { { track_id = data.track.id } }
    end
  elseif step.tool == "write_midi_notes" then
    if data.track and data.track.id then
      payload.midi_item_created = { { track_id = data.track.id } }
    end
  elseif step.tool == "create_send" then
    if data.source_track and data.source_track.id and data.dest_track and data.dest_track.id then
      payload.track_exists = {
        { track_id = data.source_track.id },
        { track_id = data.dest_track.id },
      }
    end
  elseif step.tool == "route_track_to_bus" then
    if data.source_track and data.source_track.id and data.bus_track and data.bus_track.id then
      payload.track_exists = {
        { track_id = data.source_track.id },
        { track_id = data.bus_track.id },
      }
    end
  elseif step.tool == "render_project" then
    payload.render_export_completed = true
  end

  return payload
end

local function execute_plan(plan, request_payload, messages, retry_count)
  retry_count = retry_count or 0
  request_payload = request_payload or {}
  local results = {}
  local steps = plan.steps or {}
  local plan_state = plan_state_new(plan)
  local project_state = get_project_context()

  local function mark_pending(step_index)
    local filtered = {}
    for _, pending in ipairs(plan_state.pending_steps) do
      if pending ~= step_index then
        filtered[#filtered + 1] = pending
      end
    end
    plan_state.pending_steps = filtered
  end

  for i, step in ipairs(steps) do
    plan_state.current_step = i
    mark_pending(i)

    if not registry.is_allowed_tool(step.tool) then
      plan_state.status = "failed"
      return false, "Forbidden tool: " .. tostring(step.tool), results
    end

    local resolved_args = resolve_step_args(step, plan_state.results, project_state)
    local result = registry.execute_tool(step.tool, resolved_args)
    local step_result = {
      step_id = step.step_id,
      tool = step.tool,
      ok = result.ok,
      result = result.result,
      error = result.error,
    }
    results[#results + 1] = step_result

    if not result.ok then
      plan_state.failed_steps[#plan_state.failed_steps + 1] = step.step_id or i
      plan_state.status = "failed"
      if retry_count < 1 and not request_payload.skip_repair then
        local repair_request = {
          mode = "repair",
          user_text = request_payload.user_text,
          messages = request_payload.messages,
          project_state = get_project_context(),
          selected_tools = request_payload.selected_tools,
          recipes = request_payload.recipes,
          plugin_catalog = request_payload.plugin_catalog,
          execution_error = {
            failed_step = step,
            failed_result = result,
            step_index = i,
            executed_results = results,
            original_plan = plan,
          },
        }
        local ok, repaired = run_backend(repair_request)
        if not ok then
          return false, repaired, results
        end
        local valid, validation_error = validate_plan_locally(repaired, request_payload.selected_tools)
        if not valid then
          return false, "Repair plan invalid: " .. tostring(validation_error), results
        end
        return execute_plan(repaired, request_payload, messages, retry_count + 1)
      end
      return false, friendly_error_text(result.error), results
    end

    plan_state.completed_steps[#plan_state.completed_steps + 1] = step.step_id or i
    store_step_result(plan_state, step, result)
    project_state = get_project_context()

    local verify_payload = verification_checks_for_step(step, result)
    if next(verify_payload) ~= nil
      and step.tool ~= "insert_fx"
      and step.tool ~= "create_track"
      and step.tool ~= "create_midi_item"
      and step.tool ~= "write_midi_notes" then
      local verify_result = registry.execute_tool("verify_project_state", { checks = verify_payload })
      local verify_step_result = {
        step_id = step.step_id,
        tool = "verify_project_state",
        ok = verify_result.ok,
        result = verify_result.result,
        error = verify_result.error,
      }
      results[#results + 1] = verify_step_result

      if not verify_result.ok then
        plan_state.failed_steps[#plan_state.failed_steps + 1] = step.step_id or i
        plan_state.status = "failed"
        if retry_count < 1 and not request_payload.skip_repair then
          local repair_request = {
            mode = "repair",
            user_text = request_payload.user_text,
            messages = request_payload.messages,
            project_state = get_project_context(),
            selected_tools = request_payload.selected_tools,
            recipes = request_payload.recipes,
            plugin_catalog = request_payload.plugin_catalog,
            execution_error = {
              failed_step = step,
              failed_result = verify_result,
              step_index = i,
              executed_results = results,
              original_plan = plan,
            },
          }
          local ok, repaired = run_backend(repair_request)
          if not ok then
            return false, repaired, results
          end
          local valid, validation_error = validate_plan_locally(repaired, request_payload.selected_tools)
          if not valid then
            return false, "Repair plan invalid: " .. tostring(validation_error), results
          end
          return execute_plan(repaired, request_payload, messages, retry_count + 1)
        end
        return false, friendly_error_text(verify_result.error), results
      end
    end
  end

  plan_state.status = "completed"
  return true, plan, results
end

local function build_request_payload(messages, mode, execution_error, selected_tools)
  local history = truncate_history(messages, 16)
  local payload = {
    mode = mode or "plan",
    user_text = "",
    messages = history,
    project_state = get_project_context(),
    selected_tools = selected_tools or registry.get_tool_metadata(),
    recipes = registry.get_recipe_metadata(),
    plugin_catalog = registry.get_plugin_catalog(),
  }

  for i = #messages, 1, -1 do
    if messages[i].role == "user" then
      payload.user_text = messages[i].content or ""
      break
    end
  end

  if execution_error then
    payload.execution_error = execution_error
  end

  return payload
end

local messages = {
  { role = "system", content = "Чат REAPER готов. v" .. AGENT_VERSION },
}

local input = ""
local status = "Ready"
local error_text = ""
local should_quit = false
local scroll_to_bottom = true
local chat_scroll = 0
local mouse_was_down = false
local pending_plan = nil
local pending_plan_request = nil
local dock_guard_frames = 0
local RIGHT_DOCK_ID = 1
local RIGHT_DOCK_STATE = 257

local function dock_state_is_right()
  local state = gfx.dock(-1)
  if state < 0 then
    return false
  end
  local docked = state & 1
  local docker_index = math.floor(state / 256) % 256
  return docked == 1 and docker_index == RIGHT_DOCK_ID
end

local function enforce_right_dock()
  if not dock_state_is_right() then
    if reaper and reaper.Dock_UpdateDockID then
      reaper.Dock_UpdateDockID(title, RIGHT_DOCK_ID)
    end
    gfx.dock(RIGHT_DOCK_STATE)
  end
end

local function send_prompt()
  local prompt = trim(input)
  if prompt == "" then
    return
  end

  local direct_plugin_query = extract_plugin_query(prompt)
  local direct_plugin_command = likely_plugin_command(prompt, direct_plugin_query)

  if direct_plugin_command then
    append_message(messages, "user", prompt)
    messages = truncate_history(messages, 20)
    input = ""
    status = "Thinking..."
    error_text = ""

    local selected_tools = registry.get_tool_metadata()
    local plan = build_plugin_fallback_plan(prompt)
    if not plan then
      status = "Error"
      error_text = "Не удалось распознать плагин."
      append_message(messages, "assistant", "Ошибка: не удалось распознать плагин.")
      scroll_to_bottom = true
      return
    end

    local valid, validation_error = validate_plan_locally(plan, selected_tools)
    if not valid then
      status = "Error"
      error_text = validation_error
      append_message(messages, "assistant", "Ошибка плана: " .. tostring(validation_error))
      scroll_to_bottom = true
      return
    end

    local exec_ok, exec_or_error = execute_plan(plan, {
      user_text = prompt,
      selected_tools = selected_tools,
      recipes = {},
      plugin_catalog = {},
      skip_repair = true,
    }, messages, 0)
    if not exec_ok then
      status = "Error"
      error_text = tostring(exec_or_error)
      append_message(messages, "assistant", "Ошибка: " .. tostring(exec_or_error))
      scroll_to_bottom = true
      return
    end

    local message = trim(plan.user_message or "Готово.")
    if message ~= "" then
      append_message(messages, "assistant", message)
    end

    status = "Ready"
    scroll_to_bottom = true
    return
  end

  local direct_midi_plan = build_simple_midi_plan(prompt)
  if direct_midi_plan then
    append_message(messages, "user", prompt)
    messages = truncate_history(messages, 20)
    input = ""
    status = "Thinking..."
    error_text = ""

    local selected_tools = registry.get_tool_metadata()
    local valid, validation_error = validate_plan_locally(direct_midi_plan, selected_tools)
    if not valid then
      status = "Error"
      error_text = validation_error
      append_message(messages, "assistant", "Ошибка плана: " .. tostring(validation_error))
      scroll_to_bottom = true
      return
    end

    local exec_ok, exec_or_error = execute_plan(direct_midi_plan, {
      user_text = prompt,
      selected_tools = selected_tools,
      recipes = {},
      plugin_catalog = {},
      skip_repair = true,
    }, messages, 0)
    if not exec_ok then
      status = "Error"
      error_text = tostring(exec_or_error)
      append_message(messages, "assistant", "Ошибка: " .. tostring(exec_or_error))
      scroll_to_bottom = true
      return
    end

    local message = trim(direct_midi_plan.user_message or "Готово.")
    if message ~= "" then
      append_message(messages, "assistant", message)
    end

    status = "Ready"
    scroll_to_bottom = true
    return
  end

  local direct_midi_edit_plan = build_simple_midi_edit_plan(prompt)
  if direct_midi_edit_plan then
    append_message(messages, "user", prompt)
    messages = truncate_history(messages, 20)
    input = ""
    status = "Thinking..."
    error_text = ""

    local selected_tools = registry.get_tool_metadata()
    local valid, validation_error = validate_plan_locally(direct_midi_edit_plan, selected_tools)
    if not valid then
      status = "Error"
      error_text = validation_error
      append_message(messages, "assistant", "Ошибка плана: " .. tostring(validation_error))
      scroll_to_bottom = true
      return
    end

    local exec_ok, exec_or_error = execute_plan(direct_midi_edit_plan, {
      user_text = prompt,
      selected_tools = selected_tools,
      recipes = {},
      plugin_catalog = {},
      skip_repair = true,
    }, messages, 0)
    if not exec_ok then
      status = "Error"
      error_text = tostring(exec_or_error)
      append_message(messages, "assistant", "Ошибка: " .. tostring(exec_or_error))
      scroll_to_bottom = true
      return
    end

    local message = trim(direct_midi_edit_plan.user_message or "Готово.")
    if message ~= "" then
      append_message(messages, "assistant", message)
    end

    status = "Ready"
    scroll_to_bottom = true
    return
  end

  if pending_plan and is_confirmation(prompt) then
    append_message(messages, "user", prompt)
    input = ""
    status = "Thinking..."
    error_text = ""
    local ok, plan_or_error, results = execute_plan(pending_plan, pending_plan_request, messages, 0)
    if not ok then
      status = "Error"
      error_text = tostring(plan_or_error)
      append_message(messages, "assistant", "Ошибка: " .. tostring(plan_or_error))
      pending_plan = nil
      pending_plan_request = nil
      scroll_to_bottom = true
      return
    end
    append_message(messages, "assistant", trim(plan_or_error.user_message or "Готово."))
    pending_plan = nil
    pending_plan_request = nil
    status = "Ready"
    scroll_to_bottom = true
    return
  end

  append_message(messages, "user", prompt)
  messages = truncate_history(messages, 20)
  input = ""
  status = "Thinking..."
  error_text = ""

  local router_ok, router_or_error = run_router(messages)
  if not router_ok then
    status = "Error"
    error_text = router_or_error
    append_message(messages, "assistant", "Ошибка роутера: " .. router_or_error)
    scroll_to_bottom = true
    return
  end

  local selected_tools = select_tools_for_router(router_or_error, prompt)
  local request_payload = build_request_payload(messages, "plan", nil, selected_tools)
  request_payload.router_result = router_or_error

  local ok, plan_or_error = run_backend(request_payload)
  if not ok then
    status = "Error"
    error_text = plan_or_error
    append_message(messages, "assistant", "Ошибка: " .. plan_or_error)
    scroll_to_bottom = true
    return
  end

  local plan = plan_or_error
  if (not plan.steps or #plan.steps == 0) and (matches_known_plugin(prompt) or has_token(prompt, "открой") or has_token(prompt, "open") or has_token(prompt, "load") or has_token(prompt, "плагин") or has_token(prompt, "plugin")) then
    local fallback_plan = build_plugin_fallback_plan(prompt)
    if fallback_plan then
      plan = fallback_plan
    end
  end
  local valid, validation_error = validate_plan_locally(plan, selected_tools)
  if not valid then
    status = "Error"
    error_text = validation_error
    append_message(messages, "assistant", "Ошибка плана: " .. tostring(validation_error))
    scroll_to_bottom = true
    return
  end

  if plan.requires_confirmation then
    pending_plan = plan
    pending_plan_request = request_payload
    local confirm_text = trim(plan.user_message or "Нужна подтверждение.")
    append_message(messages, "assistant", confirm_text)
    status = "Ready"
    scroll_to_bottom = true
    return
  end

  local exec_ok, exec_or_error = execute_plan(plan, request_payload, messages, 0)
  if not exec_ok then
    status = "Error"
    error_text = tostring(exec_or_error)
    append_message(messages, "assistant", "Ошибка: " .. tostring(exec_or_error))
    scroll_to_bottom = true
    return
  end

  local message = trim(plan.user_message or "Готово.")
  if message ~= "" then
    append_message(messages, "assistant", message)
  end

  status = "Ready"
  scroll_to_bottom = true
end

local function send_voice_prompt()
  status = "Listening..."
  error_text = ""
  gfx.update()

  local ok, voice_text_or_error = run_voice_stt()
  if not ok then
    status = "Error"
    error_text = voice_text_or_error
    append_message(messages, "assistant", "Ошибка голоса: " .. voice_text_or_error)
    scroll_to_bottom = true
    return
  end

  local voice_text = trim(voice_text_or_error)
  if voice_text == "" then
    status = "Ready"
    append_message(messages, "assistant", "Не расслышал. Повтори ещё раз.")
    scroll_to_bottom = true
    return
  end

  input = voice_text
  send_prompt()
end

local function draw_rect(x, y, w, h, r, g, b, a)
  gfx.set(r, g, b, a)
  gfx.rect(x, y, w, h, 1)
end

local function draw_button(x, y, w, h, label, hot)
  draw_rect(x, y, w, h, hot and 0.18 or 0.12, 0.43, 0.95, 1)
  gfx.set(1, 1, 1, 1)
  local tw, th = gfx.measurestr(label)
  gfx.x = x + (w - tw) / 2
  gfx.y = y + (h - th) / 2
  gfx.drawstr(label)
end

local function point_in_rect(px, py, x, y, w, h)
  return px >= x and px <= x + w and py >= y and py <= y + h
end

local function clamp(value, min_value, max_value)
  if value < min_value then
    return min_value
  elseif value > max_value then
    return max_value
  end
  return value
end

local function decode_key(code)
  if code < 0 then
    return nil, true, false
  end
  if code == 0 then
    return nil, false, false
  end
  if (code >> 24) == string.byte("u") then
    return code & 0xFFFFFF, false, true
  end
  return code, false, false
end

local function pop_utf8_char(text)
  text = tostring(text or "")
  if text == "" then
    return ""
  end
  local len = utf8.len(text)
  if not len or len <= 0 then
    return ""
  end
  local pos = utf8.offset(text, len)
  if not pos or pos <= 1 then
    return ""
  end
  return text:sub(1, pos - 1)
end

local function handle_keyboard()
  local key_code = gfx.getchar()
  while key_code and key_code ~= 0 do
    local key, special, unicode_input = decode_key(key_code)
    if key == 13 or key == 10 then
      send_prompt()
    elseif key == 9 then
      -- ignore tab
    elseif key == 27 then
      should_quit = true
      return
    elseif key == 8 or key == 127 then
      if #input > 0 then
        input = pop_utf8_char(input)
      end
    elseif key and unicode_input then
      input = input .. utf8.char(key)
    elseif key and not special and key >= 32 and key <= 126 then
      input = input .. string.char(key)
    end
    key_code = gfx.getchar()
  end
end

local function wrap_text(text, max_width)
  local lines = {}
  for raw_line in (text .. "\n"):gmatch("(.-)\n") do
    if raw_line == "" then
      lines[#lines + 1] = ""
    else
      local current = ""
      for word in raw_line:gmatch("%S+") do
        local candidate = current == "" and word or (current .. " " .. word)
        if gfx.measurestr(candidate) > max_width and current ~= "" then
          lines[#lines + 1] = current
          current = word
        else
          current = candidate
        end
      end
      if current ~= "" then
        lines[#lines + 1] = current
      end
    end
  end
  return lines
end

local function layout_message(role, content, width)
  local wrapped = wrap_text(content or "", width - 18)
  local line_h = gfx.texth + 4
  return math.max(24, (#wrapped + 1) * line_h + 8), wrapped
end

local function draw_message(role, content, x, y, w)
  local bg_r, bg_g, bg_b = 0.18, 0.22, 0.28
  local label = "SYSTEM"

  if role == "user" then
    bg_r, bg_g, bg_b = 0.14, 0.39, 0.98
    label = "YOU"
  elseif role == "assistant" then
    bg_r, bg_g, bg_b = 0.13, 0.15, 0.19
    label = "AGENT"
  end

  draw_rect(x, y, w, select(1, layout_message(role, content, w)) - 2, bg_r, bg_g, bg_b, 1)
  gfx.setfont(1, "Arial", 12)
  gfx.set(1, 1, 1, 0.85)
  gfx.x = x + 10
  gfx.y = y + 8
  gfx.drawstr(label)

  gfx.setfont(1, "Arial", 13)
  gfx.set(1, 1, 1, 1)
  local _, wrapped = layout_message(role, content, w)
  local yy = y + 28
  for _, line in ipairs(wrapped) do
    gfx.x = x + 10
    gfx.y = yy
    gfx.drawstr(line)
    yy = yy + gfx.texth + 4
  end
end

local function loop()
  handle_keyboard()
  if should_quit then
    return
  end

  local w = gfx.w
  local h = gfx.h
  local mouse_x = gfx.mouse_x
  local mouse_y = gfx.mouse_y
  local mouse_cap = gfx.mouse_cap
  local mouse_wheel = gfx.mouse_wheel or 0
  local mouse_down = (mouse_cap & 1) == 1
  local mouse_pressed = mouse_down and not mouse_was_down
  mouse_was_down = mouse_down

  local pad = 12
  local header_h = 54
  local footer_h = 72
  local chat_x = pad
  local chat_y = pad + header_h + 10
  local chat_w = w - pad * 2
  local chat_h = h - (chat_y + footer_h + pad)
  local input_h = 32
  local input_y = h - pad - input_h
  local send_w = 64
  local button_gap = 6
  local input_w = w - pad * 2 - (send_w * 2) - button_gap

  if dock_guard_frames > 0 then
    enforce_right_dock()
    dock_guard_frames = dock_guard_frames - 1
  end

  if point_in_rect(mouse_x, mouse_y, chat_x, chat_y, chat_w, chat_h) and mouse_wheel ~= 0 then
    chat_scroll = chat_scroll - mouse_wheel * 38
  end

  draw_rect(0, 0, w, h, 0.07, 0.08, 0.10, 1)
  draw_rect(pad, pad, w - pad * 2, header_h, 0.10, 0.12, 0.15, 1)
  gfx.setfont(1, "Arial", 16)
  gfx.set(1, 1, 1, 1)
  gfx.x = 28
  gfx.y = 26
  gfx.drawstr("REAPER Agent")
  gfx.setfont(1, "Arial", 11)
  gfx.x = 28
  gfx.y = 46
  gfx.drawstr("Status: " .. status)
  gfx.x = w - 170
  gfx.y = 52
  gfx.drawstr(dock_state_is_right() and "Dock: Right" or "Dock: waiting")

  if error_text ~= "" then
    gfx.set(1, 0.55, 0.55, 1)
    gfx.x = 170
    gfx.y = 52
    gfx.drawstr(error_text)
  end

  gfx.setfont(1, "Arial", 13)
  draw_rect(chat_x, chat_y, chat_w, chat_h, 0.11, 0.13, 0.16, 1)
  draw_rect(chat_x + 1, chat_y + 1, chat_w - 2, chat_h - 2, 0.12, 0.14, 0.18, 1)

  local total_h = 0
  local layouts = {}
  for i = 1, #messages do
    local item = messages[i]
    local item_h = select(1, layout_message(item.role, item.content, chat_w - 24))
    layouts[i] = { role = item.role, content = item.content, height = item_h }
    total_h = total_h + item_h
  end

  local max_scroll = math.max(0, total_h - (chat_h - 24))
  if scroll_to_bottom then
    chat_scroll = max_scroll
    scroll_to_bottom = false
  end
  chat_scroll = clamp(chat_scroll, 0, max_scroll)

  local y_cursor = chat_y + 12 - chat_scroll
  for i = 1, #layouts do
    local item = layouts[i]
    local item_bottom = y_cursor + item.height
    if item_bottom >= chat_y + 8 and y_cursor <= chat_y + chat_h - 8 then
      draw_message(item.role, item.content, chat_x + 12, y_cursor, chat_w - 24)
    end
    y_cursor = y_cursor + item.height
  end

  draw_rect(pad, input_y, input_w, input_h, 0.15, 0.17, 0.20, 1)
  draw_rect(pad + 1, input_y + 1, input_w - 2, input_h - 2, 0.18, 0.20, 0.24, 1)
  gfx.setfont(1, "Arial", 13)
  gfx.set(1, 1, 1, 1)
  gfx.x = pad + 14
  gfx.y = input_y + 10
  gfx.drawstr(input == "" and "Напиши запрос здесь..." or input, 256, pad + input_w - 18, input_y + input_h - 6)

  local send_x = w - pad - send_w
  local send_y = input_y
  local send_h = input_h
  local voice_x = send_x - send_w - button_gap
  local voice_y = input_y
  local hover_send = point_in_rect(mouse_x, mouse_y, send_x, send_y, send_w, send_h)
  local hover_voice = point_in_rect(mouse_x, mouse_y, voice_x, voice_y, send_w, send_h)
  draw_button(send_x, send_y, send_w, send_h, "Send", hover_send)
  draw_button(voice_x, voice_y, send_w, send_h, "Voice", hover_voice)

  if mouse_pressed then
    if hover_send then
      send_prompt()
    elseif hover_voice then
      send_voice_prompt()
    end
  end

  gfx.update()
  reaper.defer(loop)
end

-- Prefer the right docker instead of the bottom panel.
-- gfx.dock state uses the docked flag plus a docker index; on this installation docker 1 is right-side.
if reaper and reaper.Dock_UpdateDockID then
  reaper.Dock_UpdateDockID(title, RIGHT_DOCK_ID)
end
gfx.init(title, 640, 360, RIGHT_DOCK_STATE, 100, 100)
if reaper and reaper.Dock_UpdateDockID then
  reaper.Dock_UpdateDockID(title, RIGHT_DOCK_ID)
end
gfx.dock(RIGHT_DOCK_STATE)
gfx.setfont(1, "Arial", 16)
dock_guard_frames = 180
loop()
