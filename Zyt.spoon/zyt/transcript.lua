--- A chat's own name, out of the transcript the tool keeps. Pure: it is handed
--- the end of that file as text and answers with the lines worth decoding,
--- newest first. Decoding them is the adapter's business, because the file is
--- JSON and the core has no JSON in it.
local M = {}

--- The two lines of a transcript that can name the chat: the newest `ai-title`
--- entry, which is what the tool calls the conversation and rewrites as it goes
--- on, and the newest `last-prompt` entry, which is the last thing typed into
--- it and says as much about which chat this is. Either can be missing, and a
--- chat nobody has spoken to twice has neither.
---
--- Read backwards, because the newest entry is the one that counts. The first
--- line of a slice taken from the end of a long file is half a line, and there
--- is nothing to do about that but let it fail to decode.
function M.newest(text)
  if type(text) ~= "string" then
    return nil, nil
  end
  local lines = {}
  for line in text:gmatch("[^\n]+") do
    lines[#lines + 1] = line
  end
  local title, prompt
  for index = #lines, 1, -1 do
    local line = lines[index]
    if not title and line:find('"type"%s*:%s*"ai%-title"') then
      title = line
    end
    if not prompt and line:find('"type"%s*:%s*"last%-prompt"') then
      prompt = line
    end
    if title and prompt then
      break
    end
  end
  return title, prompt
end

return M
