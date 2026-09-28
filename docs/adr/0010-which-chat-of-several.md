# 0010 — Which chat, out of the several open in one editor

**Status:** accepted, 2026-09-20; amended 2026-09-28, the panel asks whose time
it is and the chats are listed in the menu.

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
about the editors that do not. When the live chats straddle both classes the
panel from [ADR 0009](0009-ask-once-and-remember.md) opens and asks whose time
it is: Work, Private, Later. Two rows and the way out.

Listing the chats instead was tried first, and the reasoning was sound enough on
paper: the class of each is already known, so the only open question is which of
them is being read, and naming one settles it without the person having to think
about classes at all. In practice it asks them to do the classifying. A list of
conversations has to be read, and then mapped onto work and private in the head,
several times an afternoon, and the rows were repository names at first, which
is not how anybody remembers which chat is which. The question the tracker needs
answered is whose time this is, and that is the question to put. The count of
open chats goes in the line above the rows, because that is the whole reason it
is being asked.

The answer is about this hour, not about any of the chats, and it is kept in
memory. A prompt landing in one of that application's chats drops it: typing
says where they are more plainly than an answer given a while ago, and the chat
typed into is what the class comes from again. An unlock drops it too, for the
same reason a pin does not survive one. A question that was answered gives its
cooldown back, so the next time nothing can tell, it is asked again rather than
guessed at for half an hour; Later is what spends the cooldown, and that is what
Later is for.

Typing is an answer, and it comes first. A prompt sent within `typingSeconds`
(two minutes) says which chat the person is in more plainly than a click on a
panel could, and it is newer than any answer they could give one, so while it is
that fresh nothing is asked and a panel already standing goes away. It wears off
because the reason the question exists is the other chat, the one they turn to
while this one works, and that is what makes it rare. It is put to somebody who
has been reading rather than typing, which is exactly when nothing else can tell.

**The chats are in the menu**, one row each, for naming one by hand when that is
what the person wants: the class of the named chat then decides and no panel is
involved. One row per chat, up to eight of them, and every chat whose repository
has a class gets one. Two chats in one checkout are two rows once they have named
themselves, since the names are what is being picked between; two that have not
named themselves are one row, because two rows carrying the same repository and
the same class would be a choice made blind. Past eight the newest chat of each
class is kept whatever its age, since a list with one class in it has nothing to
pick between. What is kept is one question and the order is another: the rows
stand in the order they were typed into, so nothing older sits above something
newer for having been the only one of its class.

A row names the conversation, not the checkout. It said the repository at first,
because that is where the class comes from and there was nothing else to go on,
and it read as a list of checkouts. The note carries the name the chat goes by
now. Claude Code keeps a `custom-title` entry in the session transcript for a
chat that has been renamed by hand and an `ai-title` entry otherwise, rewriting
the latter as the conversation moves on, and one of those is the title the person
reads in their own list of chats. A name they typed in themselves comes first,
whatever the tool has called the conversation since. The hook takes the end of
that file on every prompt and keeps what it finds. A chat too young to have been
named offers the last thing typed into it, which says as much, and a note from
before any of this still has its repository to fall back on.

The note is not the only way to that name, because a note only changes when
somebody types. A chat that has been read for an hour, or one whose note was
written before any of this existed, would sit in the list as a checkout until it
was next spoken to. So a note without a title sends the Spoon to the transcript
itself: the file is found by session id under the tool's own directory, since the
directory is named after where the session started and not where it went, and the
end of it is read the same way. More than one line of each kind is worth trying,
because the newest can be half of one: the file is appended to while it is read,
and a slice taken from the end of a long one starts in the middle of a line.
Which half is which is for the decoder to say rather than for a pattern to guess
at, and the line before it is the answer either way. What it finds is kept for
five minutes, because a name moves with the conversation it is about. A quarter
of a megabyte of the end is enough of it: the tool rewrites the name on every
exchange, and over the transcripts on this machine that carry a name somebody
typed in, the newest of them was 28.9 KB from the end at the worst, in a file of
37 MB. The hook writing the title at the prompt is what keeps that from having to
happen at all, and a note too old to be a live chat is not worth a file to read.

A chat named from the menu holds for that application until they type into
another one, the same as an answer given to the panel, and for the same reason.
Neither is written down: both are answers about this afternoon, not rules about
a repository. Until there is one, the class is still the chat last typed into,
and the tracker keeps running rather than stopping on a question
([ADR 0002](0002-unknown-is-sticky-not-a-third-class.md)).

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
