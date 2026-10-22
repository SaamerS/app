import Foundation

// Migration 1 of the team database, as SQL: The team, its binders and agents, the changes feed, and what every write goes through. Applied by TeamDatabaseSetup in one transaction with the
// others, as the team's owner role. Never change a migration that has shipped: add the next one.

extension TeamSchema {
    static let migration1 = TeamMigration(version: 1, name: "The team, its binders and agents, the changes feed, and what every write goes through", sql: #"""
-- Migration 1: the team, its binders and agents, the changes feed, and what every write goes through.
--
-- Applied by TeamDatabaseSetup as the team's owner role, with search_path set to the binders schema, the schema that
-- holds pgvector, and pg_catalog. The owner owns every table and function; members read through row-level security and
-- write only through the functions here and in later migrations, which run as the owner with search_path pinned and
-- check who is calling with session_user.

-- The team: one row, written at setup.
CREATE TABLE binders.team_settings (
    -- Its one row's id: there's only ever one.
    id uuid PRIMARY KEY DEFAULT '00000000-0000-0000-0000-000000000001' CHECK (id = '00000000-0000-0000-0000-000000000001'),
    name text NOT NULL,
    team_role text NOT NULL,
    owner_role text NOT NULL,
    -- The embedding model every Mac uses for the team's knowledge, and how many numbers it gives (the vector column's
    -- dimension). A new pin empties the vectors and adds one to the epoch.
    embedding_model text NOT NULL,
    embedding_dimension integer NOT NULL CHECK (embedding_dimension BETWEEN 1 AND 2000),
    embedding_epoch integer NOT NULL DEFAULT 1,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);

-- A person, or a headless agent with a login of its own. `login` is the Postgres role.
CREATE TABLE binders.members (
    id uuid PRIMARY KEY,
    login text NOT NULL UNIQUE,
    name text NOT NULL CHECK (btrim(name) <> ''),
    kind text NOT NULL DEFAULT 'person' CHECK (kind IN ('person', 'agent')),
    is_admin boolean NOT NULL DEFAULT false,
    -- On until the member changes the one-time password they were given; until then they see and change nothing.
    temporary_password boolean NOT NULL DEFAULT true,
    password_expires timestamptz,
    added_by uuid REFERENCES binders.members (id),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);

-- A binder in the team. Its own id is its binder. Shared with the whole team (`everyone`), or with its binder_members.
CREATE TABLE binders.binders (
    id uuid PRIMARY KEY,
    name text NOT NULL CHECK (btrim(name) <> ''),
    color text,
    icon text,
    everyone boolean NOT NULL DEFAULT false,
    agents_may_finish boolean NOT NULL DEFAULT false,
    agents_may_place boolean NOT NULL DEFAULT false,
    created_by uuid REFERENCES binders.members (id),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);

CREATE TABLE binders.binder_members (
    id uuid PRIMARY KEY,
    binder_id uuid NOT NULL REFERENCES binders.binders (id),
    member_id uuid NOT NULL REFERENCES binders.members (id),
    added_by uuid REFERENCES binders.members (id),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    UNIQUE (binder_id, member_id)
);
CREATE INDEX binder_members_member ON binders.binder_members (member_id);

-- The team's agents, as the team sees them. Nothing about how one runs (its command, folders, permissions, addresses or
-- secrets): that stays on its owner's Mac. `login_id` is a headless agent's own login.
CREATE TABLE binders.agents (
    id uuid PRIMARY KEY,
    owner_id uuid NOT NULL REFERENCES binders.members (id),
    login_id uuid UNIQUE REFERENCES binders.members (id),
    name text NOT NULL CHECK (btrim(name) <> ''),
    kind text NOT NULL DEFAULT '',
    purpose text NOT NULL DEFAULT '',
    binder_ids uuid[] NOT NULL DEFAULT '{}',
    takes_team_cards boolean NOT NULL DEFAULT true,
    online_at timestamptz,
    running_card_id uuid,
    status text NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);
CREATE INDEX agents_owner ON binders.agents (owner_id);

