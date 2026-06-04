local resource = reaper.GetResourcePath()
local script_path = resource .. "/Scripts/REAPER Agent/reaper_chat_agent.lua"

local ok, err = pcall(dofile, script_path)
if not ok then
  reaper.ShowConsoleMsg("REAPER Agent startup failed: " .. tostring(err) .. "\n")
end
