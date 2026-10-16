# All-day capture

Binders can listen all day, on your iPhone or on your Mac, cut the day into conversations and write each one down as a **capture**. On the
iPhone it's written down on the phone and only the text goes to Binders on your Mac. There, each conversation gets a summary, its promises become to-dos, and it is filed in the binder
it belongs to, searchable and askable like a meeting. It's a way to try an all-day wearable before there is one: a
wearable will be another microphone feeding the same pipeline on the phone.

## How it works

1. **Listening.** With All-day capture on, the iPhone's microphone stays on in the background, mixed with whatever you're
   playing, so music and podcasts carry on at full volume. A small voice detector (Silero, through FluidAudio, on the
   CPU) hears when someone is speaking; until it has downloaded, loudness stands in.
2. **Conversations.** The first speech after a quiet spell opens a conversation. It closes after three minutes without
   speech, or at 90 minutes, where it's split and the next one carries on. One with less than 20 seconds of speech in it
   is dropped straight away: a cough, a "thanks", the radio next door.
3. **Only speech is kept.** The phone writes only the speech, with a second either side, to one file per conversation, and
   notes when each stretch was heard, so the transcript's times line up with the day.
4. **Writing it down, on the phone.** When a conversation ends, Parakeet (the same model the Mac uses for meetings)
   transcribes it, and the offline diarizer tells the voices apart: "Speaker 1", "Speaker 2". If you taught Binders your
   voice, the voice closest to it is "You". This happens right away while the app is open (on iOS 27 the screen stays on
   while it does). In the background it happens while the phone charges on iOS 17-26; on iOS 27 it waits for the app to
   be opened (see Known iOS limits). A capture that ends with the app in the background brings one quiet notification, at
   most once an hour, that captures are waiting. Every step is saved, so a quit or an iOS time limit only pauses it: what
   was cut short waits, and voices are never merged into one because it ran out of time. One that fails is tried again
   when the app next comes to the front, once a visit, up to three times. Deleting one while it's being written down stops
   the work, and nothing of it goes to the Mac.
5. **Text to the Mac.** The transcript goes into the outbox the app already uses for notes and dictation, and is sent when
   the Mac is reachable (home network or Tailscale). Once it's in the outbox, the audio is deleted.
6. **On the Mac.** Each conversation becomes a record of its own kind. The language model writes a short summary,
   decisions, promises by you and to you, ideas and people mentioned, then picks the binder it belongs to from your binders'
   names and what's in them. When nothing clearly fits, it goes where new things go. A conversation with nothing worth
   keeping (small talk, a TV in the background) is marked trivial: hidden, and deleted after a week. Under 40 words, it's
   trivial without asking the model.

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
same voice detector and the same cut into conversations, written down with the Mac's speech model and diarizer, and kept
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

They come as notifications on the device that heard the conversation, and wait on the conversation's page on both the
iPhone and the Mac. On the iPhone, while capture listens, the app stays connected to the Mac so they arrive while you're
out. Turn them off in Settings → All-day capture on the Mac (each kind), or with **Notify me** on the iPhone.

## Reading them on the iPhone

Tap a capture on the All-day capture screen to read it: who said what, at what time, and, once your Mac has written it up,
its notes. The transcript stays on the iPhone after the audio is deleted, for 30 days after it's sent, and can be shared
again from there.

Captures show under **Today → Captures**, in a **Captures** tab in the binders they're filed in, and in search, ⌘O and
Ask, labelled as captures. They never appear in the Meetings lists. Over MCP, `list_meetings` leaves them out unless
asked for `kind: capture`, and `search_knowledge` takes `kind: capture` (both still take `conversation`, which is how
captures are stored).

## Privacy

