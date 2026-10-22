import Foundation

// Migration 6 of the team database, as SQL (lane DB3): notes edited together. Each shared note is an Automerge document
// whose every change is kept (`note_changes`, only ever added to) and grouped into versions by who made them; who is in a
// note right now (`note_presence`); folders made, moved and deleted with what they hold; Distill's records with the parts
// the tables lacked; and bringing a folder team's binders, notes and meetings in, each once. Applied by
// TeamDatabaseSetup in one transaction with the others, as the team's owner role. Never change a migration that has
// shipped: add the next one.

extension TeamSchema {
    static let migration6 = TeamMigration(version: 6, name: "Notes edited together, their versions and who's in them; folders and distills; moving a folder team over", sql: migration6Columns + migration6Notes + migration6Versions + migration6Folders + migration6Imports)

    // MARK: Columns and the presence table

    private static let migration6Columns = #"""
-- Migration 6: notes edited together, their history, who's in them; folders and distills; moving a folder team over.
--
-- A shared note is an Automerge document (the Macs make and read it; the database keeps it whole every so often in
-- notes.document, and every change in note_changes, with who made it). The database groups the changes into versions:
-- one person's (or one agent's) editing session each. Presence is a row per note and person, refreshed while they're in
-- it, so it travels through the feed and row-level security like everything else.

-- The heads the note was first brought in as (by a share or a move): a later move merges the team folder's edits from
-- there. Who made it in a team folder, when it came from one ({"id": their id in the folder, "name": …}).
ALTER TABLE binders.notes ADD COLUMN origin_heads text[] NOT NULL DEFAULT '{}';
ALTER TABLE binders.notes ADD COLUMN imported_author jsonb;
-- How many changes the saved document holds: a save never replaces one that holds more.
ALTER TABLE binders.notes ADD COLUMN document_changes integer NOT NULL DEFAULT 0;
-- What a change did, as the Mac that made it worked out (lines added and removed, sections touched), and its version.
ALTER TABLE binders.note_changes ADD COLUMN lines_added integer NOT NULL DEFAULT 0;
ALTER TABLE binders.note_changes ADD COLUMN lines_removed integer NOT NULL DEFAULT 0;
ALTER TABLE binders.note_changes ADD COLUMN sections text[] NOT NULL DEFAULT '{}';
ALTER TABLE binders.note_changes ADD COLUMN version_id uuid;
-- A version's first and last change by hash (its text is the document at its last change), the version it put back,
-- and whether it came in from a team folder.
ALTER TABLE binders.note_versions ADD COLUMN first_hash text;
ALTER TABLE binders.note_versions ADD COLUMN last_hash text;
ALTER TABLE binders.note_versions ADD COLUMN restored_from uuid;
ALTER TABLE binders.note_versions ADD COLUMN imported boolean NOT NULL DEFAULT false;
-- Distill's fields the tables don't have columns for (what it compared with, the updates it offers, the card that asked an
-- agent; an item's section hash, how its "meant for" was picked, the reader's hint, dropped), as Distill keeps them.
ALTER TABLE binders.distills ADD COLUMN extra jsonb NOT NULL DEFAULT '{}';
ALTER TABLE binders.distill_items ADD COLUMN extra jsonb NOT NULL DEFAULT '{}';
-- Who made a binder, a meeting or a folder in a team folder, when it came from one.
ALTER TABLE binders.binders ADD COLUMN imported_author jsonb;
ALTER TABLE binders.meetings ADD COLUMN imported_author jsonb;
ALTER TABLE binders.folders ADD COLUMN imported_author jsonb;

CREATE INDEX note_changes_version ON binders.note_changes (version_id);
CREATE INDEX note_versions_latest ON binders.note_versions (note_id, ended_at);

-- Who is in a note now: one row per note and person, `viewing` it or `reviewing` one of its Distill proposals, refreshed
-- while they're in it (seen_at), marked left when they leave. Never what they type, select or point at.
CREATE TABLE binders.note_presence (
    id uuid PRIMARY KEY,
    binder_id uuid NOT NULL REFERENCES binders.binders (id),
    note_id uuid NOT NULL REFERENCES binders.notes (id),
    member_id uuid NOT NULL REFERENCES binders.members (id),
    kind text NOT NULL DEFAULT 'viewing' CHECK (kind IN ('viewing', 'reviewing')),
    distill_id uuid,
    seen_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    UNIQUE (note_id, member_id)
);
CREATE INDEX note_presence_binder ON binders.note_presence (binder_id);
SELECT binders._track('note_presence', 'binder_id'), binders._guard('note_presence', 'binder_id');

"""#

    // MARK: Notes and their changes

    private static let migration6Notes = #"""
-- MARK: Notes and their changes

-- A note in one of the caller's binders, locked: null when there's none (or it's in a binder they don't see).
CREATE FUNCTION binders._lock_note(p_note uuid) RETURNS binders.notes
LANGUAGE plpgsql SET search_path = pg_catalog, binders AS $$
DECLARE
    v_note binders.notes;
BEGIN
    SELECT * INTO v_note FROM binders.notes WHERE id = p_note FOR UPDATE;
    IF v_note.id IS NULL OR NOT (v_note.binder_id = ANY (binders.my_binder_ids())) THEN
        RETURN NULL;
    END IF;
    RETURN v_note;
END $$;

