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

local function clock(iso)
  local h, m, s = iso:match("T(%d%d):(%d%d):(%d%d)")
  if not h then
    return 0
  end
  return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
end

--- The calendar day after `day` (YYYY-MM-DD), or nil for a malformed day.
function M.nextDay(day)
  local y, m, d = day:match("^(%d+)%-(%d+)%-(%d+)$")
  if not y then
    return nil
  end
  local noon = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
  return os.date("%Y-%m-%d", noon + 86400)
end

--- Seconds per class that fall on `day` (YYYY-MM-DD). A row that runs past
--- midnight is split: the part before it belongs to its start day, the rest
--- to the day after, which is how the report counts too.
--- The union of a list of `{from, to}`, in seconds. Two rows that cover the
--- same minute are not two minutes: somebody at the keyboard in a meeting is
--- doing both, and the record says both.
local function union(spans)
  table.sort(spans, function(a, b)
    return a[1] < b[1]
  end)
  local total, reach = 0, nil
  for _, span in ipairs(spans) do
    local from, to = span[1], span[2]
    if not reach or from > reach then
      total = total + (to - from)
      reach = to
    elseif to > reach then
      total = total + (to - reach)
      reach = to
    end
  end
  return total
end

function M.forDay(rows, day)
  local spans = { work = {}, private = {} }
  for _, r in ipairs(rows) do
    if spans[r.class] then
      local startDay = r.start:sub(1, 10)
      local from = clock(r.start)
      local untilMidnight = 86400 - from
      if startDay == day then
        spans[r.class][#spans[r.class] + 1] = { from, from + math.min(r.seconds, untilMidnight) }
      elseif r.seconds > untilMidnight and M.nextDay(startDay) == day then
        spans[r.class][#spans[r.class] + 1] = { 0, math.min(r.seconds - untilMidnight, 86400) }
      end
    end
  end
  return { work = union(spans.work), private = union(spans.private) }
end

--- 7h05 for 25500 seconds. Whole minutes; nobody books seconds.
function M.format(seconds)
  seconds = math.max(0, math.floor(seconds or 0))
  return ("%dh%02d"):format(seconds // 3600, (seconds % 3600) // 60)
end

return M
