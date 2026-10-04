# 0010 — Which chat, out of the several open in one editor

**Status:** accepted, 2026-09-20; amended 2026-09-28, the panel asks whose time
it is; amended 2026-10-04, the answer belongs to the chat and the list of chats
is gone.

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
it is: Work, Private, Later. Two rows and the way out, and the line above them
names the chat the question is about.

Listing the chats instead was tried first, and the reasoning was sound enough on
paper: the class of each is already known, so the only open question is which of
them is being read, and naming one settles it without the person having to think
about classes at all. In practice it asks them to do the classifying. A list of
conversations has to be read, and then mapped onto work and private in the head,
several times an afternoon, and the rows were repository names at first, which
is not how anybody remembers which chat is which. The question the tracker needs
answered is whose time this is, and that is the question to put.

**The answer belongs to the chat it was asked about**, and is kept in memory
under its session id. The chat the person last typed into is the one the panel
names and the one the answer is filed under, so each conversation is asked about
once and never again, however many times the editor goes quiet afterwards. What
brings the panel back is a chat nobody has answered for: a new session, or an
older one surfacing in an editor whose chats still straddle both classes.

Asking per application was what the amendment of 2026-09-28 did, and it asked
too often. The answer was dropped by any prompt in any of that application's
chats, including the chat it was about, so a conversation that had just been
classified put the same question again on its next exchange. Keyed by chat, a
prompt needs to drop nothing: typing in a chat that has been answered for leaves
a standing answer standing, and typing in one that has not is `typingSeconds` of
quiet followed by its own question. An unlock no longer drops the answers either.
A conversation is work or private for its whole life, which an hour of an editor
is not.

Later still spends the cooldown, which is what keeps a question somebody walked
away from, or one they chose not to answer, from coming straight back.

Typing is an answer, and it comes first. A prompt sent within `typingSeconds`
(two minutes) says which chat the person is in more plainly than a click on a
panel could, and it is newer than any answer they could give one, so while it is
that fresh nothing is asked and a panel already standing goes away. It wears off
because the reason the question exists is the other chat, the one they turn to
while this one works, and that is what makes it rare. It is put to somebody who
has been reading rather than typing, which is exactly when nothing else can tell.

**The list of chats is gone.** It stood in the menu for a fortnight as a way of
naming the chat in front by hand, and nothing about it earned its keep: naming
one is the same work as answering the question, it was one more thing to keep
current on every tick, and the question the panel now puts does not need to know
which chat it is to be answered. What is left of it in the menu is one row,
offering to forget the answer about the chat in front, under the name that chat
goes by.

The name is what the panel says, so it is still read. It said the repository at
first, because that is where the class comes from and there was nothing else to
go on, and it read as a list of checkouts. The note carries the name the chat
goes by now. Claude Code keeps a `custom-title` entry in the session transcript for a
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

Nothing of this is written down: an answer about a conversation is true while
that conversation is live, and the notes behind it expire with it. Until there is
an answer, the class is still the chat last typed into, and the tracker keeps
running rather than stopping on a question
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

Writing the answer to `learned.json`. The answers there are about a repository
or an application and stay true tomorrow. One about a chat is true while the
chat is, and the next conversation in the same checkout can be the other class,
so a stale answer there would be worse than no answer.

Asking about every new chat, whatever the rules say. It is one question per
conversation either way, and the rules answer most of them correctly without
being asked: a chat in an employer repository among employer repositories is
work, and a panel confirming that is a panel nobody needed. The question stays
where nothing else can tell.
