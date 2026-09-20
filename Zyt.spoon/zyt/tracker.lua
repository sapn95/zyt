--- The segment state machine: which class the clock is running against, since
--- when, and the rows that come out when it stops. Pure; time and the clock's
--- formatting are handed in.
local M = {}

M.header = "start,end,seconds,class,source,app"

local function field(value)
  value = tostring(value or "")
  if value:find('[,"\n]') then
    return '"' .. (value:gsub('"', '""')) .. '"'
  end
  return value
end

--- One CSV line for a closed row.
function M.csv(row)
  return table.concat({
    row.start,
    row.finish,
    tostring(row.seconds),
    row.class,
    row.source,
    field(row.app),
  }, ",")
end

function M.new(rules, clock)
  return { rules = rules, clock = clock, open = nil, last = nil, presentUntil = nil }
end

--- Whether anybody is here, and since when not.
---   obs.idle    seconds since the last input
---   obs.app     the frontmost application
---   obs.locked  the screen is locked
---   obs.asleep  the machine is asleep
--- Idle time counts from the last input, but time in front of an application
--- in `noIdleApps` counts as present, so a call that ends with the focus
--- elsewhere is not wiped out by the idle minutes it contained: away starts
--- at the last input or at the last moment the person was seen present,
--- whichever is later.
function M.presence(state, now, obs)
  local rules = state.rules
  local idle = math.floor(obs.idle or 0)
  local idleAway = idle >= rules.idleSeconds and not rules.noIdleApps[obs.app or ""]
  if not (obs.locked or obs.asleep or idleAway) then
    state.presentUntil = now
    return false, nil
  end
  local since = now - idle
  if state.presentUntil and state.presentUntil > since then
    since = state.presentUntil
  end
  return true, math.min(since, now)
end

local function row(state, segment, finish)
  local seconds = finish - segment.start
  if seconds <= 0 then
    return nil
  end
  return {
    start = state.clock.iso(segment.start),
    finish = state.clock.iso(finish),
    seconds = seconds,
    class = segment.class,
    source = segment.source,
    app = segment.app,
  }
end

--- Close the open segment at `at` (its last sighting when not given). Returns
--- the row, or nil when there was nothing open or nothing worth a row.
function M.close(state, at)
  local open = state.open
  if not open then
    return nil
  end
  state.open = nil
  return row(state, open, at or open.lastSeen)
end

--- One observation at `now`:
---   obs.away       nobody is here: locked, asleep, or idle past the threshold
---   obs.awaySince  when that started, so the idle minutes are not counted
---   obs.class      what the rules decided, or nil when they did not
---   obs.source     where that decision came from
---   obs.app        the frontmost application, kept on the row for reading back
--- Returns a closed row when this observation ended a segment.
function M.observe(state, now, obs)
  if obs.away then
    return M.close(state, math.min(now, obs.awaySince or now))
  end
  local class, source = obs.class, obs.source
  if not class then
    class = state.last or state.rules.defaultClass
    source = state.last and "sticky" or "default"
  end
  state.last = class

  local closed
  local open = state.open
  if open and open.class ~= class then
    closed = M.close(state, now)
    open = nil
  end
  if open then
    open.lastSeen = now
    local inherited = source == "sticky" or source == "default"
    if not inherited and (open.source == "sticky" or open.source == "default") then
      open.source = source
    end
  else
    state.open = { start = now, class = class, source = source, app = obs.app, lastSeen = now }
  end
  return closed
end

--- What a Hammerspoon that stopped without closing left behind: the segment it
--- had open, ended at the last tick that saw it.
function M.recover(state, open)
  if type(open) ~= "table" or type(open.start) ~= "number" or type(open.lastSeen) ~= "number" then
    return nil
  end
  if type(open.class) ~= "string" then
    return nil
  end
  return row(state, open, open.lastSeen)
end

return M
