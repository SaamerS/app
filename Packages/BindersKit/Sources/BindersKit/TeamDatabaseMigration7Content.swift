import Foundation

// Migration 7 of the team database, as SQL (lane DB4): meetings, captures,
// knowledge and to-dos as the Macs share them. A transcript in revisions, what a Mac shows of a capture and a to-do, the
// title and hash a knowledge chunk was made with; an item's maker can bring it back after taking it off the team, move it
// to another shared binder with its transcript and index, or take it off the team with its words erased; an item's whole
// index replaced at once. Applied by TeamDatabaseSetup in one transaction with the others, as the team's owner role.
// Never change a migration that has shipped: add the next one. Folders are migration 6's (`_folder_in`).

extension TeamSchema {
    static let migration7 = TeamMigration(version: 7, name: "Meetings, captures, knowledge and to-dos as the Macs share them: transcripts in revisions, items taken off the team and brought back, an item's index at once",
                                          sql: migration7Columns + migration7Items + migration7Knowledge)

    // MARK: Columns

    private static let migration7Columns = #"""
-- Migration 7: meetings, captures, knowledge and to-dos as the Macs share them.
--
-- A meeting's transcript is only ever added to, in revisions: the lines heard while it's recorded are revision 0, and
-- each time its Mac writes the transcript again (who said what, a better pass, a mic track replaced) the whole new
-- transcript is added as the next revision, and the meeting says which one is current. Nothing sent is changed.

-- Meetings: where the recording is, and which transcript revision is current.
ALTER TABLE binders.meetings ADD COLUMN status text NOT NULL DEFAULT 'ready';
ALTER TABLE binders.meetings ADD COLUMN transcript_revision integer NOT NULL DEFAULT 0;
-- A transcript line's revision, and the channel it was heard on (microphone or system).
ALTER TABLE binders.meeting_segments ADD COLUMN revision integer NOT NULL DEFAULT 0;
ALTER TABLE binders.meeting_segments ADD COLUMN channel text NOT NULL DEFAULT '';

-- Captures filed in a shared binder: what their owner's Mac shows of one (never its audio, which has no column).
ALTER TABLE binders.captures ADD COLUMN status text NOT NULL DEFAULT 'ready';
ALTER TABLE binders.captures ADD COLUMN transcript_revision integer NOT NULL DEFAULT 0;
ALTER TABLE binders.captures ADD COLUMN duration double precision NOT NULL DEFAULT 0;
ALTER TABLE binders.captures ADD COLUMN app_name text;
ALTER TABLE binders.captures ADD COLUMN speaker_names jsonb NOT NULL DEFAULT '{}';
ALTER TABLE binders.captures ADD COLUMN notes text NOT NULL DEFAULT '';
ALTER TABLE binders.capture_segments ADD COLUMN revision integer NOT NULL DEFAULT 0;
ALTER TABLE binders.capture_segments ADD COLUMN channel text NOT NULL DEFAULT '';

-- Knowledge: the title a chunk's vector was made with (the model reads "title: … | text: …"), and a hash of all of its
-- item's chunks, so another Mac tells whether what the team has is for the item as it has it.
ALTER TABLE binders.knowledge_chunks ADD COLUMN title text NOT NULL DEFAULT '';
ALTER TABLE binders.knowledge_chunks ADD COLUMN chunks_hash text NOT NULL DEFAULT '';
ALTER TABLE binders.entities ADD COLUMN chunks_hash text NOT NULL DEFAULT '';
ALTER TABLE binders.relations ADD COLUMN chunks_hash text NOT NULL DEFAULT '';

-- To-dos: what a Mac shows of one. Whose promise it is stays in `owner`; never the message it was found in.
ALTER TABLE binders.todos ADD COLUMN kind text NOT NULL DEFAULT 'todo';
ALTER TABLE binders.todos ADD COLUMN to_name text;
ALTER TABLE binders.todos ADD COLUMN due_text text;
ALTER TABLE binders.todos ADD COLUMN origin text;
ALTER TABLE binders.todos ADD COLUMN made_by text;
ALTER TABLE binders.todos ADD COLUMN source_title text NOT NULL DEFAULT '';
ALTER TABLE binders.todos ADD COLUMN done_at timestamptz;

-- Who made an item: a meeting's author, a capture's owner, a to-do's maker.
CREATE FUNCTION binders._item_maker(p_table text, p_row jsonb) RETURNS uuid
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, binders AS $$
    SELECT (CASE p_table WHEN 'meetings' THEN p_row ->> 'author_id' WHEN 'captures' THEN p_row ->> 'owner_id'
                         ELSE p_row ->> 'created_by' END)::uuid
$$;

-- The knowledge kind an item's index goes by (as the Macs' own index names it).
CREATE FUNCTION binders._knowledge_kind(p_table text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, binders AS $$
    SELECT CASE p_table WHEN 'meetings' THEN 'meeting' WHEN 'captures' THEN 'conversation' END
$$;

"""#
}

extension TeamSchema {
    // MARK: Items: back, moved, taken off the team

    fileprivate static let migration7Items = #"""
-- MARK: Items

-- A meeting, capture or to-do as put_row writes it, and, when it was taken off the team (withdraw_item, delete_row) and
-- whoever made it shares it again, back: the same row, as given.
CREATE FUNCTION binders.put_item(p_op uuid, p_table text, p_row jsonb, p_agent uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'put_item', jsonb_build_object('table', p_table, 'row', md5(coalesce(p_row::text, '')),
        'agent', p_agent));
    v_actor binders.actor;
    v_existing jsonb;
    v_put jsonb;
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    IF coalesce(p_table, '') NOT IN ('meetings', 'captures', 'todos') THEN
        RAISE EXCEPTION 'put_item writes meetings, captures and to-dos, not %.', coalesce(p_table, 'that table') USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(p_row) IS DISTINCT FROM 'object' OR (p_row ->> 'id') IS NULL THEN
        RAISE EXCEPTION 'A row is an object with an id.' USING ERRCODE = '22023';
    END IF;
    v_actor := binders._acting_as(p_agent);
    -- A folder the database doesn't have in the item's binder (not sent yet, or deleted) is the top, as for notes.
    IF p_table <> 'todos' AND p_row ? 'folder_id' THEN
        p_row := jsonb_set(p_row, '{folder_id}',
            coalesce(to_jsonb(binders._folder_in((p_row ->> 'binder_id')::uuid, (p_row ->> 'folder_id')::uuid)), 'null'::jsonb));
    END IF;
    EXECUTE format('SELECT to_jsonb(t) FROM binders.%I t WHERE id = $1 FOR UPDATE', p_table) INTO v_existing USING (p_row ->> 'id')::uuid;
    IF v_existing IS NOT NULL AND v_existing ->> 'deleted_at' IS NOT NULL THEN
        PERFORM binders._require_binder((v_existing ->> 'binder_id')::uuid);
        IF binders._item_maker(p_table, v_existing) IS DISTINCT FROM v_actor.member_id THEN
            RETURN binders._op_end(p_op, binders._refusal('deleted', 'It was deleted, so it can''t be changed. Make a new one instead.'));
        END IF;
        EXECUTE format('UPDATE binders.%I SET deleted_at = NULL WHERE id = $1', p_table) USING (p_row ->> 'id')::uuid;
    END IF;
    v_put := binders._put(v_actor, p_table, p_row);
    IF v_put ? 'refusal' THEN
        -- Nothing of it is kept, the item's coming back included.
        RAISE EXCEPTION '%', v_put -> 'refusal' ->> 'message' USING ERRCODE = 'BD002', DETAIL = (v_put -> 'refusal')::text;
    END IF;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true) || v_put);
