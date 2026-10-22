import Foundation

// Migration 3 of the team database, as SQL: Folders, notes, meetings, captures, knowledge, distills and to-dos, and writing their rows. Applied by TeamDatabaseSetup in one transaction with the
// others, as the team's owner role. Never change a migration that has shipped: add the next one.

extension TeamSchema {
    static let migration3 = TeamMigration(version: 3, name: "Folders, notes, meetings, captures, knowledge, distills and to-dos, and writing their rows", sql: #"""
-- Migration 3: what's in a binder besides its board. Folders, notes and their history, meetings, captures, knowledge,
-- distills and to-dos, written through put_row / put_rows / replace_rows / delete_row, which keep each table's rules:
-- meetings change only by their author and captures by their owner, notes by anyone in the binder; the transcript's
-- segments and a note's changes are only ever added to; who wrote a row is set here, never taken from the caller.

CREATE TABLE binders.folders (
    id uuid PRIMARY KEY,
    binder_id uuid NOT NULL REFERENCES binders.binders (id),
    parent_id uuid REFERENCES binders.folders (id),
    name text NOT NULL CHECK (btrim(name) <> ''),
    position double precision NOT NULL DEFAULT 0,
    created_by uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);
CREATE INDEX folders_binder ON binders.folders (binder_id);

CREATE TABLE binders.notes (
    id uuid PRIMARY KEY,
    binder_id uuid NOT NULL REFERENCES binders.binders (id),
    folder_id uuid REFERENCES binders.folders (id),
    title text NOT NULL DEFAULT '',
    properties jsonb NOT NULL DEFAULT '{}',
    distill boolean NOT NULL DEFAULT false,
    -- The note as Markdown, readable by anyone who reads the database, and its Automerge document, saved every so often.
    body text NOT NULL DEFAULT '',
    document bytea,
    document_heads text[] NOT NULL DEFAULT '{}',
    document_saved_at timestamptz,
    created_by uuid,
    created_by_agent uuid,
    last_edited_by uuid,
    last_edited_by_agent uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);
CREATE INDEX notes_binder ON binders.notes (binder_id);

-- Each edit as an Automerge change, with the member and, for an agent's edit, the agent. Only ever added to.
CREATE TABLE binders.note_changes (
    id uuid PRIMARY KEY,
    binder_id uuid NOT NULL REFERENCES binders.binders (id),
    note_id uuid NOT NULL REFERENCES binders.notes (id),
    member_id uuid NOT NULL,
    agent_id uuid,
    change bytea NOT NULL,
    hash text NOT NULL,
    deps text[] NOT NULL DEFAULT '{}',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    UNIQUE (note_id, hash)
);
CREATE INDEX note_changes_binder ON binders.note_changes (binder_id);

CREATE TABLE binders.note_versions (
    id uuid PRIMARY KEY,
    binder_id uuid NOT NULL REFERENCES binders.binders (id),
    note_id uuid NOT NULL REFERENCES binders.notes (id),
    first_change_id uuid,
    last_change_id uuid,
    member_id uuid,
    agent_id uuid,
    started_at timestamptz,
    ended_at timestamptz,
    lines_added integer NOT NULL DEFAULT 0,
    lines_removed integer NOT NULL DEFAULT 0,
    sections text[] NOT NULL DEFAULT '{}',
    name text,
    distill_id uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);
CREATE INDEX note_versions_note ON binders.note_versions (note_id);
CREATE INDEX note_versions_binder ON binders.note_versions (binder_id);

CREATE TABLE binders.meetings (
    id uuid PRIMARY KEY,
    binder_id uuid NOT NULL REFERENCES binders.binders (id),
    folder_id uuid REFERENCES binders.folders (id),
    author_id uuid NOT NULL,
    title text NOT NULL DEFAULT '',
    started_at timestamptz,
    ended_at timestamptz,
    duration double precision NOT NULL DEFAULT 0,
    app_name text,
    attendees text[] NOT NULL DEFAULT '{}',
    template_id text,
    summary text NOT NULL DEFAULT '',
    notes text NOT NULL DEFAULT '',
    speaker_names jsonb NOT NULL DEFAULT '{}',
    -- While it's recording: its segments arrive as they're transcribed.
    live boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);
CREATE INDEX meetings_binder ON binders.meetings (binder_id);

-- A meeting's transcript, only ever added to, so it streams while the meeting runs.
CREATE TABLE binders.meeting_segments (
    id uuid PRIMARY KEY,
    binder_id uuid NOT NULL REFERENCES binders.binders (id),
    meeting_id uuid NOT NULL REFERENCES binders.meetings (id),
    position integer NOT NULL,
    speaker text NOT NULL DEFAULT '',
    text text NOT NULL DEFAULT '',
    start_time double precision,
    end_time double precision,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    UNIQUE (meeting_id, position)
);
CREATE INDEX meeting_segments_binder ON binders.meeting_segments (binder_id);

-- Only captures filed in a shared binder come here; what the iPhone hears is private otherwise.
CREATE TABLE binders.captures (
    id uuid PRIMARY KEY,
    binder_id uuid NOT NULL REFERENCES binders.binders (id),
    folder_id uuid REFERENCES binders.folders (id),
    owner_id uuid NOT NULL,
    started_at timestamptz,
    ended_at timestamptz,
    title text NOT NULL DEFAULT '',
    summary text NOT NULL DEFAULT '',
    kept boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);
CREATE INDEX captures_binder ON binders.captures (binder_id);

CREATE TABLE binders.capture_segments (
    id uuid PRIMARY KEY,
    binder_id uuid NOT NULL REFERENCES binders.binders (id),
    capture_id uuid NOT NULL REFERENCES binders.captures (id),
    position integer NOT NULL,
    speaker text NOT NULL DEFAULT '',
    text text NOT NULL DEFAULT '',
    start_time double precision,
    end_time double precision,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    UNIQUE (capture_id, position)
);
CREATE INDEX capture_segments_binder ON binders.capture_segments (binder_id);

-- The index the Mac that added an item made of it: its chunks (the vectors come in migration 4), the people and
-- topics in it, how they relate, and corrections, each with the item it came from.
CREATE TABLE binders.knowledge_chunks (
    id uuid PRIMARY KEY,
    binder_id uuid NOT NULL REFERENCES binders.binders (id),
    source_kind text NOT NULL,
    source_id text NOT NULL,
    chunk_index integer NOT NULL DEFAULT 0,
    text text NOT NULL,
    tsv tsvector GENERATED ALWAYS AS (to_tsvector('simple'::regconfig, text)) STORED,
    embedding_model text,
    start_time double precision,
    speaker text,
    created_by uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);
CREATE INDEX knowledge_chunks_source ON binders.knowledge_chunks (binder_id, source_kind, source_id);
CREATE INDEX knowledge_chunks_tsv ON binders.knowledge_chunks USING gin (tsv);

CREATE TABLE binders.entities (
    id uuid PRIMARY KEY,
    binder_id uuid NOT NULL REFERENCES binders.binders (id),
    source_kind text NOT NULL,
    source_id text NOT NULL,
    name text NOT NULL,
    kind text NOT NULL DEFAULT '',
    created_by uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);
CREATE INDEX entities_source ON binders.entities (binder_id, source_kind, source_id);

CREATE TABLE binders.relations (
    id uuid PRIMARY KEY,
    binder_id uuid NOT NULL REFERENCES binders.binders (id),
    source_kind text NOT NULL,
    source_id text NOT NULL,
    subject text NOT NULL,
    predicate text NOT NULL,
    object text NOT NULL,
    created_by uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);
CREATE INDEX relations_source ON binders.relations (binder_id, source_kind, source_id);

CREATE TABLE binders.corrections (
    id uuid PRIMARY KEY,
    binder_id uuid NOT NULL REFERENCES binders.binders (id),
    source_kind text NOT NULL,
    source_id text NOT NULL,
    text text NOT NULL,
    created_by uuid,
    created_by_agent uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);
CREATE INDEX corrections_source ON binders.corrections (binder_id, source_kind, source_id);

CREATE TABLE binders.distills (
    id uuid PRIMARY KEY,
    binder_id uuid NOT NULL REFERENCES binders.binders (id),
    note_id uuid NOT NULL REFERENCES binders.notes (id),
    run_by uuid,
    run_by_agent uuid,
    -- Who read the note: a model ("the model in Settings → AI") or an agent.
    reader text NOT NULL DEFAULT '',
    reader_agent_id uuid,
    read_at timestamptz,
    note_version_id uuid,
    status text NOT NULL DEFAULT 'proposed' CHECK (status IN ('proposed', 'placed', 'dismissed')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);
CREATE INDEX distills_note ON binders.distills (note_id);
CREATE INDEX distills_binder ON binders.distills (binder_id);

CREATE TABLE binders.distill_items (
    id uuid PRIMARY KEY,
    binder_id uuid NOT NULL REFERENCES binders.binders (id),
    distill_id uuid NOT NULL REFERENCES binders.distills (id),
    position integer NOT NULL DEFAULT 0,
    title text NOT NULL,
    brief text NOT NULL DEFAULT '',
    done_when text NOT NULL DEFAULT '',
    section text,
    section_version_id uuid,
    waits_for uuid[] NOT NULL DEFAULT '{}',
    size text,
    meant_for text,
    card_id uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);
CREATE INDEX distill_items_distill ON binders.distill_items (distill_id);
CREATE INDEX distill_items_binder ON binders.distill_items (binder_id);

CREATE TABLE binders.todos (
    id uuid PRIMARY KEY,
    binder_id uuid NOT NULL REFERENCES binders.binders (id),
    source_kind text CHECK (source_kind IN ('meeting', 'capture', 'note')),
    source_id uuid,
    text text NOT NULL,
    -- Whose promise it is, as the item names them.
    owner text,
    due_at timestamptz,
    status text NOT NULL DEFAULT 'open',
    card_id uuid,
    created_by uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);
CREATE INDEX todos_binder ON binders.todos (binder_id);

SELECT binders._track(t, 'binder_id'), binders._guard(t, 'binder_id')
FROM unnest(ARRAY['folders', 'notes', 'note_changes', 'note_versions', 'meetings', 'meeting_segments', 'captures',
                  'capture_segments', 'knowledge_chunks', 'entities', 'relations', 'corrections', 'distills', 'distill_items',
                  'todos']) AS t;

-- MARK: Writing rows

-- The tables put_row writes, and the columns it sets itself (who wrote it), which the caller's row can't.
CREATE FUNCTION binders._writable(p_table text) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, binders AS $$
    SELECT p_table = ANY (ARRAY['folders', 'notes', 'note_changes', 'note_versions', 'meetings', 'meeting_segments', 'captures',
                                'capture_segments', 'knowledge_chunks', 'entities', 'relations', 'corrections', 'distills',
                                'distill_items', 'todos'])
$$;

CREATE FUNCTION binders._only_added(p_table text) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, binders AS $$
    SELECT p_table = ANY (ARRAY['note_changes', 'meeting_segments', 'capture_segments'])
$$;

CREATE FUNCTION binders._server_columns(p_table text) RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, binders AS $$
    SELECT ARRAY['id', 'created_at', 'updated_at', 'deleted_at'] || CASE p_table
        WHEN 'meetings' THEN ARRAY['author_id']
        WHEN 'captures' THEN ARRAY['owner_id']
        WHEN 'note_changes' THEN ARRAY['member_id', 'agent_id']
        WHEN 'notes' THEN ARRAY['created_by', 'created_by_agent', 'last_edited_by', 'last_edited_by_agent']
        WHEN 'corrections' THEN ARRAY['created_by', 'created_by_agent']
        WHEN 'distills' THEN ARRAY['run_by', 'run_by_agent']
        WHEN 'note_versions' THEN ARRAY[]::text[]
        WHEN 'distill_items' THEN ARRAY[]::text[]
        ELSE ARRAY['created_by'] END
$$;

-- The columns of a table a row can carry: not generated ones.
CREATE FUNCTION binders._columns(p_table text) RETURNS text[]
LANGUAGE sql STABLE SET search_path = pg_catalog, binders AS $$
    SELECT coalesce(array_agg(a.attname::text ORDER BY a.attnum), '{}')
    FROM pg_attribute a
    WHERE a.attrelid = ('binders.' || quote_ident(p_table))::regclass AND a.attnum > 0 AND NOT a.attisdropped AND a.attgenerated = ''
$$;

-- A row as its table stores it, read back as JSON: to compare what was sent with what's there.
CREATE FUNCTION binders._as_stored(p_table text, p_row jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = pg_catalog, binders AS $$
DECLARE
    v_row jsonb;
BEGIN
    EXECUTE format('SELECT to_jsonb(r) FROM jsonb_populate_record(NULL::binders.%I, $1) r', p_table) INTO v_row USING p_row;
    RETURN v_row;
END $$;

-- Writes one row of `p_table` for `p_actor`, after its table's rules: {"row": …, "unchanged": …} or a refusal. Columns
-- the row leaves out keep what they had (or their defaults); its id is the caller's.
CREATE FUNCTION binders._put(p_actor binders.actor, p_table text, p_row jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path = pg_catalog, binders AS $$
DECLARE
    v_id uuid;
    v_existing jsonb;
    v_binder uuid;
    v_old_binder uuid;
    v_parent jsonb;
    v_row jsonb := p_row;
    v_server jsonb := '{}';
    v_columns text[];
    v_list text;
    v_key text;
    v_model text;
    v_dimension integer;
    v_result jsonb;
BEGIN
    IF NOT binders._writable(coalesce(p_table, '')) THEN
        RAISE EXCEPTION 'put_row doesn''t write %.', coalesce(p_table, 'that table') USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(p_row) IS DISTINCT FROM 'object' OR (p_row ->> 'id') IS NULL THEN
        RAISE EXCEPTION 'A row is an object with an id.' USING ERRCODE = '22023';
    END IF;
    v_id := (p_row ->> 'id')::uuid;
    v_columns := binders._columns(p_table);
    FOR v_key IN SELECT jsonb_object_keys(p_row) LOOP
        IF NOT (v_key = ANY (v_columns)) THEN
            RAISE EXCEPTION 'The % table has no column %.', p_table, v_key USING ERRCODE = '22023';
        END IF;
    END LOOP;
    EXECUTE format('SELECT to_jsonb(t) FROM binders.%I t WHERE id = $1 FOR UPDATE', p_table) INTO v_existing USING v_id;
    v_old_binder := (v_existing ->> 'binder_id')::uuid;
    v_binder := coalesce((p_row ->> 'binder_id')::uuid, v_old_binder);
    PERFORM binders._require_binder(v_binder);
    IF v_existing IS NOT NULL THEN
        IF v_old_binder <> v_binder THEN
            PERFORM binders._require_binder(v_old_binder);
        END IF;
        IF v_existing ->> 'deleted_at' IS NOT NULL THEN
            RETURN binders._refusal('deleted', 'It was deleted, so it can''t be changed. Make a new one instead.');
        END IF;
        IF binders._only_added(p_table) THEN
            -- Sent again, as it is: already there. Anything else would change what's only ever added to.
            IF binders._as_stored(p_table, v_existing || (p_row - binders._server_columns(p_table)))
               = binders._as_stored(p_table, v_existing) THEN
                RETURN jsonb_build_object('row', v_existing, 'unchanged', true);
            END IF;
            RETURN binders._refusal('only_added', 'This is only ever added to, so it can''t be changed.');
        END IF;
    END IF;

    -- Each table's rules, and who wrote it.
    CASE p_table
    WHEN 'meetings' THEN
        IF v_existing IS NOT NULL AND (v_existing ->> 'author_id')::uuid <> p_actor.member_id THEN
            RAISE EXCEPTION 'Only the meeting''s author changes it.' USING ERRCODE = '42501';
        END IF;
        IF v_existing IS NULL THEN
            v_server := jsonb_build_object('author_id', p_actor.member_id);
        END IF;
    WHEN 'captures' THEN
        IF v_existing IS NOT NULL AND (v_existing ->> 'owner_id')::uuid <> p_actor.member_id THEN
            RAISE EXCEPTION 'Only the capture''s owner changes it.' USING ERRCODE = '42501';
        END IF;
        IF v_existing IS NULL THEN
            v_server := jsonb_build_object('owner_id', p_actor.member_id);
        END IF;
    WHEN 'meeting_segments', 'capture_segments' THEN
        IF p_table = 'meeting_segments' THEN
            SELECT jsonb_build_object('binder', binder_id, 'by', author_id) INTO v_parent FROM binders.meetings
            WHERE id = (p_row ->> 'meeting_id')::uuid AND deleted_at IS NULL;
        ELSE
            SELECT jsonb_build_object('binder', binder_id, 'by', owner_id) INTO v_parent FROM binders.captures
            WHERE id = (p_row ->> 'capture_id')::uuid AND deleted_at IS NULL;
        END IF;
        IF v_parent IS NULL OR (v_parent ->> 'binder')::uuid <> v_binder THEN
            RAISE EXCEPTION 'A segment goes with its % in the same binder.', CASE WHEN p_table = 'meeting_segments' THEN 'meeting' ELSE 'capture' END
                USING ERRCODE = '22023';
        END IF;
        IF (v_parent ->> 'by')::uuid <> p_actor.member_id THEN
            RAISE EXCEPTION 'Only its % adds to its transcript.', CASE WHEN p_table = 'meeting_segments' THEN 'meeting''s author' ELSE 'capture''s owner' END
                USING ERRCODE = '42501';
        END IF;
    WHEN 'notes' THEN
        v_server := jsonb_build_object('last_edited_by', p_actor.member_id, 'last_edited_by_agent', p_actor.agent_id);
        IF v_existing IS NULL THEN
            v_server := v_server || jsonb_build_object('created_by', p_actor.member_id, 'created_by_agent', p_actor.agent_id);
        END IF;
    WHEN 'note_changes' THEN
        IF NOT EXISTS (SELECT 1 FROM binders.notes WHERE id = (p_row ->> 'note_id')::uuid AND binder_id = v_binder) THEN
            RAISE EXCEPTION 'A note''s change goes with its note, in the same binder.' USING ERRCODE = '22023';
        END IF;
        -- The same change under another id: already there.
        SELECT to_jsonb(c) INTO v_result FROM binders.note_changes c
        WHERE c.note_id = (p_row ->> 'note_id')::uuid AND c.hash = p_row ->> 'hash';
        IF v_result IS NOT NULL THEN
            RETURN jsonb_build_object('row', v_result, 'unchanged', true);
        END IF;
        v_server := jsonb_build_object('member_id', p_actor.member_id, 'agent_id', p_actor.agent_id);
    WHEN 'folders' THEN
        IF p_row ? 'parent_id' AND p_row ->> 'parent_id' IS NOT NULL THEN
            IF NOT EXISTS (SELECT 1 FROM binders.folders WHERE id = (p_row ->> 'parent_id')::uuid AND binder_id = v_binder) THEN
                RAISE EXCEPTION 'A folder''s parent is a folder in the same binder.' USING ERRCODE = '22023';
            END IF;
            IF EXISTS (WITH RECURSIVE up(id, parent) AS (
                           SELECT id, parent_id FROM binders.folders WHERE id = (p_row ->> 'parent_id')::uuid
                           UNION
                           SELECT f.id, f.parent_id FROM binders.folders f JOIN up ON f.id = up.parent)
                       SELECT 1 FROM up WHERE id = v_id) THEN
                RETURN binders._refusal('cycle', 'A folder can''t go inside itself.');
            END IF;
        END IF;
        IF v_existing IS NULL THEN
            v_server := jsonb_build_object('created_by', p_actor.member_id);
        END IF;
    WHEN 'corrections' THEN
        IF v_existing IS NULL THEN
            v_server := jsonb_build_object('created_by', p_actor.member_id, 'created_by_agent', p_actor.agent_id);
        END IF;
    WHEN 'distills' THEN
        IF v_existing IS NULL THEN
            v_server := jsonb_build_object('run_by', p_actor.member_id, 'run_by_agent', p_actor.agent_id);
        END IF;
    WHEN 'note_versions', 'distill_items' THEN
        NULL;
    ELSE
        IF v_existing IS NULL THEN
            v_server := jsonb_build_object('created_by', p_actor.member_id);
        END IF;
    END CASE;

    -- A knowledge vector names the team's model and has its dimension.
    IF p_table = 'knowledge_chunks' AND jsonb_typeof(p_row -> 'embedding') = 'array' THEN
        SELECT embedding_model, embedding_dimension INTO v_model, v_dimension FROM binders.team_settings;
        IF p_row ->> 'embedding_model' IS DISTINCT FROM v_model THEN
            RETURN binders._refusal('embedding_model', format('The team embeds with %s, and this vector came from %s.',
                v_model, coalesce(p_row ->> 'embedding_model', 'a model it doesn''t name')));
        END IF;
        IF jsonb_array_length(p_row -> 'embedding') <> v_dimension THEN
            RETURN binders._refusal('embedding_dimension', format('%s gives %s numbers, and this vector has %s.',
                v_model, v_dimension, jsonb_array_length(p_row -> 'embedding')));
        END IF;
        v_row := jsonb_set(v_row, '{embedding}', to_jsonb((p_row -> 'embedding')::text));
    END IF;

    v_row := (v_row - binders._server_columns(p_table)) || v_server;
    IF v_existing IS NULL THEN
        v_row := v_row || jsonb_build_object('id', v_id);
        IF p_row ? 'created_at' THEN
            v_row := v_row || jsonb_build_object('created_at', p_row -> 'created_at');
        END IF;
        SELECT string_agg(quote_ident(k), ', ') INTO v_list FROM jsonb_object_keys(v_row) k;
        EXECUTE format('INSERT INTO binders.%I (%s) SELECT %s FROM jsonb_populate_record(NULL::binders.%I, $1)',
                       p_table, v_list, v_list, p_table) USING v_row;
    ELSE
        SELECT string_agg(quote_ident(k), ', ') INTO v_list FROM jsonb_object_keys(v_row) k;
        IF v_list IS NOT NULL THEN
            EXECUTE format('UPDATE binders.%I SET (%s) = (SELECT %s FROM jsonb_populate_record(NULL::binders.%I, $1)) WHERE id = $2',
                           p_table, v_list, v_list, p_table) USING v_row, v_id;
        END IF;
    END IF;
    EXECUTE format('SELECT to_jsonb(t) - ''tsv'' FROM binders.%I t WHERE id = $1', p_table) INTO v_result USING v_id;
    RETURN jsonb_build_object('row', v_result, 'unchanged', false);
END $$;

-- Writes one row of a binder's notes, meetings, captures, knowledge, distills, to-dos or folders. `p_row` is the row
-- as JSON, with its id; the columns it leaves out keep what they had.
CREATE FUNCTION binders.put_row(p_op uuid, p_table text, p_row jsonb, p_agent uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'put_row', jsonb_build_object('table', p_table, 'row', md5(coalesce(p_row::text, '')),
        'agent', p_agent));
    v_put jsonb;
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    v_put := binders._put(binders._acting_as(p_agent), p_table, p_row);
    IF v_put ? 'refusal' THEN
        RETURN binders._op_end(p_op, v_put);
    END IF;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true) || v_put);
END $$;

-- Writes several rows of one table, in order, all or none: one refused refuses them all (SQLSTATE BD002, with its
-- words), and nothing is kept.
CREATE FUNCTION binders.put_rows(p_op uuid, p_table text, p_rows jsonb, p_agent uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'put_rows', jsonb_build_object('table', p_table, 'rows', md5(coalesce(p_rows::text, '')),
        'agent', p_agent));
    v_actor binders.actor;
    v_put jsonb;
    v_row jsonb;
    v_ids jsonb := '[]';
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    IF jsonb_typeof(p_rows) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'put_rows takes an array of rows.' USING ERRCODE = '22023';
    END IF;
    v_actor := binders._acting_as(p_agent);
    FOR v_row IN SELECT r FROM jsonb_array_elements(p_rows) WITH ORDINALITY AS t(r, n) ORDER BY n LOOP
        v_put := binders._put(v_actor, p_table, v_row);
        IF v_put ? 'refusal' THEN
            RAISE EXCEPTION '%', v_put -> 'refusal' ->> 'message' USING ERRCODE = 'BD002', DETAIL = (v_put -> 'refusal')::text;
        END IF;
        v_ids := v_ids || jsonb_build_array(v_row ->> 'id');
    END LOOP;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true, 'ids', v_ids));
END $$;

-- An item's index made again: its rows in `p_table` (knowledge chunks, entities or relations of one source) become
-- `p_rows`, and the ones not among them are deleted, all at once.
CREATE FUNCTION binders.replace_rows(p_op uuid, p_table text, p_binder uuid, p_source_kind text, p_source_id text, p_rows jsonb,
                                     p_agent uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'replace_rows', jsonb_build_object('table', p_table, 'binder', p_binder,
        'source_kind', p_source_kind, 'source_id', p_source_id, 'rows', md5(coalesce(p_rows::text, '')), 'agent', p_agent));
    v_actor binders.actor;
    v_put jsonb;
    v_row jsonb;
    v_keep uuid[] := '{}';
    v_gone integer;
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    IF p_table NOT IN ('knowledge_chunks', 'entities', 'relations', 'corrections') THEN
        RAISE EXCEPTION 'replace_rows replaces an item''s knowledge, not %.', coalesce(p_table, 'that table') USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(p_rows) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'replace_rows takes an array of rows.' USING ERRCODE = '22023';
    END IF;
    v_actor := binders._acting_as(p_agent);
    PERFORM binders._require_binder(p_binder);
    FOR v_row IN SELECT r FROM jsonb_array_elements(p_rows) WITH ORDINALITY AS t(r, n) ORDER BY n LOOP
        v_row := v_row || jsonb_build_object('binder_id', p_binder, 'source_kind', p_source_kind, 'source_id', p_source_id);
        v_put := binders._put(v_actor, p_table, v_row);
        IF v_put ? 'refusal' THEN
            RAISE EXCEPTION '%', v_put -> 'refusal' ->> 'message' USING ERRCODE = 'BD002', DETAIL = (v_put -> 'refusal')::text;
        END IF;
        v_keep := v_keep || (v_row ->> 'id')::uuid;
    END LOOP;
    EXECUTE format('UPDATE binders.%I SET deleted_at = now() WHERE binder_id = $1 AND source_kind = $2 AND source_id = $3 '
                   'AND deleted_at IS NULL AND NOT (id = ANY ($4))', p_table)
        USING p_binder, p_source_kind, p_source_id, v_keep;
    GET DIAGNOSTICS v_gone = ROW_COUNT;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true, 'kept', cardinality(v_keep), 'deleted', v_gone));