-- A folder an item in `p_binder` can be filed in: the folder, or the nearest one above it still there; null for the
-- top (no folder, one in another binder, or one that's gone with nothing above it).
CREATE FUNCTION binders._folder_in(p_binder uuid, p_folder uuid) RETURNS uuid
LANGUAGE plpgsql STABLE SET search_path = pg_catalog, binders AS $$
DECLARE
    v_folder binders.folders;
    v_seen uuid[] := '{}';
BEGIN
    SELECT * INTO v_folder FROM binders.folders WHERE id = p_folder AND binder_id = p_binder;
    WHILE v_folder.id IS NOT NULL AND v_folder.deleted_at IS NOT NULL AND NOT (v_folder.id = ANY (v_seen)) LOOP
        v_seen := v_seen || v_folder.id;
        SELECT * INTO v_folder FROM binders.folders WHERE id = v_folder.parent_id AND binder_id = p_binder;
    END LOOP;
    RETURN CASE WHEN v_folder.deleted_at IS NULL THEN v_folder.id END;
END $$;

-- One change of a note's document, kept: `p_change` as the Mac sent it ({id, hash, deps, change: "\x…", lines_added,
-- lines_removed, sections}), in `p_version`, by `p_actor`. The same change (by its hash) is kept once.
CREATE FUNCTION binders._keep_note_change(p_note binders.notes, p_change jsonb, p_actor binders.actor, p_version uuid, p_id uuid)
RETURNS void
LANGUAGE plpgsql SET search_path = pg_catalog, binders AS $$
BEGIN
    INSERT INTO binders.note_changes (id, binder_id, note_id, member_id, agent_id, change, hash, deps, lines_added, lines_removed,
                                      sections, version_id)
    VALUES (p_id, p_note.binder_id, p_note.id, p_actor.member_id, p_actor.agent_id, (p_change ->> 'change')::bytea, p_change ->> 'hash',
            coalesce(ARRAY(SELECT jsonb_array_elements_text(coalesce(p_change -> 'deps', '[]'))), '{}'),
            greatest(coalesce((p_change ->> 'lines_added')::integer, 0), 0), greatest(coalesce((p_change ->> 'lines_removed')::integer, 0), 0),
            coalesce(ARRAY(SELECT jsonb_array_elements_text(coalesce(p_change -> 'sections', '[]'))), '{}'), p_version);
END $$;

-- Whether a change is one a Mac can send: a hash and its bytes.
CREATE FUNCTION binders._valid_note_change(p_change jsonb) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, binders AS $$
    SELECT jsonb_typeof(p_change) = 'object' AND coalesce(p_change ->> 'hash', '') ~ '^[0-9a-f]{64}$'
       AND coalesce(p_change ->> 'change', '') ~ '^\\x([0-9a-f]{2})+$'
$$;

-- A note shared through the database, in one transaction: its row, its first changes (the document's skeleton and its
-- text) and its first version. `p_fields`: folder_id, title, body, properties, distill, document ("\x…"),
-- document_heads, document_changes, origin_heads, created_at; for a note brought in from a team folder also
-- imported_author ({"id", "name"}), author (the member it's by, when they're in the team), started_at, ended_at and
-- claim (the caller's own id in that folder). A note that's there already is refused (`exists`, with its row), so it's
-- made once whichever Mac shares it first; one that was deleted comes back when `p_undelete` says so (Undo).
CREATE FUNCTION binders.create_note(p_op uuid, p_note uuid, p_binder uuid, p_fields jsonb, p_changes jsonb, p_agent uuid DEFAULT NULL,
                                    p_undelete boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'create_note', jsonb_build_object('note', p_note, 'binder', p_binder,
        'fields', md5(coalesce(p_fields::text, '')), 'changes', md5(coalesce(p_changes::text, '')), 'agent', p_agent, 'undelete', p_undelete));
    v_fields jsonb := coalesce(p_fields, '{}');
    v_actor binders.actor;
    v_author binders.actor;
    v_note binders.notes;
    v_existing binders.notes;
    v_imported boolean := jsonb_typeof(coalesce(p_fields, '{}') -> 'imported_author') = 'object';
    v_change jsonb;
    v_version uuid;
    v_id uuid;
    v_ids jsonb := '[]';
    v_row jsonb;
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    v_actor := binders._acting_as(p_agent);
    PERFORM binders._require_binder(p_binder);
    IF p_note IS NULL OR jsonb_typeof(coalesce(p_changes, 'null'::jsonb)) <> 'array' OR jsonb_array_length(p_changes) = 0 THEN
        RAISE EXCEPTION 'A note needs an id and its first changes.' USING ERRCODE = '22023';
    END IF;
    FOR v_change IN SELECT * FROM jsonb_array_elements(p_changes) LOOP
        IF NOT binders._valid_note_change(v_change) THEN
            RAISE EXCEPTION 'A change has its hash and its bytes.' USING ERRCODE = '22023';
        END IF;
    END LOOP;
    SELECT * INTO v_existing FROM binders.notes WHERE id = p_note FOR UPDATE;
    IF v_existing.id IS NOT NULL AND NOT (v_existing.binder_id = ANY (binders.my_binder_ids())) THEN
        RETURN binders._op_end(p_op, binders._refusal('exists', 'A note with that id is already in the team.'));
    END IF;
    IF v_existing.id IS NOT NULL AND (v_existing.deleted_at IS NULL OR NOT coalesce(p_undelete, false)) THEN
        -- Brought in before you joined, by someone else: it's yours.
        IF v_imported AND v_actor.kind = 'person' AND v_existing.imported_author ->> 'id' IS NOT NULL
           AND v_existing.imported_author ->> 'id' = v_fields ->> 'claim' AND v_existing.created_by IS DISTINCT FROM v_actor.member_id THEN
            UPDATE binders.note_versions SET member_id = v_actor.member_id
            WHERE note_id = p_note AND imported AND member_id IS NOT DISTINCT FROM v_existing.created_by;
            UPDATE binders.notes SET created_by = v_actor.member_id WHERE id = p_note;
            SELECT * INTO v_existing FROM binders.notes WHERE id = p_note;
        END IF;
        RETURN binders._op_end(p_op, binders._refusal('exists', 'This note is already in the team.',
            jsonb_build_object('note', to_jsonb(v_existing) - 'document')));
    END IF;
    -- Whose it is: the caller, or for a note from a team folder the member who wrote it there, when they're in the team.
    v_author := v_actor;
    IF v_imported AND v_actor.kind = 'person' AND (v_fields ->> 'author') IS NOT NULL THEN
        SELECT 'person', m.id, NULL::uuid, m.name INTO v_author FROM binders.members m
        WHERE m.id = (v_fields ->> 'author')::uuid AND m.deleted_at IS NULL AND m.kind = 'person';
        IF v_author.member_id IS NULL THEN
            v_author := v_actor;
        END IF;
    END IF;
    IF v_existing.id IS NOT NULL THEN
        -- Deleted, and put back (Undo): in this binder, as it was, with the changes made since.
        UPDATE binders.notes SET deleted_at = NULL, binder_id = p_binder,
            folder_id = binders._folder_in(p_binder, (v_fields ->> 'folder_id')::uuid)
        WHERE id = p_note;
    ELSE
        INSERT INTO binders.notes (id, binder_id, folder_id, title, properties, distill, body, document, document_heads, document_saved_at,
                                   document_changes, origin_heads, imported_author, created_by, created_by_agent, last_edited_by,
                                   last_edited_by_agent, created_at)
        VALUES (p_note, p_binder, binders._folder_in(p_binder, (v_fields ->> 'folder_id')::uuid), left(coalesce(v_fields ->> 'title', ''), 300),
                CASE WHEN jsonb_typeof(v_fields -> 'properties') = 'object' THEN v_fields -> 'properties' ELSE '{}' END,
                coalesce((v_fields ->> 'distill')::boolean, false), coalesce(v_fields ->> 'body', ''),
                (v_fields ->> 'document')::bytea,
                coalesce(ARRAY(SELECT jsonb_array_elements_text(coalesce(v_fields -> 'document_heads', '[]'))), '{}'),
                CASE WHEN v_fields ? 'document' THEN now() END, greatest(coalesce((v_fields ->> 'document_changes')::integer, 0), 0),
                coalesce(ARRAY(SELECT jsonb_array_elements_text(coalesce(v_fields -> 'origin_heads', '[]'))), '{}'),
                CASE WHEN v_imported THEN v_fields -> 'imported_author' END,
                v_author.member_id, v_author.agent_id, v_author.member_id, v_author.agent_id,
                coalesce((v_fields ->> 'created_at')::timestamptz, now()));
    END IF;
    SELECT * INTO v_note FROM binders.notes WHERE id = p_note;
    -- Its first changes, in one version: by the caller (extendable, as typing goes on), or the team folder's, by its author.
    FOR v_change IN SELECT c FROM jsonb_array_elements(p_changes) WITH ORDINALITY AS t(c, n) ORDER BY n LOOP
        SELECT id INTO v_id FROM binders.note_changes WHERE note_id = p_note AND hash = v_change ->> 'hash';
        IF v_id IS NOT NULL THEN
            v_ids := v_ids || to_jsonb(v_id);
            CONTINUE;
        END IF;
        v_id := coalesce((v_change ->> 'id')::uuid, gen_random_uuid());
        IF v_version IS NULL THEN
            v_version := binders._note_version_for(v_note, v_id, v_change, v_author, NULL, v_imported,
                (v_fields ->> 'started_at')::timestamptz, (v_fields ->> 'ended_at')::timestamptz);
        ELSE
            PERFORM binders._extend_note_version(v_version, v_id, v_change);
        END IF;
        PERFORM binders._keep_note_change(v_note, v_change, v_actor, v_version, v_id);
        v_ids := v_ids || to_jsonb(v_id);
    END LOOP;
    SELECT to_jsonb(n) - 'document' INTO v_row FROM binders.notes n WHERE id = p_note;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true, 'note', v_row, 'changes', v_ids,
        'versions', (SELECT coalesce(jsonb_agg(to_jsonb(v)), '[]') FROM binders.note_versions v WHERE v.id = v_version)));
