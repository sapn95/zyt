--- === Zyt ===
---
--- Work or private: a menu-bar clock that knows which one is running. Every
--- half minute, and whenever another application comes to the front, it looks
--- at the frontmost window, asks the rules, and keeps the answer as a segment.
--- Locks, sleep and idle time end a segment; the rows go to a CSV that
--- `zyt week` turns into a booking proposal.
---
--- Everything that decides anything lives in `zyt/` and is tested there. This
--- file is the adapter: Hammerspoon on one side, those modules on the other.

local obj = {}
obj.__index = obj

obj.name = "Zyt"
obj.version = "0.1.0"
obj.author = "Sebastian Winterberger"
obj.license = "MIT"
obj.homepage = "https://github.com/sapn95/zyt"

obj.spoonPath = debug.getinfo(1, "S").source:match("^@(.*/)")
package.path = obj.spoonPath .. "?.lua;" .. obj.spoonPath .. "?/init.lua;" .. package.path

local rules = require("zyt.rules")
local classify = require("zyt.classify")
local repo = require("zyt.repo")
local tracker = require("zyt.tracker")
local totals = require("zyt.totals")
local learned = require("zyt.learned")
local meetings = require("zyt.meetings")
local transcript = require("zyt.transcript")

local HOME = os.getenv("HOME")

local function xdg(variable, fallback)
  local value = os.getenv(variable)
  if value and value ~= "" then
    return value
  end
  return HOME .. fallback
end

--- Zyt.configPath
--- Variable
--- The rules file. Set it before `:start()` to move it.
obj.configPath = xdg("XDG_CONFIG_HOME", "/.config") .. "/zyt/rules.json"

--- Zyt.statePath
--- Variable
--- Where the rows, the open segment and the tools' context notes live.
obj.statePath = xdg("XDG_STATE_HOME", "/.local/state") .. "/zyt"

--- Zyt.cli
--- Variable
--- The command the menu runs for the report: the checkout's own script when
--- the Spoon is linked from one, otherwise whatever `zyt` is on the PATH.
obj.cli = "zyt"

--- Zyt.cwdOf
--- Variable
--- Per application, a function that returns its working directory, for the
--- terminals whose title does not say. iTerm2 is answered over AppleScript.
obj.cwdOf = nil

--- Zyt.paneOf
--- Variable
--- Per application, a function that returns the id of the pane it has in front,
--- matched against the pane a chat says it was opened in. iTerm2 is answered
--- over AppleScript; a terminal that keeps that to itself is left out and its
--- chats are told apart by what they work on
--- ([ADR 0012](../docs/adr/0012-the-pane-in-front-is-the-chat.md)).
obj.paneOf = nil

obj.logger = hs.logger.new("zyt", "info")
obj.running = false
obj.override = nil
obj.locked = false
obj.asleep = false

--- Per application, the chat the person said they were in, and when they said
--- it. In memory only: it is an answer about this afternoon, not a rule.
obj.chosen = {}

--- Per application, the class the person named when they were asked whose time
--- it was, and when they named it. In memory only, and dropped as soon as
--- anything newer says where they are: it is an answer about this hour.
obj.said = {}

--- Per session, the name its transcript gave it and where that file is. In
--- memory only, and reread from time to time: a name moves with the
--- conversation it is about.
obj.titles = {}

--- Where the coding tool keeps its transcripts, one directory per checkout a
--- session was started in.
obj.transcripts = HOME .. "/.claude/projects"

-- ---------------------------------------------------------------------------
-- Files

