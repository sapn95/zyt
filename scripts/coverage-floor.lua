-- A coverage number that is reported but not enforced is a number that goes
-- down. The floor lives here, in the repository, rather than in the workflow.
local FLOOR = 85
local REPORT = arg[1] or "luacov.report.out"

local file = io.open(REPORT, "r")
if not file then
  io.stderr:write(("no coverage report at %s — run `busted --coverage` and `luacov` first\n"):format(REPORT))
  os.exit(1)
end
local contents = file:read("a")
file:close()

local total = contents:match("\nTotal%s+%d+%s+%d+%s+([%d%.]+)%%")
if not total then
  io.stderr:write(("could not find the total in %s\n"):format(REPORT))
  os.exit(1)
end

local percent = tonumber(total)
if percent < FLOOR then
  io.stderr:write(("coverage %.2f%% is below the floor of %d%%\n"):format(percent, FLOOR))
  os.exit(1)
end
io.write(("coverage %.2f%%, floor %d%%\n"):format(percent, FLOOR))
