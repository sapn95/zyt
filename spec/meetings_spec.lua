local meetings = require("zyt.meetings")

local SETTINGS = { statuses = { "busy", "oof", "tentative" }, minimumSeconds = 300, class = "work" }

local function event(start, finish, over)
  local out = { start = start, finish = finish, status = "busy", response = "accepted" }
  for key, value in pairs(over or {}) do
    out[key] = value
  end
  return out
end

describe("meetings.counts", function()
  it("takes the hours somebody actually sat through", function()
    assert.is_true(meetings.counts(SETTINGS, event(100, 200)))
    assert.is_true(meetings.counts(SETTINGS, event(100, 200, { status = "oof" })))
    assert.is_true(meetings.counts(SETTINGS, event(100, 200, { response = "organizer" })))
  end)

  it("leaves out what was no hour in a room", function()
    -- said no: somebody else's meeting
    assert.is_false(meetings.counts(SETTINGS, event(100, 200, { response = "declined" })))
    -- called off, marked free, or a marker across the whole day
    assert.is_false(meetings.counts(SETTINGS, event(100, 200, { cancelled = true })))
    assert.is_false(meetings.counts(SETTINGS, event(100, 200, { status = "free" })))
    -- and free stays out even when a rules file lists it
    assert.is_false(meetings.counts({ statuses = { "free" } }, event(100, 200, { status = "free" })))
    assert.is_false(meetings.counts(SETTINGS, event(100, 200, { allDay = true })))
    -- a status the rules do not name, and no event at all
    assert.is_false(meetings.counts(SETTINGS, event(100, 200, { status = "workingElsewhere" })))
    assert.is_false(meetings.counts(SETTINGS, nil))
  end)
end)

describe("meetings.fill", function()
  it("cuts a meeting to the gap at both ends", function()
    local out = meetings.fill(SETTINGS, 1000, 2000, { event(500, 1500), event(1600, 3000) })
    assert.same({ { start = 1000, finish = 1500, seconds = 500 }, { start = 1600, finish = 2000, seconds = 400 } }, out)
  end)

  it("makes one stretch of meetings that run into each other", function()
    local out = meetings.fill(SETTINGS, 0, 10000, { event(1000, 2000), event(2000, 3000), event(2500, 4000) })
    -- what goes into the record is time, not meetings: two rows that touch
    -- would be read as one anyway
    assert.same({ { start = 1000, finish = 4000, seconds = 3000 } }, out)
  end)

  it("keeps the order the day had", function()
    local out = meetings.fill(SETTINGS, 0, 10000, { event(5000, 6000), event(1000, 2000) })
    assert.equal(1000, out[1].start)
    assert.equal(5000, out[2].start)
  end)

  it("drops a sliver, and counts two short ones that add up", function()
    -- a minute of a meeting at the edge of the gap is not worth a row
    assert.same({}, meetings.fill(SETTINGS, 0, 60, { event(0, 3600) }))
    -- but two five-minute meetings back to back are ten minutes of the day
    local out = meetings.fill(SETTINGS, 0, 10000, { event(0, 300), event(300, 600) })
    assert.same({ { start = 0, finish = 600, seconds = 600 } }, out)
  end)

  it("leaves out an event that is missing a moment", function()
    -- a start nobody wrote would otherwise be read as zero, clamped to the
    -- start of the gap, and cover everything up to the other moment
    local broken = { status = "busy", response = "accepted", ["end"] = 9000 }
    assert.same({}, meetings.fill(SETTINGS, 1000, 8000, { broken }))
    assert.same({}, meetings.fill(SETTINGS, 1000, 8000, { { status = "busy", start = 2000 } }))
    assert.same({}, meetings.fill(SETTINGS, 1000, 8000, { event("noon", 9000) }))
  end)

  it("writes whole seconds, whatever the calendar answered in", function()
    local out = meetings.fill(SETTINGS, 1000.25, 9000.75, { event(1000.25, 5000.5) })
    assert.same({ { start = 1000, finish = 5000, seconds = 4000 } }, out)
    assert.equal(math.floor(out[1].seconds), out[1].seconds)
  end)

  it("has nothing to say about a gap no meeting touches", function()
    assert.same({}, meetings.fill(SETTINGS, 0, 100, {}))
    assert.same({}, meetings.fill(SETTINGS, 0, 100, nil))
    assert.same({}, meetings.fill(SETTINGS, 5000, 6000, { event(1000, 2000) }))
  end)
end)

