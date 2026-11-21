--- The hours a calendar can account for and the tracker cannot: a meeting sat
--- through with the notebook shut, where there is no window to look at and no
--- keystroke to count. Pure: it is handed a gap, the events around it and the
--- rules, and it answers with the stretches of that gap a meeting covered.
local M = {}

--- An answer that means the person said they would not be there.
local DECLINED = "declined"

--- What the calendar calls time that is not taken.
local FREE = "free"

--- What the calendar calls time somebody is away.
local OOF = "oof"

--- The answer of an invitation nobody has answered. It says nothing about
--- whether the hour was spent in the room, so it is not taken as a yes.
local UNANSWERED = "notResponded"

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
  if event.response == DECLINED or event.response == UNANSWERED then
    return false
  end
  for _, status in ipairs(settings.statuses or {}) do
    if event.status == status then
      return true
    end
  end
  return false
end

local function listed(settings, status)
  for _, each in ipairs(settings.statuses or {}) do
    if each == status then
      return true
    end
  end
  return false
end

--- The stretches somebody marked themselves away for in the day, an
--- out-of-office block such as an appointment. A meeting inside one was not
--- sat through, so its hours are cut out again. Only while the rules leave
--- `oof` out of `statuses`: a rules file that lists it says that an away block
--- is work, and then nothing is cut.
local function away(settings, events)
  local out = {}
  if listed(settings, OOF) then
    return out
  end
  for _, event in ipairs(events or {}) do
    if
      type(event) == "table"
      and event.status == OOF
      and not event.cancelled
      and not event.allDay
      and event.response ~= DECLINED
    then
      local begins = tonumber(event.start)
      local ends = tonumber(event.finish or event["end"])
      if begins and ends and ends > begins then
        out[#out + 1] = { start = begins, finish = ends }
      end
    end
  end
  return out
end

local function cut(pieces, holes)
  for _, hole in ipairs(holes) do
    local kept = {}
    for _, piece in ipairs(pieces) do
      if hole.finish <= piece.start or hole.start >= piece.finish then
        kept[#kept + 1] = piece
      else
        if piece.start < hole.start then
          kept[#kept + 1] = { start = piece.start, finish = math.floor(hole.start) }
        end
        if hole.finish < piece.finish then
          kept[#kept + 1] = { start = math.ceil(hole.finish), finish = piece.finish }
        end
      end
    end
    pieces = kept
  end
  return pieces
end

--- The stretches of `from` to `to` that a meeting covered, in order, merged
--- where they meet and cut to the window at both ends.
---
--- What the calendar says, not what is left of it: an hour in a meeting is an
--- hour in a meeting whether or not somebody typed during it. Keeping the two
--- apart is what lets a day show both, and the arithmetic takes the union so
--- that neither is counted twice.
---
--- Merged, because two meetings that run back to back are one stretch of the
--- afternoon. Anything shorter than `minimumSeconds` is left out after the
--- merge, so two five-minute meetings in a row still count while a sliver of
--- one at the edge of the window does not.
function M.wanted(settings, from, to, events)
  local pieces = {}
  for _, event in ipairs(events or {}) do
    if M.counts(settings, event) then
      -- An event without both moments is no stretch of the day.
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
  merged = cut(merged, away(settings, events))
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
--- A meeting is written whether or not the tracker was recording through it.
--- Somebody at the keyboard in a meeting is doing both, and a record that had
--- to choose would be wrong about one of them. What stops the hour from being
--- counted twice is the arithmetic, which takes the union of the hours of a
--- class rather than their sum.
---
--- Nothing is written for time that has not happened: a meeting in the diary
--- for tomorrow is not an hour anybody has worked. The window reaches forward
--- so that what moved into it can be recognised, not so that it can be booked.
function M.sync(settings, rows, events, from, to, now)
  local upTo = math.min(to, now)
  local current = {}
  for _, row in ipairs(rows) do
    if row.start and row.finish and row.source == MEETING and row.start >= from and row.finish <= to then
      current[#current + 1] = row
    end
  end
  local wanted = M.wanted(settings, from, upTo, events)
  local have, want = {}, {}
  local double = {}
  for _, row in ipairs(current) do
    local key = row.start .. ":" .. row.finish
    if have[key] then
      -- The same hour written twice is the hour counted twice. One of them is
      -- the row; the rest go, whatever the calendar says about that time.
      double[#double + 1] = row
    else
      have[key] = row
    end
  end
  for _, piece in ipairs(wanted) do
    want[piece.start .. ":" .. piece.finish] = true
  end
  local add, drop = {}, double
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

local function dateParts(text)
  if type(text) ~= "string" then
    return nil
  end
  local year, month, day = text:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
  if not year then
    return nil
  end
  return tonumber(year), tonumber(month), tonumber(day)
end

--- The dates from `first` up to and not including `last`, both `YYYY-MM-DD`,
--- counted on the calendar rather than in seconds, so no zone can move them.
local function datesBetween(first, last)
  local out = {}
  local year, month, day = dateParts(first)
  if not year or not dateParts(last) then
    return out
  end
  local days = daysFromCivil(year, month, day)
  local y2, m2, d2 = dateParts(last)
  local stop = daysFromCivil(y2, m2, d2)
  while days < stop do
    out[#out + 1] = os.date("!%Y-%m-%d", days * 86400)
    days = days + 1
  end
  return out
end

--- The days an all-day out-of-office entry covers, as `YYYY-MM-DD`, sorted.
--- Such a day is a day off: the proposal leaves it its own hours and gives it
--- none from the rest of the week. The command line hands over the calendar
--- dates as Graph wrote them, and those are used when they are there. Without
--- them each day is read at the noon of the moment, which gives the same date
--- for a UTC midnight and for a local one.
function M.daysOff(events)
  local seen, out = {}, {}
  for _, event in ipairs(events or {}) do
    if
      type(event) == "table"
      and event.allDay
      and event.status == OOF
      and not event.cancelled
      and event.response ~= DECLINED
    then
      local dates = {}
      if dateParts(event.startDate) and dateParts(event.endDate) then
        dates = datesBetween(event.startDate, event.endDate)
      else
        local begins = tonumber(event.start)
        local ends = tonumber(event.finish or event["end"])
        if begins and ends then
          local at = begins + 43200
          while at < ends do
            dates[#dates + 1] = os.date("!%Y-%m-%d", at)
            at = at + 86400
          end
        end
      end
      for _, day in ipairs(dates) do
        if not seen[day] then
          seen[day] = true
          out[#out + 1] = day
        end
      end
    end
  end
  table.sort(out)
  return out
end

--- The days off known before a sync, brought into line with the ones the
--- calendar gave for the window `from` to `to`: a day inside the window is
--- whatever the calendar now says, a day outside it is kept as it was.
function M.mergeDaysOff(known, found, from, to)
  -- `to` is the first moment after the window, so the last day is the one
  -- the second before it falls on: a window that ends at midnight does not
  -- reach into the next day.
  local first, last = os.date("%Y-%m-%d", from), os.date("%Y-%m-%d", to - 1)
  local seen, out = {}, {}
  local function add(day)
    if type(day) == "string" and day:match("^%d%d%d%d%-%d%d%-%d%d$") and not seen[day] then
      seen[day] = true
      out[#out + 1] = day
    end
  end
  for _, day in ipairs(known or {}) do
    if type(day) == "string" and (day < first or day > last) then
      add(day)
    end
  end
  for _, day in ipairs(found or {}) do
    add(day)
  end
  table.sort(out)
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