END $$;

-- More of a note's changes, in order: each kept once (by its hash), each in a version (`_note_version_for`). An agent's
-- changes are marked as the agent's (`p_agent`, one of the caller's). `p_restores`: the version a change puts back (its
-- one change), which starts a version of its own that says so. Each change may carry what it did to the version it
-- expects to extend (`version_first`, the hash of that version's first change, with `version_added`, `version_removed`,
-- `version_sections`), so a version's numbers are its whole difference rather than a sum.
CREATE FUNCTION binders.add_note_changes(p_op uuid, p_note uuid, p_changes jsonb, p_agent uuid DEFAULT NULL, p_restores uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'add_note_changes', jsonb_build_object('note', p_note,
        'changes', md5(coalesce(p_changes::text, '')), 'agent', p_agent, 'restores', p_restores));
    v_actor binders.actor;
    v_note binders.notes;
    v_change jsonb;
    v_id uuid;
    v_version uuid;
    v_versions uuid[] := '{}';
    v_restores uuid := p_restores;
    v_ids jsonb := '[]';
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    v_actor := binders._acting_as(p_agent);
    IF jsonb_typeof(coalesce(p_changes, 'null'::jsonb)) <> 'array' OR jsonb_array_length(p_changes) = 0 THEN
        RAISE EXCEPTION 'add_note_changes takes at least one change.' USING ERRCODE = '22023';
    END IF;
    FOR v_change IN SELECT * FROM jsonb_array_elements(p_changes) LOOP
        IF NOT binders._valid_note_change(v_change) THEN
            RAISE EXCEPTION 'A change has its hash and its bytes.' USING ERRCODE = '22023';
        END IF;
    END LOOP;
    v_note := binders._lock_note(p_note);
    IF v_note.id IS NULL THEN
        RETURN binders._op_end(p_op, binders._refusal('not_found', 'No note with that id is in a binder shared with you.'));
    END IF;
    IF v_note.deleted_at IS NOT NULL THEN
        RETURN binders._op_end(p_op, binders._refusal('deleted', 'This note was deleted for the team, so it can''t be changed.'));
    END IF;
    IF v_restores IS NOT NULL AND NOT EXISTS (SELECT 1 FROM binders.note_versions WHERE id = v_restores AND note_id = p_note) THEN
        RAISE EXCEPTION 'That version isn''t one of this note''s.' USING ERRCODE = '22023';
    END IF;
    FOR v_change IN SELECT c FROM jsonb_array_elements(p_changes) WITH ORDINALITY AS t(c, n) ORDER BY n LOOP
        -- Sent before (by this Mac, or by one that merged it): already there.
        SELECT id INTO v_id FROM binders.note_changes WHERE note_id = p_note AND hash = v_change ->> 'hash';
        IF v_id IS NOT NULL THEN
            v_ids := v_ids || to_jsonb(v_id);
            CONTINUE;
        END IF;
        v_id := coalesce((v_change ->> 'id')::uuid, gen_random_uuid());
        IF EXISTS (SELECT 1 FROM binders.note_changes WHERE id = v_id) THEN
            v_id := gen_random_uuid();
        END IF;
        v_version := binders._note_version_for(v_note, v_id, v_change, v_actor, v_restores, false, NULL, NULL);
        v_restores := NULL;
        PERFORM binders._keep_note_change(v_note, v_change, v_actor, v_version, v_id);
        IF NOT (v_version = ANY (v_versions)) THEN
            v_versions := v_versions || v_version;
        END IF;
        v_ids := v_ids || to_jsonb(v_id);
    END LOOP;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true, 'changes', v_ids,
        'versions', (SELECT coalesce(jsonb_agg(to_jsonb(v)), '[]') FROM binders.note_versions v WHERE v.id = ANY (v_versions))));
