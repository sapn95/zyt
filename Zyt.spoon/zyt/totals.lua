--- The per-class seconds of one day, from the rows already written. The menu
--- shows this; the report on the command line does the rest.
local M = {}

--- Rows from the CSV text; the header and anything malformed are skipped.
function M.parse(text)
  local rows = {}
  for line in (text or ""):gmatch("[^\n]+") do
    local start, finish, seconds, class = line:match("^([^,]*),([^,]*),([^,]*),([^,]*)")
    if start and start ~= "start" then
      rows[#rows + 1] = { start = start, finish = finish, seconds = tonumber(seconds) or 0, class = class }
    end
  end
  return rows
end

--- Seconds per class for the rows that start on `day` (YYYY-MM-DD).
function M.forDay(rows, day)
  local out = { work = 0, private = 0 }
  for _, r in ipairs(rows) do
    if r.start:sub(1, 10) == day and out[r.class] then
      out[r.class] = out[r.class] + r.seconds
    end
  end
  return out
end

--- 7h05 for 25500 seconds. Whole minutes; nobody books seconds.
function M.format(seconds)
  seconds = math.max(0, math.floor(seconds or 0))
  return ("%dh%02d"):format(seconds // 3600, (seconds % 3600) // 60)
end

return M