-- Every change's operation id and its first answer, so a retry applies once and gets that answer back. Each member
-- sees only their own.
CREATE TABLE binders.operations (
    op_id uuid PRIMARY KEY,
    member_id uuid NOT NULL,
    fn text NOT NULL,
    request jsonb NOT NULL,
    result jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX operations_member ON binders.operations (member_id, created_at);

-- The changes feed: one row per changed row and transaction, numbered in commit order (see _record_change). It holds
-- where a change was, never what it was: readers read the row as it is now.
CREATE TABLE binders.changes (
    seq bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    xid xid8 NOT NULL DEFAULT pg_current_xact_id(),
    binder_id uuid,
    table_name text NOT NULL,
    row_id uuid NOT NULL,
    kind text NOT NULL CHECK (kind IN ('insert', 'update', 'delete')),
    member_id uuid,
    at timestamptz NOT NULL DEFAULT now(),
    UNIQUE NULLS NOT DISTINCT (xid, table_name, row_id, binder_id)
);
CREATE INDEX changes_binder ON binders.changes (binder_id, seq);

-- Who is acting: the actor's kind and name as the board shows them, the member whose login it is, and the agent when
-- an agent acts.
CREATE TYPE binders.actor AS (kind text, member_id uuid, agent_id uuid, name text);

-- MARK: Who's calling

-- The member whose login this session is: null for a login that isn't a member, was removed, or hasn't changed its
-- one-time password yet.
CREATE FUNCTION binders.me() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
    SELECT id FROM binders.members WHERE login = session_user AND deleted_at IS NULL AND NOT temporary_password
$$;

-- The binders this session's member sees: shared with everyone, or with them. Empty for anyone else.
CREATE FUNCTION binders.my_binder_ids() RETURNS uuid[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
    SELECT coalesce(array_agg(b.id ORDER BY b.id), '{}')
    FROM binders.binders b, (SELECT binders.me() AS id) who
    WHERE who.id IS NOT NULL
      AND (b.everyone OR EXISTS (SELECT 1 FROM binders.binder_members m
                                 WHERE m.binder_id = b.id AND m.member_id = who.id AND m.deleted_at IS NULL))
$$;

-- The calling member, or an error that says why there's none.
CREATE FUNCTION binders._caller() RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_id uuid := binders.me();
BEGIN
    IF v_id IS NOT NULL THEN
        RETURN v_id;
    END IF;
    IF EXISTS (SELECT 1 FROM binders.members WHERE login = session_user AND deleted_at IS NULL AND temporary_password) THEN
        RAISE EXCEPTION 'Change the one-time password first.' USING ERRCODE = 'BD001';
    END IF;
    RAISE EXCEPTION 'This login isn''t a member of the team.' USING ERRCODE = '42501';
END $$;

-- The calling member's row, as above.
CREATE FUNCTION binders._caller_row() RETURNS binders.members
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
    SELECT * FROM binders.members WHERE id = binders._caller()
$$;

-- Who acts on a change: the caller, or the agent `p_agent` when it belongs to the caller (its owner, or the headless
-- agent whose login this is). A headless agent's login always acts as its agent.
CREATE FUNCTION binders._acting_as(p_agent uuid) RETURNS binders.actor
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_me binders.members := binders._caller_row();
    v_agent binders.agents;
    v_owner text;
BEGIN
    IF p_agent IS NULL THEN
        IF v_me.kind = 'agent' THEN
            SELECT * INTO v_agent FROM binders.agents WHERE login_id = v_me.id AND deleted_at IS NULL;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'This login''s agent isn''t listed in the team any more.' USING ERRCODE = '42501';
            END IF;
            RETURN ROW('agent', v_me.id, v_agent.id, v_agent.name)::binders.actor;
        END IF;
        RETURN ROW('person', v_me.id, NULL, v_me.name)::binders.actor;
    END IF;
    SELECT * INTO v_agent FROM binders.agents WHERE id = p_agent AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No agent with that id is listed in the team.' USING ERRCODE = '42501';
    END IF;
    IF v_agent.login_id = v_me.id OR (v_agent.owner_id = v_me.id AND v_me.kind = 'person') THEN
        RETURN ROW('agent', v_me.id, v_agent.id, v_agent.name)::binders.actor;
    END IF;
    SELECT name INTO v_owner FROM binders.members WHERE id = v_agent.owner_id;
    RAISE EXCEPTION '% belongs to %, so this login can''t act for it.', v_agent.name, coalesce(v_owner, 'someone else')
        USING ERRCODE = '42501';
END $$;

-- A person acting for themselves: refuses agents, and headless agents' logins.
CREATE FUNCTION binders._person() RETURNS binders.actor
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_actor binders.actor := binders._acting_as(NULL);
BEGIN
    IF v_actor.kind <> 'person' THEN
        RAISE EXCEPTION 'Only a person in the team can do that.' USING ERRCODE = '42501';
    END IF;
    RETURN v_actor;
END $$;

-- An admin acting for themselves.
CREATE FUNCTION binders._admin() RETURNS binders.actor
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_actor binders.actor := binders._person();
BEGIN
    IF NOT (SELECT is_admin FROM binders.members WHERE id = v_actor.member_id) THEN
        RAISE EXCEPTION 'Only an admin of the team can do that.' USING ERRCODE = '42501';
    END IF;
    RETURN v_actor;
END $$;

-- That the caller sees `p_binder`. The same words whether it doesn't exist or isn't shared with them.
CREATE FUNCTION binders._require_binder(p_binder uuid) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
BEGIN
    IF p_binder IS NULL OR NOT (p_binder = ANY (binders.my_binder_ids())) THEN
        RAISE EXCEPTION 'No binder with that id is shared with you.' USING ERRCODE = '42501';
    END IF;
END $$;

-- MARK: Operation ids

-- Starts a change with its operation id: null when it's new (go ahead), or the first answer when this id was seen
-- before, marked replayed. A retry that arrives while the first try is still running waits for it, here.
CREATE FUNCTION binders._op_begin(p_op uuid, p_fn text, p_request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_me uuid := binders._caller();
    v_row binders.operations;
BEGIN
    IF p_op IS NULL THEN
        RAISE EXCEPTION 'Every change needs an operation id.' USING ERRCODE = '22023';
    END IF;
    INSERT INTO binders.operations (op_id, member_id, fn, request) VALUES (p_op, v_me, p_fn, p_request)
    ON CONFLICT (op_id) DO NOTHING;
    IF FOUND THEN
        RETURN NULL;
    END IF;
    SELECT * INTO v_row FROM binders.operations WHERE op_id = p_op;
    IF v_row.member_id <> v_me OR v_row.fn <> p_fn OR v_row.request IS DISTINCT FROM p_request THEN
        RAISE EXCEPTION 'This operation id was already used for another change.' USING ERRCODE = '22023';
    END IF;
    RETURN v_row.result || jsonb_build_object('replayed', true);
END $$;

-- Keeps a change's answer with its operation id, and returns it.
CREATE FUNCTION binders._op_end(p_op uuid, p_result jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
BEGIN
    UPDATE binders.operations SET result = p_result WHERE op_id = p_op;
    RETURN p_result;
END $$;

-- A refusal: a recorded answer, not an error, so a retry gets it back.
CREATE FUNCTION binders._refusal(p_code text, p_message text, p_extra jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, binders AS $$
    SELECT jsonb_build_object('ok', false, 'refusal', jsonb_build_object('code', p_code, 'message', p_message) || p_extra)
$$;

-- MARK: Rows' times and the changes feed

-- Every row's times: created_at as given or now, never changed after; updated_at now, on every write.
CREATE FUNCTION binders._touch() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, binders AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.created_at := coalesce(NEW.created_at, now());
    ELSE
        NEW.created_at := OLD.created_at;
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END $$;

-- Writes a changed row's place in the feed, at commit (a deferred constraint trigger), holding one lock for the feed
-- from then until the transaction ends: so numbers are handed out in the order transactions commit, and a reader that
-- saw a number never later meets a smaller one. Nothing else is locked while it's held, so writers can't deadlock on
-- it. A row moved to another binder is a delete under the old one and an insert under the new. One NOTIFY per
-- transaction, carrying only a number: NOTIFY isn't filtered by row-level security, so it never says where.
CREATE FUNCTION binders._record_change() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_scope text := TG_ARGV[0];
    v_new jsonb;
    v_old jsonb;
    v_id uuid;
    v_binder uuid;
    v_old_binder uuid;
    v_kind text;
    v_seq bigint;
    v_first bigint;
    v_member uuid := binders.me();
BEGIN
    PERFORM pg_advisory_xact_lock(7311960516743086921);
    IF TG_OP <> 'INSERT' THEN
        v_old := to_jsonb(OLD);
    END IF;
    IF TG_OP <> 'DELETE' THEN
        v_new := to_jsonb(NEW);
    END IF;
    v_id := (coalesce(v_new, v_old) ->> 'id')::uuid;
    IF v_scope <> 'team' THEN
        v_binder := (coalesce(v_new, v_old) ->> v_scope)::uuid;
        v_old_binder := (v_old ->> v_scope)::uuid;
    END IF;
    v_kind := CASE
        WHEN TG_OP = 'INSERT' THEN 'insert'
        WHEN TG_OP = 'DELETE' THEN 'delete'
        WHEN v_new ->> 'deleted_at' IS NOT NULL AND v_old ->> 'deleted_at' IS NULL THEN 'delete'
        ELSE 'update'
    END;
    IF TG_OP = 'UPDATE' AND v_old_binder IS DISTINCT FROM v_binder THEN
        INSERT INTO binders.changes (binder_id, table_name, row_id, kind, member_id)
        VALUES (v_old_binder, TG_TABLE_NAME, v_id, 'delete', v_member)
        ON CONFLICT DO NOTHING RETURNING seq INTO v_first;
        IF v_kind = 'update' THEN
            v_kind := 'insert';
        END IF;
    END IF;
    INSERT INTO binders.changes (binder_id, table_name, row_id, kind, member_id)
    VALUES (v_binder, TG_TABLE_NAME, v_id, v_kind, v_member)
    ON CONFLICT DO NOTHING RETURNING seq INTO v_seq;
    v_first := coalesce(v_first, v_seq);
    IF v_first IS NOT NULL AND current_setting('binders.notified', true) IS DISTINCT FROM pg_current_xact_id()::text THEN
        PERFORM set_config('binders.notified', pg_current_xact_id()::text, true);
        PERFORM pg_notify('binders_changes', v_first::text);
    END IF;
    RETURN NULL;
END $$;

-- The two triggers every table gets: its times, and its place in the feed. `p_scope` is the column holding the row's
-- binder ('binder_id', 'id' for binders themselves), or 'team' for rows the whole team sees.
CREATE FUNCTION binders._track(p_table text, p_scope text) RETURNS void
LANGUAGE plpgsql SET search_path = pg_catalog, binders AS $$
BEGIN
    EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE ON binders.%I FOR EACH ROW EXECUTE FUNCTION binders._touch()',
                   p_table || '_touch', p_table);
    EXECUTE format('CREATE CONSTRAINT TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON binders.%I '
                   'DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION binders._record_change(%L)',
                   p_table || '_changes', p_table, p_scope);
END $$;

-- Row-level security for a table whose rows belong to a binder: a member sees a row only when its binder is one of
-- theirs. Members never write tables directly, so there are only read policies.
CREATE FUNCTION binders._guard(p_table text, p_column text) RETURNS void
LANGUAGE plpgsql SET search_path = pg_catalog, binders AS $$
BEGIN
    EXECUTE format('ALTER TABLE binders.%I ENABLE ROW LEVEL SECURITY', p_table);
    EXECUTE format('CREATE POLICY %I ON binders.%I FOR SELECT USING (%I = ANY ((SELECT binders.my_binder_ids())::uuid[]))',
                   p_table || '_in_my_binders', p_table, p_column);
END $$;

SELECT binders._track('team_settings', 'team');
SELECT binders._track('members', 'team');
SELECT binders._track('binders', 'id');
SELECT binders._track('binder_members', 'binder_id');
SELECT binders._track('agents', 'team');

ALTER TABLE binders.team_settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY team_settings_members ON binders.team_settings FOR SELECT USING ((SELECT binders.me()) IS NOT NULL);
ALTER TABLE binders.members ENABLE ROW LEVEL SECURITY;
CREATE POLICY members_members ON binders.members FOR SELECT USING ((SELECT binders.me()) IS NOT NULL);
ALTER TABLE binders.agents ENABLE ROW LEVEL SECURITY;
CREATE POLICY agents_members ON binders.agents FOR SELECT USING ((SELECT binders.me()) IS NOT NULL);
SELECT binders._guard('binders', 'id');
SELECT binders._guard('binder_members', 'binder_id');
ALTER TABLE binders.operations ENABLE ROW LEVEL SECURITY;
CREATE POLICY operations_own ON binders.operations FOR SELECT USING (member_id = (SELECT binders.me()));
-- The record of migrations, made by the setup before this one: anyone may read which were applied.
ALTER TABLE binders.schema_migrations ENABLE ROW LEVEL SECURITY;
CREATE POLICY schema_migrations_read ON binders.schema_migrations FOR SELECT USING (true);
ALTER TABLE binders.changes ENABLE ROW LEVEL SECURITY;
CREATE POLICY changes_mine ON binders.changes FOR SELECT
    USING ((binder_id IS NULL AND (SELECT binders.me()) IS NOT NULL) OR binder_id = ANY ((SELECT binders.my_binder_ids())::uuid[]));

-- MARK: Privileges

-- What the team role may do, after every migration: use the schema, read every table (row-level security filters),
-- and run the functions whose names don't start with an underscore. Nothing for anyone else.
CREATE FUNCTION binders._grant_team() RETURNS void
LANGUAGE plpgsql SET search_path = pg_catalog, binders AS $$
DECLARE
    v_team text := (SELECT team_role FROM binders.team_settings);
    v_function regprocedure;
BEGIN
    REVOKE ALL ON SCHEMA binders FROM PUBLIC;
    REVOKE ALL ON ALL TABLES IN SCHEMA binders FROM PUBLIC;
    REVOKE ALL ON ALL SEQUENCES IN SCHEMA binders FROM PUBLIC;
    REVOKE ALL ON ALL FUNCTIONS IN SCHEMA binders FROM PUBLIC;
    IF v_team IS NULL THEN
        RETURN;
    END IF;
    EXECUTE format('GRANT USAGE ON SCHEMA binders TO %I', v_team);
    EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA binders TO %I', v_team);
    EXECUTE format('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA binders FROM %I', v_team);
    FOR v_function IN
        SELECT p.oid::regprocedure FROM pg_proc p
        WHERE p.pronamespace = 'binders'::regnamespace AND p.prokind = 'f' AND left(p.proname, 1) <> '_'
    LOOP
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I', v_function, v_team);
    END LOOP;
END $$;

-- MARK: Setting up

-- The team's one row, at setup, by the owner.
CREATE FUNCTION binders._setup_team(p_name text, p_team_role text, p_owner_role text, p_model text, p_dimension integer)
RETURNS void
LANGUAGE plpgsql SET search_path = pg_catalog, binders AS $$
BEGIN
    INSERT INTO binders.team_settings (name, team_role, owner_role, embedding_model, embedding_dimension)
    VALUES (p_name, p_team_role, p_owner_role, p_model, p_dimension);
END $$;

-- A login name Binders makes: lower-case letters, digits and underscores, starting with a letter.
CREATE FUNCTION binders._valid_login(p_login text) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, binders AS $$
    SELECT p_login ~ '^[a-z][a-z0-9_]{1,62}$'
$$;

-- A name no member or agent may have: the user's own on the board ("You", as BoardRules.isReserved reads it) or
-- Binders' own.
CREATE FUNCTION binders._reserved_name(p_name text) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, binders AS $$
    SELECT lower(btrim(p_name)) IN ('you', 'binders') OR lower(btrim(p_name)) LIKE 'you %'
$$;

-- A password as Binders hands it over: a SCRAM-SHA-256 verifier made on the Mac, never the password itself, so the
-- server, its logs and its backups never see one.
CREATE FUNCTION binders._valid_verifier(p_verifier text) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, binders AS $$
    SELECT p_verifier ~ '^SCRAM-SHA-256\$[0-9]+:[A-Za-z0-9+/]+=*\$[A-Za-z0-9+/]+=*:[A-Za-z0-9+/]+=*$'
$$;

-- The first person, at setup, by the owner: an admin, with the password they chose.
CREATE FUNCTION binders._add_first_member(p_member uuid, p_login text, p_name text, p_verifier text) RETURNS void
LANGUAGE plpgsql SET search_path = pg_catalog, binders AS $$
DECLARE
    v_team text := (SELECT team_role FROM binders.team_settings);
BEGIN
    IF EXISTS (SELECT 1 FROM binders.members) THEN
        RAISE EXCEPTION 'This team already has members.' USING ERRCODE = '22023';
    END IF;
    IF NOT binders._valid_login(p_login) OR NOT binders._valid_verifier(p_verifier) OR binders._reserved_name(p_name) THEN
        RAISE EXCEPTION 'That login, name or password can''t be used.' USING ERRCODE = '22023';
    END IF;
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L IN ROLE %I', p_login, p_verifier, v_team);
    INSERT INTO binders.members (id, login, name, kind, is_admin, temporary_password)
    VALUES (p_member, p_login, btrim(p_name), 'person', true, false);
END $$;

-- MARK: Members

-- Who this login is, for the Mac that just connected: works on a one-time password too.
CREATE FUNCTION binders.whoami() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
    SELECT jsonb_build_object(
        'login', session_user::text,
        'member', (SELECT to_jsonb(m) FROM binders.members m WHERE m.login = session_user AND m.deleted_at IS NULL),
        'agent', (SELECT to_jsonb(a) FROM binders.agents a JOIN binders.members m ON m.id = a.login_id
                  WHERE m.login = session_user AND a.deleted_at IS NULL),
        'team', (SELECT to_jsonb(t) - 'team_role' - 'owner_role' FROM binders.team_settings t),
        'schema', (SELECT max(version) FROM binders.schema_migrations),
        'binders', to_jsonb(binders.my_binder_ids()))
$$;

-- An admin adds a person, or a headless agent with its own login (`p_kind` 'agent', with the agent's id and name; the
-- admin owns it). The password is one-time: it lasts 7 days, and nothing works until the member changes it.
CREATE FUNCTION binders.add_member(p_op uuid, p_member uuid, p_login text, p_name text, p_verifier text,
                                   p_kind text DEFAULT 'person', p_agent uuid DEFAULT NULL, p_agent_name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'add_member', jsonb_build_object('member', p_member, 'login', p_login,
        'name', p_name, 'kind', p_kind, 'agent', p_agent, 'agent_name', p_agent_name));
    v_admin binders.actor;
    v_team text := (SELECT team_role FROM binders.team_settings);
    v_expires timestamptz := now() + interval '7 days';
    v_row jsonb;
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    v_admin := binders._admin();
    IF p_kind NOT IN ('person', 'agent') OR p_member IS NULL OR btrim(coalesce(p_name, '')) = '' THEN
        RAISE EXCEPTION 'A member needs an id, a name, and a kind (person or agent).' USING ERRCODE = '22023';
    END IF;
    IF binders._reserved_name(p_name) OR (p_kind = 'agent' AND binders._reserved_name(coalesce(p_agent_name, ''))) THEN
        RETURN binders._op_end(p_op, binders._refusal('name_reserved', 'That name is kept for Binders itself. Pick another.'));
    END IF;
    IF NOT binders._valid_login(p_login) THEN
        RETURN binders._op_end(p_op, binders._refusal('login_invalid',
            'A login is 2 to 63 lower-case letters, digits or underscores, starting with a letter.'));
    END IF;
    IF NOT binders._valid_verifier(p_verifier) THEN
        RAISE EXCEPTION 'Binders hands passwords over only as SCRAM-SHA-256 verifiers.' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = p_login) THEN
        RETURN binders._op_end(p_op, binders._refusal('login_taken',
            format('A login named %s already exists on this server. Pick another.', p_login)));
    END IF;
    IF p_kind = 'agent' AND (p_agent IS NULL OR btrim(coalesce(p_agent_name, '')) = '') THEN
        RAISE EXCEPTION 'A headless agent''s login needs the agent''s id and name.' USING ERRCODE = '22023';
    END IF;
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L IN ROLE %I VALID UNTIL %L', p_login, p_verifier, v_team, v_expires);
    INSERT INTO binders.members (id, login, name, kind, is_admin, temporary_password, password_expires, added_by)
    VALUES (p_member, p_login, btrim(p_name), p_kind, p_kind = 'person', true, v_expires, v_admin.member_id);
    IF p_kind = 'agent' THEN
        INSERT INTO binders.agents (id, owner_id, login_id, name) VALUES (p_agent, v_admin.member_id, p_member, btrim(p_agent_name));
    END IF;
    SELECT to_jsonb(m) INTO v_row FROM binders.members m WHERE m.id = p_member;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true, 'member', v_row));
END $$;

-- An admin gives a member a new one-time password, for 7 days.
CREATE FUNCTION binders.reset_password(p_op uuid, p_member uuid, p_verifier text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'reset_password', jsonb_build_object('member', p_member));
    v_login text;
    v_expires timestamptz := now() + interval '7 days';
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    PERFORM binders._admin();
    IF NOT binders._valid_verifier(p_verifier) THEN
        RAISE EXCEPTION 'Binders hands passwords over only as SCRAM-SHA-256 verifiers.' USING ERRCODE = '22023';
    END IF;
    SELECT login INTO v_login FROM binders.members WHERE id = p_member AND deleted_at IS NULL;
    IF v_login IS NULL THEN
        RETURN binders._op_end(p_op, binders._refusal('not_found', 'No member with that id is in the team.'));
    END IF;
    EXECUTE format('ALTER ROLE %I LOGIN PASSWORD %L VALID UNTIL %L', v_login, p_verifier, v_expires);
    UPDATE binders.members SET temporary_password = true, password_expires = v_expires WHERE id = p_member;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true, 'expires', v_expires));