END $$;

-- The note whole, every so often (`p_fields`: document, document_heads, document_changes, body, title, properties,
-- distill): what a Mac that reads the note starts from before it applies the changes, and what anyone reading the
-- database reads. A copy holding fewer changes than the one kept doesn't replace it.
CREATE FUNCTION binders.save_note(p_op uuid, p_note uuid, p_fields jsonb, p_agent uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_note binders.notes;
    v_fields jsonb := coalesce(p_fields, '{}');
    v_count integer := greatest(coalesce((coalesce(p_fields, '{}') ->> 'document_changes')::integer, 0), 0);
BEGIN
    -- The same every time it's sent, and sent often: not kept as an operation.
    PERFORM binders._acting_as(p_agent);
    v_note := binders._lock_note(p_note);
    IF v_note.id IS NULL THEN
        RETURN binders._refusal('not_found', 'No note with that id is in a binder shared with you.');
    END IF;
    IF v_note.deleted_at IS NOT NULL THEN
        RETURN binders._refusal('deleted', 'This note was deleted for the team, so it can''t be changed.');
    END IF;
    IF v_count < v_note.document_changes THEN
        RETURN jsonb_build_object('ok', true, 'unchanged', true);
    END IF;
    UPDATE binders.notes SET
        document = CASE WHEN v_fields ? 'document' THEN (v_fields ->> 'document')::bytea ELSE document END,
        document_heads = CASE WHEN v_fields ? 'document_heads'
                              THEN coalesce(ARRAY(SELECT jsonb_array_elements_text(v_fields -> 'document_heads')), '{}') ELSE document_heads END,
        document_changes = v_count,
        document_saved_at = now(),
        body = coalesce(v_fields ->> 'body', body),
        title = left(coalesce(v_fields ->> 'title', title), 300),
        properties = CASE WHEN jsonb_typeof(v_fields -> 'properties') = 'object' THEN v_fields -> 'properties' ELSE properties END,
        distill = coalesce((v_fields ->> 'distill')::boolean, distill)
    WHERE id = p_note;
    RETURN jsonb_build_object('ok', true, 'unchanged', false);
END $$;

-- A note to another folder, or to another shared binder (its history, versions, presence and distills go with it, as
-- they're read by who's in its binder). `p_folder` null: the top of the binder.
CREATE FUNCTION binders.move_note(p_op uuid, p_note uuid, p_binder uuid, p_folder uuid DEFAULT NULL, p_agent uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'move_note', jsonb_build_object('note', p_note, 'binder', p_binder, 'folder', p_folder,
        'agent', p_agent));
    v_note binders.notes;
    v_binder uuid;
    v_row jsonb;
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    PERFORM binders._acting_as(p_agent);
    v_note := binders._lock_note(p_note);
    IF v_note.id IS NULL THEN
        RETURN binders._op_end(p_op, binders._refusal('not_found', 'No note with that id is in a binder shared with you.'));
    END IF;
    IF v_note.deleted_at IS NOT NULL THEN
        RETURN binders._op_end(p_op, binders._refusal('deleted', 'This note was deleted for the team, so it can''t be changed.'));
    END IF;
    v_binder := coalesce(p_binder, v_note.binder_id);
    PERFORM binders._require_binder(v_binder);
    UPDATE binders.notes SET binder_id = v_binder, folder_id = binders._folder_in(v_binder, p_folder) WHERE id = p_note;
    IF v_binder <> v_note.binder_id THEN
        UPDATE binders.note_changes SET binder_id = v_binder WHERE note_id = p_note;
        UPDATE binders.note_versions SET binder_id = v_binder WHERE note_id = p_note;
        UPDATE binders.note_presence SET binder_id = v_binder WHERE note_id = p_note;
        UPDATE binders.distill_items SET binder_id = v_binder WHERE distill_id IN (SELECT id FROM binders.distills WHERE note_id = p_note);
        UPDATE binders.distills SET binder_id = v_binder WHERE note_id = p_note;
    END IF;
    SELECT to_jsonb(n) - 'document' INTO v_row FROM binders.notes n WHERE id = p_note;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true, 'note', v_row));
END $$;

"""#

    // MARK: Versions

    private static let migration6Versions = #"""
-- MARK: Versions

-- The version a new change of a note goes in. It extends the note's latest version when that's by the same member and
-- the same agent (or no agent), its last change was less than 5 minutes ago, and it wasn't named, read by a distill, put
-- back or brought in since; otherwise it starts a new version (by `p_author`), which a change putting a version back
-- (`p_restores`) or bringing one in from a team folder (`p_imported`) always does. A new version lets old ones of a note
-- without Distill go (`_trim_note_versions`).
CREATE FUNCTION binders._note_version_for(p_note binders.notes, p_change uuid, p_stats jsonb, p_author binders.actor, p_restores uuid,
                                          p_imported boolean, p_started timestamptz, p_ended timestamptz) RETURNS uuid
LANGUAGE plpgsql SET search_path = pg_catalog, binders AS $$
DECLARE
    v_latest binders.note_versions;
    v_id uuid;