describe("meetings.moment", function()
  it("reads back the time a row was written with", function()
    local when = os.time({ year = 2026, month = 9, day = 30, hour = 13, min = 5, sec = 0 })
    assert.equal(when, meetings.moment(os.date("%Y-%m-%dT%H:%M:%S%z", when)))
  end)

  it("takes the offset the row carries, not the zone the machine is in", function()
    -- the same instant, written three ways: whichever zone this test runs in,
    -- a row means what its own offset says it means
    assert.equal(1790766300, meetings.moment("2026-09-30T13:05:00+02:00"))
    assert.equal(1790766300, meetings.moment("2026-09-30T13:05:00+0200"))
    assert.equal(1790766300, meetings.moment("2026-09-30T11:05:00Z"))
    -- and west of Greenwich the sign has to go the other way
    assert.equal(1768480200, meetings.moment("2026-01-15T07:30:00-05:00"))
  end)

  it("reads a row without an offset as local time, having nothing else", function()
    local when = os.time({ year = 2026, month = 9, day = 30, hour = 13, min = 5, sec = 0 })
    assert.equal(when, meetings.moment("2026-09-30T13:05:00"))
  end)

  it("says nothing about what is no row", function()
    assert.is_nil(meetings.moment("yesterday"))
    assert.is_nil(meetings.moment(nil))
  end)
end)

describe("meetings.gaps", function()
  local function row(fromHour, toHour)
    local function stamp(hour)
      return os.date(
        "%Y-%m-%dT%H:%M:%S%z",
        os.time({ year = 2026, month = 9, day = 30, hour = hour, min = 0, sec = 0 })
      )
    end
    return { start = stamp(fromHour), finish = stamp(toHour) }
  end

  local function hour(h)
    return os.time({ year = 2026, month = 9, day = 30, hour = h, min = 0, sec = 0 })
  end

  it("finds what the record says nothing about", function()
    local out = meetings.gaps({ row(8, 9), row(11, 12) }, hour(7), hour(13), 300)
    assert.same({
      { start = hour(7), finish = hour(8) },
      { start = hour(9), finish = hour(11) },
      { start = hour(12), finish = hour(13) },
    }, out)
  end)

  it("sorts what was written out of order", function()
    -- a gap filled in after the fact is appended, so the file is no longer in
    -- the order the day happened
    local out = meetings.gaps({ row(11, 12), row(8, 9) }, hour(8), hour(12), 300)
    assert.same({ { start = hour(9), finish = hour(11) } }, out)
  end)

  it("takes a row that overlaps the one before it as cover, not as a gap", function()
    local out = meetings.gaps({ row(8, 11), row(9, 10) }, hour(8), hour(12), 300)
    assert.same({ { start = hour(11), finish = hour(12) } }, out)
  end)

  it("leaves out what is shorter than the least worth filling", function()
    assert.same({}, meetings.gaps({ row(8, 9) }, hour(8), hour(9), 300))
    local out = meetings.gaps({ row(8, 9), row(9, 10) }, hour(8), hour(10), 300)
    assert.same({}, out)
  end)

  it("says the whole window when nothing was recorded in it", function()
    assert.same({ { start = hour(8), finish = hour(12) } }, meetings.gaps({}, hour(8), hour(12), 300))
  end)
end)

