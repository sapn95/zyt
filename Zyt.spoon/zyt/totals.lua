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
--- A list of `{from, to}` merged into the stretches it covers, in order. Two
--- rows over the same minute are one stretch: somebody at the keyboard in a
--- meeting is doing both, and the record says both.
local function merge(spans)
  table.sort(spans, function(a, b)
    return a[1] < b[1]
  end)
  local out = {}
  for _, span in ipairs(spans) do
    local last = out[#out]
    if last and span[1] <= last[2] then
      last[2] = math.max(last[2], span[2])
    else
      out[#out + 1] = { span[1], span[2] }
    end
  end
  return out
end

--- The seconds a list of merged stretches covers.
local function total(stretches)
  local sum = 0
  for _, stretch in ipairs(stretches) do
    sum = sum + (stretch[2] - stretch[1])
  end
  return sum
end

--- `stretches` with every second of `holes` taken out of them. Both merged
--- and in order, as `merge` gives them back.
local function without(stretches, holes)
  local out = {}
  for _, stretch in ipairs(stretches) do
    local cursor = stretch[1]
    for _, hole in ipairs(holes) do
      if hole[2] > cursor and hole[1] < stretch[2] then
        if hole[1] > cursor then
          out[#out + 1] = { cursor, hole[1] }
        end
        cursor = math.max(cursor, hole[2])
      end
      if cursor >= stretch[2] then
        break
      end
    end
    if cursor < stretch[2] then
      out[#out + 1] = { cursor, stretch[2] }
    end
  end
  return out
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
  -- A minute spent privately is not a work minute, whatever else says it is.
  -- The calendar writes a meeting as one row and the keyboard goes on
  -- recording underneath it, so a private message answered in a meeting
  -- arrives as both. The menu says the same thing the report does.
  local private = merge(spans.private)
  return { work = total(without(merge(spans.work), private)), private = total(private) }
end

--- 7h05 for 25500 seconds. Whole minutes; nobody books seconds.
function M.format(seconds)
  seconds = math.max(0, math.floor(seconds or 0))
  return ("%dh%02d"):format(seconds // 3600, (seconds % 3600) // 60)
end

return M