BEGIN
    SELECT * INTO v_latest FROM binders.note_versions WHERE note_id = p_note.id AND deleted_at IS NULL
    ORDER BY ended_at DESC NULLS LAST, created_at DESC, id DESC LIMIT 1 FOR UPDATE;
    IF p_restores IS NULL AND NOT coalesce(p_imported, false) AND v_latest.id IS NOT NULL
       AND v_latest.member_id IS NOT DISTINCT FROM p_author.member_id AND v_latest.agent_id IS NOT DISTINCT FROM p_author.agent_id
       AND v_latest.name IS NULL AND v_latest.distill_id IS NULL AND v_latest.restored_from IS NULL AND NOT v_latest.imported
       AND v_latest.ended_at > now() - interval '5 minutes' THEN
        PERFORM binders._extend_note_version(v_latest.id, p_change, p_stats);
        RETURN v_latest.id;
    END IF;
    v_id := gen_random_uuid();
    INSERT INTO binders.note_versions (id, binder_id, note_id, first_change_id, last_change_id, first_hash, last_hash, member_id, agent_id,
                                       started_at, ended_at, lines_added, lines_removed, sections, restored_from, imported)
    VALUES (v_id, p_note.binder_id, p_note.id, p_change, p_change, p_stats ->> 'hash', p_stats ->> 'hash', p_author.member_id, p_author.agent_id,
            coalesce(p_started, now()), coalesce(p_ended, now()), greatest(coalesce((p_stats ->> 'lines_added')::integer, 0), 0),
            greatest(coalesce((p_stats ->> 'lines_removed')::integer, 0), 0),
            coalesce(ARRAY(SELECT jsonb_array_elements_text(coalesce(p_stats -> 'sections', '[]'))), '{}'), p_restores, coalesce(p_imported, false));
    PERFORM binders._trim_note_versions(p_note);
    RETURN v_id;
END $$;

-- A version takes one more change: its last change, its end, and its numbers: the whole version's, as the Mac that made
-- the change worked them out, when it expected this version (by its first change); else this change's added on.
CREATE FUNCTION binders._extend_note_version(p_version uuid, p_change uuid, p_stats jsonb) RETURNS void
LANGUAGE plpgsql SET search_path = pg_catalog, binders AS $$
BEGIN
    UPDATE binders.note_versions v SET
        last_change_id = p_change,
        last_hash = p_stats ->> 'hash',
        ended_at = greatest(now(), v.ended_at),
        lines_added = CASE WHEN p_stats ->> 'version_first' IS NOT NULL AND p_stats ->> 'version_first' = v.first_hash
                           THEN greatest(coalesce((p_stats ->> 'version_added')::integer, 0), 0)
                           ELSE v.lines_added + greatest(coalesce((p_stats ->> 'lines_added')::integer, 0), 0) END,
        lines_removed = CASE WHEN p_stats ->> 'version_first' IS NOT NULL AND p_stats ->> 'version_first' = v.first_hash
                             THEN greatest(coalesce((p_stats ->> 'version_removed')::integer, 0), 0)
                             ELSE v.lines_removed + greatest(coalesce((p_stats ->> 'lines_removed')::integer, 0), 0) END,
        sections = CASE WHEN p_stats ->> 'version_first' IS NOT NULL AND p_stats ->> 'version_first' = v.first_hash
                        THEN coalesce(ARRAY(SELECT jsonb_array_elements_text(coalesce(p_stats -> 'version_sections', '[]'))), '{}')
                        ELSE ARRAY(SELECT DISTINCT s FROM unnest(v.sections || coalesce(ARRAY(SELECT jsonb_array_elements_text(
                                 coalesce(p_stats -> 'sections', '[]'))), '{}')) AS s ORDER BY s) END
    WHERE v.id = p_version;
END $$;

-- What a note keeps of its versions: everything, for a note with Distill on; otherwise the latest 20, and any newer than
-- 30 days. The rest are let go (marked deleted, so every Mac learns of it); their changes stay.
CREATE FUNCTION binders._trim_note_versions(p_note binders.notes) RETURNS void
LANGUAGE plpgsql SET search_path = pg_catalog, binders AS $$
BEGIN
    IF (SELECT distill FROM binders.notes WHERE id = p_note.id) THEN
        RETURN;
    END IF;
    UPDATE binders.note_versions SET deleted_at = now()
    WHERE id IN (SELECT id FROM binders.note_versions WHERE note_id = p_note.id AND deleted_at IS NULL
                 ORDER BY ended_at DESC NULLS LAST, created_at DESC, id DESC OFFSET 20)
      AND coalesce(ended_at, created_at) < now() - interval '30 days';
END $$;

-- Gives a version a name ("Approved", "v2"), or takes it away (empty). A named version isn't extended any more.
CREATE FUNCTION binders.name_note_version(p_op uuid, p_version uuid, p_name text, p_agent uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'name_note_version', jsonb_build_object('version', p_version, 'name', p_name, 'agent', p_agent));
    v_version binders.note_versions;
    v_row jsonb;
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    PERFORM binders._acting_as(p_agent);
    SELECT * INTO v_version FROM binders.note_versions WHERE id = p_version FOR UPDATE;
    IF v_version.id IS NULL OR NOT (v_version.binder_id = ANY (binders.my_binder_ids())) OR v_version.deleted_at IS NOT NULL THEN
        RETURN binders._op_end(p_op, binders._refusal('not_found', 'No version with that id is in a binder shared with you.'));
    END IF;
    UPDATE binders.note_versions SET name = nullif(left(btrim(coalesce(p_name, '')), 60), '') WHERE id = p_version;
    SELECT to_jsonb(v) INTO v_row FROM binders.note_versions v WHERE id = p_version;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true, 'version', v_row));
END $$;

