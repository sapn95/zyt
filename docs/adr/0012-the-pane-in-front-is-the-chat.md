# 0012 — The pane in front is the chat, and the terminal says which

**Status:** accepted, 2026-09-22.

## The problem

Four Claude Code sessions in four tabs of one terminal window, in four different
repositories, two of them the employer's and two not. Everything the Spoon had to
go on was wrong for at least one of them. The window title is whatever the tool
called the conversation, so a word in it names a checkout by accident or not at
all. The working directory iTerm2 reports over AppleScript is the shell's, which
is where the session was started and not where it is working: a terminal opened
in `~/git` resolves to no repository at all. The shared note names whichever
session spoke last, so reading an employer repository in one tab while another
tab worked on a private one recorded private time. Measured on this machine: the
open segment said `class = private, source = repo` while the tab in front was a
work repository, because a sibling tab's conversation was called `pfadi` and
`~/git/pfadi` exists.

[ADR 0010](0010-which-chat-of-several.md) made every session keep its own note
and turned a disagreement into a question. The question is the right answer when
nothing can know. Here something does know.

## The decision

**The note says which pane it was opened in, and the Spoon asks the terminal
which pane is in front.** iTerm2 puts an id for the pane into the environment of
every shell it opens there, and everything started in that shell inherits it, a
hook included; the same id is what AppleScript returns for the session in front.
So the hook writes `pane` into the session note, the Spoon reads
`unique ID of current session of current window`, and the two meet on a string.
No panels have to be enumerated, no accessibility tree has to be walked, and
nothing has to be installed into the terminal.

**It outranks everything else about a terminal window.** The pane is the one fact
here that nobody has to interpret: the terminal said which of its panes is
selected, and the session opened in that pane said what it last worked on. A word
in the title that names another checkout, and a shell still sitting where it was
opened, are both weaker, and they were what a terminal full of chats used to be
classified by.

**It also answers the question instead of asking it.** When the pane names the
chat, the chats no longer disagree about anything and the panel from
[ADR 0009](0009-ask-once-and-remember.md) stays down. Switching tabs in a
terminal is now silent and correct, where before every switch between an employer
repository and a private one was worth a question. A chat picked by hand still
counts inside the pane — two sessions can have shared one tab, one after the
other — but a pick naming a chat in some other pane is not an answer about this
one, and the menu stops showing it as if it were.

A terminal that keeps its panes to itself, or a session started somewhere that
has no panes at all, writes no `pane` and loses nothing: the order from
[ADR 0003](0003-a-terminal-belongs-to-its-remote.md) is still there underneath.
`zyt doctor` says which of the two the terminal it is run in is.

## What was rejected

Enumerating the panes and reading their titles. iTerm2 refuses it: asking for the
variables of every session of every window comes back `-1723 Access not allowed`,
and it would be a lot of AppleScript per tick for something the pane id settles
in one call.

Matching on the tty instead of the pane id. Terminal.app exposes the tty of its
selected tab and iTerm2 exposes both, so it looks like the more portable key. A
hook cannot find its own tty, though: its standard input is the JSON payload on a
pipe and its output is captured, so there is no file descriptor left that names a
terminal. The pane id arrives in the environment, which a hook always has.

Trusting the pane's chat only while its working directory agrees. It sounds
careful and it buys nothing: while a session runs in a pane, that pane's shell is
blocked and its directory cannot change, so the two only disagree after the
session has ended, and then the note ages out on its own within `chatSeconds`.
