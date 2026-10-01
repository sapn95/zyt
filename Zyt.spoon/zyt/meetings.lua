--- The hours a calendar can account for and the tracker cannot: a meeting sat
--- through with the notebook shut, where there is no window to look at and no
--- keystroke to count. Pure: it is handed a gap, the events around it and the
--- rules, and it answers with the stretches of that gap a meeting covered.
local M = {}

--- An answer that means the person said they would not be there.
local DECLINED = "declined"

--- What the calendar calls time that is not taken.
local FREE = "free"

--- The source a row written from the calendar carries.
M.SOURCE = "meeting"
local MEETING = M.SOURCE

--- Days from 1970-01-01 to a calendar date, by Howard Hinnant's civil
--- algorithm. `os.time` would do this too, but it reads the fields as local
--- time, and a row carries the offset it was written with.
local function daysFromCivil(year, month, day)
  year = month <= 2 and year - 1 or year
  local era = math.floor(year / 400)
  local yearOfEra = year - era * 400
  local dayOfYear = math.floor((153 * (month + (month > 2 and -3 or 9)) + 2) / 5) + day - 1
  local dayOfEra = yearOfEra * 365 + math.floor(yearOfEra / 4) - math.floor(yearOfEra / 100) + dayOfYear
  return era * 146097 + dayOfEra - 719468
end

--- Whether an event is time somebody spent. A cancelled meeting did not
--- happen, an all-day entry is a marker rather than an hour in a room, `free`
--- says so itself, and a meeting turned down is somebody else's.
function M.counts(settings, event)
  if type(event) ~= "table" or event.cancelled or event.allDay then
    return false
  end
  -- `free` is the calendar saying the time is not taken, whatever a rules file
  -- lists. An entry somebody marked free is a note to themselves.
  if event.status == FREE then
    return false
  end
  if event.response == DECLINED then
    return false
  end
  for _, status in ipairs(settings.statuses or {}) do
    if event.status == status then
      return true
    end
  end
  return false
end