describe("meetings.sync", function()
  local function stamp(hour, minute)
    return os.date(
      "%Y-%m-%dT%H:%M:%S%z",
      os.time({ year = 2026, month = 9, day = 30, hour = hour, min = minute or 0, sec = 0 })
    )
  end

  local function at(hour, minute)
    return os.time({ year = 2026, month = 9, day = 30, hour = hour, min = minute or 0, sec = 0 })
  end

  local function line(fromHour, toHour, source)
    return ("%s,%s,%d,work,%s,calendar"):format(stamp(fromHour), stamp(toHour), (toHour - fromHour) * 3600, source)
  end

  local SET = { statuses = { "busy" }, minimumSeconds = 300, class = "work" }

  local function meeting(fromHour, toHour)
    return { start = at(fromHour), ["end"] = at(toHour), status = "busy", response = "accepted" }
  end

  it("reads the rows back with the source they carry", function()
    local rows =
      meetings.rows("start,end,seconds,class,source,app\n" .. line(9, 10, "meeting") .. "\n" .. line(11, 12, "app"))
    assert.equal(2, #rows)
    assert.equal("meeting", rows[1].source)
    assert.equal(at(11), rows[2].start)
  end)

  it("writes what is missing and takes out what the calendar no longer says", function()
    local rows = meetings.rows(line(9, 10, "meeting") .. "\n" .. line(14, 15, "meeting"))
    -- the calendar still has the morning one and has lost the afternoon one
    local add, drop = meetings.sync(SET, rows, { meeting(9, 10), meeting(16, 17) }, at(8), at(18), at(18))
    assert.same({ { start = at(16), finish = at(17), seconds = 3600 } }, add)
    assert.equal(1, #drop)
    assert.equal(at(14), drop[1].start)
  end)

  it("never touches a row the tracker wrote itself", function()
    local rows = meetings.rows(line(9, 10, "app"))
    local add, drop = meetings.sync(SET, rows, {}, at(8), at(18), at(18))
    assert.same({}, add)
    assert.same({}, drop)
  end)

  it("leaves the hours the tracker recorded to the tracker", function()
    -- a meeting the person sat through at the keyboard is already in the
    -- record, and the calendar does not get to write it a second time
    local rows = meetings.rows(line(9, 10, "app"))
    local add = meetings.sync(SET, rows, { meeting(9, 10) }, at(8), at(18), at(18))
    assert.same({}, add)
  end)

  it("books nothing that has not happened yet", function()
    local add = meetings.sync(SET, {}, { meeting(9, 10), meeting(16, 17) }, at(8), at(20), at(12))
    -- the window reaches forward so that a meeting which moved can be found,
    -- not so that tomorrow can be booked
    assert.same({ { start = at(9), finish = at(10), seconds = 3600 } }, add)
  end)

  it("leaves a row that reaches outside the window alone", function()
    local rows = meetings.rows(line(7, 9, "meeting"))
    local _, drop = meetings.sync(SET, rows, {}, at(8), at(18), at(18))
    assert.same({}, drop)
  end)
end)

describe("meetings.sync and a row written twice", function()
  local function at(h)
    return os.time({ year = 2026, month = 9, day = 29, hour = h, min = 0, sec = 0 })
  end

  local function line(fromHour, toHour, seconds)
    local stamp = function(h)
      return os.date("%Y-%m-%dT%H:%M:%S%z", at(h))
    end
    return ("%s,%s,%s,work,meeting,calendar"):format(stamp(fromHour), stamp(toHour), seconds)
  end

  it("keeps one of two rows that say the same hour", function()
    -- the same hour written twice is the hour counted twice, and the two can
    -- look different: one of them came from a version that wrote fractions
    local rows = meetings.rows(line(9, 10, "3600") .. "\n" .. line(9, 10, "3600.0"))
    local events = { { start = at(9), ["end"] = at(10), status = "busy", response = "accepted" } }
    local add, drop = meetings.sync(
      { statuses = { "busy" }, minimumSeconds = 300, class = "work" },
      rows,
      events,
      at(8),
      at(18),
      at(18)
    )
    assert.same({}, add)
    assert.equal(1, #drop)
  end)
end)