END $$;

-- Deletes a row (it stays, with deleted_at set, so other Macs learn of it), with the same rules as writing it. What's
-- only ever added to isn't deleted.
CREATE FUNCTION binders.delete_row(p_op uuid, p_table text, p_id uuid, p_agent uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'delete_row', jsonb_build_object('table', p_table, 'id', p_id, 'agent', p_agent));
    v_actor binders.actor;
    v_existing jsonb;
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    IF NOT binders._writable(coalesce(p_table, '')) THEN
        RAISE EXCEPTION 'delete_row doesn''t delete from %.', coalesce(p_table, 'that table') USING ERRCODE = '22023';
    END IF;
    v_actor := binders._acting_as(p_agent);
    EXECUTE format('SELECT to_jsonb(t) FROM binders.%I t WHERE id = $1 FOR UPDATE', p_table) INTO v_existing USING p_id;
    IF v_existing IS NULL OR NOT ((v_existing ->> 'binder_id')::uuid = ANY (binders.my_binder_ids())) THEN
        RETURN binders._op_end(p_op, binders._refusal('not_found', 'Nothing with that id is in a binder shared with you.'));
    END IF;
    IF binders._only_added(p_table) THEN
        RETURN binders._op_end(p_op, binders._refusal('only_added', 'This is only ever added to, so it can''t be deleted.'));
    END IF;
    IF (p_table = 'meetings' AND (v_existing ->> 'author_id')::uuid <> v_actor.member_id)
       OR (p_table = 'captures' AND (v_existing ->> 'owner_id')::uuid <> v_actor.member_id) THEN
        RAISE EXCEPTION 'Only its % deletes it.', CASE WHEN p_table = 'meetings' THEN 'author' ELSE 'owner' END USING ERRCODE = '42501';
    END IF;
    IF v_existing ->> 'deleted_at' IS NULL THEN
        EXECUTE format('UPDATE binders.%I SET deleted_at = now() WHERE id = $1', p_table) USING p_id;
    END IF;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true));
END $$;
"""#)
}
