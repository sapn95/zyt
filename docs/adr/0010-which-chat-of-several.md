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

Typing is an answer, and it comes first. A prompt sent within `typingSeconds`
(two minutes) says which chat the person is in more plainly than a click on a
panel could, and it is newer than any answer they could give one, so while it is
that fresh nothing is asked and a panel already standing goes away. The cooldown
stays where it is when a panel goes like that: the question was answered, not
missed. It wears off because the reason the question exists is the other chat,
the one they turn to while this one works, and that is what makes it rare. It is
put to somebody who has been reading rather than typing, which is exactly when
nothing else can tell.

One row per chat, up to eight of them, and every chat whose repository has a
class gets one: a panel that showed three and kept the fourth to itself was
asking about a chat the person could not pick. Two chats in
one checkout are two rows once they have named themselves, since the names are
what is being picked between; two that have not named themselves are one row,
because two rows carrying the same repository and the same class would be a
choice made blind. Past eight the newest chat of each class is kept whatever its
age, since the question is only asked because the chats straddle both classes
and a list with one class in it has no answer in it. What is kept is one
question and the order is another: the rows stand in the order they were typed
into, so nothing older sits above something newer for having been the only one
of its class. The
last row is Later, which answers nothing and takes the panel away, and it is
there because nothing else does any more.

A row names the conversation, not the checkout. The first list said the
repository, because that is where the class comes from and the panel had
nothing else to go on, and it read as a list of checkouts: not how anybody
remembers which chat is which, and two chats in one repository were two
identical rows. The note carries the name the chat has given itself now. Claude
Code keeps an `ai-title` entry in the session transcript and rewrites it as the
conversation moves on, which is the title the person reads in their own list of
chats, so the hook takes the end of that file on every prompt and keeps what it
finds. A chat too young to have been named offers the last thing typed into it,
which says as much, and a note from before any of this still has its repository
to fall back on.

The note is not the only way to that name, because a note only changes when
somebody types. A chat that has been read for an hour, or one whose note was
written before any of this existed, would sit in the list as a checkout until it
was next spoken to, which is exactly the chat the question is about. So a note
without a title sends the Spoon to the transcript itself: the file is found by
session id under the tool's own directory, since the directory is named after
where the session started and not where it went, and the end of it is read the
same way. What it finds is kept for five minutes, because a name moves with the
conversation it is about. The hook writing the title at the prompt is what keeps
that from having to happen at all, and a note too old to be a live chat is not
worth a file to read. The colour goes on saying work or private, so dropping the name
of the checkout costs the row nothing.

The question goes when the window it is about does. A panel about the chats of
one editor cannot change what is being recorded while another application is in
front, nothing is keeping its list current there, and a chat it names may have
ended in the meantime: a list like that is a question about an afternoon that
has moved on. So it is taken down as soon as the application it is about is no
longer in front, and the cooldown stays where it is. Somebody who saw the
question and went somewhere else has said Later without having to click it.

A panel that is waiting has its list rebuilt on every tick, whether anybody is
at the keyboard or not. A chat that has closed drops out of it, one opened since
comes into it, and once the chats stop disagreeing the panel goes on its own. The
cooldown and the wait for somebody to be there are what it takes to ask a
question, not what it takes to keep one honest while it stands.

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