-- The version a distill read: marked with it (so it isn't extended any more, and the note's history says "Distilled by
-- …"). Named by its id, or by the hash of the change it read the note at (`p_hash`, the version that change is in): the
-- reading Mac knows the change before the database has said which version it went in.
CREATE FUNCTION binders.mark_note_version(p_op uuid, p_note uuid, p_version uuid, p_distill uuid, p_hash text DEFAULT NULL,
                                          p_agent uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'mark_note_version', jsonb_build_object('note', p_note, 'version', p_version,
        'distill', p_distill, 'hash', p_hash, 'agent', p_agent));
    v_id uuid := p_version;
    v_version binders.note_versions;
    v_row jsonb;
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    PERFORM binders._acting_as(p_agent);
    IF v_id IS NULL THEN
        SELECT version_id INTO v_id FROM binders.note_changes WHERE note_id = p_note AND hash = p_hash;
    END IF;
    SELECT * INTO v_version FROM binders.note_versions WHERE id = v_id AND note_id = p_note FOR UPDATE;
    IF v_version.id IS NULL OR NOT (v_version.binder_id = ANY (binders.my_binder_ids())) THEN
        RETURN binders._op_end(p_op, binders._refusal('not_found', 'No version of that note is in a binder shared with you.'));
    END IF;
    UPDATE binders.note_versions SET distill_id = p_distill WHERE id = v_id;
    SELECT to_jsonb(v) INTO v_row FROM binders.note_versions v WHERE id = v_id;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true, 'versions', jsonb_build_array(v_row)));
END $$;

-- MARK: Who's in a note

-- This person is in a note (`p_here`), viewing it or reviewing one of its proposals (`p_kind`, `p_distill`), or has left
-- it. Sent when they open it, every so often while it's open, and when they close it: the same every time, so it isn't
-- kept as an operation. Nothing about what they do in it.
CREATE FUNCTION binders.be_in_note(p_op uuid, p_note uuid, p_here boolean DEFAULT true, p_kind text DEFAULT 'viewing',
                                   p_distill uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_me uuid := binders._caller();
    v_binder uuid;
BEGIN
    IF coalesce(p_kind, 'viewing') NOT IN ('viewing', 'reviewing') THEN
        RAISE EXCEPTION 'Someone in a note is viewing it or reviewing a proposal.' USING ERRCODE = '22023';
    END IF;
    SELECT binder_id INTO v_binder FROM binders.notes WHERE id = p_note AND deleted_at IS NULL;
    IF v_binder IS NULL OR NOT (v_binder = ANY (binders.my_binder_ids())) THEN
        RETURN binders._refusal('not_found', 'No note with that id is in a binder shared with you.');
    END IF;
    INSERT INTO binders.note_presence (id, binder_id, note_id, member_id, kind, distill_id, seen_at, deleted_at)
    VALUES (gen_random_uuid(), v_binder, p_note, v_me, coalesce(p_kind, 'viewing'), CASE WHEN p_kind = 'reviewing' THEN p_distill END, now(),
            CASE WHEN coalesce(p_here, true) THEN NULL ELSE now() END)
    ON CONFLICT (note_id, member_id) DO UPDATE SET binder_id = EXCLUDED.binder_id, kind = EXCLUDED.kind, distill_id = EXCLUDED.distill_id,
        seen_at = now(), deleted_at = EXCLUDED.deleted_at;
    RETURN jsonb_build_object('ok', true);
END $$;

"""#

    // MARK: Folders

    private static let migration6Folders = #"""
-- MARK: Folders

-- A folder made, renamed or moved (`p_fields`: name, parent_id, position; imported_author for one from a team folder), or
-- put back after it was deleted (Undo). It stays in its binder, and never goes inside itself or one of its own folders.
-- A parent that's gone files it under the nearest folder above that's still there.
CREATE FUNCTION binders.put_folder(p_op uuid, p_folder uuid, p_binder uuid, p_fields jsonb, p_agent uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'put_folder', jsonb_build_object('folder', p_folder, 'binder', p_binder, 'fields', p_fields,
        'agent', p_agent));
    v_fields jsonb := coalesce(p_fields, '{}');
    v_actor binders.actor;
    v_existing binders.folders;
    v_name text;
    v_parent uuid;
    v_row jsonb;
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    v_actor := binders._acting_as(p_agent);
    PERFORM binders._require_binder(p_binder);
    IF p_folder IS NULL THEN
        RAISE EXCEPTION 'A folder needs an id.' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_existing FROM binders.folders WHERE id = p_folder FOR UPDATE;
    IF v_existing.id IS NOT NULL AND v_existing.binder_id <> p_binder THEN
        RETURN binders._op_end(p_op, binders._refusal('other_binder', 'A folder stays in its binder. Move what''s in it instead.'));
    END IF;
    v_name := nullif(left(btrim(coalesce(v_fields ->> 'name', v_existing.name, '')), 80), '');
    IF v_name IS NULL THEN
        RAISE EXCEPTION 'A folder needs a name.' USING ERRCODE = '22023';
    END IF;
    v_parent := CASE WHEN v_fields ? 'parent_id' THEN binders._folder_in(p_binder, (v_fields ->> 'parent_id')::uuid) ELSE v_existing.parent_id END;
    IF v_parent IS NOT NULL AND (v_parent = p_folder OR EXISTS (
            WITH RECURSIVE up(id, parent) AS (
                SELECT id, parent_id FROM binders.folders WHERE id = v_parent
                UNION
                SELECT f.id, f.parent_id FROM binders.folders f JOIN up ON f.id = up.parent)
            SELECT 1 FROM up WHERE id = p_folder)) THEN
        RETURN binders._op_end(p_op, binders._refusal('cycle', 'A folder can''t go inside itself or one of its own folders.'));
    END IF;
    IF v_existing.id IS NULL THEN
        INSERT INTO binders.folders (id, binder_id, parent_id, name, position, created_by, imported_author)
        VALUES (p_folder, p_binder, v_parent, v_name, coalesce((v_fields ->> 'position')::double precision, 0), v_actor.member_id,
                CASE WHEN jsonb_typeof(v_fields -> 'imported_author') = 'object' THEN v_fields -> 'imported_author' END);
    ELSE
        -- Only what differs: the same folder sent again changes nothing, and so tells no Mac anything.
        UPDATE binders.folders SET name = v_name, parent_id = v_parent,
            position = coalesce((v_fields ->> 'position')::double precision, position), deleted_at = NULL
        WHERE id = p_folder AND (name, parent_id, position, deleted_at)
              IS DISTINCT FROM (v_name, v_parent, coalesce((v_fields ->> 'position')::double precision, position), NULL::timestamptz);
    END IF;
    SELECT to_jsonb(f) INTO v_row FROM binders.folders f WHERE id = p_folder;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true, 'folder', v_row));
END $$;

