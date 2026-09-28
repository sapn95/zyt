--- A chat's own name, out of the transcript the tool keeps. Pure: it is handed
--- the end of that file as text and answers with the lines worth decoding, in
--- the order they should be tried. Decoding them is the adapter's business,
--- because the file is JSON and the core has no JSON in it.
local M = {}

--- What can name a chat, in the order it counts. A name the person typed in
--- themselves is the name they read in their own list, whatever the tool has
--- called the conversation since. Failing both, the last thing typed into it
--- says which chat this is as well as anything.
local KINDS = {
  { pattern = '"type"%s*:%s*"custom%-title"', key = "customTitle" },
  { pattern = '"type"%s*:%s*"ai%-title"', key = "aiTitle" },
  { pattern = '"type"%s*:%s*"last%-prompt"', key = "lastPrompt" },
}

--- The lines that can name this chat: `keep` of each kind at the outside,
--- newest of each kind first, the kinds in the order above. Each comes with the
--- field to read out of it once it has been decoded.
---
--- More than one of a kind, because a line can be half written. The file is
--- being appended to while it is read, and the slice taken from the end of a
--- long one starts in the middle of a line as well: either way the line before
--- it is the answer, and only the decoder can tell which is which.
function M.naming(text, keep)
  local out = {}
  if type(text) ~= "string" then
    return out
  end
  keep = keep or 3
  local lines = {}
  for line in text:gmatch("[^\n]+") do
    lines[#lines + 1] = line
  end
  for _, kind in ipairs(KINDS) do
    local found = 0
    for index = #lines, 1, -1 do
      if found >= keep then
        break
      end
      if lines[index]:find(kind.pattern) then
        found = found + 1
        out[#out + 1] = { line = lines[index], key = kind.key }
      end
    end
  end
  return out
end

return M
