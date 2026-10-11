local totals = require("zyt.totals")

local TEXT = table.concat({
  "start,end,seconds,class,source,app",
  "2026-09-14T08:00:00+02:00,2026-09-14T09:00:00+02:00,3600,work,app,Mail",
  "2026-09-14T09:00:00+02:00,2026-09-14T09:10:00+02:00,600,private,app,Spotify",
  "2026-09-15T08:00:00+02:00,2026-09-15T08:30:00+02:00,1800,work,app,Mail",
  "garbage",
  "2026-09-14T10:00:00+02:00,2026-09-14T10:05:00+02:00,300,unknown,app,X",
}, "\n")

describe("totals", function()
  it("sums the classes of one day and ignores what it cannot read", function()
    local rows = totals.parse(TEXT)
    assert.same({ work = 3600, private = 600 }, totals.forDay(rows, "2026-09-14"))
    assert.same({ work = 1800, private = 0 }, totals.forDay(rows, "2026-09-15"))
    assert.same({ work = 0, private = 0 }, totals.forDay(totals.parse(nil), "2026-09-14"))
  end)

  it("splits a row that runs past midnight between its two days", function()
    local rows = totals.parse(table.concat({
      "start,end,seconds,class,source,app",
      "2026-09-19T23:30:00+02:00,2026-09-20T00:30:00+02:00,3600,work,app,Mail",
      "2026-09-20T09:00:00+02:00,2026-09-20T09:10:00+02:00,600,private,app,Spotify",
    }, "\n"))
    assert.same({ work = 1800, private = 0 }, totals.forDay(rows, "2026-09-19"))
    assert.same({ work = 1800, private = 600 }, totals.forDay(rows, "2026-09-20"))
    assert.same({ work = 0, private = 0 }, totals.forDay(rows, "2026-09-21"))
  end)

  it("knows the day after, months and years included", function()
    assert.equals("2026-10-01", totals.nextDay("2026-09-30"))
    assert.equals("2027-01-01", totals.nextDay("2026-12-31"))
    assert.is_nil(totals.nextDay("garbage"))
  end)

  it("formats whole minutes", function()
    assert.equals("7h05", totals.format(25500))
    assert.equals("0h00", totals.format(59))
    assert.equals("0h00", totals.format(nil))
    assert.equals("0h00", totals.format(-5))
  end)
end)

describe("totals.forDay and two rows over one hour", function()
  it("counts an hour once, however many rows cover it", function()
    local rows = {
      { start = "2026-09-30T09:00:00+02:00", finish = "2026-09-30T10:00:00+02:00", seconds = 3600, class = "work" },
      { start = "2026-09-30T09:00:00+02:00", finish = "2026-09-30T10:00:00+02:00", seconds = 3600, class = "work" },
      { start = "2026-09-30T09:30:00+02:00", finish = "2026-09-30T11:00:00+02:00", seconds = 5400, class = "work" },
    }
    -- somebody at the keyboard in a meeting is doing both, and both are
    -- written; two hours of the day have passed, not three and a half
    assert.equal(7200, totals.forDay(rows, "2026-09-30").work)
  end)
end)

describe("totals.forDay and a private minute inside a meeting", function()
  it("counts it once, and as private", function()
    -- The calendar writes the meeting as one row from 09:00 to 11:00 and the
    -- keyboard writes the private half hour underneath it.
    local rows = totals.parse(table.concat({
      "start,end,seconds,class",
      "2026-09-14T09:00:00+02:00,2026-09-14T11:00:00+02:00,7200,work",
      "2026-09-14T09:40:00+02:00,2026-09-14T10:10:00+02:00,1800,private",
    }, "\n"))
    assert.same({ work = 5400, private = 1800 }, totals.forDay(rows, "2026-09-14"))
  end)

  it("leaves a day that was only private without any work in it", function()
    local rows = totals.parse(table.concat({
      "start,end,seconds,class",
      "2026-09-14T20:00:00+02:00,2026-09-14T22:00:00+02:00,7200,private",
    }, "\n"))
    assert.same({ work = 0, private = 7200 }, totals.forDay(rows, "2026-09-14"))
  end)
end)