END $$;

-- A meeting or a capture to another binder shared with its author or owner, by them: with its transcript (every
-- revision) and its index, which belong to it. At the top of the new binder: a folder belongs to its binder.
CREATE FUNCTION binders.move_item(p_op uuid, p_table text, p_id uuid, p_binder uuid, p_agent uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'move_item', jsonb_build_object('table', p_table, 'id', p_id, 'binder', p_binder,
        'agent', p_agent));
    v_actor binders.actor;
    v_existing jsonb;
    v_from uuid;
    v_kind text;
    v_row jsonb;
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    IF coalesce(p_table, '') NOT IN ('meetings', 'captures') THEN
        RAISE EXCEPTION 'move_item moves meetings and captures, not %.', coalesce(p_table, 'that table') USING ERRCODE = '22023';
    END IF;
    v_actor := binders._acting_as(p_agent);
    EXECUTE format('SELECT to_jsonb(t) FROM binders.%I t WHERE id = $1 FOR UPDATE', p_table) INTO v_existing USING p_id;
    IF v_existing IS NULL OR NOT ((v_existing ->> 'binder_id')::uuid = ANY (binders.my_binder_ids())) THEN
        RETURN binders._op_end(p_op, binders._refusal('not_found', 'Nothing with that id is in a binder shared with you.'));
    END IF;
    IF v_existing ->> 'deleted_at' IS NOT NULL THEN
        RETURN binders._op_end(p_op, binders._refusal('deleted', 'It was deleted, so it can''t be moved. Share it again instead.'));
    END IF;
    IF binders._item_maker(p_table, v_existing) IS DISTINCT FROM v_actor.member_id THEN
        RAISE EXCEPTION 'Only its % moves it.', CASE WHEN p_table = 'meetings' THEN 'author' ELSE 'owner' END USING ERRCODE = '42501';
    END IF;
    PERFORM binders._require_binder(p_binder);
    v_from := (v_existing ->> 'binder_id')::uuid;
    IF v_from <> p_binder THEN
        v_kind := binders._knowledge_kind(p_table);
        EXECUTE format('UPDATE binders.%I SET binder_id = $1, folder_id = NULL WHERE id = $2', p_table) USING p_binder, p_id;
        IF p_table = 'meetings' THEN
            UPDATE binders.meeting_segments SET binder_id = p_binder WHERE meeting_id = p_id;
        ELSE
            UPDATE binders.capture_segments SET binder_id = p_binder WHERE capture_id = p_id;
        END IF;
        UPDATE binders.knowledge_chunks SET binder_id = p_binder WHERE binder_id = v_from AND source_kind = v_kind AND source_id = p_id::text;
        UPDATE binders.entities SET binder_id = p_binder WHERE binder_id = v_from AND source_kind = v_kind AND source_id = p_id::text;
        UPDATE binders.relations SET binder_id = p_binder WHERE binder_id = v_from AND source_kind = v_kind AND source_id = p_id::text;
    END IF;
    EXECUTE format('SELECT to_jsonb(t) FROM binders.%I t WHERE id = $1', p_table) INTO v_row USING p_id;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true, 'row', v_row, 'unchanged', v_from = p_binder));
