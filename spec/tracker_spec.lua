local tracker = require("zyt.tracker")
local rules = require("zyt.rules")

local clock = {
  iso = function(t)
    return "T" .. tostring(t)
  end,
}

local function fresh()
  return tracker.new(assert(rules.normalise({ defaultClass = "work" }, "/h")), clock)
end

describe("tracker.observe", function()
  it("opens with the default when nothing has been decided yet", function()
    local s = fresh()
    assert.is_nil(tracker.observe(s, 100, { app = "Finder" }))
    assert.same({ start = 100, class = "work", source = "default", app = "Finder", lastSeen = 100 }, s.open)
  end)

  it("closes and returns a row when the class changes", function()
    local s = fresh()
    tracker.observe(s, 100, { class = "work", source = "app", app = "Mail" })
    tracker.observe(s, 130, { class = "work", source = "app", app = "Mail" })
    local row = tracker.observe(s, 160, { class = "private", source = "app", app = "Spotify" })
    assert.same({ start = "T100", finish = "T160", seconds = 60, class = "work", source = "app", app = "Mail" }, row)
    assert.equals("private", s.open.class)
    assert.equals(160, s.open.start)
  end)

  it("keeps the class it knew when the rules have no opinion", function()
    local s = fresh()
    tracker.observe(s, 100, { class = "private", source = "app", app = "Spotify" })
    assert.is_nil(tracker.observe(s, 130, { app = "Finder" }))
    assert.equals("private", s.open.class)
    assert.equals("app", s.open.source)
  end)

  it("names the better source once a sticky segment is confirmed", function()
    local s = fresh()
    tracker.observe(s, 100, { app = "Finder" })
    assert.equals("default", s.open.source)
    tracker.observe(s, 115, { app = "Finder" })
    assert.equals("default", s.open.source)
    tracker.observe(s, 130, { class = "work", source = "app", app = "Mail" })
    assert.equals("app", s.open.source)
    assert.equals(100, s.open.start)
  end)

  it("ends the segment when the last input was, not when it noticed", function()
    local s = fresh()
    tracker.observe(s, 100, { class = "work", source = "app", app = "Mail" })
    local row = tracker.observe(s, 1000, { away = true, awaySince = 400 })
    assert.equals(300, row.seconds)
    assert.equals("T400", row.finish)
    assert.is_nil(s.open)
    assert.is_nil(tracker.observe(s, 1030, { away = true, awaySince = 430 }))
  end)

  it("drops a segment that ended before it started", function()
    local s = fresh()
    tracker.observe(s, 100, { class = "work", source = "app" })
    assert.is_nil(tracker.observe(s, 130, { away = true, awaySince = 50 }))
    assert.is_nil(s.open)
  end)

  it("comes back with the class it left with", function()
    local s = fresh()
    tracker.observe(s, 100, { class = "private", source = "app" })
    tracker.observe(s, 1000, { away = true, awaySince = 400 })
    tracker.observe(s, 2000, { app = "Finder" })
    assert.equals("private", s.open.class)
    assert.equals("sticky", s.open.source)
    assert.equals(2000, s.open.start)
  end)
end)

describe("tracker.presence", function()
  local function state(extra)
    local r = { idleSeconds = 600, noIdleApps = { ["Microsoft Teams"] = true } }
    for k, v in pairs(extra or {}) do
      r[k] = v
    end
    return { rules = r }
  end

  it("is present while there is input, and remembers when", function()
    local s = state()
    assert.same({ false }, { tracker.presence(s, 1000, { idle = 5, app = "Mail" }) })
    assert.equals(1000, s.presentUntil)
  end)

  it("is away from the last input once the idle threshold is passed", function()
    local s = state()
    tracker.presence(s, 1000, { idle = 5, app = "Mail" })
    assert.same({ true, 1300 }, { tracker.presence(s, 2000, { idle = 700, app = "Mail" }) })
  end)

  it("counts a call as present although nobody typed", function()
    local s = state()
    assert.same({ false }, { tracker.presence(s, 2000, { idle = 1800, app = "Microsoft Teams" }) })
    assert.equals(2000, s.presentUntil)
  end)

  it("ends the call where the call ended, not where it began", function()
    local s = state()
    tracker.presence(s, 1000, { idle = 0, app = "Microsoft Teams" })
    tracker.presence(s, 2000, { idle = 1000, app = "Microsoft Teams" })
    tracker.presence(s, 3700, { idle = 2700, app = "Microsoft Teams" })
    -- the call window closes, focus lands on Outlook with 45 idle minutes behind it
    assert.same({ true, 3700 }, { tracker.presence(s, 3710, { idle = 2710, app = "Microsoft Outlook" }) })
  end)

  it("stays present while a coding tool is working, until the screen locks", function()
    local s = state()
    tracker.presence(s, 1000, { idle = 0, app = "Code" })
    assert.same({ false }, { tracker.presence(s, 2000, { idle = 1000, app = "Code", working = true }) })
    assert.equals(2000, s.presentUntil)
    assert.same(
      { true, 2000 },
      { tracker.presence(s, 2100, { idle = 1100, app = "Code", working = true, locked = true }) }
    )
    assert.same({ true, 2000 }, { tracker.presence(s, 2200, { idle = 1200, app = "Code" }) })
  end)

  it("is away when locked or asleep, whatever the idle time", function()
    local s = state()
    assert.same({ true, 990 }, { tracker.presence(s, 1000, { idle = 10, app = "Mail", locked = true }) })
    assert.same({ true, 1000 }, { tracker.presence(s, 1000, { idle = 0, app = "Mail", asleep = true }) })
  end)
end)

describe("tracker.close", function()
  it("closes at the given time, or at the last sighting", function()
    local s = fresh()
    tracker.observe(s, 100, { class = "work", source = "app" })
    tracker.observe(s, 190, { class = "work", source = "app" })
    assert.equals(90, tracker.close(s).seconds)
    assert.is_nil(tracker.close(s))
    tracker.observe(s, 300, { class = "work", source = "app" })
    assert.equals("T333", tracker.close(s, 333).finish)
  end)
end)

describe("tracker.recover", function()
  it("turns a leftover open segment into a row ending at its last sighting", function()
    local s = fresh()
    local row = tracker.recover(s, { start = 10, lastSeen = 70, class = "work", source = "app", app = "Mail" })
    assert.same({ start = "T10", finish = "T70", seconds = 60, class = "work", source = "app", app = "Mail" }, row)
  end)

  it("ignores garbage", function()
    local s = fresh()
    assert.is_nil(tracker.recover(s, nil))
    assert.is_nil(tracker.recover(s, { start = "x" }))
    assert.is_nil(tracker.recover(s, { start = 1, lastSeen = 2 }))
    assert.is_nil(tracker.recover(s, { start = 5, lastSeen = 5, class = "work" }))
  end)
end)

describe("tracker.csv", function()
  it("writes one line and quotes an application name that needs it", function()
    local row = { start = "a", finish = "b", seconds = 5, class = "work", source = "app", app = 'Foo, "Bar"' }
    assert.equals('a,b,5,work,app,"Foo, ""Bar"""', tracker.csv(row))
    row.app = nil
    assert.equals("a,b,5,work,app,", tracker.csv(row))
    assert.equals("start,end,seconds,class,source,app", tracker.header)
  end)
end)
