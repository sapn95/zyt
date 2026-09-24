# 0010 — Which chat, out of the several open in one editor

**Status:** accepted, 2026-09-20; amended 2026-09-24, the chats are a list with a
row for every repository they are in, up to eight.

## The problem

One editor window can hold several chats at once, in different repositories,
and the class of the moment is whichever one the person is actually reading.
Nothing on the outside says which. The accessibility tree of an Electron editor
lists a handful of elements and no panels: a walk of a Visual Studio Code
window found fifteen elements and not one tab. The lock file the editor's
Claude Code extension writes (`~/.claude/ide/<port>.lock`) names the workspace
folders of the window, one file per window, and says nothing about what is open
inside it.

[ADR 0004](0004-a-tool-says-where-it-is-working.md) settled for the chat the
person last typed into. That is right until they read the other one.

## The decision

Three things, in the order they help.

**A note per session, which remembers.** The hook writes
`sessions/<session id>.json` beside the shared notes, and each event merges into
the one before it: the repository kept is the last one that session actually
touched, and `promptAt` is when somebody last talked to it. Without that memory
the common case is the broken one — a session started in a folder full of
checkouts has a working directory that resolves to no repository, and a prompt
carries no file to go on, so the chat being typed into would be the one thing
about it nobody knows. A session that has only ever worked has no `promptAt`
and is no chat; the busy ones are what `context.json` is for. The merge takes a
lock on one empty file in that directory, because a session's hooks do arrive at
once: a prompt typed while a task left running in the background reports the
file it touched. Both would read the note and the later write would erase what
the other had just learnt. Expired notes are dropped under the same lock, so
one that looked stale cannot be deleted after the session it belongs to has
written it again. The lock is never deleted, so it cannot be unlinked from under
a hook that holds it, and one lock for the directory means there is nothing to
decide about that. Which hook reaches the lock first settles nothing else: where
the session is comes from the newest event to have written, an older one that sat
out a `git` call only fills in what the note does not say yet, and no timestamp
goes backwards. A whole second cannot tell two of one session's hooks apart, so
the note also carries the moment to the microsecond, and that is what the merge
reads.

**Agreement is certainty.** The Spoon reads every note, keeps the ones written
by the application in front and typed into within `chatSeconds`, and asks the
rules for each. When they all come out the same class, that is the class, and
which panel is in front stops mattering. Two chats in employer repositories are
work whichever one is being read.

**Disagreement is a question, not a guess** — where nothing can know which panel
is in front. A terminal does know, and
[ADR 0012](0012-the-pane-in-front-is-the-chat.md) asks it, so what follows is
about the editors that do not. When the live chats straddle both
classes the panel from [ADR 0009](0009-ask-once-and-remember.md) opens with the
repositories listed in it — `sapn95/zyt` or `sapn95/budget`, not Work or
Private, because the class is already known for each and the open question is
which of them the person is in. The owner is part of the name, since the same
name under two owners is one of the reasons to be asked in the first place.

One row per repository, the newest chat of it, and every repository that has a
class gets a row up to eight of them: a panel that showed three and kept the
fourth to itself was asking about a chat the person could not pick. Two chats in
one checkout are one row, because two rows with the same name and the same class
would be a choice made blind. Past eight the newest chat of each class keeps its
place whatever its age, since the question is only asked because the chats
straddle both classes and a list with one class in it has no answer in it. The
last row is Later, which answers nothing and takes the panel away, and it is
there because nothing else does any more.

A panel that is waiting has its list rebuilt on every tick. A chat that has
closed drops out of it, one opened since comes into it, and once the chats stop
disagreeing the panel goes on its own: the cooldown holds the question back, not
the list the panel is showing while it waits.

The answer holds for that application until they type into another chat, which
says where they are more plainly than a click. It is kept in memory and not
written down: it is an answer about this afternoon, not a rule about a
repository. The same list is in the menu, so the chat can be named without
waiting to be asked. Until it is answered, the class is still the
chat last typed into, and the tracker keeps running rather than stopping on a
question ([ADR 0002](0002-unknown-is-sticky-not-a-third-class.md)).

## What was rejected

Taking whichever session's transcript grew most recently. That is the session
doing the most work, not the one being read, and it is exactly the mistake the
chat note was introduced to stop: an agent grinding away in the background
would outvote the person typing.

Asking the editor over its own extension API. It would mean an extension per
editor to install and keep working, for one string; Kiro and the next editor
each need their own. The person answers in one click and the hook keeps working
for every tool that has one.

Writing the choice to `learned.json`. The answers there are about a repository
or an application and stay true tomorrow. Which chat somebody is reading is
true for an afternoon, and a stale answer there would be worse than no answer.
