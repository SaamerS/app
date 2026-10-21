# All-day capture

Binders can listen all day, on your iPhone or on your Mac, cut the day into conversations and write each one down as a **capture**. On the
iPhone it's written down on the phone and only the text goes to Binders on your Mac. There, each conversation gets a summary, its promises become to-dos, and it is filed in the binder
it belongs to, searchable and askable like a meeting. It's a way to try an all-day wearable before there is one: a
wearable will be another microphone feeding the same pipeline on the phone.

## How it works

1. **Listening.** With All-day capture on, the iPhone's microphone stays on in the background, mixed with whatever you're
   playing, so music and podcasts carry on at full volume. A small voice detector (Silero, through FluidAudio, on the
   CPU) hears when someone is speaking; until it has downloaded, or whenever it can't read a stretch, loudness stands in,
   and the capture screen says so ("by loudness until the voice detector is ready") until it reads again.
2. **Conversations.** The first speech after a quiet spell opens a conversation. It closes after three minutes without
   speech, or at 90 minutes, where it's split and the next one carries on. One with less than 20 seconds of speech in it
   isn't kept: a cough, a "thanks", the radio next door. Its audio is deleted at once and it leaves a **Not kept · too
   short** row with only its time and how many seconds of speech it had, which goes after 30 days; the day's count says
   how many ("Too short to keep"). **Wrap Up Now**, on the capture screen or the open capture's page, closes it at once and keeps it from 3
   seconds of speech; the Mac doesn't drop it for being short, though its model can still call it small talk. With a
   Mac from before outcomes (0.8.0), Wrap Up keeps the usual 20 seconds, as that Mac would call less small talk.
