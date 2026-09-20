# 0004 — A coding tool says where it is working, through a hook

**Status:** accepted, 2026-09-20.

## The problem

A coding assistant runs for minutes at a time with the person reading, not
typing, and its window title does not name the repository it is changing. Yet
that repository is the clearest possible answer to whose time it is: a session
in the employer's repository is work, one in a GitHub repository is not.

## The decision

The tool tells the tracker. `zyt hook claude-code` is wired to Claude Code's
`UserPromptSubmit` and `PostToolUse` events; it reads the hook's JSON, takes
the directory of the file the tool touched (a session started in a folder full
of checkouts says nothing by its working directory alone) or else the working
directory, asks git for its `origin` remote, and writes a note
(`context.json` in the state directory: when, which tool, which directory,
which remote) whole and then renamed into place. The Spoon reads the note on
every tick and, for a `repo` application whose own directory and title said
nothing, uses it while it is younger than `signalSeconds`.

The hook prints nothing. Anything a `UserPromptSubmit` hook writes to standard
output is handed to the model as context, and a time tracker has no business
there.

Any other tool can leave the same note with `zyt context <source> <dir>`.

## What was rejected

Finding the assistant's processes and reading their working directories. It
finds every session, not the one being looked at, and it needs `lsof` on every
tick.

Having the Spoon call `hs` from the hook to push the note in. The ipc client
can hang when Hammerspoon is busy or restarting, and a hook that hangs stalls
the tool it is attached to. A file is written in a millisecond and read when
the reader is ready.