--- The stretches of `from` to `to` that a meeting covered, in order, merged
--- where they meet and cut to the gap at both ends.
---
--- Merged, because what goes into the record is time and not meetings: two that
--- run back to back are one stretch of the afternoon, and two rows that touch
--- would only be read as one anyway. Anything shorter than `minimumSeconds` is
--- left out after the merge, so two five-minute meetings in a row still count
--- while a five-minute sliver of one at the edge of the gap does not.
function M.fill(settings, from, to, events)
  local pieces = {}
  for _, event in ipairs(events or {}) do
    if M.counts(settings, event) then
      -- An event without both moments is no stretch of the day. Reading a
      -- missing one as zero would clamp it to the start of the gap and cover
      -- everything up to the other end.
      local begins = tonumber(event.start)
      local ends = tonumber(event.finish or event["end"])
      if begins and ends then
        -- Whole seconds: the calendar answers in fractions of one, and a row
        -- that says 6074.0 is a row somebody has to read twice.
        local start = math.floor(math.max(begins, from))
        local finish = math.floor(math.min(ends, to))
        if finish > start then
          pieces[#pieces + 1] = { start = start, finish = finish }
        end
      end
    end
  end
  table.sort(pieces, function(a, b)
    if a.start == b.start then
      return a.finish < b.finish
    end
    return a.start < b.start
  end)
  local merged = {}
  for _, piece in ipairs(pieces) do
    local last = merged[#merged]
    if last and piece.start <= last.finish then
      if piece.finish > last.finish then
        last.finish = piece.finish
      end
    else
      merged[#merged + 1] = { start = piece.start, finish = piece.finish }
    end
  end
  local out = {}
  local least = tonumber(settings.minimumSeconds) or 0
  for _, piece in ipairs(merged) do
    local seconds = piece.finish - piece.start
    if seconds >= least then
      out[#out + 1] = { start = piece.start, finish = piece.finish, seconds = seconds }
    end
  end
  return out
end

--- The rows of the file as they were written, each with the line it came from,
--- so that a file can be written back without touching a row this does not
--- understand. The last field holds the application and may be quoted, which
--- is why only the five before it are cut off.
function M.rows(text)
  local out = {}
  for line in (text or ""):gmatch("[^\n]+") do
    local start, finish, seconds, class, source = line:match("^([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),")
    if start and start ~= "start" then
      out[#out + 1] = {
        line = line,
        start = M.moment(start),
        finish = M.moment(finish),
        seconds = tonumber(seconds),
        class = class,
        source = source,
      }
    end
  end
  return out
end

--- What the record and the calendar disagree about in a window: the meeting
--- rows to write, and the ones to take out.
---
--- The calendar is the authority for its own hours and for nothing else. A
--- meeting that moved, was shortened or called off leaves a row behind that is
--- no longer true, and the only way to say so is to take it out again. Rows the
--- tracker wrote itself are never touched, and neither is a meeting row that
--- reaches outside the window, since nothing here knows what the calendar says
--- about the time around it.
---
--- Nothing is written for time that has not happened: a meeting in the diary
--- for tomorrow is not an hour anybody has worked. The window reaches forward
--- so that what moved into it can be recognised, not so that it can be booked.
function M.sync(settings, rows, events, from, to, now)
  local upTo = math.min(to, now)
  local keep, current = {}, {}
  for _, row in ipairs(rows) do
    if row.start and row.finish then
      local inside = row.start >= from and row.finish <= to
      if row.source == MEETING and inside then
        current[#current + 1] = row
      elseif row.finish > from and row.start < upTo then
        keep[#keep + 1] = { start = row.start, finish = row.finish }
      end
    end
  end
  local wanted = {}
  for _, hole in ipairs(M.gaps(keep, from, upTo, settings.minimumSeconds)) do
    for _, piece in ipairs(M.fill(settings, hole.start, hole.finish, events)) do
      wanted[#wanted + 1] = piece
    end
  end
  local have, want = {}, {}
  for _, row in ipairs(current) do
    have[row.start .. ":" .. row.finish] = row
  end
  for _, piece in ipairs(wanted) do
    want[piece.start .. ":" .. piece.finish] = true
  end
  local add, drop = {}, {}
  for _, piece in ipairs(wanted) do
    if not have[piece.start .. ":" .. piece.finish] then
      add[#add + 1] = piece
    end
  end
  for key, row in pairs(have) do
    if not want[key] then
      drop[#drop + 1] = row
    end
  end
  table.sort(drop, function(a, b)
    return a.start < b.start
  end)
  return add, drop
end

--- The stretches of `from` to `to` that the record says nothing about, longest
--- first in time order. A gap is where the tracker was not running or nobody
--- was at the keyboard: the places a calendar can account for.
---
--- Rows arrive in the order they were written, which is not the order they
--- happened once a gap has been filled in after the fact, so they are sorted.
--- A row that overlaps the one before it moves the edge of the covered time
--- forward rather than opening a gap behind it.
function M.gaps(rows, from, to, minimum)
  local spans = {}
  for _, row in ipairs(rows or {}) do
    -- A row read from the file carries stamps; one that has already been read
    -- carries seconds. Both are rows, and this is the one place that has to
    -- know it.
    local start = M.moment(row.start) or tonumber(row.start)
    local finish = M.moment(row.finish) or tonumber(row.finish)
    if start and finish and finish > start and finish > from and start < to then
      spans[#spans + 1] = { start = start, finish = finish }
    end
  end
  table.sort(spans, function(a, b)
    return a.start < b.start
  end)
  local out = {}
  local reach = from
  local least = tonumber(minimum) or 0
  for _, span in ipairs(spans) do
    if span.start - reach >= least then
      out[#out + 1] = { start = reach, finish = span.start }
    end
    if span.finish > reach then
      reach = span.finish
    end
  end
  if to - reach >= least then
    out[#out + 1] = { start = reach, finish = to }
  end
  return out
end

--- The moment a written row says, as seconds.
---
--- The offset the row carries is what decides it, not the zone this machine is
--- in now. They are the same until somebody travels or the clocks go back: an
--- hour that happens twice is two different instants with two different
--- offsets, and reading the fields as local time would make them one. A row
--- from before there were offsets, or one written by hand, is read as local
--- time because there is nothing else to read it as.
function M.moment(iso)
  if type(iso) ~= "string" then
    return nil
  end
  local year, month, day, hour, minute, second = iso:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not year then
    return nil
  end
  year, month, day = tonumber(year), tonumber(month), tonumber(day)
  hour, minute, second = tonumber(hour), tonumber(minute), tonumber(second)
  local sign, offsetHours, offsetMinutes = iso:match("([+-])(%d%d):?(%d%d)$")
  if not sign and not iso:match("Z$") then
    return os.time({ year = year, month = month, day = day, hour = hour, min = minute, sec = second })
  end
  local offset = 0
  if sign then
    offset = (tonumber(offsetHours) * 3600 + tonumber(offsetMinutes) * 60) * (sign == "-" and -1 or 1)
  end
  return daysFromCivil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second - offset
end

return M
