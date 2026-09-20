# 0003 — A terminal belongs to the remote of the repository in it

**Status:** accepted, 2026-09-20.

## The problem

The applications a developer spends most of the day in are the ones that say
least about whose time it is. A terminal, an editor and a coding assistant look
the same whether the repository in them is the employer's or a hobby.

## The decision

For an application marked `repo` in the rules, the class comes from the git
remote of the repository it is in: the `remotes` rules map a substring of the
remote URL (`github.com`, the employer's git host) to a class. Where the
repository is found is tried in this order:

1. the working directory the application reports (iTerm2 answers over
   AppleScript);
2. a word in the window title that names a directory under one of the
   `repoRoots`;
3. a recent note from a coding tool's hook ([ADR 0004](0004-a-tool-says-where-it-is-working.md)).

The remote is read from `.git/config` directly, with worktree and submodule
pointers followed, so that thirty title words a minute do not start thirty git
processes. Answers, misses included, are remembered for ten minutes.

## What was rejected

Classifying by directory path (`~/work/…` versus `~/private/…`). It asks the
person to keep their checkouts sorted for the tracker's sake, and the first
repository cloned into the wrong folder is misfiled for as long as it lives
there. A remote is a fact about the repository, not about where it was put.

Reading the title alone. A terminal's title is whatever the shell or the
running command sets it to, and an editor with a workspace folder that is not
itself a repository (a `~/git` full of them) names nothing useful.