END $$;

-- A member sets their own password, one-time or not: the Mac makes a new one and keeps it in the Keychain.
CREATE FUNCTION binders.change_password(p_op uuid, p_verifier text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_member binders.members;
    v_done jsonb;
BEGIN
    SELECT * INTO v_member FROM binders.members WHERE login = session_user AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'This login isn''t a member of the team.' USING ERRCODE = '42501';
    END IF;
    IF NOT binders._valid_verifier(p_verifier) THEN
        RAISE EXCEPTION 'Binders hands passwords over only as SCRAM-SHA-256 verifiers.' USING ERRCODE = '22023';
    END IF;
    -- Recorded without the verifier. A member on a one-time password has no `me` yet, so this one is kept by hand.
    INSERT INTO binders.operations (op_id, member_id, fn, request) VALUES (p_op, v_member.id, 'change_password', '{}')
    ON CONFLICT (op_id) DO NOTHING;
    IF NOT FOUND THEN
        SELECT result || jsonb_build_object('replayed', true) INTO v_done FROM binders.operations
        WHERE op_id = p_op AND member_id = v_member.id AND fn = 'change_password';
        IF v_done IS NULL THEN
            RAISE EXCEPTION 'This operation id was already used for another change.' USING ERRCODE = '22023';
        END IF;
        RETURN v_done;
    END IF;
    EXECUTE format('ALTER ROLE %I PASSWORD %L VALID UNTIL %L', session_user, p_verifier, 'infinity');
    UPDATE binders.members SET temporary_password = false, password_expires = NULL WHERE id = v_member.id;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true));