END $$;

-- Whoever made a meeting, capture or to-do takes it off the team: moved to a binder that isn't shared, or deleted on
-- their Mac. A tombstone stays, so every Mac drops its copy, with its words erased: the title, summary and notes, who
-- was there and who spoke, every transcript line's text, and its index, which goes for good.
CREATE FUNCTION binders.withdraw_item(p_op uuid, p_table text, p_id uuid, p_agent uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'withdraw_item', jsonb_build_object('table', p_table, 'id', p_id, 'agent', p_agent));
    v_actor binders.actor;
    v_existing jsonb;
    v_binder uuid;
    v_kind text;
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    IF coalesce(p_table, '') NOT IN ('meetings', 'captures', 'todos') THEN
        RAISE EXCEPTION 'withdraw_item takes meetings, captures and to-dos off the team, not %.', coalesce(p_table, 'that table')
            USING ERRCODE = '22023';
    END IF;
    v_actor := binders._acting_as(p_agent);
    EXECUTE format('SELECT to_jsonb(t) FROM binders.%I t WHERE id = $1 FOR UPDATE', p_table) INTO v_existing USING p_id;
    IF v_existing IS NULL OR NOT ((v_existing ->> 'binder_id')::uuid = ANY (binders.my_binder_ids())) THEN
        RETURN binders._op_end(p_op, binders._refusal('not_found', 'Nothing with that id is in a binder shared with you.'));
    END IF;
    IF binders._item_maker(p_table, v_existing) IS DISTINCT FROM v_actor.member_id THEN
        RAISE EXCEPTION 'Only whoever made it takes it off the team.' USING ERRCODE = '42501';
    END IF;
    v_binder := (v_existing ->> 'binder_id')::uuid;
    IF p_table = 'meetings' THEN
        UPDATE binders.meetings SET title = '', summary = '', notes = '', attendees = '{}', speaker_names = '{}', app_name = NULL,
            template_id = NULL, live = false, deleted_at = coalesce(deleted_at, now())
        WHERE id = p_id;
        UPDATE binders.meeting_segments SET text = '', speaker = '', deleted_at = coalesce(deleted_at, now())
        WHERE meeting_id = p_id AND (text <> '' OR speaker <> '' OR deleted_at IS NULL);
    ELSIF p_table = 'captures' THEN
        UPDATE binders.captures SET title = '', summary = '', notes = '', speaker_names = '{}', app_name = NULL,
            deleted_at = coalesce(deleted_at, now())
        WHERE id = p_id;
        UPDATE binders.capture_segments SET text = '', speaker = '', deleted_at = coalesce(deleted_at, now())
        WHERE capture_id = p_id AND (text <> '' OR speaker <> '' OR deleted_at IS NULL);
    ELSE
        UPDATE binders.todos SET text = '', owner = NULL, to_name = NULL, due_text = NULL, made_by = NULL, source_title = '',
            deleted_at = coalesce(deleted_at, now())
        WHERE id = p_id;
    END IF;
    v_kind := binders._knowledge_kind(p_table);
    IF v_kind IS NOT NULL THEN
        DELETE FROM binders.knowledge_chunks WHERE binder_id = v_binder AND source_kind = v_kind AND source_id = p_id::text;
        DELETE FROM binders.entities WHERE binder_id = v_binder AND source_kind = v_kind AND source_id = p_id::text;
        DELETE FROM binders.relations WHERE binder_id = v_binder AND source_kind = v_kind AND source_id = p_id::text;
    END IF;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true));
