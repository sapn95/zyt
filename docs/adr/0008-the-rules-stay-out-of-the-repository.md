# 0008 — The rules stay out of the repository

**Status:** accepted, 2026-09-20.

## The problem

The rules that make this useful are the ones that name things: the employer's
git host, the applications used at work, the words in a browser title that
mean an internal system. A repository that carried them would describe one
person's employer, and could not be opened.

## The decision

`~/.config/zyt/rules.json` is read at start and on request and is never in
this repository. `examples/rules.json` shows the shape with documentation
names in it, and that is all the repository knows. The leak lint refuses any
IPv4 address that is not from a documentation range — private space included,
because that is where real internal addresses live and a real one looks like an
invented one — and the secret scan in CI does the rest a machine can do. Names
it cannot check; that rule is written here and kept by reading.

The state directory (`~/.local/state/zyt/`) is not in any repository either.
The rows are a record of one person's day and belong to them.

## What was rejected

A private branch or a second private repository with the real rules and a
build step that merges them. Two places to keep in step for one JSON file,
and the merge is a way to publish the wrong one.