END $$;

-- An admin takes a member out of the team: their login stops working, and at once they see nothing.
CREATE FUNCTION binders.remove_member(p_op uuid, p_member uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'remove_member', jsonb_build_object('member', p_member));
    v_admin binders.actor;
    v_login text;
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    v_admin := binders._admin();
    IF p_member = v_admin.member_id THEN
        RETURN binders._op_end(p_op, binders._refusal('not_yourself', 'Ask another admin to take you out of the team.'));
    END IF;
    SELECT login INTO v_login FROM binders.members WHERE id = p_member AND deleted_at IS NULL;
    IF v_login IS NULL THEN
        RETURN binders._op_end(p_op, binders._refusal('not_found', 'No member with that id is in the team.'));
    END IF;
    EXECUTE format('ALTER ROLE %I NOLOGIN', v_login);
    UPDATE binders.members SET deleted_at = now() WHERE id = p_member;
    UPDATE binders.agents SET deleted_at = now() WHERE login_id = p_member AND deleted_at IS NULL;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true));
END $$;

-- MARK: Binders

-- A person makes a binder in the team, and is in it.
CREATE FUNCTION binders.create_binder(p_op uuid, p_binder uuid, p_name text, p_everyone boolean DEFAULT false,
                                      p_fields jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'create_binder', jsonb_build_object('binder', p_binder, 'name', p_name,
        'everyone', p_everyone, 'fields', p_fields));
    v_person binders.actor;
    v_row jsonb;
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    v_person := binders._person();
    IF p_binder IS NULL OR btrim(coalesce(p_name, '')) = '' THEN
        RAISE EXCEPTION 'A binder needs an id and a name.' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM binders.binders WHERE id = p_binder) THEN
        RETURN binders._op_end(p_op, binders._refusal('exists', 'A binder with that id is already in the team.'));
    END IF;
    INSERT INTO binders.binders (id, name, color, icon, everyone, agents_may_finish, agents_may_place, created_by)
    VALUES (p_binder, btrim(p_name), p_fields ->> 'color', p_fields ->> 'icon', coalesce(p_everyone, false),
            coalesce((p_fields ->> 'agents_may_finish')::boolean, false), coalesce((p_fields ->> 'agents_may_place')::boolean, false),
            v_person.member_id);
    INSERT INTO binders.binder_members (id, binder_id, member_id, added_by)
    VALUES (gen_random_uuid(), p_binder, v_person.member_id, v_person.member_id);
    SELECT to_jsonb(b) INTO v_row FROM binders.binders b WHERE b.id = p_binder;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true, 'binder', v_row));