END $$;

"""#
}

extension TeamSchema {
    // MARK: Knowledge: an item's index at once

    fileprivate static let migration7Knowledge = #"""
-- MARK: Knowledge

-- A row with its vector, when it has one as a list of numbers, as text: how the vector column reads it.
CREATE FUNCTION binders._vector_as_text(p_row jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, binders AS $$
    SELECT CASE WHEN jsonb_typeof(p_row -> 'embedding') = 'array'
                THEN jsonb_set(p_row, '{embedding}', to_jsonb((p_row -> 'embedding')::text)) ELSE p_row END
$$;

-- An item's whole index, from the Mac that made the item (a meeting's author, a capture's owner; a note's, anyone in its
-- binder), in one go: its chunks (text, the title the vector was made with, the vector and its model, start time,
-- speaker, the hash of all the item's chunks), its people and topics, how they relate, and for a note that keeps a
-- correction, the correction. Chunks are matched by their place in the item, people and topics by name and kind,
-- relations and corrections by their words: what's the same stays as it is, so the feed carries only what changed; what's
-- new is added; what's gone is deleted for good, so no copies of old words pile up. A vector names the team's model and
-- has its length, or nothing is kept.
CREATE FUNCTION binders.replace_knowledge(p_op uuid, p_binder uuid, p_source_kind text, p_source_id text, p_chunks jsonb,
                                          p_entities jsonb DEFAULT '[]', p_relations jsonb DEFAULT '[]',
                                          p_corrections jsonb DEFAULT NULL, p_agent uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'replace_knowledge', jsonb_build_object('binder', p_binder, 'source_kind', p_source_kind,
        'source_id', p_source_id, 'chunks', md5(coalesce(p_chunks::text, '')), 'entities', md5(coalesce(p_entities::text, '')),
        'relations', md5(coalesce(p_relations::text, '')), 'corrections', md5(coalesce(p_corrections::text, '')), 'agent', p_agent));
    v_actor binders.actor;
    v_model text;
    v_dimension integer;
    v_maker uuid;
    v_found boolean;
    v_item jsonb;
    v_index integer;
    v_row jsonb;
    v_new jsonb;
    v_put jsonb;
    v_keep uuid[];
    v_changed integer := 0;
    v_gone integer;
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    v_actor := binders._acting_as(p_agent);
    PERFORM binders._require_binder(p_binder);
    IF btrim(coalesce(p_source_kind, '')) = '' OR btrim(coalesce(p_source_id, '')) = '' THEN
        RAISE EXCEPTION 'An item''s index needs the item''s kind and id.' USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(coalesce(p_chunks, 'null'::jsonb)) <> 'array' OR jsonb_typeof(coalesce(p_entities, '[]'::jsonb)) <> 'array'
       OR jsonb_typeof(coalesce(p_relations, '[]'::jsonb)) <> 'array'
       OR (p_corrections IS NOT NULL AND jsonb_typeof(p_corrections) <> 'array') THEN
        RAISE EXCEPTION 'replace_knowledge takes lists of chunks, people and topics, relations and corrections.' USING ERRCODE = '22023';
    END IF;
    -- A meeting's index is its author's to make, a capture's its owner's.
    IF p_source_kind IN ('meeting', 'conversation') THEN
        IF p_source_kind = 'meeting' THEN
            SELECT author_id, true INTO v_maker, v_found FROM binders.meetings WHERE id = p_source_id::uuid AND binder_id = p_binder;
        ELSE
            SELECT owner_id, true INTO v_maker, v_found FROM binders.captures WHERE id = p_source_id::uuid AND binder_id = p_binder;
        END IF;
        IF NOT coalesce(v_found, false) THEN
            RETURN binders._op_end(p_op, binders._refusal('not_found', 'That item isn''t in this binder.'));
        END IF;
        IF v_maker IS DISTINCT FROM v_actor.member_id THEN
            RAISE EXCEPTION 'Only whoever made it indexes it for the team.' USING ERRCODE = '42501';
        END IF;
    END IF;
    -- One item's index at a time.
    PERFORM pg_advisory_xact_lock(hashtextextended('binders.knowledge:' || p_binder::text || ':' || p_source_kind || ':' || p_source_id, 0));
    SELECT embedding_model, embedding_dimension INTO v_model, v_dimension FROM binders.team_settings;
    -- Every chunk is checked before anything changes.
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_chunks) LOOP
        IF jsonb_typeof(v_item) <> 'object' OR v_item ->> 'text' IS NULL THEN
            RAISE EXCEPTION 'Each chunk is an object with its text.' USING ERRCODE = '22023';
        END IF;
        IF jsonb_typeof(v_item -> 'embedding') = 'array' THEN
            IF v_item ->> 'embedding_model' IS DISTINCT FROM v_model THEN
                RETURN binders._op_end(p_op, binders._refusal('embedding_model', format('The team embeds with %s, and this vector came from %s.',
                    v_model, coalesce(v_item ->> 'embedding_model', 'a model it doesn''t name'))));
            END IF;
            IF jsonb_array_length(v_item -> 'embedding') <> v_dimension THEN
                RETURN binders._op_end(p_op, binders._refusal('embedding_dimension', format('%s gives %s numbers, and this vector has %s.',
                    v_model, v_dimension, jsonb_array_length(v_item -> 'embedding'))));
            END IF;
        END IF;
    END LOOP;

    -- Chunks, by their place in the item.
    DELETE FROM binders.knowledge_chunks k
    WHERE k.binder_id = p_binder AND k.source_kind = p_source_kind AND k.source_id = p_source_id AND k.deleted_at IS NULL
      AND k.chunk_index >= jsonb_array_length(p_chunks);
    GET DIAGNOSTICS v_gone = ROW_COUNT;
    v_changed := v_changed + v_gone;
    FOR v_item, v_index IN SELECT c, (n - 1)::integer FROM jsonb_array_elements(p_chunks) WITH ORDINALITY AS t(c, n) LOOP
        v_new := jsonb_build_object('binder_id', p_binder, 'source_kind', p_source_kind, 'source_id', p_source_id, 'chunk_index', v_index,
            'text', v_item ->> 'text', 'title', coalesce(v_item ->> 'title', ''), 'chunks_hash', coalesce(v_item ->> 'chunks_hash', ''),
            'start_time', coalesce(v_item -> 'start_time', 'null'::jsonb), 'speaker', coalesce(v_item -> 'speaker', 'null'::jsonb),
            'embedding_model', CASE WHEN jsonb_typeof(v_item -> 'embedding') = 'array' THEN to_jsonb(v_model) ELSE 'null'::jsonb END,
            'embedding', CASE WHEN jsonb_typeof(v_item -> 'embedding') = 'array' THEN v_item -> 'embedding' ELSE 'null'::jsonb END);
        SELECT to_jsonb(k) - 'tsv' INTO v_row FROM binders.knowledge_chunks k
        WHERE k.binder_id = p_binder AND k.source_kind = p_source_kind AND k.source_id = p_source_id AND k.deleted_at IS NULL
          AND k.chunk_index = v_index
        ORDER BY k.created_at, k.id LIMIT 1;
        IF v_row IS NOT NULL THEN
            -- Two in one place (written some other way): the first stays.
            DELETE FROM binders.knowledge_chunks k
            WHERE k.binder_id = p_binder AND k.source_kind = p_source_kind AND k.source_id = p_source_id AND k.deleted_at IS NULL
              AND k.chunk_index = v_index AND k.id <> (v_row ->> 'id')::uuid;
            GET DIAGNOSTICS v_gone = ROW_COUNT;
            v_changed := v_changed + v_gone;
            CONTINUE WHEN binders._as_stored('knowledge_chunks', v_row || binders._vector_as_text(v_new))
                          = binders._as_stored('knowledge_chunks', v_row);
        END IF;
        v_put := binders._put(v_actor, 'knowledge_chunks', v_new || jsonb_build_object('id', coalesce(v_row ->> 'id', gen_random_uuid()::text)));
        IF v_put ? 'refusal' THEN
            RAISE EXCEPTION '%', v_put -> 'refusal' ->> 'message' USING ERRCODE = 'BD002', DETAIL = (v_put -> 'refusal')::text;
        END IF;
        v_changed := v_changed + 1;
    END LOOP;

    -- People and topics, by name and kind.
    v_keep := '{}';
    FOR v_item IN SELECT * FROM jsonb_array_elements(coalesce(p_entities, '[]'::jsonb)) LOOP
        CONTINUE WHEN btrim(coalesce(v_item ->> 'name', '')) = '';
        SELECT to_jsonb(e) INTO v_row FROM binders.entities e
        WHERE e.binder_id = p_binder AND e.source_kind = p_source_kind AND e.source_id = p_source_id AND e.deleted_at IS NULL
          AND e.name = v_item ->> 'name' AND e.kind = coalesce(v_item ->> 'kind', '') AND NOT (e.id = ANY (v_keep))
        ORDER BY e.created_at, e.id LIMIT 1;
        IF v_row IS NULL THEN
            v_put := binders._put(v_actor, 'entities', jsonb_build_object('id', gen_random_uuid(), 'binder_id', p_binder,
                'source_kind', p_source_kind, 'source_id', p_source_id, 'name', v_item ->> 'name', 'kind', coalesce(v_item ->> 'kind', ''),
                'chunks_hash', coalesce(v_item ->> 'chunks_hash', '')));
            IF v_put ? 'refusal' THEN
                RAISE EXCEPTION '%', v_put -> 'refusal' ->> 'message' USING ERRCODE = 'BD002', DETAIL = (v_put -> 'refusal')::text;
            END IF;
            v_keep := v_keep || (v_put -> 'row' ->> 'id')::uuid;
            v_changed := v_changed + 1;
        ELSE
            v_keep := v_keep || (v_row ->> 'id')::uuid;
            IF v_row ->> 'chunks_hash' IS DISTINCT FROM coalesce(v_item ->> 'chunks_hash', '') THEN
                UPDATE binders.entities SET chunks_hash = coalesce(v_item ->> 'chunks_hash', '') WHERE id = (v_row ->> 'id')::uuid;
                v_changed := v_changed + 1;
            END IF;
        END IF;
    END LOOP;
    DELETE FROM binders.entities e
    WHERE e.binder_id = p_binder AND e.source_kind = p_source_kind AND e.source_id = p_source_id AND e.deleted_at IS NULL
      AND NOT (e.id = ANY (v_keep));
    GET DIAGNOSTICS v_gone = ROW_COUNT;
    v_changed := v_changed + v_gone;

    -- How they relate, by subject, predicate and object.
    v_keep := '{}';
    FOR v_item IN SELECT * FROM jsonb_array_elements(coalesce(p_relations, '[]'::jsonb)) LOOP
        CONTINUE WHEN btrim(coalesce(v_item ->> 'subject', '')) = '' OR btrim(coalesce(v_item ->> 'object', '')) = '';
        SELECT to_jsonb(r) INTO v_row FROM binders.relations r
        WHERE r.binder_id = p_binder AND r.source_kind = p_source_kind AND r.source_id = p_source_id AND r.deleted_at IS NULL
          AND r.subject = v_item ->> 'subject' AND r.predicate = coalesce(v_item ->> 'predicate', '') AND r.object = v_item ->> 'object'
          AND NOT (r.id = ANY (v_keep))
        ORDER BY r.created_at, r.id LIMIT 1;
        IF v_row IS NULL THEN
            v_put := binders._put(v_actor, 'relations', jsonb_build_object('id', gen_random_uuid(), 'binder_id', p_binder,
                'source_kind', p_source_kind, 'source_id', p_source_id, 'subject', v_item ->> 'subject',
                'predicate', coalesce(v_item ->> 'predicate', ''), 'object', v_item ->> 'object',
                'chunks_hash', coalesce(v_item ->> 'chunks_hash', '')));
            IF v_put ? 'refusal' THEN
                RAISE EXCEPTION '%', v_put -> 'refusal' ->> 'message' USING ERRCODE = 'BD002', DETAIL = (v_put -> 'refusal')::text;
            END IF;
            v_keep := v_keep || (v_put -> 'row' ->> 'id')::uuid;
            v_changed := v_changed + 1;
        ELSE
            v_keep := v_keep || (v_row ->> 'id')::uuid;
            IF v_row ->> 'chunks_hash' IS DISTINCT FROM coalesce(v_item ->> 'chunks_hash', '') THEN
                UPDATE binders.relations SET chunks_hash = coalesce(v_item ->> 'chunks_hash', '') WHERE id = (v_row ->> 'id')::uuid;
                v_changed := v_changed + 1;
            END IF;
        END IF;
    END LOOP;
    DELETE FROM binders.relations r
    WHERE r.binder_id = p_binder AND r.source_kind = p_source_kind AND r.source_id = p_source_id AND r.deleted_at IS NULL
      AND NOT (r.id = ANY (v_keep));
    GET DIAGNOSTICS v_gone = ROW_COUNT;
    v_changed := v_changed + v_gone;

    -- Corrections, by their words: only when given (a note's index), so a meeting's never touches them.
    IF p_corrections IS NOT NULL THEN
        v_keep := '{}';
        FOR v_item IN SELECT * FROM jsonb_array_elements(p_corrections) LOOP
            CONTINUE WHEN btrim(coalesce(v_item ->> 'text', '')) = '';
            SELECT to_jsonb(c) INTO v_row FROM binders.corrections c
            WHERE c.binder_id = p_binder AND c.source_kind = p_source_kind AND c.source_id = p_source_id AND c.deleted_at IS NULL
              AND c.text = v_item ->> 'text' AND NOT (c.id = ANY (v_keep))
            ORDER BY c.created_at, c.id LIMIT 1;
            IF v_row IS NULL THEN
                v_put := binders._put(v_actor, 'corrections', jsonb_build_object('id', gen_random_uuid(), 'binder_id', p_binder,
                    'source_kind', p_source_kind, 'source_id', p_source_id, 'text', v_item ->> 'text'));
                IF v_put ? 'refusal' THEN
                    RAISE EXCEPTION '%', v_put -> 'refusal' ->> 'message' USING ERRCODE = 'BD002', DETAIL = (v_put -> 'refusal')::text;
                END IF;
                v_keep := v_keep || (v_put -> 'row' ->> 'id')::uuid;
                v_changed := v_changed + 1;
            ELSE
                v_keep := v_keep || (v_row ->> 'id')::uuid;
            END IF;
        END LOOP;
        DELETE FROM binders.corrections c
        WHERE c.binder_id = p_binder AND c.source_kind = p_source_kind AND c.source_id = p_source_id AND c.deleted_at IS NULL
          AND NOT (c.id = ANY (v_keep));
        GET DIAGNOSTICS v_gone = ROW_COUNT;
        v_changed := v_changed + v_gone;
    END IF;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true, 'unchanged', v_changed = 0, 'changed', v_changed,
        'chunks', jsonb_array_length(p_chunks)));
END $$;
"""#
}