-- A folder deleted, in one transaction: what it held (notes, meetings, captures and folders) moves up to where it was,
-- then it's marked deleted. Nothing is deleted with it. Anyone in the binder may, as anyone may edit a note there.
CREATE FUNCTION binders.delete_folder(p_op uuid, p_folder uuid, p_agent uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'delete_folder', jsonb_build_object('folder', p_folder, 'agent', p_agent));
    v_folder binders.folders;
    v_up uuid;
    v_notes integer;
    v_meetings integer;
    v_captures integer;
    v_folders integer;
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    PERFORM binders._acting_as(p_agent);
    SELECT * INTO v_folder FROM binders.folders WHERE id = p_folder FOR UPDATE;
    IF v_folder.id IS NULL OR NOT (v_folder.binder_id = ANY (binders.my_binder_ids())) THEN
        RETURN binders._op_end(p_op, binders._refusal('not_found', 'No folder with that id is in a binder shared with you.'));
    END IF;
    IF v_folder.deleted_at IS NOT NULL THEN
        RETURN binders._op_end(p_op, jsonb_build_object('ok', true, 'unchanged', true));
    END IF;
    v_up := binders._folder_in(v_folder.binder_id, v_folder.parent_id);
    UPDATE binders.notes SET folder_id = v_up WHERE folder_id = p_folder;
    GET DIAGNOSTICS v_notes = ROW_COUNT;
    UPDATE binders.meetings SET folder_id = v_up WHERE folder_id = p_folder;
    GET DIAGNOSTICS v_meetings = ROW_COUNT;
    UPDATE binders.captures SET folder_id = v_up WHERE folder_id = p_folder;
    GET DIAGNOSTICS v_captures = ROW_COUNT;
    UPDATE binders.folders SET parent_id = v_up WHERE parent_id = p_folder AND id <> p_folder;
    GET DIAGNOSTICS v_folders = ROW_COUNT;
    UPDATE binders.folders SET deleted_at = now() WHERE id = p_folder;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true, 'unchanged', false, 'notes', v_notes, 'meetings', v_meetings,
        'captures', v_captures, 'folders', v_folders));
END $$;

"""#

    // MARK: Moving a folder team over

    private static let migration6Imports = #"""
-- MARK: Moving a folder team over

-- The member a team folder's author is, when they're a person in the team: the one `p_member` names.
CREATE FUNCTION binders._import_author(p_member uuid) RETURNS uuid
LANGUAGE sql STABLE SET search_path = pg_catalog, binders AS $$
    SELECT id FROM binders.members WHERE id = p_member AND kind = 'person' AND deleted_at IS NULL
$$;

-- A binder a team folder shared, brought into the database once: by whoever wrote it there when they're in the team
-- (`p_author`), else by the caller, with who wrote it kept (`p_imported_author`, {"id": their id in the folder, "name"}).
-- Shared with everyone, as the team folder shared it. One that's there already is left as it is (`exists`), except that
-- the person who wrote it in the folder (`p_claim`, their own id there) becomes who made it.
CREATE FUNCTION binders.import_binder(p_op uuid, p_binder uuid, p_name text, p_fields jsonb, p_imported_author jsonb,
                                      p_author uuid DEFAULT NULL, p_claim text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'import_binder', jsonb_build_object('binder', p_binder, 'name', p_name, 'fields', p_fields,
        'imported_author', p_imported_author, 'author', p_author, 'claim', p_claim));
    v_person binders.actor;
    v_fields jsonb := coalesce(p_fields, '{}');
    v_existing binders.binders;
    v_author uuid;
    v_row jsonb;
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    v_person := binders._person();
    IF p_binder IS NULL OR btrim(coalesce(p_name, '')) = '' THEN
        RAISE EXCEPTION 'A binder needs an id and a name.' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_existing FROM binders.binders WHERE id = p_binder FOR UPDATE;
    IF v_existing.id IS NOT NULL THEN
        IF NOT (p_binder = ANY (binders.my_binder_ids())) THEN
            RETURN binders._op_end(p_op, binders._refusal('exists', 'A binder with that id is already in the team.'));
        END IF;
        IF p_claim IS NOT NULL AND v_existing.imported_author ->> 'id' = p_claim AND v_existing.created_by IS DISTINCT FROM v_person.member_id THEN
            UPDATE binders.binders SET created_by = v_person.member_id WHERE id = p_binder;
        END IF;
        SELECT to_jsonb(b) INTO v_row FROM binders.binders b WHERE b.id = p_binder;
        RETURN binders._op_end(p_op, binders._refusal('exists', 'This binder is already in the team.', jsonb_build_object('binder', v_row)));
    END IF;
    v_author := coalesce(binders._import_author(p_author), v_person.member_id);
    INSERT INTO binders.binders (id, name, color, icon, everyone, agents_may_finish, agents_may_place, created_by, imported_author)
    VALUES (p_binder, btrim(p_name), v_fields ->> 'color', v_fields ->> 'icon', coalesce((v_fields ->> 'everyone')::boolean, true),
            coalesce((v_fields ->> 'agents_may_finish')::boolean, false), coalesce((v_fields ->> 'agents_may_place')::boolean, false),
            v_author, CASE WHEN jsonb_typeof(p_imported_author) = 'object' THEN p_imported_author END);
    INSERT INTO binders.binder_members (id, binder_id, member_id, added_by)
    VALUES (gen_random_uuid(), p_binder, v_person.member_id, v_person.member_id);
    IF v_author <> v_person.member_id THEN
        INSERT INTO binders.binder_members (id, binder_id, member_id, added_by)
        VALUES (gen_random_uuid(), p_binder, v_author, v_person.member_id) ON CONFLICT (binder_id, member_id) DO NOTHING;
    END IF;
    SELECT to_jsonb(b) INTO v_row FROM binders.binders b WHERE b.id = p_binder;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true, 'binder', v_row));
END $$;