END $$;

-- A person in the binder changes its name, colour, icon or settings. Agents can't: what they may do and see isn't
-- theirs to change.
CREATE FUNCTION binders.update_binder(p_op uuid, p_binder uuid, p_fields jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'update_binder', jsonb_build_object('binder', p_binder, 'fields', p_fields));
    v_key text;
    v_row jsonb;
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    PERFORM binders._person();
    PERFORM binders._require_binder(p_binder);
    FOR v_key IN SELECT jsonb_object_keys(p_fields) LOOP
        IF v_key NOT IN ('name', 'color', 'icon', 'everyone', 'agents_may_finish', 'agents_may_place') THEN
            RAISE EXCEPTION 'A binder has no setting %.', v_key USING ERRCODE = '22023';
        END IF;
    END LOOP;
    UPDATE binders.binders SET
        name = CASE WHEN p_fields ? 'name' AND btrim(p_fields ->> 'name') <> '' THEN btrim(p_fields ->> 'name') ELSE name END,
        color = CASE WHEN p_fields ? 'color' THEN p_fields ->> 'color' ELSE color END,
        icon = CASE WHEN p_fields ? 'icon' THEN p_fields ->> 'icon' ELSE icon END,
        everyone = coalesce((p_fields ->> 'everyone')::boolean, everyone),
        agents_may_finish = coalesce((p_fields ->> 'agents_may_finish')::boolean, agents_may_finish),
        agents_may_place = coalesce((p_fields ->> 'agents_may_place')::boolean, agents_may_place)
    WHERE id = p_binder;
    SELECT to_jsonb(b) INTO v_row FROM binders.binders b WHERE b.id = p_binder;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true, 'binder', v_row));
