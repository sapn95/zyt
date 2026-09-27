--- Which class a moment belongs to, from what is on screen and what the tools
--- have said about themselves. Pure: it is handed the rules, an observation and
--- a resolver, and it answers with a class and where the answer came from, or
--- with nothing when it does not know.
local M = {}

local function lower(text)
  return (text or ""):lower()
end

--- The class a git remote belongs to, by the first `remotes` rule whose
--- `match` is a substring of the URL.
function M.remoteClass(rules, remote)
  if type(remote) ~= "string" then
    return nil
  end
  for _, rule in ipairs(rules.remotes) do
    if remote:find(rule.match, 1, true) then
      return rule.class
    end
  end
  return nil
end

--- The words in a window title that could be a directory name: split on
--- whitespace and on path separators, with the decoration taken off the ends.
--- Lua patterns see bytes, so `%p` would leave a bullet or a dash alone; the
--- ends are trimmed to letters, digits and underscores instead.
function M.tokens(title)
  local out = {}
  for word in (title or ""):gmatch("%S+") do
    for part in word:gmatch("[^/:]+") do
      local trimmed = part:gsub("^[^%w_]+", "")
      trimmed = trimmed:gsub("[^%w_]+$", "")
      if #trimmed >= 2 then
        out[#out + 1] = trimmed
      end
    end
  end
  return out
end

local function fresh(rules, signal)
  return signal ~= nil and type(signal.age) == "number" and signal.age <= rules.signalSeconds
end

--- Absolute paths in a window title, `~` expanded. An editor whose title is
--- set to name the active file's folder is classified from that folder.
function M.paths(title, home)
  local out = {}
  -- Copied into a local of its own: from Lua 5.5 on, the variable a generic for
  -- loop hands out is a constant, and Hammerspoon will get there.
  for found in (title or ""):gmatch("~?/%S+") do
    local path = found
    if path:sub(1, 1) == "~" then
      path = (home or "") .. path:sub(2)
    end
    out[#out + 1] = path
  end
  return out
end

--- The chats hosted in the application in front: the sessions somebody has
--- typed into within `chatSeconds`, in the order the adapter sorted them,
--- newest prompt first. A session that has never seen a prompt is not a chat
--- anybody is looking at, and the adapter leaves it out.
function M.liveChats(rules, obs)
  local list = obs.chats
  if not list and obs.chat then
    list = { obs.chat }
  end
  local out = {}
  for _, chat in ipairs(list or {}) do
    if type(chat.age) == "number" and chat.age <= rules.chatSeconds and chat.bundle == obs.bundle and chat.remote then
      out[#out + 1] = chat
    end
  end
  return out
end

--- A pane id with any window and tab in front of it taken off. iTerm2 puts
--- `w0t3p0:<uuid>` into the environment of a shell, where only the part after
--- the colon belongs to the pane, and answers with that part on its own when it
--- is asked which pane is in front. Both ends are cut to the same shape here,
--- where they are compared, so that no adapter has to remember to.
function M.paneId(pane)
  if type(pane) ~= "string" then
    return nil
  end
  return pane:match("([^:]+)$")
end

--- The chat in the pane the terminal says is in front, or nil when there is
--- none. A terminal knows which of its panes is selected and it gives every
--- shell it opens an id for that pane, which a tool started there carries into
--- its note: four chats in four tabs are then told apart by the terminal itself
--- and nobody has to be asked. One pane can have held two sessions, one after
--- the other; then it is the one last spoken to, or the one the person picked
--- out of them by hand. A pick naming a chat in another pane is not an answer
--- about this one.
function M.paneChat(rules, obs)
  local pane = M.paneId(obs.pane)
  if not pane then
    return nil
  end
  local found
  for _, chat in ipairs(M.liveChats(rules, obs)) do
    if M.paneId(chat.pane) == pane then
      if obs.chosen and chat.session == obs.chosen then
        return chat
      end
      found = found or chat
    end
  end
  return found
end

--- Which of the live chats the person is in. The pane in front settles it when
--- the terminal named one; otherwise the chat they picked by hand wins, and
--- otherwise the one they typed into last.
---
--- Returns remote, unsure, candidates. `unsure` says the answer is a guess:
--- the live chats straddle both classes, and nothing on screen says which
--- panel is in front, so only the person can. A prompt typed within
--- `typingSeconds` is not a guess, and nobody is asked about it. `candidates`
--- are the chats whose repository the rules do have a class for — the ones
--- worth offering.
---
--- The newest chat is the pick even when the rules have no class for its
--- repository, and then the caller ends up asking about that repository rather
--- than reading the class off an older chat. That is on purpose: the person is
--- in the chat they last typed into, and an answer about the repository they
--- are actually in is true tomorrow as well.
function M.chatOf(rules, obs)
  local chats = M.liveChats(rules, obs)
  if #chats == 0 then
    return nil
  end
  -- A choice made by hand is an answer about an afternoon; the pane is where
  -- the person is right now. Nothing they could say beats the terminal saying
  -- which of its panes they are looking at.
  local inPane = M.paneChat(rules, obs)
  local pick, candidates, seen, kinds = inPane or chats[1], {}, {}, 0
  for _, chat in ipairs(chats) do
    if not inPane and obs.chosen and chat.session == obs.chosen then
      pick = chat
    end
    local class = M.remoteClass(rules, chat.remote)
    if class then
      candidates[#candidates + 1] = chat
      if not seen[class] then
        seen[class] = true
        kinds = kinds + 1
      end
    end
  end
  -- Somebody who has just typed into a chat is in that chat. The prompt says so
  -- more plainly than a click would, it is newer than any answer they could
  -- give, and a panel put in front of them in that second is asking about the
  -- window they are looking at. It wears off, because the reason the question
  -- exists at all is the other chat they turn to while this one works.
  --
  -- A pick still beats a prompt here, and that is the caller's business rather
  -- than an order of precedence: a pick is only passed in while it stands, and
  -- a prompt typed into another chat after it was made is what ends it. The
  -- times that decision needs are the caller's; this function is handed a
  -- session id and no clock.
  local typing = type(chats[1].age) == "number" and chats[1].age <= rules.typingSeconds
  local told = typing or inPane ~= nil or (obs.chosen ~= nil and pick.session == obs.chosen)
  local unsure
  if kinds > 1 and not told then
    unsure = true
  end
  return pick.remote, unsure, candidates
end

--- The chats worth putting to the person when nothing on screen says which one
--- is in front: the newest chat of each repository, newest first, `max` of them
--- at the outside. Two chats in one checkout are one entry, because they carry
--- the same name and the same class and either answer would do.
---
--- When there are more repositories than `max`, the newest chat of each class
--- keeps its place whatever its age: the question only gets asked because the
--- chats straddle both classes, and a list with one class in it has no answer in
--- it. The rest of the room goes to the newest.
function M.chatChoices(rules, obs, max)
  local _, _, candidates = M.chatOf(rules, obs)
  local rows, seen = {}, {}
  for _, chat in ipairs(candidates or {}) do
    if type(chat.session) == "string" and not seen[chat.remote] then
      seen[chat.remote] = true
      rows[#rows + 1] = { session = chat.session, remote = chat.remote, class = M.remoteClass(rules, chat.remote) }
    end
  end
  if #rows <= max then
    return rows
  end
  local kept, taken, classes = {}, {}, {}
  for index, row in ipairs(rows) do
    if not classes[row.class] then
      classes[row.class] = true
      taken[index] = true
      kept[#kept + 1] = row
    end
  end
  for index, row in ipairs(rows) do
    if not taken[index] and #kept < max then
      kept[#kept + 1] = row
    end
  end
  return kept
end

--- The remote of the repository a `repo` application's window is about, and
--- where it was found: the chat in the pane the terminal says is in front, its
--- working directory, an absolute path in the title, a title word that names a
--- checkout, the chat the person is in out of the ones hosted here, or a fresh
--- note from any tool hosted in it. Nil when none of them names a repository.
--- The third value is true when the chat was picked out of several that
--- disagree.
function M.repositoryOf(rules, obs)
  -- The pane is the one thing here nobody has to interpret: the terminal said
  -- which of its panes is selected, and the session opened in that pane said
  -- what it is working on. A word in the window title that happens to name
  -- another checkout, or a shell still sitting in the directory it was opened
  -- in, are both weaker than that, and until the pane was asked they were what
  -- a terminal full of chats was classified by.
  local inPane = M.paneChat(rules, obs)
  if inPane then
    return inPane.remote, "pane"
  end
  if obs.cwd then
    local remote = obs.resolve(obs.cwd)
    if remote then
      return remote, "cwd"
    end
  end
  for _, path in ipairs(M.paths(obs.title, rules.home)) do
    local remote = obs.resolve(path)
    if remote then
      return remote, "path"
    end
  end
  for _, token in ipairs(M.tokens(obs.title)) do
    for _, root in ipairs(rules.repoRoots) do
      local remote = obs.resolve(root .. "/" .. token)
      if remote then
        return remote, "repo"
      end
    end
  end
  local chatted, unsure = M.chatOf(rules, obs)
  if chatted then
    return chatted, "chat", unsure
  end
  local signal = obs.signal
  if fresh(rules, signal) and (signal.bundle == nil or signal.bundle == obs.bundle) and signal.remote then
    return signal.remote, "llm"
  end
  return nil
end

local function byRepository(rules, obs)
  local remote, how, unsure = M.repositoryOf(rules, obs)
  local class = M.remoteClass(rules, remote)
  if class then
    return class, how, unsure
  end
  return nil
end

local function byTitle(rules, title)
  title = lower(title)
  for _, rule in ipairs(rules.titles) do
    if title:find(lower(rule.contains), 1, true) then
      return rule.class, "title"
    end
  end
  return nil
end

--- Decide for one observation:
---   obs.app      the frontmost application's name
---   obs.bundle   its bundle id, matched against the one a tool's note names
---   obs.title    the focused window's title
---   obs.cwd      the working directory the application reported, if it can
---   obs.pane     the id of the pane a terminal says is in front, if it says
---   obs.idle     seconds since the last input
---   obs.signal   { age = seconds, remote = url, bundle = id } left behind by a tool's hook
---   obs.chats    the same per chat session, plus promptAt, session and pane, newest prompt first
---   obs.chosen   the session id the person named as the chat they are in
---   obs.resolve  function(path) -> remote url or nil
--- Returns class, source, unsure — or nil when nothing here has an opinion.
--- `unsure` means the class is right for one of the chats open here and the
--- person is the only one who can say it is theirs.
---
--- While nobody has typed for `idleSeconds` and a coding tool has reported in
--- recently, the tool's repository decides: the window in front is whatever
--- was left there, and the work is happening in the session. While somebody
--- is typing, the note only speaks for the application hosting the tool: a
--- second editor open on another repository is not the session's business.
function M.decide(rules, obs)
  if type(obs.idle) == "number" and obs.idle >= rules.idleSeconds and fresh(rules, obs.signal) then
    local class = M.remoteClass(rules, obs.signal.remote)
    if class then
      return class, "llm"
    end
  end
  local byApp = rules.apps[obs.app or ""]
  if rules.CLASSES and rules.CLASSES[byApp] or byApp == "work" or byApp == "private" then
    return byApp, "app"
  end
  if byApp == "repo" then
    local class, source, unsure = byRepository(rules, obs)
    if class then
      return class, source, unsure
    end
  end
  return byTitle(rules, obs.title)
end

return M
