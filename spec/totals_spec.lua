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

  it("formats whole minutes", function()
    assert.equals("7h05", totals.format(25500))
    assert.equals("0h00", totals.format(59))
    assert.equals("0h00", totals.format(nil))
    assert.equals("0h00", totals.format(-5))
  end)
end)
