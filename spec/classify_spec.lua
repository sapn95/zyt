local classify = require("zyt.classify")
local rules = require("zyt.rules")

local R = assert(rules.normalise({
  apps = { Mail = "work", Spotify = "private", iTerm2 = "repo", Code = "repo", Kiro = "repo" },
  titles = { { contains = "jira", class = "work" }, { contains = "GitHub", class = "private" } },
  remotes = { { match = "git.example.com", class = "work" }, { match = "github.com", class = "private" } },
  repoRoots = { "~/git" },
  signalSeconds = 300,
}, "/Users/me"))

local remotes = {
  ["/Users/me/git/infra"] = "ssh://git@git.example.com:7999/team/infra.git",
  ["/Users/me/git/budget"] = "git@github.com:me/budget.git",
}
-- Like repo.resolver: any path inside a repository answers with its remote.
local function resolve(path)
  for prefix, remote in pairs(remotes) do
    if path == prefix or path:sub(1, #prefix + 1) == prefix .. "/" then
      return remote
    end
  end
  return nil
end

local function decide(obs)
  obs.resolve = obs.resolve or resolve
  return classify.decide(R, obs)
end

describe("classify.decide", function()
  it("takes the application's word first", function()
    assert.same({ "work", "app" }, { decide({ app = "Mail", title = "GitHub notifications" }) })
    assert.same({ "private", "app" }, { decide({ app = "Spotify", title = "" }) })
  end)

  it("reads titles without caring about case", function()
    assert.same({ "work", "title" }, { decide({ app = "firefox", title = "ABC-1 · JIRA" }) })
    assert.same({ "private", "title" }, { decide({ app = "firefox", title = "Pull requests · GitHub" }) })
  end)

  it("has no opinion on a window it does not know", function()
    assert.is_nil(decide({ app = "Finder", title = "Downloads" }))
    assert.is_nil(decide({ app = nil, title = nil }))
  end)

  describe("for a repository application", function()
    it("asks the working directory first", function()
      assert.same({ "work", "cwd" }, { decide({ app = "iTerm2", title = "GitHub", cwd = "/Users/me/git/infra" }) })
    end)

    it("finds the repository in the title when there is no working directory", function()
      assert.same(
        { "private", "repo" },
        { decide({ app = "Code", title = "● main.go — budget — Visual Studio Code" }) }
      )
      -- a path in the title is read as a path, before any word is tried as a name
      assert.same({ "work", "path" }, { decide({ app = "iTerm2", title = "me@mac: ~/git/infra" }) })
      assert.same({ "work", "repo" }, { decide({ app = "iTerm2", title = "me@mac: infra (zsh)" }) })
    end)

    it("reads an absolute path out of the title, with ~ expanded", function()
      assert.same(
        { "work", "path" },
        { decide({ app = "Code", title = "● main.tf — git — /Users/me/git/infra/stacks/prod" }) }
      )
      assert.same({ "private", "path" }, { decide({ app = "Kiro", title = "notes.md — ~/git/budget/docs" }) })
      assert.is_nil(decide({ app = "Code", title = "readme — /Users/me/elsewhere/file" }))
    end)

    it("falls back to a recent note from a tool", function()
      local signal = { age = 60, remote = "git@github.com:me/budget.git" }
      assert.same({ "private", "llm" }, { decide({ app = "Code", title = "git", signal = signal }) })
    end)

    it("trusts the chat the person talks to over whatever session is busy", function()
      local busy = { age = 10, remote = "git@github.com:me/budget.git", bundle = "com.microsoft.VSCode" }
      local talking =
        { age = 900, remote = "ssh://git@git.example.com:7999/team/infra.git", bundle = "com.microsoft.VSCode" }
      assert.same(
        { "work", "chat" },
        { decide({ app = "Code", bundle = "com.microsoft.VSCode", title = "git", signal = busy, chat = talking }) }
      )
      -- a chat from another editor, or one from too long ago, does not count
      talking.bundle = "dev.kiro.desktop"
      assert.same(
        { "private", "llm" },
        { decide({ app = "Code", bundle = "com.microsoft.VSCode", title = "git", signal = busy, chat = talking }) }
      )
      talking.bundle = "com.microsoft.VSCode"
      talking.age = 99999
      assert.same(
        { "private", "llm" },
        { decide({ app = "Code", bundle = "com.microsoft.VSCode", title = "git", signal = busy, chat = talking }) }
      )
    end)

    it("counts every chat of this application, not only the last one typed into", function()
      -- Both prompts are old enough that neither of them answers the question:
      -- what is being read here is which chats count, not who is typing.
      local work = {
        age = 300,
        promptAt = 200,
        session = "w",
        remote = "ssh://git@git.example.com:7999/team/infra.git",
        bundle = "com.microsoft.VSCode",
      }
      local also = {
        age = 3000,
        promptAt = 100,
        session = "w2",
        remote = "ssh://git@git.example.com:7999/team/other.git",
        bundle = "com.microsoft.VSCode",
      }
      local obs = { app = "Code", bundle = "com.microsoft.VSCode", title = "git", chats = { work, also } }
      -- two chats that agree: which panel is in front does not matter
      assert.same({ "work", "chat" }, { decide(obs) })

      -- one of each, and nothing on screen says which is in front
      also.remote = "git@github.com:me/budget.git"
      assert.same({ "work", "chat", true }, { decide(obs) })

      -- unless the person has been asked whose time the chat in front is, and
      -- then their word stands
      obs.said = "private"
      assert.same({ "private", "said" }, { decide(obs) })

      -- a chat whose repository the rules know nothing about is not a second
      -- opinion, it is no opinion
      also.remote = "git@example.org:me/elsewhere.git"
      obs.said = nil
      assert.same({ "work", "chat" }, { decide(obs) })
    end)

    it("stays in the newest chat even when it is the one nothing is known about", function()
      local unknown =
        { age = 60, promptAt = 200, session = "u", remote = "git@example.org:me/elsewhere.git", bundle = "b" }
      local known = {
        age = 300,
        promptAt = 100,
        session = "k",
        remote = "ssh://git@git.example.com:7999/team/infra.git",
        bundle = "b",
      }
      local obs = { app = "Code", bundle = "b", title = "git", chats = { unknown, known }, resolve = resolve }
      -- the older chat's class is not borrowed: the question to ask is about
      -- the repository the person is in, and that answer keeps
      assert.equal("git@example.org:me/elsewhere.git", (classify.repositoryOf(R, obs)))
      assert.is_nil(decide(obs))
    end)

    it("counts only the chats the rules have a class for as a disagreement", function()
      -- Nothing has been typed into for a while: a prompt of a minute ago would
      -- answer the question by itself, and nobody would be asked.
      local chats = {
        { age = 300, promptAt = 3, session = "a", remote = "git@github.com:me/budget.git", bundle = "b" },
        { age = 600, promptAt = 2, session = "b", remote = "git@example.org:me/elsewhere.git", bundle = "b" },
        {
          age = 900,
          promptAt = 1,
          session = "c",
          remote = "ssh://git@git.example.com:7999/team/infra.git",
          bundle = "b",
        },
      }
      local remote, unsure = classify.chatOf(R, { bundle = "b", chats = chats })
      assert.equal("git@github.com:me/budget.git", remote)
      assert.is_true(unsure)
      -- the unknown repository is the newest of the three and still not a
      -- class, so two classes are in play rather than three
      chats[1].remote = "git@example.org:me/nothing-known.git"
      local _, oneClass = classify.chatOf(R, { bundle = "b", chats = chats })
      assert.is_nil(oneClass)
      assert.is_nil(classify.chatOf(R, { bundle = "b", chats = {} }))
    end)

    it("asks nobody about the chat they are typing into", function()
      local chats = {
        { age = 5, promptAt = 400, session = "a", remote = "git@github.com:me/budget.git", bundle = "b" },
        {
          age = 900,
          promptAt = 100,
          session = "c",
          remote = "ssh://git@git.example.com:7999/team/infra.git",
          bundle = "b",
        },
      }
      local obs = { app = "Code", bundle = "b", title = "git", chats = chats, resolve = resolve }
      -- the two chats straddle both classes, so the panel would open, except
      -- that the person is typing into one of them and has said where they are
      local remote, unsure = classify.chatOf(R, obs)
      assert.equal("git@github.com:me/budget.git", remote)
      assert.is_nil(unsure)
      -- and the chat it picked is the one that was typed into
      assert.equal("a", (classify.chatInFront(R, obs)).session)
      -- the third value is nil, so nothing here is unsure
      assert.same({ "private", "chat" }, { decide(obs) })
      -- once the prompt is older than typingSeconds the question is a question
      -- again: this is the chat they left running while they read the other one
      chats[1].age = 121
      local _, later = classify.chatOf(R, obs)
      assert.is_true(later)
    end)

    it("takes the word of somebody who has been asked whose time it is", function()
      local chats = {
        { age = 300, promptAt = 400, session = "a", remote = "git@github.com:me/budget.git", bundle = "b" },
        {
          age = 900,
          promptAt = 100,
          session = "c",
          remote = "ssh://git@git.example.com:7999/team/infra.git",
          bundle = "b",
        },
      }
      local obs = { app = "Code", bundle = "b", title = "git", chats = chats, resolve = resolve }
      -- without an answer the newest chat decides and the question is open
      assert.same({ "private", "chat", true }, { decide(obs) })
      -- with one, that is the class, and there is nothing left to ask
      obs.said = "work"
      assert.same({ "work", "said" }, { decide(obs) })
      -- a class nobody could have named is no answer
      obs.said = "sometimes"
      assert.same({ "private", "chat", true }, { decide(obs) })
      -- and it only speaks where nothing else can: one chat, no question
      obs.said = "work"
      obs.chats = { chats[1] }
      assert.same({ "private", "chat" }, { decide(obs) })
    end)

    it("takes the chat in the pane the terminal says is in front", function()
      local work = {
        age = 60,
        promptAt = 200,
        session = "w",
        pane = "PANE-A",
        remote = "ssh://git@git.example.com:7999/team/infra.git",
        bundle = "com.googlecode.iterm2",
      }
      local other = {
        age = 30,
        promptAt = 300,
        session = "p",
        pane = "PANE-B",
        remote = "git@github.com:me/budget.git",
        bundle = "com.googlecode.iterm2",
      }
      -- the tab in front holds the work chat, while the window title names the
      -- other checkout and the shell still sits where it was opened
      local obs = {
        app = "iTerm2",
        bundle = "com.googlecode.iterm2",
        title = "me@mac: budget (claude)",
        cwd = "/Users/me/git/budget",
        pane = "PANE-A",
        chats = { other, work },
      }
      -- two values and no third: nothing is unsure, so nobody is asked
      assert.same({ "work", "pane" }, { decide(obs) })
      obs.pane = "PANE-B"
      assert.same({ "private", "pane" }, { decide(obs) })
      -- a pane no chat was opened in leaves the old order in charge
      obs.pane = "PANE-C"
      assert.same({ "private", "cwd" }, { decide(obs) })
    end)

    it("takes the newest of two chats that shared one pane", function()
      local older = {
        age = 300,
        promptAt = 100,
        session = "o",
        pane = "P",
        remote = "ssh://git@git.example.com:7999/team/infra.git",
        bundle = "b",
      }
      local newer =
        { age = 60, promptAt = 200, session = "n", pane = "P", remote = "git@github.com:me/budget.git", bundle = "b" }
      local obs = { app = "iTerm2", bundle = "b", title = "", pane = "P", chats = { newer, older } }
      assert.same({ "private", "pane" }, { decide(obs) })
      -- the terminal named the pane, so there is nothing to ask about either
      local _, unsure = classify.chatOf(R, obs)
      assert.is_nil(unsure)
    end)

    it("applies the note to the application that wrote it and to no other", function()
      local signal = { age = 60, remote = "git@github.com:me/budget.git", bundle = "com.microsoft.VSCode" }
      assert.same(
        { "private", "llm" },
        { decide({ app = "Code", bundle = "com.microsoft.VSCode", title = "git", signal = signal }) }
      )
      assert.is_nil(decide({ app = "Kiro", bundle = "dev.kiro.desktop", title = "git", signal = signal }))
      -- once nobody types, the session's repository counts wherever the focus is
      assert.same(
        { "private", "llm" },
        { decide({ app = "Kiro", bundle = "dev.kiro.desktop", title = "git", idle = 900, signal = signal }) }
      )
    end)

    it("ignores a stale note", function()
      local signal = { age = 301, remote = "git@github.com:me/budget.git" }
      assert.is_nil(decide({ app = "Code", title = "git", signal = signal }))
    end)

    it("lets the tool's repository decide while nobody is typing", function()
      local signal = { age = 30, remote = "ssh://git@git.example.com:7999/team/infra.git" }
      -- Spotify is private by its own rule, but nobody has touched the machine
      -- for a while and a session is working in the work repository.
      assert.same({ "work", "llm" }, { decide({ app = "Spotify", title = "", idle = 900, signal = signal }) })
      -- typing again: the window in front decides
      assert.same({ "private", "app" }, { decide({ app = "Spotify", title = "", idle = 3, signal = signal }) })
      -- a stale note, or one without a known remote, changes nothing
      assert.same(
        { "private", "app" },
        { decide({ app = "Spotify", title = "", idle = 900, signal = { age = 999, remote = signal.remote } }) }
      )
      assert.same(
        { "private", "app" },
        { decide({ app = "Spotify", title = "", idle = 900, signal = { age = 30, remote = nil } }) }
      )
    end)

    it("still reads the title rules when no repository is found", function()
      assert.same({ "work", "title" }, { decide({ app = "iTerm2", title = "jira export" }) })
    end)
  end)
end)

describe("classify.chatLabel", function()
  it("says the name the chat gave itself, on one line", function()
    assert.equal("Arbeitszit timetracke", classify.chatLabel({ title = "  Arbeitszit\n  timetracke " }, 44))
  end)

  it("has nothing to say about a note from before there were titles", function()
    assert.is_nil(classify.chatLabel({ remote = "git@github.com:me/budget.git" }, 44))
    assert.is_nil(classify.chatLabel({ title = "   " }, 44))
    assert.is_nil(classify.chatLabel({ title = 42 }, 44))
    assert.is_nil(classify.chatLabel(nil, 44))
  end)

  it("cuts a long one to the width of a row", function()
    local label = classify.chatLabel({ title = string.rep("a", 80) }, 10)
    assert.equal(string.rep("a", 9) .. "…", label)
    assert.equal(10, utf8.len(label))
    -- a title that fits is left alone, ellipsis and all
    assert.equal("exactly 10", classify.chatLabel({ title = "exactly 10" }, 10))
  end)

  it("cuts between characters and not through one", function()
    -- Cutting by bytes would leave half of an ä behind, and half a character is
    -- not a character: utf8.len says nil about the result.
    local label = classify.chatLabel({ title = string.rep("ä", 40) }, 10)
    assert.equal(10, utf8.len(label))
    assert.equal(string.rep("ä", 9) .. "…", label)
    -- the space before a cut goes with it, so no row ends in a gap
    assert.equal("one two…", classify.chatLabel({ title = "one two three" }, 8))
  end)
end)

describe("classify.chatInFront", function()
  local infra = "ssh://git@git.example.com:7999/team/infra.git"
  local budget = "git@github.com:me/budget.git"

  local function chat(session, remote, age)
    return { age = age or 300, promptAt = 100, session = session, remote = remote, bundle = "b" }
  end

  it("is the chat last typed into, and the question is about that one", function()
    local newest, older = chat("a", budget), chat("c", infra)
    newest.promptAt = 400
    local pick, unsure = classify.chatInFront(R, { bundle = "b", chats = { newest, older } })
    assert.equal("a", pick.session)
    assert.is_true(unsure)
  end)

  it("is the chat in the pane the terminal says is in front", function()
    local inPane, other = chat("a", budget), chat("c", infra)
    inPane.pane, other.pane = "P", "Q"
    local pick, unsure = classify.chatInFront(R, { bundle = "b", pane = "P", chats = { other, inPane } })
    assert.equal("a", pick.session)
    -- the terminal said which panel is in front, so nobody is asked
    assert.is_nil(unsure)
  end)

  it("asks nothing while somebody is typing, or when the chats agree", function()
    local typed, older = chat("a", budget, 5), chat("c", infra)
    typed.promptAt = 400
    local _, typing = classify.chatInFront(R, { bundle = "b", chats = { typed, older } })
    assert.is_nil(typing)
    local _, agreeing = classify.chatInFront(R, { bundle = "b", chats = { chat("a", infra), chat("c", infra) } })
    assert.is_nil(agreeing)
  end)

  it("is nothing when no chat is live here", function()
    assert.is_nil(classify.chatInFront(R, { bundle = "b", chats = {} }))
    assert.is_nil(classify.chatInFront(R, { bundle = "elsewhere", chats = { chat("a", budget) } }))
  end)
end)

describe("classify.repositoryOf", function()
  it("names the repository even when no rule knows its class", function()
    local unknown = function(path)
      return path == "/Users/me/git/gadget" and "git@gitlab.com:me/gadget.git" or nil
    end
    assert.same(
      { "git@gitlab.com:me/gadget.git", "cwd" },
      { classify.repositoryOf(R, { app = "iTerm2", title = "", cwd = "/Users/me/git/gadget", resolve = unknown }) }
    )
    assert.is_nil(classify.decide(R, { app = "iTerm2", title = "", cwd = "/Users/me/git/gadget", resolve = unknown }))
    assert.is_nil(classify.repositoryOf(R, { app = "iTerm2", title = "nothing", resolve = unknown }))
  end)
end)

describe("classify.paneChat", function()
  local chat = {
    age = 60,
    promptAt = 100,
    session = "s",
    pane = "P",
    remote = "git@github.com:me/budget.git",
    bundle = "b",
  }

  it("matches a chat to the pane it was opened in", function()
    assert.equal("s", classify.paneChat(R, { bundle = "b", pane = "P", chats = { chat } }).session)
  end)

  it("cuts the window and tab off both ends before comparing them", function()
    -- the environment says w0t3p0:P and AppleScript says P, or the other way
    -- round if an adapter hands back what it was given
    assert.equal("s", classify.paneChat(R, { bundle = "b", pane = "w0t3p0:P", chats = { chat } }).session)
    local prefixed = { age = 60, promptAt = 100, session = "s", pane = "w0t3p0:P", remote = chat.remote, bundle = "b" }
    assert.equal("s", classify.paneChat(R, { bundle = "b", pane = "P", chats = { prefixed } }).session)
    assert.is_nil(classify.paneChat(R, { bundle = "b", pane = "w0t3p0:Q", chats = { chat } }))
  end)

  it("needs a pane on both sides, and the same application", function()
    assert.is_nil(classify.paneChat(R, { bundle = "b", chats = { chat } }))
    assert.is_nil(classify.paneChat(R, { bundle = "b", pane = "", chats = { chat } }))
    assert.is_nil(classify.paneChat(R, { bundle = "b", pane = "Q", chats = { chat } }))
    assert.is_nil(classify.paneChat(R, { bundle = "elsewhere", pane = "P", chats = { chat } }))
  end)

  it("ignores a chat nobody has spoken to for longer than chatSeconds", function()
    local stale = { age = 99999, promptAt = 1, session = "s", pane = "P", remote = chat.remote, bundle = "b" }
    assert.is_nil(classify.paneChat(R, { bundle = "b", pane = "P", chats = { stale } }))
  end)
end)

describe("classify.tokens", function()
  it("splits on whitespace and path separators and strips decoration", function()
    assert.same(
      { "main.go", "budget", "Visual", "Studio", "Code" },
      classify.tokens("● main.go — budget — Visual Studio Code")
    )
    assert.same({ "me@mac", "git", "infra" }, classify.tokens("me@mac: ~/git/infra"))
    assert.same({}, classify.tokens(nil))
  end)
end)

describe("classify.paths", function()
  it("finds every absolute path and expands the home directory", function()
    assert.same(
      { "/Users/me/git/infra/stacks", "/Users/me/git/budget" },
      classify.paths("a — /Users/me/git/infra/stacks — ~/git/budget", "/Users/me")
    )
    assert.same({}, classify.paths("no path here", "/Users/me"))
    assert.same({}, classify.paths(nil, "/Users/me"))
  end)
end)

describe("classify.remoteClass", function()
  it("matches the first rule whose text is in the URL", function()
    assert.equals("work", classify.remoteClass(R, "https://git.example.com/scm/x/y.git"))
    assert.is_nil(classify.remoteClass(R, "https://gitlab.com/x/y.git"))
    assert.is_nil(classify.remoteClass(R, nil))
  end)
end)
