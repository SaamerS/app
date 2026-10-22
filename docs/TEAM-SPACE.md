# Sharing binders with a team

Binders shares through a folder you already sync, such as OneDrive, Dropbox, Google Drive or iCloud Drive. There is no server
in between, and nothing is shared until someone flips a binder's switch.

## Set up

1. One person makes a folder for the team inside their cloud drive (not the top of the drive itself, which can't be shared as a
   whole), chooses **Settings → Team → Create team space…** on it, and shares **that folder** with the others, with permission
   to edit. It holds `Meetings`, `Notes` and `_binders`; share the folder around them, not `_binders` alone.
2. Everyone else adds the shared folder to their own drive, which is what brings it to their Mac: in OneDrive, open **Shared**
   on the web and choose **Add shortcut to My files** (or **Sync**); in Google Drive, **Add shortcut to Drive**; in Dropbox,
   **Add to my Dropbox**. Once it shows up in Finder, they choose **Settings → Team → Join team space…** and pick it. Picking
   a folder inside it, or the drive it sits in, works too.
3. Set **Your name** in the same place, so teammates see who shared what. It starts as the name on your Mac account.

If Join says there's no team space, run this in Terminal: it lists every team space your drives have brought to the Mac.

```
find ~/Library/CloudStorage -maxdepth 4 -path '*_binders/team.json'
```

A path like `…/Alex Doe - _binders/team.json` means only the `_binders` folder was shared or synced: share and add the folder
around it instead. No output means the shared folder hasn't reached the Mac yet.

## Who is who

There are no accounts. Each Mac gets a random member id the first time Binders runs, and your name comes from
**Settings → Team → Your name**. Everything you share carries both, and each Mac keeps a small file in `_binders/members`
with its name and when it last synced, which is how the Members list is filled in. Who can join is decided by the drive:
anyone the folder is shared with, with permission to edit, can join.

## Sharing

Sharing is per binder. Open a binder and switch on **Share with team**: its meetings and notes are written to the team folder,
and the binder appears in your teammates' sidebars within a minute or so. Switch it off and your items are withdrawn.

- Shared meetings are read-only for everyone but their author.
- Shared notes can be edited by anyone. If two people edit the same note at once, the team's version stays and your own edit is
  saved as a private note, so nothing is lost. That copy keeps whose words they are: a note an agent wrote or changed stays
  marked until you make it yours.
- A note an agent wrote or changed is marked as the agent's in the team folder too (`binders_made_by`,
  `binders_edited_by`, `binders_edited_at` in its front matter), so teammates' Macs label it the agent's and leave it out
  of Ask until someone chooses **Make It Mine**, which clears the mark for everyone. A teammate on Binders 0.8.0 keeps the
  edit mark but doesn't show it: the note stays the agent's until someone on Binders 0.9.0 or later makes it theirs.
- A note with Distill on says `binders_distill: true` in its front matter (Obsidian shows it as a checkbox), so it's on for
  the whole team. A Binders before 0.10.0 keeps the line through its edits, as it keeps every line it doesn't know.
- Shared items show up in teammates' search, answers and knowledge graph, marked with who they came from.
- The team folder holds plain Markdown with front matter, so it also opens as an Obsidian vault.

Audio never goes to the team folder. Only notes, summaries and transcripts of what you chose to share do. Captures, and
notes made from what you said to yourself near your iPhone, stay on your Mac even in a shared binder: moved into one, or
left in a binder you delete whose notes go to a shared General, they stay unshared, and the Delete Binder dialog says so.

## Folders

A shared binder's folders are shared with it: everyone has the same ones, and anyone in the binder can make, rename, move
or delete one, as anyone can edit a note there. The change made last wins.

- Each folder is a file in `_binders/folders`: its binder, the folder it's in, its name and, once it's deleted, when. A
  folder deleted on one Mac goes on all of them, and what was in it moves up to where it was; nothing is deleted with it.
  A deleted folder's file is let go after 60 days.
- A note's folder is in its front matter: `binders_folder_id`, which Binders goes by, and `binders_folder`, the folder's
  path, for people and Obsidian. A note that leaves its folders says `binders_folder_id: ""`. A meeting's folder is in its
  file in `_binders/meetings`, and its readable copy is in the folder's subfolder of `Meetings`.
- In the team folder, a note in a folder is kept in the matching subfolder of `Notes`: `Notes/DevOps/Pipeline cleanup.md`.
  A new note is written there at once. An existing note's file moves there only once every member's Binders knows
  folders (each Mac's file in `_binders/members` says so, in `features`); until then, moving a note changes its front
  matter and its file stays where it is. Settings → Team → Folders says who it waits for. A member file that hasn't
  finished downloading counts as a Binders before folders.
- Why: a Binders from before folders (0.8.0, 0.9.0) finds a note by its id wherever its file is, and writes its edits
  back to the file where it found it, so a note whose file moved is still one note there. But a drive can deliver a move
  as a copy followed by a delete, and a Binders before folders that sees both files at once takes the moved one for a
  conflict copy and gives it a new id: a second note, for everyone. So no Binders moves a note's file while one of those
  is in the team. When this Binders sees one note's file in two places with the same words, it keeps one note and leaves
  the other file for the drive to take away.
- Each Mac moves the files of the notes it wrote. A move never carries an edit: the note's front matter is written
  first, where its file is, and the file moves on a later pass as it is, as one item. The files the note uses are
  copied next to its new place, and a subfolder left empty goes. When a Binders that knows folders sees one note's file
  in two places with the same words, it keeps the same one as every other Mac and sets the other aside until someone
  changes it.
- A Binders before folders keeps a note's folder lines through its edits, as it keeps every line it doesn't know. When one
  writes a note's file from scratch without them, the note stays in its folder, and the next Binders that knows folders
  writes the lines back.
- Folder names on disk are made safe: no `/\:*?"<>|`, no dot in front, not `attachments` or `_binders`, at most 60
  characters. Two binders' folders with the same name share one subfolder; the front matter keeps their notes apart.
