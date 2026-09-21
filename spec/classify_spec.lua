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
      local work = {
        age = 60,
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

      -- unless the person has said, and then their word stands
      obs.chosen = "w2"
      assert.same({ "private", "chat" }, { decide(obs) })
      obs.chosen = "gone"
      assert.same({ "work", "chat", true }, { decide(obs) })

      -- a chat whose repository the rules know nothing about is not a second
      -- opinion, it is no opinion
      also.remote = "git@example.org:me/elsewhere.git"
      obs.chosen = nil
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

    it("offers as candidates only the chats the rules have a class for", function()
      local chats = {
        { age = 1, promptAt = 3, session = "a", remote = "git@github.com:me/budget.git", bundle = "b" },
        { age = 2, promptAt = 2, session = "b", remote = "git@example.org:me/elsewhere.git", bundle = "b" },
        {
          age = 3,
          promptAt = 1,
          session = "c",
          remote = "ssh://git@git.example.com:7999/team/infra.git",
          bundle = "b",
        },
      }
      local remote, unsure, candidates = classify.chatOf(R, { bundle = "b", chats = chats })
      assert.equal("git@github.com:me/budget.git", remote)
      assert.is_true(unsure)
      assert.same({ "a", "c" }, { candidates[1].session, candidates[2].session })
      assert.equal(2, #candidates)
      assert.is_nil(classify.chatOf(R, { bundle = "b", chats = {} }))
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

    it("takes the newest of two chats that shared one pane, or the one picked out of them", function()
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
      obs.chosen = "o"
      assert.same({ "work", "pane" }, { decide(obs) })
      -- a chat picked in another pane says nothing about this one
      obs.chosen = "elsewhere"
      assert.same({ "private", "pane" }, { decide(obs) })
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