- **Audio never leaves the iPhone.** There is no phone-to-Mac audio path. The Mac only ever receives text.
- **Audio is deleted** once its transcript is in the outbox (on the Mac, once it's kept). Until it's written down, a
  conversation's audio waits on the iPhone (on iOS 27, until Binders is opened). On the iPhone, a capture that couldn't
  be written down loses its audio three days after it was heard. The iPhone's debug builds have a developer setting,
  "Keep audio for 24 hours", to check transcription quality; its release builds never keep audio. (The Mac's Settings
  has the same option.)
- **Not in iCloud backups.** On the iPhone, the capture folder (audio and records), the outbox that holds text on its
  way to the Mac, and the downloaded speech models are excluded from backups.
- **Never shared with your team.** A conversation filed in a binder you share with teammates stays on your Mac. Team sync
  skips conversations entirely.
- **Mute** turns the microphone off completely, and iOS's microphone indicator goes away. Turning capture off does the same.
- **It never turns itself on.** If it was on when the app quit, Binders asks before turning it back on.
- **The first time you turn it on**, on the iPhone and on the Mac, Binders reminds you that many places require
  everyone's consent before a conversation is recorded, and to let the people around you know.
- The voice print from "Teach Binders your voice" stays in the iPhone's keychain. The twenty seconds you read aren't kept.
- The speech models download from Hugging Face once, over Wi-Fi only. Parakeet is about 500 MB.

## Settings (on the iPhone, Binders → All-day capture)

- **All-day capture** on or off, and a large **Mute** button.
- **Today**: how long it has listened, how much speech it heard, how many captures, and when it was paused and why.
- **Captures**, today's and those heard in the last 30 days, each with its state: waiting (and why), transcribing,
  labelling speakers, waiting for the Mac (or "On this iPhone" with no Mac paired), sent, AirDropped, not written down,
  not sent (the Mac couldn't read it). Tap one to read it; swipe to delete one before it's sent, which removes its audio
  and its place in the outbox.
- **Speech model**: English (Parakeet v2, the default) or multilingual (Parakeet v3), and its download. Until it's on the
  phone, Apple's on-device speech recognition (iOS 26) writes conversations down instead, and the transcript says which.
- **Your voice**: teach Binders your voice, or forget it.
- **Developer** (debug builds only): keep audio for 24 hours, and Process Sample File, which runs the pipeline on a
  recording that ships with the app.
- **Without a Mac.** An unpaired iPhone opens on pairing, with All-day capture, Dictate and the keyboard under "On this
  iPhone". Captures are written down and kept on the phone; their text goes to the first Mac you pair. Dictate offers
  Copy and Share until a Mac is paired.

## Known iOS limits

- **Starting again after an interruption.** A call or Siri pauses capture. When it's over, iOS usually lets it carry on; when
  it won't (the app is in the background and iOS refuses), Binders posts "All-day capture paused. Tap to resume." The
  paused stretch shows on the capture screen, for example "Paused 10:42–10:57".
- **Writing down in the background.** iOS doesn't let an app run heavy work in the background on battery, so conversations
  wait: on iOS 17-26 for a background task iOS runs while the phone charges, when it chooses (often overnight); open the
  app to write them down straight away. iOS 27 also keeps background apps off the Neural Engine unless they hold Apple's
  Background Inference entitlement (com.apple.developer.background-tasks.continued-processing.inference), so until Binders
  has it, conversations are written down only while the app is open. The voice detector runs on the CPU, so it keeps
  hearing speech with the phone locked. `BindersBackgroundInference` in Info.plist turns background writing back on, with
  the entitlement.
- **Dictating pauses capture.** While you dictate in the app or with the Binders keyboard, capture lets go of the
  microphone, and picks it up again afterwards. After a keyboard dictation, the keyboard keeps the microphone ready for
  half a minute while capture waits (five minutes otherwise); Resume takes it back straight away.
- **Bluetooth headphones** keep playing in high quality. Capture listens with the iPhone's own microphone, as listening
  through the headphones' microphone would switch them to call quality.
- **The Simulator has no microphone.** `-captureSource silence` stands in for it, and `-processSample YES` (debug builds)
  runs the sample recording through the whole pipeline.

## Testing

- BindersKit: `ConversationSplitterTests`, `ConversationPayloadTests`, `ConversationPromptTests` (`swift test` in
  `Packages/BindersKit`).
- Mac: `BINDERS_DATA_DIR=$(mktemp -d) Binders --selftest-allday two-voices.wav` runs a recording through capture on the
  Mac (closing after 5 s of quiet instead of three minutes) and checks it becomes one conversation, both voices told
  apart, written up, with its audio deleted.
- Mac: `BINDERS_DATA_DIR=$(mktemp -d) Binders --selftest-conversation` pairs a fake phone on spare ports and sends a
  three-minute conversation with a promise in it (twice), a blip and some small talk. It checks the conversation is kept
  once, not shared, written up with its promise as a to-do and filed; that the blip and the small talk end up trivial; and
  that `list_meetings` leaves conversations out. It also opens a Binders file twice: what's new in it is kept, once. Run against a folder an earlier Binders wrote, with `--store-only`, it
  checks the store opens and its meetings read as meetings. `--selftest-team` checks a conversation never reaches the team
  folder.
- iPhone: `CaptureTests` (UI tests) turn capture on, mute, unmute and turn it off, with the silent source; and run the
  sample through the pipeline, open it, read who said what, and find Share.