local function readFile(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local text = file:read("a")
  file:close()
  return text
end

local function readJSON(path)
  local text = readFile(path)
  if not text then
    return nil
  end
  local ok, decoded = pcall(hs.json.decode, text)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

local function ensureDirectory(path)
  local built = ""
  for part in path:gmatch("[^/]+") do
    built = built .. "/" .. part
    if not hs.fs.attributes(built, "mode") then
      hs.fs.mkdir(built)
    end
  end
end

local function writeAtomically(path, contents)
  local temporary = path .. ".tmp"
  local file, err = io.open(temporary, "w")
  if not file then
    return nil, err
  end
  file:write(contents)
  file:close()
  return os.rename(temporary, path)
end

local function appendLine(path, line, header)
  local size = hs.fs.attributes(path, "size") or 0
  local file, err = io.open(path, "a")
  if not file then
    return nil, err
  end
  if size == 0 then
    file:write(header, "\n")
  end
  file:write(line, "\n")
  file:close()
  return true
end

local function isoLocal(t)
  local zone = os.date("%z", t)
  return os.date("%Y-%m-%dT%H:%M:%S", t) .. zone:sub(1, 3) .. ":" .. zone:sub(4, 5)
end

local clock = { iso = isoLocal }

function obj:complain(message)
  self.logger.e(message)
  hs.alert.show("zyt: " .. message, 4)
end

-- ---------------------------------------------------------------------------
-- Rules

function obj:loadRules()
  local raw = {}
  local text = readFile(self.configPath)
  if text then
    local ok, decoded = pcall(hs.json.decode, text)
    if ok and type(decoded) == "table" then
      raw = decoded
    else
      self:complain("the rules file is not valid JSON: " .. self.configPath)
    end
  end
  local normalised, err = rules.normalise(raw, HOME)
  if not normalised then
    self:complain(err)
    normalised = rules.normalise({}, HOME)
  end
  self.rules = normalised
  if self.state then
    self.state.rules = normalised
  end
  if self.running then
    self:armTimer()
  end
end

function obj:armTimer()
  if self.timer then
    self.timer:stop()
  end
  self.timer = hs.timer.doEvery(self.rules.tickSeconds, function()
    self:tick()
  end)
end

-- ---------------------------------------------------------------------------
-- Observing

local function focused()
  local window = hs.window.focusedWindow()
  local app = window and window:application() or hs.application.frontmostApplication()
  return app and app:name() or "", window and window:title() or "", app and app:bundleID() or nil
end

local function idleIsShort(idle)
  return type(idle) == "number" and idle < 120
end

local COLOURS = {
  work = { red = 0.20, green = 0.45, blue = 0.85 },
  private = { red = 0.55, green = 0.35, blue = 0.75 },
  other = { red = 0.35, green = 0.35, blue = 0.38 },
}

-- How many chats the panel offers at once: longer than an editor is ever asked
-- about, shorter than the screen the panel hangs from. `classify.chatChoices`
-- keeps a chat of each class in the list when it has to cut one.
local MAX_CHAT_CHOICES = 8

-- How much of a transcript is read to find the name a chat goes by, and how
-- long that answer is kept before the file is read again. The name changes as a
-- conversation goes on, and a chat that has just started has none yet.
--
-- The tool rewrites the name on every exchange, so the end of the file is where
-- it is. Measured over the seventeen transcripts on this machine that carry a
-- name somebody typed in: the newest of them sat 28.9 KB from the end at the
-- worst, in a file of 37 MB, always within a hundred bytes of the newest name
-- the tool made up. A quarter of a megabyte is that with room to spare, and a
-- name that fell out of it would come back on the next exchange.
local TRANSCRIPT_TAIL = 256 * 1024
local TITLE_SECONDS = 300

-- How many lines of a kind are worth trying. The newest is the answer unless it
-- was half written when it was read, and the one before it is then.
local TITLE_TRIES = 3

-- How much of a chat's name one row holds. Measured rather than guessed: the
-- panel is 420 points wide, and at 13 point a row of fifty characters ends
-- about fifteen points short of its own edge.
local CHAT_LABEL_CHARS = 50

-- The row that answers nothing. A session id is a UUID, so this cannot be one.
local LATER = "zyt:later"

--- The last part of a remote's path, which is what people call a repository.
local function shortRepo(remote)
  if type(remote) ~= "string" then
    return "?"
  end
  return (remote:gsub("%.git$", "")):match("([^/:]+)$") or remote
end

--- The repository a remote names, with its owner when the remote gives one. In
--- a list of chats the owner is often the whole answer: two checkouts of the
--- same name under different owners are a reason to be asked at all.
local function repoLabel(remote)
  if type(remote) ~= "string" then
    return "?"
  end
  local path = remote:gsub("%.git$", "")
  return path:match("([^/:]+/[^/]+)$") or shortRepo(remote)
end

local function applescript(script)
  local ok, out = hs.osascript.applescript(script)
  if ok and type(out) == "string" and out ~= "" then
    return out
  end
  return nil
end

local function iterm2Path()
  return applescript(
    'tell application "iTerm2" to tell current session of current window to get variable named "session.path"'
  )
end

--- Which pane of iTerm2 is in front, by the same id it puts in the environment
--- of every shell it opens there. A chat opened in that pane wrote the id into
--- its note, so the two meet and the chat in front is known (ADR 0012).
local function iterm2Pane()
  return applescript('tell application "iTerm2" to tell current session of current window to get unique ID')
end

function obj:note(name)
  local decoded = readJSON(self.statePath .. "/" .. name .. ".json")
  if not decoded or type(decoded.at) ~= "number" then
    return nil
  end
  return {
    age = os.time() - decoded.at,
    at = decoded.at,
    remote = decoded.remote,
    source = decoded.source,
    bundle = decoded.bundle,
    pane = decoded.pane,
  }
end

--- The last note any tool left: what some session is working on right now.
function obj:signal()
  return self:note("context")
end

--- The last prompt the person typed: the chat they are talking to.
function obj:chat()
  return self:note("chat")
end

--- Every chat that has been typed into, one note per session, newest prompt
--- first. A session that has only ever worked is not a chat anybody is looking
--- at and has no `promptAt`, so it is left out here; the busy sessions are what
--- `signal` is for.
---
--- The shared note counts too, for as long as nothing hosted in the same
--- application has spoken for the same prompt: a prompt that carries no session
--- id of its own leaves only that one, and dropping it would hand the window to
--- some other application's session. An older session note of that application
--- is a different chat and does not speak for it.
--- A session id, if it is one: it becomes part of a path, and what is in the
--- note came from a file somebody else wrote.
local function isSessionName(session)
  return type(session) == "string" and session:match("^[%w][%w%.%-_]*$") ~= nil
end

--- The transcript of one session, wherever the tool filed it. The directory is
--- named after where the session started, which is not where it ended up
--- working, so the directories are searched rather than worked out.
local function transcriptPath(root, session)
  local ok, iterator, directoryObject = pcall(hs.fs.dir, root)
  if not ok or not iterator then
    return nil
  end
  for name in iterator, directoryObject do
    if name ~= "." and name ~= ".." then
      local candidate = ("%s/%s/%s.jsonl"):format(root, name, session)
      if hs.fs.attributes(candidate, "mode") == "file" then
        return candidate
      end
    end
  end
  return nil
end

--- The name a chat has given itself, out of the end of its transcript: what the
--- tool calls the conversation, or failing that the last thing typed into it.
--- The core picks the lines and this decodes them, because they are JSON.
local function titleIn(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local size = file:seek("end")
  file:seek("set", math.max(0, size - TRANSCRIPT_TAIL))
  local text = file:read("a")
  file:close()
  for _, candidate in ipairs(transcript.naming(text, TITLE_TRIES)) do
    local ok, decoded = pcall(hs.json.decode, candidate.line)
    if ok and type(decoded) == "table" then
      local named = decoded[candidate.key]
      -- A name of nothing but spaces is no name: it would take the place of the
      -- one underneath it and leave the row with nothing to say.
      if type(named) == "string" and named:match("%S") then
        return named
      end
    end
  end
  return nil
end

--- What a chat calls itself, for the rows of a list of them. The hook writes it
--- into the note on every prompt, and this is for the notes that have none: a
--- chat that has been read but not typed into since the Spoon last started, and
--- every note written before there were titles. Found once and kept for
--- `TITLE_SECONDS`, because the name moves with the conversation.
function obj:titleOf(session, now)
  if not isSessionName(session) then
    return nil
  end
  local found = self.titles[session]
  -- An answer about another directory of transcripts is no answer about this
  -- one, and the path it holds is a path in there.
  if found and found.root ~= self.transcripts then
    found = nil
  end
  if found and now - found.at < TITLE_SECONDS then
    return found.title
  end
  local path = (found and found.path) or transcriptPath(self.transcripts, session)
  local title = path and titleIn(path) or nil
  if not title and path then
    -- The path it had is where the file was. A session that came back under
    -- another directory, or one whose transcript has been tidied away, is worth
    -- looking for again rather than being nameless from here on.
    local again = transcriptPath(self.transcripts, session)
    if again and again ~= path then
      path = again
      title = titleIn(again)
    end
  end
  self.titles[session] = { root = self.transcripts, path = path, title = title, at = now }
  return title
end

function obj:chats()
  local directory = self.statePath .. "/sessions"
  local out = {}
  local now = os.time()
  -- The iterator needs the directory object it comes with; called without it,
  -- it raises "directory metatable expected, got nil" on the first step. A
  -- directory that is not there at all is what the pcall is for.
  local ok, iterator, directoryObject = pcall(hs.fs.dir, directory)
  if ok and iterator then
    for name in iterator, directoryObject do
      if name:sub(-5) == ".json" then
        local decoded = readJSON(directory .. "/" .. name)
        if decoded and type(decoded.promptAt) == "number" then
          -- A note too old to be a chat is not worth a file to read.
          local fresh = decoded.source == "claude-code" and now - decoded.promptAt <= self.rules.chatSeconds
          out[#out + 1] = {
            age = now - decoded.promptAt,
            promptAt = decoded.promptAt,
            promptOrder = decoded.promptOrder,
            remote = decoded.remote,
            -- The note first, since the hook wrote it at the prompt and it
            -- costs nothing; the transcript for the chats that have not been
            -- typed into since.
            title = decoded.title or (fresh and self:titleOf(decoded.session, now)) or nil,
            source = decoded.source,
            bundle = decoded.bundle,
            pane = decoded.pane,
            session = decoded.session,
          }
        end
      end
    end
  end
  local shared = self:chat()
  if shared then
    local spokenFor = false
    for _, chat in ipairs(out) do
      spokenFor = spokenFor or (chat.bundle == shared.bundle and chat.promptAt >= shared.at)
    end
    if not spokenFor then
      shared.promptAt = shared.at
      out[#out + 1] = shared
    end
  end
  table.sort(out, function(a, b)
    return a.promptAt > b.promptAt
  end)
  return out
end

function obj:observe(now)
  local app, title, bundle = focused()
  local idle = hs.host.idleTime()
  local signal = self:signal()
  local away, awaySince = tracker.presence(self.state, now, {
    idle = idle,
    app = app,
    locked = self.locked,
    asleep = self.asleep,
    working = signal ~= nil and signal.age <= self.rules.signalSeconds,
  })
  if away then
    return { away = true, awaySince = awaySince, app = app }
  end
  -- Looked at while a pin is running too. A pin says whose time it is and
  -- nothing else, and the menu is built from what was last seen: it names the
  -- answer it offers to forget and lists the chats of the window in front, and
  -- both would otherwise be whatever happened to be there when the pin went on.
  local obs, key, remote = self:look(app, title, bundle, idle, signal)
  if self.override then
    return { class = self.override, source = "manual", app = app }
  end
  local class, source, unsure = classify.decide(self.rules, obs)
  self:askWhose(now, obs, unsure)
  if not class then
    class, source = self:recall(now, obs, key, remote)
  end
  return { class = class, source = source, app = app }
end

--- What is in front, in the shape the pure core reads, plus the key an answer
--- about it would be filed under and the repository it is about. `seen` is
--- brought up to date on the way, because the menu is put together between
--- ticks out of whatever was seen last.
function obj:look(app, title, bundle, idle, signal)
  local cwdOf = self.cwdOf[app]
  local paneOf = self.paneOf[app]
  local chats = self:chats()
  local obs = {
    app = app,
    bundle = bundle,
    title = title,
    idle = idle,
    cwd = cwdOf and cwdOf() or nil,
    pane = paneOf and paneOf() or nil,
    signal = signal,
    chats = chats,
    chosen = self:stillChosen(bundle, chats),
    said = self:stillSaid(bundle, chats),
    resolve = self.resolve,
  }
  local key, remote = self:about(obs)
  local inPane = classify.paneChat(self.rules, obs)
  self.seen = {
    app = app,
    bundle = bundle,
    chats = classify.liveChats(self.rules, obs),
    inPane = inPane and inPane.session or nil,
    key = key,
    about = remote and shortRepo(remote) or app,
  }
  return obs, key, remote
end

--- What an answer about the window in front would be filed under, and the
--- repository it is about when there is one. Worked out on every tick and not
--- only when a question is due, because the menu offers to forget this one
--- answer and has to be able to say whose it is.
function obj:about(obs)
  local remote
  if self.rules.apps[obs.app or ""] == "repo" then
    remote = classify.repositoryOf(self.rules, obs)
  end
  return learned.key(remote, obs.app), remote
end

--- The cooldown on asking which chat somebody is in is per application, the
--- same as the chat they named, so that forgetting one answer clears both.
local CHAT_PREFIX = "chat:"

local function chatKey(bundle)
  return CHAT_PREFIX .. (bundle or "")
end

local function isChatKey(key)
  return type(key) == "string" and key:sub(1, #CHAT_PREFIX) == CHAT_PREFIX
end

--- When a prompt was sent, as closely as the note can say. The second a prompt
--- and an answer share cannot put them in order, and which came first is what
--- decides whether the answer still stands. A note from before the hook wrote
--- the moment has its second and nothing better.
local function promptMoment(chat)
  return chat.promptOrder or chat.promptAt or 0
end

--- The chat the person named for this application, while that choice still
--- stands. Typing into another one of them replaces it: they have said where
--- they are by saying something there. Only the chats of this application can
--- do that. A prompt typed in the other editor says nothing about which panel
--- is in front here.
function obj:stillChosen(bundle, chats)
  local at = bundle or ""
  local choice = self.chosen[at]
  if not choice then
    return nil
  end
  for _, chat in ipairs(chats) do
    if chat.bundle == bundle and chat.session ~= choice.session and promptMoment(chat) > choice.at then
      self.chosen[at] = nil
      return nil
    end
  end
  return choice.session
end

--- The class the person named for this application, while that answer still
--- stands. A prompt in one of its chats replaces it: typing says where they are
--- more plainly than an answer given a while ago, and the chat typed into is
--- what the class comes from again.
function obj:stillSaid(bundle, chats)
  local at = bundle or ""
  local answer = self.said[at]
  if not answer then
    return nil
  end
  for _, chat in ipairs(chats) do
    if chat.bundle == bundle and promptMoment(chat) > answer.at then
      self.said[at] = nil
      return nil
    end
  end
  return answer.class
end

--- Zyt:say(bundle, class)
--- Method
--- Take the person's word for whose time this is, for as long as nothing newer
--- says otherwise. Not written down: the same editor is work in one hour and
--- private in the next, which is why the question comes back at all.
function obj:say(bundle, class)
  self.said[bundle or ""] = { class = class, at = hs.timer.secondsSinceEpoch() }
  -- A question that was answered has not been spent. It is asked again as soon
  -- as nothing can tell whose time it is, which is the whole of the bargain.
  self.asked[chatKey(bundle)] = nil
  self:dismiss()
  self:tick()
end

--- Zyt:choose(bundle, session)
--- Method
--- Take the person's word for which of the chats open in an application they
--- are in. Nothing on screen can say: the editor's accessibility tree does not
--- expose its panels.
function obj:choose(bundle, session)
  self.chosen[bundle or ""] = { session = session, at = hs.timer.secondsSinceEpoch() }
  self:dismiss()
  self:tick()
end

--- What the person answered the last time this window came up, or a fresh
--- question when nothing is known yet. Nil while the answer is pending: the
--- tracker keeps whatever was running (ADR 0002).
function obj:recall(now, obs, key, remote)
  local answer = learned.lookup(self.learned, key)
  if answer == "work" or answer == "private" then
    return answer, "learned"
  end
  if answer == nil and key and self.rules.prompt.enabled and idleIsShort(obs.idle) then
    if learned.due(self.asked, key, now, self.rules.prompt.cooldownSeconds) then
      local shown = self:ask("whose time is this?", remote and repoLabel(remote) or obs.app, {
        { id = "work", label = "Work", colour = COLOURS.work },
        { id = "private", label = "Private", colour = COLOURS.private },
        { id = "inherit", label = "Don't ask", colour = COLOURS.other },
      }, function(id)
        self:answer(key, id)
      end, key)
      -- The cooldown counts from a question somebody saw. Another panel being
      -- up already is not an answer, and next tick is soon enough to try again.
      if shown then
        self.asked[key] = now
      end
    end
  end
  return nil
end

--- Several chats are open in this application, they are not all of one class,
--- and nothing on screen says which of them is being read. The question put to
--- the person is not which chat that is: the answer to that is a list of
--- conversations to read at a glance, and it asks them to do the classifying.
--- It is the question zyt needs answered, whose time this is, and the answer
--- holds until something newer says otherwise.
---
--- Called on every tick, whether the question is open or not: `unsure` says it
--- is, and the panel belongs to this method either way.
function obj:askWhose(now, obs, unsure)
  -- Keyed the way the answer itself is, by the application hosting the chats,
  -- so that forgetting one clears both.
  local key = chatKey(obs.bundle)
  local standing = self.prompt ~= nil and self.prompt.about == key
  -- A question about the chats of one application is a question about the
  -- window in front. With another application there it cannot change what is
  -- being recorded, and a chat it was about may have ended while it stood: it
  -- goes, and the cooldown stays, because a question somebody saw and walked
  -- away from is the Later row by other means.
  if not standing and self.prompt and isChatKey(self.prompt.about) then
    self:dismiss()
  end
  if not unsure then
    -- The question has stopped being one. Somebody typed into one of the chats,
    -- named a pane or answered it, and a panel left standing is asking for an
    -- answer that has been given.
    if standing then
      self:dismiss()
    end
    return
  end
  if not self.rules.prompt.enabled then
    return
  end
  -- A panel standing for this question is kept current, and neither gate below
  -- holds it back. Somebody at the keyboard and a cooldown are what it takes to
  -- ask; keeping one honest while it waits takes nothing.
  if not standing then
    if not idleIsShort(obs.idle) then
      return
    end
    if not learned.due(self.asked, key, now, self.rules.prompt.cooldownSeconds) then
      return
    end
  end
  -- How many chats disagree is why this is being asked, and saying so is what
  -- tells this panel apart from the one about a repository nobody knows.
  local open = #classify.chatChoices(self.rules, obs, MAX_CHAT_CHOICES)
  local shown = self:ask("whose time is this?", ("%s · %d chats"):format(obs.app or "?", open), {
    { id = "work", label = "Work", colour = COLOURS.work },
    { id = "private", label = "Private", colour = COLOURS.private },
    { id = LATER, label = "Later", colour = COLOURS.other },
  }, function(id)
    if id == LATER then
      self:dismiss()
    else
      self:say(obs.bundle, id)
    end
  end, key)
  -- The cooldown counts from a question somebody saw, and Later is what spends
  -- it. An answer gives it back, in `say`.
  if shown then
    self.asked[key] = now
  end
end

-- ---------------------------------------------------------------------------
-- Answers

function obj:loadLearned()
  self.learned = {}
  self.asked = {}
  local text = readFile(self.statePath .. "/learned.json")
  if text then
    local ok, decoded = pcall(hs.json.decode, text)
    if ok and type(decoded) == "table" then
      self.learned = decoded
    end
  end
end

function obj:saveLearned()
  writeAtomically(self.statePath .. "/learned.json", hs.json.encode(self.learned, true))
end

--- Zyt:forget([key, bundle])
--- Method
--- Drop one answer, or all of them. With a `key` it is the answer filed under
--- that key, and with it the chat named for `bundle` and the cooldowns on both:
--- those are answers about the same window, and forgetting one while keeping the
--- other would leave it classified by whichever was kept. With no arguments
--- every answer goes.
function obj:forget(key, bundle)
  if key then
    self.learned[key] = nil
    self.asked[key] = nil
    self.chosen[bundle or ""] = nil
    self.said[bundle or ""] = nil
    self.asked[chatKey(bundle)] = nil
    self:saveLearned()
  else
    self.learned = {}
    self.asked = {}
    self.chosen = {}
    self.said = {}
    os.remove(self.statePath .. "/learned.json")
  end
  self:tick()
end

--- Zyt:ask(headline, what, choices, answered, about)
--- Method
--- A small panel under the menu bar, one row per choice, each
--- `{ id, label, colour, class }`, `class` naming what the colour stands for
--- where it can change under one id. It stays until it is answered, and nothing
--- changes while it is up. `about` is the key the question is about; a question that
--- loses the panel to another one has its cooldown dropped, so it can be asked
--- again. Returns true when it showed: one panel is up at a time, and a question
--- that lost the place was never asked.
function obj:ask(headline, what, choices, answered, about)
  if #choices == 0 then
    return false
  end
  -- What is being asked: the key, and every row the way it will be drawn. The
  -- id alone is not the row. A session that moved to another checkout keeps its
  -- id and changes both name and colour, and the panel would go on offering the
  -- repository it left.
  local asking = { tostring(about) }
  for _, choice in ipairs(choices) do
    asking[#asking + 1] = table.concat({ tostring(choice.id), tostring(choice.label), tostring(choice.class) }, "\t")
  end
  local question = table.concat(asking, "\n")
  if self.prompt then
    -- The same question again leaves the panel where it is. Anything else takes
    -- the place: nothing clears a panel on a timer any more, so a question left
    -- standing about a window nobody is at would otherwise be the last one ever
    -- asked, and a chat opened since belongs in the list it is offering.
    if self.prompt.question == question then
      return false
    end
    -- The question that loses the panel keeps its turn. Its cooldown was spent
    -- on a panel nobody answered, and half an hour is a long time to hold a
    -- window against an answer it never got.
    if self.prompt.about ~= nil then
      self.asked[self.prompt.about] = nil
    end
    self:dismiss()
  end
  local screen = hs.screen.mainScreen():frame()
  -- A row each, the full width of the panel. Side by side the rows shared the
  -- width between them, and a repository name is longer than a third of 380
  -- points: the labels were cut off before they could be read.
  local w, pad, row, gap, top = 420, 14, 30, 6, 52
  local h = top + #choices * row + (#choices - 1) * gap + pad
  local canvas = hs.canvas.new({ x = screen.x + screen.w - w - 12, y = screen.y + 6, w = w, h = h })
  canvas:appendElements({
    type = "rectangle",
    action = "fill",
    fillColor = { red = 0.13, green = 0.13, blue = 0.15, alpha = 0.96 },
    roundedRectRadii = { xRadius = 10, yRadius = 10 },
  }, {
    type = "text",
    text = "zyt · " .. headline,
    textSize = 12,
    textColor = { white = 0.7 },
    frame = { x = pad, y = 8, w = w - 2 * pad, h = 18 },
  }, {
    type = "text",
    text = what or "",
    textSize = 14,
    textColor = { white = 1 },
    frame = { x = pad, y = 26, w = w - 2 * pad, h = 22 },
  })
  for index, choice in ipairs(choices) do
    local y = top + (index - 1) * (row + gap)
    canvas:appendElements({
      id = choice.id,
      type = "rectangle",
      action = "fill",
      frame = { x = pad, y = y, w = w - 2 * pad, h = row },
      fillColor = { white = 1, alpha = 0.1 },
      roundedRectRadii = { xRadius = 6, yRadius = 6 },
      trackMouseUp = true,
    }, {
      -- The class is still the blue and the purple of the board and the
      -- menu bar, now a dot beside the name instead of the whole button.
      type = "rectangle",
      action = "fill",
      frame = { x = pad + 9, y = y + 10, w = 11, h = 11 },
      fillColor = choice.colour,
      roundedRectRadii = { xRadius = 3, yRadius = 3 },
    }, {
      type = "text",
      text = choice.label,
      textSize = 13,
      textColor = { white = 1 },
      frame = { x = pad + 30, y = y + 6, w = w - 2 * pad - 40, h = 20 },
    })
  end
  canvas:mouseCallback(function(_, event, id)
    if event == "mouseUp" then
      answered(id)
    end
  end)
  canvas:clickActivating(false)
  canvas:level(hs.canvas.windowLevels.floating)
  canvas:show()
  self.prompt = { canvas = canvas, question = question, about = about }
  -- A question that takes itself off the screen is one the person watched
  -- vanish half read, and then the class is decided by nobody. It waits.
  -- `prompt.seconds` above zero puts the old behaviour back.
  if self.rules.prompt.seconds > 0 then
    self.prompt.timer = hs.timer.doAfter(self.rules.prompt.seconds, function()
      self:dismiss()
    end)
  end
  return true
end

function obj:dismiss()
  local prompt = self.prompt
  if not prompt then
    return
  end
  self.prompt = nil
  if prompt.timer then
    prompt.timer:stop()
  end
  prompt.canvas:delete()
end

function obj:answer(key, answer)
  learned.remember(self.learned, key, answer)
  self:saveLearned()
  self:dismiss()
  self:tick()
end

-- ---------------------------------------------------------------------------
-- Segments

function obj:append(row)
  local ok, err = appendLine(self.statePath .. "/intervals.csv", tracker.csv(row), tracker.header)
  if not ok then
    self:complain("could not write a row: " .. tostring(err))
  end
  self.rows = nil
end

function obj:persistOpen()
  local path = self.statePath .. "/open.json"
  if self.state.open then
    writeAtomically(path, hs.json.encode(self.state.open))
  else
    os.remove(path)
  end
end

function obj:readOpen()
  local text = readFile(self.statePath .. "/open.json")
  if not text then
    return nil
  end
  local ok, decoded = pcall(hs.json.decode, text)
  return ok and decoded or nil
end

function obj:closeNow()
  local closed = tracker.close(self.state, os.time())
  if closed then
    self:append(closed)
  end
  self:persistOpen()
  self:refresh({ away = true })
end

function obj:tick()
  local now = os.time()
  local obs = self:observe(now)
  local closed = tracker.observe(self.state, now, obs)
  if closed then
    self:append(closed)
  end
  self:persistOpen()
  self:refresh(obs)
end

--- Zyt:setOverride(class)
--- Method
--- Pin the class to "work" or "private" until the next lock, or pass nil to
--- let the rules decide again. Returns the status line.
function obj:setOverride(class)
  if class ~= "work" and class ~= "private" then
    class = nil
  end
  if class ~= self.override then
    -- The pin, and its end, are boundaries: what came before was decided
    -- one way, what follows is decided another, and the rows say which.
    self.override = class
    local closed = tracker.close(self.state, os.time())
    if closed then
      self:append(closed)
    end
  end
  self:tick()
  return self:statusJSON()
end

-- ---------------------------------------------------------------------------
-- The calendar

--- The end of the last row written, as seconds. Where the record stops is
--- where a gap starts, and the file is the only thing that knows it across a
--- restart.
function obj:lastRecorded()
  if not self.rows then
    self.rows = totals.parse(readFile(self.statePath .. "/intervals.csv"))
  end
  local last = self.rows[#self.rows]
  return last and meetings.moment(last.finish) or nil
end

--- The hours the calendar can account for and the tracker cannot: a meeting
--- sat through with the notebook shut, or in a room with it open and
--- untouched, where the idle rule ended the segment at the last keystroke.
---
--- Run when somebody comes back, because the gap is over then and its edges
--- stand still. The command line does the asking, in a shell of its own, so a
--- round trip to Graph never holds up a tick. What comes back is clipped to
--- the gap, so nothing is written over time that was recorded properly.
function obj:fillMeetings()
  local settings = self.rules.meetings
  if not settings.enabled or self.filling then
    return
  end
  local from = self:lastRecorded()
  if not from then
    return
  end
  -- Up to the open segment, never into it: the segment that started when they
  -- came back is the same time, recorded properly.
  local now = os.time()
  local to = (self.state and self.state.open and self.state.open.start) or now
  local floor = now - settings.lookbackHours * 3600
  if from < floor then
    from = floor
  end
  if to - from < settings.minimumSeconds then
    return
  end
  self.filling = true
  -- Standard error stays where it is. The command line says on it what it left
  -- out and why, and folded into the answer it would be a line of JSON that is
  -- not JSON.
  local command = ("%q meetings --json --hours %d"):format(self.cli, settings.lookbackHours)
  local task = hs.task.new("/bin/zsh", function(code, out, err)
    self.filling = false
    if code ~= 0 then
      self.logger.e("zyt meetings: " .. tostring(err ~= "" and err or out))
      return
    end
    if err and err ~= "" then
      self.logger.w("zyt meetings: " .. err)
    end
    local ok, answer = pcall(hs.json.decode, out)
    if not ok or type(answer) ~= "table" then
      self.logger.e("zyt meetings said something that is not JSON")
      return
    end
    self:writeMeetings(from, to, answer.events or {})
  end, { "-lc", command })
  if not task:start() then
    -- Nothing will call the callback, so the flag has to come back here or the
    -- next gap is never looked at.
    self.filling = false
    self.logger.e("zyt meetings could not be started")
  end
end

--- Zyt:fillGaps(payload)
--- Method
--- Fill every gap in a window, from events handed in as JSON:
--- `{ from = seconds, to = seconds, events = { ... } }`. The command line reads
--- the calendar and calls this, so the record keeps one writer and the whole of
--- a week can be caught up with at once. Returns the seconds written, or -1
--- when the payload is not one.
function obj:fillGaps(payload)
  local ok, body = pcall(hs.json.decode, payload)
  if not ok or type(body) ~= "table" then
    return -1
  end
  local from, to = tonumber(body.from), tonumber(body.to)
  if not from or not to or to <= from then
    return -1
  end
  if not self.rows then
    self.rows = totals.parse(readFile(self.statePath .. "/intervals.csv"))
  end
  -- The gaps are worked out before the first row is written, because writing
  -- one closes the gap it was written into.
  local holes = meetings.gaps(self.rows, from, to, self.rules.meetings.minimumSeconds)
  local written = 0
  for _, hole in ipairs(holes) do
    written = written + self:writeMeetings(hole.start, hole.finish, body.events or {})
  end
  return written
end

--- The rows for one gap. Kept apart from the asking, so what is written can be
--- read without a calendar anywhere near it.
function obj:writeMeetings(from, to, events)
  local settings = self.rules.meetings
  local written = 0
  for _, piece in ipairs(meetings.fill(settings, from, to, events)) do
    self:append({
      start = clock.iso(piece.start),
      finish = clock.iso(piece.finish),
      seconds = piece.seconds,
      class = settings.class,
      source = "meeting",
      app = "calendar",
    })
    written = written + piece.seconds
  end
  if written > 0 then
    self.logger.i(("filled %d s of meetings"):format(written))
    self:refresh()
  end
  return written
end

-- ---------------------------------------------------------------------------
-- Reading back

function obj:today()
  if not self.rows then
    self.rows = totals.parse(readFile(self.statePath .. "/intervals.csv"))
  end
  local now = os.time()
  local day = os.date("%Y-%m-%d", now)
  local sums = totals.forDay(self.rows, day)
  local open = self.state and self.state.open
  if open then
    local midnight = os.time({
      year = tonumber(day:sub(1, 4)),
      month = tonumber(day:sub(6, 7)),
      day = tonumber(day:sub(9, 10)),
      hour = 0,
    })
    local from = math.max(open.start, midnight)
    if now > from then
      sums[open.class] = sums[open.class] + (now - from)
    end
  end
  return sums
end

--- Zyt:status()
--- Method
--- What is running now and what today adds up to, as a table.
function obj:status()
  local open = self.state and self.state.open
  return {
    running = self.running,
    class = open and open.class or nil,
    source = open and open.source or nil,
    since = open and isoLocal(open.start) or nil,
    override = self.override,
    away = open == nil,
    today = self:today(),
    configPath = self.configPath,
    statePath = self.statePath,
  }
end

function obj:statusJSON()
  return hs.json.encode(self:status())
end

-- ---------------------------------------------------------------------------
-- Menu

function obj:copyReport()
  local out, ok = hs.execute(("%q week 2>&1"):format(self.cli), true)
  if ok then
    hs.pasteboard.setContents(out)
    hs.alert.show("zyt: this week's report is on the clipboard", 2)
  else
    self:complain("the report failed: " .. tostring(out))
  end
end

--- The week drawn as one HTML file and opened, the same as `zyt board`
--- ([ADR 0011](../../docs/adr/0011-the-board-is-one-file.md)). One line comes
--- back when it worked, the path it wrote, and there is nothing to say about a
--- page that is already on screen. Anything more than that line means the
--- browser would not take it, and then the path is the useful part.
function obj:showBoard()
  local out, ok = hs.execute(("%q board 2>&1"):format(self.cli), true)
  out = (out or ""):gsub("%s+$", "")
  if not ok then
    self:complain("the board failed: " .. out)
  elseif out:find("\n") then
    hs.alert.show("zyt: " .. out, 4)
  end
end

function obj:openRules()
  ensureDirectory(self.configPath:match("^(.*)/[^/]+$"))
  if not hs.fs.attributes(self.configPath, "mode") then
    writeAtomically(self.configPath, "{\n}\n")
  end
  hs.execute(("open %q"):format(self.configPath))
end

--- The chats open in the application that was last in front, so that the one
--- being talked to can be named without waiting for the panel to ask. Empty
--- unless there are at least two of them: with one there is nothing to choose.
function obj:chatMenu()
  local seen = self.seen or {}
  local chats = seen.chats or {}
  if #chats < 2 then
    return {}
  end
  local choice = self.chosen[seen.bundle or ""]
  local items = { { title = "-" }, { title = "Which chat in " .. (seen.app or "?") .. "?", disabled = true } }
  for _, chat in ipairs(chats) do
    -- The chat in the pane the terminal says is in front is ticked without
    -- anybody having picked it: it is not a choice, it is where they are. While
    -- the pane answers, an older pick about another one of them is not shown as
    -- if it still counted.
    local inFront = seen.inPane ~= nil and seen.inPane == chat.session
    local picked = seen.inPane == nil and choice ~= nil and choice.session == chat.session
    items[#items + 1] = {
      title = ("%s%s · %s · %s · typed %s"):format(
        classify.chatLabel(chat, CHAT_LABEL_CHARS) or repoLabel(chat.remote),
        inFront and " (in front)" or "",
        shortRepo(chat.remote),
        classify.remoteClass(self.rules, chat.remote) or "unknown",
        os.date("%H:%M", chat.promptAt)
      ),
      indent = 1,
      checked = inFront or picked,
      disabled = type(chat.session) ~= "string",
      fn = function()
        self:choose(seen.bundle, chat.session)
      end,
    }
  end
  return items
end

--- Forgetting has two scopes, because "forget that" is usually about the window
--- in front and not about every answer ever given. The narrow one names what it
--- will drop, so there is nothing to find out by clicking it.
function obj:forgetMenu()
  local seen = self.seen or {}
  local items = {}
  if seen.key then
    items[#items + 1] = {
      title = ("Only for %s"):format(seen.about or "this window"),
      fn = function()
        self:forget(seen.key, seen.bundle)
      end,
    }
  end
  items[#items + 1] = {
    title = "All of them",
    fn = function()
      self:forget()
    end,
  }
  return items
end

function obj:menu()
  local today = self:today()
  local function choice(title, class)
    return {
      title = title,
      checked = self.override == class,
      fn = function()
        self:setOverride(class)
      end,
    }
  end
  local items = {
    choice("Work", "work"),
    choice("Private", "private"),
    choice("Auto", nil),
    { title = "-" },
    {
      title = ("Today  %s work · %s private"):format(totals.format(today.work), totals.format(today.private)),
      disabled = true,
    },
    {
      title = "Copy this week's report",
      fn = function()
        self:copyReport()
      end,
    },
    {
      title = "Show this week's board",
      fn = function()
        self:showBoard()
      end,
    },
    { title = "-" },
    {
      title = "Open the rules file",
      fn = function()
        self:openRules()
      end,
    },
    {
      title = "Reload the rules",
      fn = function()
        self:loadRules()
        self:tick()
      end,
    },
    {
      title = "Forget the answers, ask again",
      menu = self:forgetMenu(),
    },
  }
  for _, item in ipairs(self:chatMenu()) do
    items[#items + 1] = item
  end
  items[#items + 1] = { title = "-" }
  items[#items + 1] = {
    title = "Quit zyt",
    fn = function()
      self:stop()
    end,
  }
  return items
end

function obj:refresh(obs)
  if not self.menubar then
    return
  end
  local labels = self.rules.labels
  local open = self.state.open
  local title = open and labels[open.class] or labels.away
  if self.override then
    title = "[" .. title .. "]"
  end
  self.menubar:setTitle(title)
  local what = open and (open.class .. " since " .. os.date("%H:%M", open.start) .. " (" .. open.source .. ")")
    or "away"
  if obs and obs.app and obs.app ~= "" then
    what = what .. " · " .. obs.app
  end
  self.menubar:setTooltip("zyt: " .. what)
end

-- ---------------------------------------------------------------------------
-- Lifecycle

function obj:watch()
  -- A switch to another application is looked at at once, so the menu-bar
  -- item changes when the window does and not up to a tick later.
  local A = hs.application.watcher
  self.appWatcher = A.new(function(_, event)
    if event == A.activated and self.running then
      self:tick()
    end
  end)
  self.appWatcher:start()

  local W = hs.caffeinate.watcher
  self.watcher = W.new(function(event)
    if event == W.screensDidLock or event == W.sessionDidResignActive then
      self.locked = true
      self:dismiss()
      self:closeNow()
    elseif event == W.screensDidUnlock or event == W.sessionDidBecomeActive then
      self.locked = false
      self.override = nil
      self.said = {}
      self:tick()
      self:fillMeetings()
    elseif event == W.systemWillSleep then
      self.asleep = true
      self:closeNow()
    elseif event == W.systemDidWake then
      self.asleep = false
      self:tick()
      self:fillMeetings()
    end
  end)
  self.watcher:start()
end

--- Zyt:start()
--- Method
--- Load the rules, pick up what a previous run left open, and start ticking.
function obj:start()
  if self.running then
    return self
  end
  ensureDirectory(self.statePath)
  self:loadRules()
  self:loadLearned()
  self.resolve = repo.resolver(repo.fs, 600, os.time)
  self.cwdOf = self.cwdOf or { iTerm2 = iterm2Path }
  self.paneOf = self.paneOf or { iTerm2 = iterm2Pane }
  local checkout = self.spoonPath .. "../scripts/zyt"
  if self.cli == "zyt" and hs.fs.attributes(checkout, "mode") then
    self.cli = checkout
  end

  self.state = tracker.new(self.rules, clock)
  local leftover = tracker.recover(self.state, self:readOpen())
  if leftover then
    self:append(leftover)
  end

  self.menubar = hs.menubar.new(true, "zyt")
  self.menubar:setMenu(function()
    return self:menu()
  end)
  self:watch()
  self:armTimer()
  local previousShutdown = hs.shutdownCallback
  hs.shutdownCallback = function()
    if self.running then
      self:closeNow()
    end
    if previousShutdown then
      previousShutdown()
    end
  end

  self.running = true
  _G.zyt = self
  self:tick()
  return self
end

--- Zyt:stop()
--- Method
--- Close the open segment, stop the timer and the watcher, take the item out
--- of the menu bar.
function obj:stop()
  if not self.running then
    return self
  end
  self:closeNow()
  self:dismiss()
  if self.timer then
    self.timer:stop()
    self.timer = nil
  end
  for _, key in ipairs({ "watcher", "appWatcher" }) do
    if self[key] then
      self[key]:stop()
      self[key] = nil
    end
  end
  if self.menubar then
    self.menubar:delete()
    self.menubar = nil
  end
  self.running = false
  return self
end

--- Zyt:bindHotkeys(mapping)
--- Method
--- Keys for `work`, `private` and `auto`, in the usual Spoon shape.
function obj:bindHotkeys(mapping)
  local actions = {
    work = function()
      self:setOverride("work")
    end,
    private = function()
      self:setOverride("private")
    end,
    auto = function()
      self:setOverride(nil)
    end,
  }
  hs.spoons.bindHotkeysToSpec(actions, mapping)
  return self
end

return obj