END $$;

-- An admin in the binder shares it with a member.
CREATE FUNCTION binders.share_binder(p_op uuid, p_binder uuid, p_member uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'share_binder', jsonb_build_object('binder', p_binder, 'member', p_member));
    v_admin binders.actor;
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    v_admin := binders._admin();
    PERFORM binders._require_binder(p_binder);
    IF NOT EXISTS (SELECT 1 FROM binders.members WHERE id = p_member AND deleted_at IS NULL) THEN
        RETURN binders._op_end(p_op, binders._refusal('not_found', 'No member with that id is in the team.'));
    END IF;
    INSERT INTO binders.binder_members (id, binder_id, member_id, added_by)
    VALUES (gen_random_uuid(), p_binder, p_member, v_admin.member_id)
    ON CONFLICT (binder_id, member_id) DO UPDATE SET deleted_at = NULL, added_by = EXCLUDED.added_by
    WHERE binder_members.deleted_at IS NOT NULL;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true));
END $$;

-- An admin in the binder stops sharing it with a member (themselves included: leaving it).
CREATE FUNCTION binders.unshare_binder(p_op uuid, p_binder uuid, p_member uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'unshare_binder', jsonb_build_object('binder', p_binder, 'member', p_member));
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    PERFORM binders._admin();
    PERFORM binders._require_binder(p_binder);
    UPDATE binders.binder_members SET deleted_at = now()
    WHERE binder_id = p_binder AND member_id = p_member AND deleted_at IS NULL;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true));