3. **Only speech is kept.** The phone writes only the speech, with a second either side, to one file per conversation, and
   notes when each stretch was heard, so the transcript's times line up with the day. Beside the records, one index file,
   `captures.index`, holds a line per capture (state, times, the outcome line, the transcript's first line, counts), so
   launch and the capture list open no record. It's only a cache: each launch checks it against the folder's file dates,
   reads a record that changed behind it, and makes it again from the records when it's missing or doesn't match.
4. **Writing it down, on the phone.** When a conversation ends, Parakeet (the same model the Mac uses for meetings)
   transcribes it, and the offline diarizer tells the voices apart: "Speaker 1", "Speaker 2". If you taught Binders your
   voice, the voice closest to it is "You". With Said to yourself's Mode at Add at Once or Auto, the phone also works out
   from the voices whether it heard only you in it; then every voice of yours is "You" (when the diarizer split your
   voice in two, both are), and a stretch with anyone else in it, or that no voice was heard saying, is "Not sure who"
   (Things you say to yourself, item 10). This happens right away while the app is open, and while the phone charges.
   In a pocket on battery it happens only with **Write down while the iPhone is locked** on (off until you turn it on, as
   it uses more battery): then, while capture listens, it keeps the app running, so a conversation is written down within
   a minute or two of ending. With it off, captures wait for the app or the charger and their rows say so, and opening
   Binders with captures waiting keeps the screen on until they're written down. A capture the speech model finds no
   words in (pocket noise, music, a language Parakeet can't read) is kept as **Not kept: nothing to write down**, with its
   timeline: it's never tried again, its audio is deleted at once, and Today counts it beside "Too short to keep". With
   the setting on, writing down on battery waits when the phone is hot, in Low Power Mode or under 20%, for
   conversations with more than 15 minutes of speech, and after an update until Binders has been opened once (both models are readied, and
   compiled for the Neural Engine, with the app open); those are written down when the app opens, or while the phone
   charges. In the background only Parakeet and the diarizer write it down, never Apple's engine and never as one voice,
   paced to stay under 40% of a core over a minute, and stopping between steps, with what's done kept, once capture
   stops listening (a call, Mute) or the phone can't spare it any more; if anything goes wrong there, that capture waits
   for the app and nothing more is tried in the pocket until the app is next open. If iOS stops Binders while it writes
   one down, a notification says capture stopped, and that capture is written down only with the app open from then on.
   A capture left waiting brings one quiet notification, at most once an hour. Every step is saved, so a quit or an iOS
   time limit only pauses it: what was cut short waits, and voices are never merged into one because it ran out of time.
   One that fails is tried again when the app next comes to the front, once a visit, up to three times, within three
   days, and its audio is deleted after the last try; if telling the voices apart is what keeps stopping Binders, the
   text goes as one voice.
   Deleting one while it's being written down stops the work, and nothing of it goes to the Mac.
5. **Text to the Mac.** The transcript goes into the outbox the app already uses for notes and dictation, and is sent when
   the Mac is reachable (home network or Tailscale), beside the writing down, so a Mac asleep never holds up the next
   capture. Once it's in the outbox, the audio is deleted. While you talk, the phone says a word to the Mac, at most
   every 30 seconds: a Mac that went to sleep is noticed before the sentence ends, and every two minutes the Mac loads
   its model (`binders/warm`), so the write-up doesn't wait for it.
6. **On the Mac.** Each conversation becomes a record of its own kind. The language model writes a short summary,
   decisions, promises by you and to you, ideas and people mentioned, then picks the binder it belongs to from your binders'
   names and what's in them. When nothing clearly fits, it goes where new things go. A conversation with nothing worth
   keeping (small talk, a TV in the background) is marked trivial: hidden, and deleted after a week. Under 40 words, it's
   trivial without asking the model, unless you wrapped it up. With no model to write notes, it isn't filed by guesswork:
   the phone hears why. A capture your iPhone heard as only you, with Mode at Add at Once or Auto, is first read for what
   you said (Things you say to yourself, item 10), and its notes then have no Promises of their own.
7. **What became of it.** The iPhone asks the Mac about its sent captures (`binders/outcomes`, over the link only) and
   each row says: **Filed** "in Events: Ignite booth plan · 2 to-dos", **Not kept** (too short, small talk, or nothing to
   write down), or **Not
   written up** with the reason ("Choose a language model in Settings"). Each capture's page has **What happened**: when
   it was heard and closed, why it waited, how it was written down (words, engine, seconds), when it was sent and where
   it was filed. The timeline stays on the iPhone and has no words from the capture.

## Without the network: AirDrop and Files

When the Mac can't be reached over the network, the iPhone can hand conversations over as a **Binders file** (`.binders`):

- On the iPhone, open a capture and choose **Share…**, or tap **Send the waiting captures by AirDrop…** under
  today's captures. The share sheet offers AirDrop, Save to Files (iCloud Drive) and Mail.
- On the Mac, a Binders file opens in Binders: AirDrop opens it as it arrives, or double-click it, or use **Open a Binders
  File…** in Settings → All-day capture or in a binder's Captures tab. Each capture in it is kept like one sent
  over the network, and one that's already here isn't kept twice. A file AirDrop left in Downloads goes to the Trash once
  it's kept, so the text doesn't sit there.
- Sent by AirDrop, a conversation leaves the iPhone's outbox. Shared anywhere else (Files, Mail), it still goes over the
  network when it can, and the Mac keeps it once.

A Binders file is JSON: `{"format": "binders", "version": 1, "conversations": [...]}`, each conversation as in
[LINK.md](LINK.md#conversations). The text is readable by anyone who has the file, so share it with your own Mac.

## On the Mac

Settings → All-day capture → **Listen for conversations on this Mac** does the same on the Mac, with its microphone: the
same voice detector and the same cut into conversations (its waveform there moves only while speech is heard, and holds
still in the quiet while a conversation stays open), written down with the Mac's speech model and diarizer, and kept
as conversations straight away. It lets go while a meeting is recorded (that's a meeting), and what you dictate isn't part
of a conversation. The menu bar menu has All-day Capture and Mute. After a quit it asks before listening again. If your
iPhone listens too, a conversation near both is written down twice.

## After a conversation: cards and answers

Once a conversation is written up, Binders offers two things:

- **A card** for each thing you said you'd do that isn't on a board yet: "Put this on the Harbor launch board?" with **Add to
  Board** and **Not Now**. Yes puts it in Ready on that binder's board, linked to the to-do, so it's ticked off when the
  card is done. When Binders doesn't know which voice is yours (no voice print), it offers anyone's promises.
- **An answer** to a question you asked that the conversation didn't answer, when your notes, meetings or earlier
  conversations hold one: "You asked: when is the Harbor launch date?" with the answer and where it came from. It only
  answers from what your binders say; when they don't say, there's no notification.

A capture in which only you spoke, from an iPhone in Add at Once or Auto mode, has no promise cards: it's read for
to-dos, things to fix and ideas instead, which are added at once rather than offered (past the eighth, offered), and in
Auto mode may be handed to an agent (Things you say to yourself, item 10). Answers come as for any capture.

They come as notifications on the device that heard the conversation, and wait on the conversation's page on both the
iPhone and the Mac. On the iPhone, while capture listens, the app stays connected to the Mac so they arrive while you're
out. Turn them off in Settings → All-day capture on the Mac (each kind), or with **Notify me** on the iPhone.

## Things you say to yourself

With **Listen for things you say to yourself** on (the capture screen, under **Said to yourself**; off until you turn it
on, and explained the first time), the iPhone also listens, while capture does, for something short said on its own: about
1 to 15 seconds of speech, with quiet before it and nobody answering after it (MomentDetector). It changes nothing for
conversations, which hear and keep the same speech.

1. **Written down on the phone**, by Parakeet when it's downloaded, otherwise Apple's on-device engine. Fewer than two
   words is let go.
2. **Kept, or let go.** It's kept when it starts with "Binders" ("Binders, remind me to call Sam tomorrow at 3"), or,
   once Binders knows your voice, when it passes four checks: quiet before it, a cue (need to, have to, got to, don't
   forget, remember to, remind me, note to self, idea for, "what was … again", and at the start of a sentence "what's
   happening", "what's going on", "what's the latest", "where are we on" or "catch me up"; "status of" anywhere), your
   voice (voice print score 0.65 or more until you calibrate it, below), and on iOS 26 with Apple Intelligence, Apple's on-device
   model reading it as the same kind of thing the rules did. The model gets 2 seconds; when it's slow, fails or isn't
   there, the other three decide, and the capture screen says so. A clip the model reads differently is let go, and why
   (kinds only, such as "Not a moment: Apple's model read it as a question, the rules as a to-do") goes on the
   conversation's What happened. Nothing is kept of the rest, and its audio never goes anywhere. More than 20 write-downs
   in ten minutes (a TV, a podcast) rests moments for ten minutes.
3. **"Binders, …" in the middle of a conversation.** A burst after about a second of quiet gets a quick check of its first
   second and a half, at most six a minute, and one that opens with "Binders" becomes a moment, with the conversation
   left as it is: its transcript keeps the sentence, but its notes and suggestions leave out what became a moment, so
   one sentence makes one to-do. While you keep talking with moments on, Parakeet stays loaded for these checks (30 seconds after the
   last one), which costs some battery. Once a conversation is written down, sentences in your voice that open with
   "Binders," become moments too, unless one with mostly the same words was heard within two minutes of its segment's
   start or end. These go to the Mac before their conversation. This needs your voice print.
4. **Only the words go to the Mac** (`binders/moment`, see [LINK.md](LINK.md)), now or once it's back. The Mac reads what
   it is with rules first (a question, a to-do, an idea, "what's happening", a note; a binder named in it; when it's
   due), and asks its model, in the fast lane ahead of write-ups, only when the rules can't tell. That one call sees your
   binders and your agents, each with what it's for, and an agent it names gets an **Assign** offer, never an
   assignment. The agent offered is the one you named; else the only agent that takes cards from the binder it went in;
   else, of those that do, the one the model says fits by what each is for (fill in **What it's for** in Settings →
   Agents: "personal errands" fits "book a doctor's appointment"). When the binder was settled without the model and two
   or more agents take its cards, one short call that sees only that binder asks which fits. Nothing says which, and no
   agent is offered rather than a guess. An agent changed outside Binders goes to the model by its name only. With Mode
   (item 9) at Auto, the phone also sends its mode and, for what it heard as you on your own, its yes for each agent
   (`mode`, `agreed`; see [LINK.md](LINK.md)).
5. **What it does.** Said with "Binders, …", a to-do goes into your to-dos and an idea onto the named binder's Backlog at
   once, with **Undo**; a question is answered from your binders, or "Nothing in your binders about …". Heard on its own,
   in **Suggest** (the default) a to-do, an idea or a note is offered (**Add**, **Not Now**, **Not Me**) and nothing is
   made until you say; in **Add at Once** and **Auto** it's made at once, with Undo (item 9). A question your binders
   can't answer stays quiet. Nothing it makes is handed to an agent without a tap, with two exceptions, both only for an
   agent you let start on cards Binders sends it (Settings → Agents) and said yes to on your iPhone: a to-do you say on
   your own with "Binders, …", that your iPhone hears as your voice, when it's clearly that agent's work; and, in Auto
   mode, a to-do or an idea you say on your own or after "Binders, …", in your voice, when Binders' decision model is
   sure enough it's that agent's work, or you named it (item 9). Nothing heard in a conversation, and nothing told to
   Siri or a Shortcut, ever starts one. Otherwise **Give to**, which names the agent ("Give to Claude Code · app"), takes a tap on an unlocked iPhone. Give to an agent that
   doesn't take that binder's cards is turned down with why ("Coder doesn't take cards from the General board. Change
   that in Settings → Agents."). With the Mac out of reach, a Give to is
   kept and goes when the Mac is back ("Kept. It goes to your Mac when it's back."), with `request_id` so it's made once;
   if the Mac turns it down then, a notification says why.
6. **Graduation**, in Suggest. Each kind heard on its own (to-dos, ideas, notes) is offered until you've answered 40 offers of it and
   nearly all were Add (a 95% lower bound of 0.85 on the share added, about 39 of the first 40), with no Not Me among the
   last 40. From then on it's added at once with Undo, and a notification says so. Two Undos in its last ten send it back
   to offering, with a quiet notification. The capture screen shows each kind's state ("Suggesting, 12 of 40", "Added with
   Undo") with a switch to go back to offering; every change starts the count afresh. Questions and status requests never
   graduate. Something added at once this way runs no automation, and work meant for an agent is still offered. It needs
   a Mac that lists `momentAdds`. **Not Me** takes the item back on the Mac, counts as a hard no, and keeps that clip's
   voice score (a number only, the last 50) for calibrating the voice print later. In Add at Once and Auto mode nothing
   is counted, and each kind stays where it was for when you're back in Suggest.
7. **On the notification.** Its title is the Mac's and never holds your words. With iOS showing previews Always, the body
   says what was done ("To-do added in Personal", "1 idea for the Ignite board", "Binders answered your question") rather
   than what you said, unless you turn on **Show what you said on the Lock Screen** (the capture screen, off by default);
   with previews hidden until you unlock, the body is your words. The buttons: an offer has Add, Not Now, Not Me and Open;
   something done has Undo, Give to and Open; something Auto mode handed over has Stop, Undo, Not Me and Open; an answer
   has Open and **Not Right**. Open, and a tap, go to the card, the to-do in its binder, or the moment's own page; for
   something handed to an agent without a tap, always its own page, where Stop, Undo, Not Me and Turn Off Auto are.
   After Add on a notification, an "Added to Personal: …" follow-up takes
   its place, with Undo, Give to and Open. Not Right keeps the question on the capture screen with **Ask Again**, which
   opens Ask with it. A "Couldn't do that" or "Waiting for your Mac" notification opens the moment's own page, to try
   again. Add on an offered note checks its binder again: shared with your team since, the note goes into one of yours
   that isn't, or isn't kept.
8. **Where it shows.** Each moment is listed under **Said to yourself** (and on Today, on iOS 26) with what became of it,
   and each row on Today opens the moment's page. An offer shows its question with **Add** and **Not Now** on its row,
   a hand-over shows **Stop** on its row,
   and waits in **Needs you** ("Add 1 thing you said?") on Today, on the home before iOS 26 and on the Needs You widget
   ("1 to add") for three days after it was heard; after that it can still be added from its page. One opens its page,
   several open their list. An offer that arrives with Binders open gives one warning by touch, as other things that wait
   on you do. A moment your Mac is still deciding says "Your Mac is working on it, and says what it made of it
   shortly."; one kept while the Mac is away says it goes to your Mac when it's back.
   On the Mac it's kept as its own kind ("Said to yourself" in the dictation history), out of search, Ask and paste. The
   iPhone deletes a sent moment's words after a week. A **Timings** row shows how long the last 50 took, p50 and p90, on
   the iPhone and on the Mac (numbers only).
9. **Mode, and Auto.** Under Said to yourself, **Mode** says what's done with what's heard on its own: **Suggest**
   (items 5 and 6), **Add at Once** (every kind added at once with Undo, as if graduated; work for an agent still
   offered, with Give to; it needs a Mac that lists `momentAdds`), or **Auto**. In Auto mode, what's heard on its own is
   added at once, and a to-do or an idea, heard on its own or said after "Binders, …", goes to the agent the Mac's
   decision model picks, or the one you named, without a tap, when: that agent has Start on cards Binders sends it on
   (Settings → Agents, with its yes given since Auto mode), drafts first, isn't one that checks the board itself, and has
   your yes on this iPhone as it's set up now, given since Auto mode; the decision model names it at its Auto level (0.60
   for Tev1 0.8B; another model's from its measure, and none without one), or you named it; no other agent's name is
   heard in it; it was you on your own (your voice past the start bar Calibrate sets, quiet before it, nobody
   answering, nothing playing on the iPhone, and nothing else said in the three minutes before it, decided as it's
   heard, `alone`; or a capture in which it heard only you, item 10); it came from an iPhone the Mac allows (the only
   one paired, or one allowed in Settings → Agents → Sorting new cards); it wasn't handed the same agent in the last 30
   minutes; and it reached the Mac within 12 hours, at most five late ones in any ten minutes. Only what the gate keeps
   can go: a sentence with a cue ("I need to", "remember to", "idea for"), or, in Auto mode, one without a cue that the
   rules and Apple's model on the phone both read as a to-do, a fix or an idea ("the login times out too fast", "we
   should add a weekly digest"), in your voice past the start bar; without Apple Intelligence, or when it doesn't
   answer, none without a cue. What you think out loud goes with its capture (item 10). A to-do goes to the agent as a
   card in Ready, to do; an idea's card goes to Ready, to look into and plan. Each hand-over has a notification with
   Stop, Undo and Not Me, the card a note saying Binders handed it over in Auto mode, and the moment's page **Turn Off
   Auto**. What doesn't go is added with Give to, and its line says why. Choosing Auto first shows which agents may take
   what you say, which won't and why; two Not Me's among its last ten hand-overs turn it off, with a notification. With
   a Mac that doesn't list `momentAuto`, Auto mode works as Add at Once, and the capture screen says so.
10. **Thinking out loud.** With Mode at Add at Once or Auto, and Said to yourself on, each capture is checked on the
    phone, once its voices are told apart, for whether only you spoke in it (`SoloRule`): the diarizer ran over the whole
    capture and found speech (its fallback "one voice" never counts); every voice heard for two seconds at a stretch is
    yours, past the start bar Calibrate sets, and two voices of yours don't take turns like two people; anything else,
    stretches too short to score, comes to under three seconds in at most two (a passer-by, a cough, a shop's
    announcement); no more than a tenth of its words were heard as no one's voice; nothing played and no call was up on
    the phone while it wrote speech (checked every five seconds); and a capture that opens right after one cut at 90
    minutes or by an interruption counts only when that one did. Only segments your voices cover, with no one else in
    them, are "You"; the rest are "Not sure who" and never read. The phone sends that with the capture (`mode`, `solo`,
    `soloMoments`, and in Auto mode its yes for each agent; `soloHold`, a word, says why not), only to a Mac that lists
    `soloAuto`, never in a Binders file, and in Auto mode only once you've seen what Auto mode now reads; the capture's
    What happened says it ("one voice, yours (0.86): only you"). The Mac takes it only over the link, from an iPhone it
    lets hand over, when the transcript agrees, it doesn't read as talking to someone, and the Mac wasn't on a call
    itself, and then reads your sentences, numbered, without those said as moments in it, with your language model,
    before its notes, for to-dos, things to fix and ideas: each with the sentences it came from, its title in those
    sentences and naming no agent they don't. The first eight each become a to-do of its own in the binder it belongs to
    (an idea, a card on its board's Backlog), added at once with **Undo**; the rest are offered. In Auto mode each then
    goes through item 9's rule on its own, as said at its first sentence's time, a name counting only in its own
    sentences and only when said as meant ("I should get Claude Code to…", not "Codex could…"): what a capture hands
    over takes a place among the five every ten minutes, late or not, and none goes more than 12 hours after it was
    said. Its card quotes only its own sentences, and its briefing leaves the capture out. A moment said during such a
    capture (after a cough, say, or between thoughts), and a "Binders, …" found in its transcript, are added at once and
    go with it: handed over once the capture turns out to be only you, with their own voice past the start bar too; in
    Auto mode a conversation that holds one isn't dropped for being short, and only its numbers go to the Mac. A
    sentence said to another assistant ("Hey Siri, …") is left out. The phone sends one notification for a capture
    (**Open**, **Stop All**), and the capture's page lists **From what you said**: what was handed to whom, added or
    offered and why, each with **Stop**, **Undo** and **Not Me**, with **Stop All**, **Not Only Me** (it asks first,
    takes back everything the capture made, raises the start bar and counts as a Not Me for Auto mode) and **Turn Off
    Auto**. A capture with someone else in it is offered as before, and its page says why. With Write down while the
    iPhone is locked on, a walk's capture is read a few minutes after you stop, for up to 15 minutes of speech;
    otherwise, and for a longer one, when you open Binders or the phone charges.

**Calibrate** (under Said to yourself) checks the gate on your iPhone with the real checks, one clip at a time: 150
phrases in seven groups read by you, the same read by someone else ("not me"), a timed run of 15, 30 or 60 minutes with a
TV or a podcast playing, and a fixed script of 40 lines with what each should come to. The results show what was taken
and let go per group, false accepts, the voice scores on 2-5 second clips and the threshold that lets about 1% of other
voices through, with **Use** (it becomes the voice-print threshold) and **Reset to 0.65**. Capture pauses while it runs
("While you calibrate"). No audio is kept: each clip is scored in memory and dropped, and results keep scores, timings,
labels and word counts, never the words. They stay on the iPhone, out of backups, until **Delete All Results**, and
**Export as CSV** shares them only when you tap it. Teaching your voice again resets the threshold.

Siri's **Ask Binders** and **Tell Binders** go the same way, as if you'd said "Binders, …": Ask always answers or says
what's happening, never adds ("Get the Ignite dates" is a question), and Siri says the answer without its sources, which
stay in the value given to Shortcuts. Ask reads your binders, so it needs the iPhone unlocked; Tell only adds things, so it
works locked and never reads an answer aloud.

## Reading them on the iPhone

Tap a capture on the All-day capture screen to read it: who said what, at what time, and, once your Mac has written it up,
its notes. The transcript stays on the iPhone after the audio is deleted, for 30 days after it's sent, and can be shared
again from there.

Captures show under **Today → Captures**, in a **Captures** tab in the binders they're filed in, and in search, ⌘O and
Ask, labelled as captures. They never appear in the Meetings lists. Over MCP they're left out for every tool until you
allow captures for that tool in Settings → MCP; then `list_meetings` leaves them out unless asked for `kind: capture`, and
`search_knowledge` takes `kind: capture` (both still take `conversation`, which is how captures are stored).

## Privacy

- **Audio never leaves the iPhone.** There is no phone-to-Mac audio path. The Mac only ever receives text.
- **Audio is deleted** once its transcript is in the outbox (on the Mac, once it's kept). Until it's written down, a
  conversation's audio waits on the iPhone until Binders is opened or the iPhone charges, or for minutes with Write down
  while the iPhone is locked on. On the iPhone, a capture that fails loses its audio after its last try, one still
  waiting loses it three days after it was heard, and one with no words loses it at once (the Mac does the same for one
  still waiting, and drops a failed capture's audio at once). The iPhone's debug
  builds have a developer setting, "Keep audio for 24 hours", to check transcription quality; its release builds never
  keep audio. (The Mac's Settings has the same option.)
- **Not in iCloud backups.** On the iPhone, the capture folder (audio, records, their index, and what you said to yourself), the
  outbox that holds text on its way to the Mac (answers to agents wait beside it, in answers.json), and the downloaded
  speech models are excluded from backups.
- **Never shared with your team.** A conversation filed in a binder you share with teammates stays on your Mac. Team sync
  skips conversations entirely.
- **Mute** turns the microphone off completely, and iOS's microphone indicator goes away. Turning capture off does the same.
- **You can see when it's on.** The Live Activity on the Lock Screen and in the Dynamic Island is the sign that capture is
  listening, next to iOS's microphone indicator; it shows counts, never what was said ("3 filed · 1 needs you": filed
  counts captures and the to-dos, ideas and notes your Mac made from what you said, and needs you counts offers too). Red there means the microphone is
  live; muted or paused shows in grey with its glyph, and the Control Center control says Muted, Paused or Off. iOS ends it after eight hours. If
  that happens while capture is on, or it's swiped away, Binders starts a new one the next time it's opened or a capture
  control is used (the Live Activity, Control Center, the Lock Screen, the Action Button), with one quiet notification
  meanwhile. With Live Activities off for Binders, the capture screen says the microphone indicator is the only sign.
  The Today widget shows today's counts and who is working on what, and names a card only if you let the Lock Screen
  show what you said.
- **It never turns itself on.** If it was on when the app quit, Binders asks before turning it back on.
- **The first time you turn it on**, on the iPhone and on the Mac, Binders reminds you that many places require
  everyone's consent before a conversation is recorded, and to let the people around you know.
- The voice print from "Teach Binders your voice" stays in the iPhone's keychain. The twenty seconds you read aren't kept.
- The speech models download from Hugging Face once. Parakeet (about 500 MB) and the diarizer come over Wi-Fi only; the
  voice detector (1 MB) over any network that isn't in Low Data Mode. A download that stalls is given up after 30
  minutes and picks up where it stopped. Until Parakeet is here, Apple's engine writes captures down with the app open.

## Settings (on the iPhone, Binders → All-day capture)

- **All-day capture** on or off, and a large **Mute** button. Its state shows with a glyph, red only while the microphone
  is listening, and the waveform moves only while someone is speaking.
- **Today**: how long it has listened, how much speech it heard, how many captures, how many were too short to keep or had
  nothing to write down, and when it was paused and why.
- **Captures**: today's kept ones on the capture screen, with those not kept (too short, small talk or nothing to write
  down) folded into one row, and the last 30 days under **Earlier captures**. Each shows its state: waiting (the reason, such as Low Power
  Mode, the iPhone is warm or the battery is under 20%, and when it's written down: with Binders open, or while
  charging; with Background App Refresh off for Binders, the charger can't help, and the row says so), transcribing,
  labelling speakers, waiting for the Mac (and when it goes: when your Mac is back, once Binders on your Mac is updated,
  or once you pair one; "On this iPhone" with no Mac paired), sent, then filed, not kept or not written up, AirDropped,
  not written down, not sent (the Mac couldn't read it). Tap one to read it and see what happened to it; swipe to delete
  one before it's sent, which removes its audio and its place in the outbox.
- **Capture settings**, behind the gear at the top of the capture screen, hold what follows, along with Notify me (after
  a capture) and **Show what you said on the Lock Screen**.
- **Speech model**: English (Parakeet v2, the default) or multilingual (Parakeet v3), and its download. Until it's on the
  phone, Apple's on-device speech recognition (iOS 26) writes conversations down instead, and the transcript says which.
- **Write down while the iPhone is locked**: off by default. On, captures are written down in the pocket on battery while
  capture listens; off, they wait for the app or the charger. It's shown only where iOS lets the models run in the
  background.
- **Your voice**: teach Binders your voice, or forget it.
- **Mode** (under Said to yourself): Suggest, Add at Once or Auto, with a line on what it does and, in Auto mode, which
  agents may take what you say now, and when what you think out loud goes.
- **Developer** (debug builds only): keep audio for 24 hours; Process Sample File, which runs the pipeline on a
  recording that ships with the app; Try SpeechTranscriber on the last clips, which writes the first seconds of the last
  three captures down with Apple's SpeechTranscriber and with Parakeet and shows the times (with Also try it while locked);
  and Time the launch on 200 test captures.
- **Without a Mac.** An unpaired iPhone opens on pairing, with All-day capture, Dictate and the keyboard under "On this
  iPhone". Captures are written down and kept on the phone; their text goes to the first Mac you pair. Dictate offers
  Copy and Share until a Mac is paired.

## Known iOS limits

- **Starting again after an interruption.** A call you take or Siri pauses capture; a call that only rings as a banner
  doesn't. When it's over, iOS usually lets it carry on (on iOS 27 it also says so when the interruption itself never
  ends); when it won't, Binders posts "All-day capture paused. Tap to resume.", and if iOS says nothing at all, a quiet
  "still paused" notice comes two minutes in. Opening Binders tries once to listen again. The paused stretch shows on the
  capture screen, for example "Paused 10:42–10:57".
- **When Binders stops without a word.** While capture listens, a notice is kept five minutes ahead and pushed back every
  minute: if iOS suspends or ends Binders, "All-day capture stopped" says when. A microphone that stops sending audio is
  restarted once, then capture pauses and says so. Connecting or disconnecting headphones carries on with the same
  conversation.
- **Writing down in the background.** With Write down while the iPhone is locked off (the default, Binders' choice),
  conversations heard in the pocket wait for the app, or for the background task iOS runs while the phone charges, when
  it chooses (often overnight). What iOS itself imposes: a suspended app can't run at all, so it's capture listening that
  keeps Binders running in the pocket; background CPU is capped, so the work is paced; and iOS 27 keeps background apps
  off the Neural Engine unless they hold Apple's Background Inference entitlement (com.apple.developer.background-tasks.continued-processing.inference).
  Binders has it from iPhone build 11; `BindersBackgroundInference` in Info.plist says so, and turning it off (with the
  entitlement) makes iOS 27 write conversations down only while the app is open. The voice detector runs on the CPU
  either way, so it keeps hearing speech with the phone locked. Background work is paced, Parakeet is let go before the
  diarizer runs there, and both go when it's done. A model's first load after an install or an update, a compile for the
  Neural Engine, happens with the app open or while the phone charges.
- **Dictating pauses capture.** While you dictate in the app or with the Binders keyboard, capture lets go of the
  microphone, and picks it up again afterwards. After a keyboard dictation, the keyboard keeps the microphone ready for
  half a minute while capture waits (five minutes otherwise); Resume takes it back straight away.
- **Bluetooth headphones** keep playing in high quality. Capture listens with the iPhone's own microphone, as listening
  through the headphones' microphone would switch them to call quality.
- **The Simulator has no microphone.** `-captureSource silence` stands in for it, and `-processSample YES` (debug builds)
  runs the sample recording through the whole pipeline.

## Testing

- BindersKit: `ConversationSplitterTests`, `ConversationPayloadTests`, `ConversationPromptTests`, `LinkFeaturesTests`,
  `WidgetSnapshotTests`, `CaptureIndicatorTests` (`swift test` in `Packages/BindersKit`).
- Mac: `BINDERS_DATA_DIR=$(mktemp -d) Binders --selftest-capture-index -notesShowMarkdown NO` checks the index: the second
  launch reads no record, records changed, added or removed behind it are caught, a broken, missing or other-version
  index is made again, an iPhone 2.0 (9) record is indexed, and it times a launch on 200 made-up captures.
- Mac: `BINDERS_DATA_DIR=$(mktemp -d) Binders --selftest-capture-worker -notesShowMarkdown NO` checks that capture says
  when loudness stands in for the voice detector, and when the detector reads again.
- Mac: `BINDERS_DATA_DIR=$(mktemp -d) Binders --selftest-capture-records` checks capture records read in both
  directions: one written by iPhone 2.0 (9) reads here, and one written now (timeline, outcome, wrap-up) still reads with
  2.0's own decoder.
- Mac: `BINDERS_DATA_DIR=$(mktemp -d) Binders --selftest-allday two-voices.wav` runs a recording through capture on the
  Mac (closing after 5 s of quiet instead of three minutes) and checks it becomes one conversation, both voices told
  apart, written up, with its audio deleted.
- Mac: `BINDERS_DATA_DIR=$(mktemp -d) Binders --selftest-conversation` pairs a fake phone on spare ports and sends a
  three-minute conversation with a promise in it (twice), a blip and some small talk. It checks the conversation is kept
  once, not shared, written up with its promise as a to-do and filed; that the blip and the small talk end up trivial; and
  that `list_meetings` leaves conversations out. It also opens a Binders file twice: what's new in it is kept, once. Run against a folder an earlier Binders wrote, with `--store-only`, it
  checks the store opens and its meetings read as meetings. `--selftest-team` checks a conversation never reaches the team
  folder.
- Mac: `BINDERS_DATA_DIR=$(mktemp -d) Binders --selftest-router -notesShowMarkdown NO` has a section for captures that
  are only you: read in Auto mode, each to-do, fix and idea handed over once, with the note and Stop, and at most five in
  ten minutes; nothing handed over in Suggest and Add at Once; a capture with two voices, a failed diarizer or a voice
  under the start bar, an older phone's, a Binders file, offered; moments said in a capture going with it in either
  order of arrival, and one not heard as your voice held back.
- iPhone: `CaptureTests` (UI tests) turn capture on, mute, unmute and turn it off, with the silent source; and run the
  sample through the pipeline, open it, read who said what, and find Share.
