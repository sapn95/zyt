local repo = require("zyt.repo")

local CONFIG = table.concat({
  "[core]",
  "\tbare = false",
  '[remote "origin"]',
  "\turl = ssh://git@git.example.com:7999/team/infra.git",
  "\tfetch = +refs/heads/*:refs/remotes/origin/*",
  '[remote "fork"]',
  "\turl = git@github.com:me/infra.git",
  "",
}, "\n")

local function fakeFs(files)
  local reads = 0
  return {
    read = function(path)
      reads = reads + 1
      return files[path]
    end,
    reads = function()
      return reads
    end,
  }
end

describe("repo.remote", function()
  it("reads origin from .git/config, from any directory inside", function()
    local fs = fakeFs({ ["/h/git/infra/.git/config"] = CONFIG })
    assert.equals("ssh://git@git.example.com:7999/team/infra.git", repo.remote("/h/git/infra", fs))
    assert.equals("ssh://git@git.example.com:7999/team/infra.git", repo.remote("/h/git/infra/stacks/prod", fs))
  end)

  it("can be asked for another remote", function()
    local fs = fakeFs({ ["/h/git/infra/.git/config"] = CONFIG })
    assert.equals("git@github.com:me/infra.git", repo.remote("/h/git/infra", fs, "fork"))
    assert.is_nil(repo.remote("/h/git/infra", fs, "upstream"))
  end)

  it("follows a worktree's pointer to the main repository's config", function()
    local fs = fakeFs({
      ["/h/git/infra-wt/.git"] = "gitdir: /h/git/infra/.git/worktrees/infra-wt\n",
      ["/h/git/infra/.git/config"] = CONFIG,
    })
    assert.equals("ssh://git@git.example.com:7999/team/infra.git", repo.remote("/h/git/infra-wt/x", fs))
  end)

  it("follows a submodule's relative pointer", function()
    local fs = fakeFs({
      ["/h/git/app/vendor/lib/.git"] = "gitdir: ../../.git/modules/vendor/lib",
      ["/h/git/app/vendor/lib/../../.git/modules/vendor/lib/config"] = CONFIG,
    })
    assert.equals("ssh://git@git.example.com:7999/team/infra.git", repo.remote("/h/git/app/vendor/lib", fs))
  end)

  it("gives up at the root", function()
    local fs = fakeFs({})
    assert.is_nil(repo.remote("/h/git/nothing", fs))
    assert.is_nil(repo.remote("/", fs))
  end)
end)

describe("repo.resolver", function()
  it("remembers hits and misses until the ttl runs out", function()
    local now = 1000
    local fs = fakeFs({ ["/h/git/infra/.git/config"] = CONFIG })
    local resolve = repo.resolver(fs, 600, function()
      return now
    end)
    assert.equals("ssh://git@git.example.com:7999/team/infra.git", resolve("/h/git/infra/"))
    assert.is_nil(resolve("/h/git/missing"))
    local after = fs.reads()
    resolve("/h/git/infra")
    resolve("/h/git/missing")
    assert.equals(after, fs.reads())
    now = now + 601
    resolve("/h/git/infra")
    assert.is_true(fs.reads() > after)
  end)
end)