END $$;

-- A person in the binder deletes it; other Macs learn of it from the feed.
CREATE FUNCTION binders.delete_binder(p_op uuid, p_binder uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'delete_binder', jsonb_build_object('binder', p_binder));
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    PERFORM binders._person();
    PERFORM binders._require_binder(p_binder);
    UPDATE binders.binders SET deleted_at = now() WHERE id = p_binder AND deleted_at IS NULL;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true));
END $$;

-- MARK: Agents

-- A person lists one of their agents for the team, or changes what the team sees of it. Only its owner can.
CREATE FUNCTION binders.put_agent(p_op uuid, p_agent uuid, p_fields jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'put_agent', jsonb_build_object('agent', p_agent, 'fields', p_fields));
    v_person binders.actor;
    v_existing binders.agents;
    v_key text;
    v_row jsonb;
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    v_person := binders._person();
    FOR v_key IN SELECT jsonb_object_keys(p_fields) LOOP
        IF v_key NOT IN ('name', 'kind', 'purpose', 'binder_ids', 'takes_team_cards', 'status', 'online_at', 'running_card_id') THEN
            RAISE EXCEPTION 'An agent has no field % the team sees.', v_key USING ERRCODE = '22023';
        END IF;
    END LOOP;
    IF binders._reserved_name(coalesce(p_fields ->> 'name', '')) THEN
        RETURN binders._op_end(p_op, binders._refusal('name_reserved', 'That name is kept for Binders itself. Pick another.'));
    END IF;
    SELECT * INTO v_existing FROM binders.agents WHERE id = p_agent FOR UPDATE;
    IF FOUND AND v_existing.owner_id <> v_person.member_id THEN
        RAISE EXCEPTION '% belongs to someone else, so only its owner changes it.', v_existing.name USING ERRCODE = '42501';
    END IF;
    IF NOT FOUND THEN
        IF btrim(coalesce(p_fields ->> 'name', '')) = '' THEN
            RAISE EXCEPTION 'An agent needs a name.' USING ERRCODE = '22023';
        END IF;
        INSERT INTO binders.agents (id, owner_id, name) VALUES (p_agent, v_person.member_id, btrim(p_fields ->> 'name'));
    END IF;
    UPDATE binders.agents SET
        name = CASE WHEN btrim(coalesce(p_fields ->> 'name', '')) <> '' THEN btrim(p_fields ->> 'name') ELSE name END,
        kind = coalesce(p_fields ->> 'kind', kind),
        purpose = coalesce(p_fields ->> 'purpose', purpose),
        binder_ids = CASE WHEN p_fields ? 'binder_ids'
                          THEN ARRAY(SELECT jsonb_array_elements_text(p_fields -> 'binder_ids'))::uuid[] ELSE binder_ids END,
        takes_team_cards = coalesce((p_fields ->> 'takes_team_cards')::boolean, takes_team_cards),
        status = coalesce(p_fields ->> 'status', status),
        online_at = CASE WHEN p_fields ? 'online_at' THEN (p_fields ->> 'online_at')::timestamptz ELSE online_at END,
        running_card_id = CASE WHEN p_fields ? 'running_card_id' THEN (p_fields ->> 'running_card_id')::uuid ELSE running_card_id END,
        deleted_at = NULL
    WHERE id = p_agent;
    SELECT to_jsonb(a) INTO v_row FROM binders.agents a WHERE a.id = p_agent;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true, 'agent', v_row));
END $$;

-- An agent says it's around (online now), with what it's doing and the card it's running: by its owner's Mac, or by a
-- headless agent's own login.
CREATE FUNCTION binders.agent_status(p_op uuid, p_agent uuid, p_status text, p_running_card uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'agent_status', jsonb_build_object('agent', p_agent, 'status', p_status,
        'running_card', p_running_card));
    v_actor binders.actor;
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    v_actor := binders._acting_as(p_agent);
    UPDATE binders.agents SET online_at = now(), status = coalesce(p_status, ''), running_card_id = p_running_card
    WHERE id = v_actor.agent_id;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true));
END $$;

-- An agent's owner takes it off the team's list.
CREATE FUNCTION binders.remove_agent(p_op uuid, p_agent uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'remove_agent', jsonb_build_object('agent', p_agent));
    v_person binders.actor;
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    v_person := binders._person();
    UPDATE binders.agents SET deleted_at = now()
    WHERE id = p_agent AND owner_id = v_person.member_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RETURN binders._op_end(p_op, binders._refusal('not_found', 'You have no agent with that id on the team''s list.'));
    END IF;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true));
END $$;
"""#)
}