-- A meeting a team folder shared, brought in once, with its transcript (never its audio): by whoever recorded it when
-- they're in the team (`p_author`), else by the caller, with who recorded it kept. One that's there already changes only
-- for its author: their own meeting brought in again (what changed in the folder since: its notes, summary, title, new
-- lines of its transcript), or the person who recorded it (`p_claim`, their own id in the folder) taking it as theirs.
-- `p_fields`: folder_id, title, started_at, ended_at, duration, app_name, attendees, template_id, summary, notes,
-- speaker_names. `p_segments`: [{position, speaker, text, start_time, end_time}].
CREATE FUNCTION binders.import_meeting(p_op uuid, p_meeting uuid, p_binder uuid, p_fields jsonb, p_segments jsonb, p_imported_author jsonb,
                                       p_author uuid DEFAULT NULL, p_claim text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'import_meeting', jsonb_build_object('meeting', p_meeting, 'binder', p_binder,
        'fields', md5(coalesce(p_fields::text, '')), 'segments', md5(coalesce(p_segments::text, '')), 'imported_author', p_imported_author,
        'author', p_author, 'claim', p_claim));
    v_person binders.actor;
    v_fields jsonb := coalesce(p_fields, '{}');
    v_existing binders.meetings;
    v_author uuid;
    v_segment jsonb;
    v_added integer := 0;
    v_changed integer := 0;
    v_row jsonb;
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    v_person := binders._person();
    PERFORM binders._require_binder(p_binder);
    IF p_meeting IS NULL THEN
        RAISE EXCEPTION 'A meeting needs an id.' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_existing FROM binders.meetings WHERE id = p_meeting FOR UPDATE;
    IF v_existing.id IS NOT NULL THEN
        IF NOT (v_existing.binder_id = ANY (binders.my_binder_ids())) THEN
            RETURN binders._op_end(p_op, binders._refusal('exists', 'A meeting with that id is already in the team.'));
        END IF;
        IF p_claim IS NOT NULL AND v_existing.imported_author ->> 'id' = p_claim AND v_existing.author_id <> v_person.member_id THEN
            UPDATE binders.meetings SET author_id = v_person.member_id WHERE id = p_meeting;
            v_existing.author_id := v_person.member_id;
        END IF;
        IF v_existing.author_id <> v_person.member_id OR v_existing.deleted_at IS NOT NULL THEN
            SELECT to_jsonb(m) INTO v_row FROM binders.meetings m WHERE m.id = p_meeting;
            RETURN binders._op_end(p_op, jsonb_build_object('ok', true, 'unchanged', true, 'meeting', v_row));
        END IF;
    ELSE
        v_author := coalesce(binders._import_author(p_author), v_person.member_id);
        INSERT INTO binders.meetings (id, binder_id, author_id, title, imported_author)
        VALUES (p_meeting, p_binder, v_author, coalesce(v_fields ->> 'title', ''),
                CASE WHEN jsonb_typeof(p_imported_author) = 'object' THEN p_imported_author END);
        v_changed := 1;
    END IF;
    -- Only what differs: the same meeting brought in again changes nothing.
    WITH wanted AS (
        SELECT binders._folder_in(m.binder_id, (v_fields ->> 'folder_id')::uuid) AS folder_id,
               coalesce(v_fields ->> 'title', m.title) AS title,
               coalesce((v_fields ->> 'started_at')::timestamptz, m.started_at) AS started_at,
               coalesce((v_fields ->> 'ended_at')::timestamptz, m.ended_at) AS ended_at,
               coalesce((v_fields ->> 'duration')::double precision, m.duration) AS duration,
               CASE WHEN v_fields ? 'app_name' THEN v_fields ->> 'app_name' ELSE m.app_name END AS app_name,
               CASE WHEN jsonb_typeof(v_fields -> 'attendees') = 'array'
                    THEN ARRAY(SELECT jsonb_array_elements_text(v_fields -> 'attendees')) ELSE m.attendees END AS attendees,
               CASE WHEN v_fields ? 'template_id' THEN v_fields ->> 'template_id' ELSE m.template_id END AS template_id,
               coalesce(v_fields ->> 'summary', m.summary) AS summary,
               coalesce(v_fields ->> 'notes', m.notes) AS notes,
               CASE WHEN jsonb_typeof(v_fields -> 'speaker_names') = 'object' THEN v_fields -> 'speaker_names' ELSE m.speaker_names END AS speaker_names
        FROM binders.meetings m WHERE m.id = p_meeting)
    UPDATE binders.meetings m SET folder_id = w.folder_id, title = w.title, started_at = w.started_at, ended_at = w.ended_at,
        duration = w.duration, app_name = w.app_name, attendees = w.attendees, template_id = w.template_id, summary = w.summary,
        notes = w.notes, speaker_names = w.speaker_names, live = false
    FROM wanted w
    WHERE m.id = p_meeting
      AND (m.folder_id, m.title, m.started_at, m.ended_at, m.duration, m.app_name, m.attendees, m.template_id, m.summary, m.notes,
           m.speaker_names, m.live)
          IS DISTINCT FROM (w.folder_id, w.title, w.started_at, w.ended_at, w.duration, w.app_name, w.attendees, w.template_id, w.summary,
                            w.notes, w.speaker_names, false);
    GET DIAGNOSTICS v_added = ROW_COUNT;
    v_changed := v_changed + v_added;
    v_added := 0;
    -- Its transcript: the lines it doesn't have yet, by their place in it.
    FOR v_segment IN SELECT * FROM jsonb_array_elements(coalesce(p_segments, '[]')) LOOP
        INSERT INTO binders.meeting_segments (id, binder_id, meeting_id, position, speaker, text, start_time, end_time)
        SELECT gen_random_uuid(), m.binder_id, p_meeting, (v_segment ->> 'position')::integer, coalesce(v_segment ->> 'speaker', ''),
               coalesce(v_segment ->> 'text', ''), (v_segment ->> 'start_time')::double precision, (v_segment ->> 'end_time')::double precision
        FROM binders.meetings m WHERE m.id = p_meeting
        ON CONFLICT (meeting_id, position) DO NOTHING;
        IF FOUND THEN
            v_added := v_added + 1;
        END IF;
    END LOOP;
    SELECT to_jsonb(m) INTO v_row FROM binders.meetings m WHERE m.id = p_meeting;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true, 'unchanged', v_changed + v_added = 0, 'meeting', v_row, 'segments', v_added));
END $$;
"""#
}
