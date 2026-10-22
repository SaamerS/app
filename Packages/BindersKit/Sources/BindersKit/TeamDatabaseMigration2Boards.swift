import Foundation

// Migration 2 of the team database, as SQL: Boards: cards, what they wait for, their timelines, and one function per action. Applied by TeamDatabaseSetup in one transaction with the
// others, as the team's owner role. Never change a migration that has shipped: add the next one.

extension TeamSchema {
    static let migration2 = TeamMigration(version: 2, name: "Boards: cards, what they wait for, their timelines, and one function per action", sql: #"""
-- Migration 2: boards. Cards, what they wait for, their timelines, and one function per action on them.
--
-- The rules mirror BoardRules in BindersKit (Board.swift) as BoardService applies them, so every Mac, headless agent and
-- older Binders goes through the same checks; the shared board cases (Fixtures/team/board-cases.json) run against both.
-- Leases are read against now(): nothing runs on a timer, and a lapsed card reads as Ready.

CREATE TABLE binders.cards (
    id uuid PRIMARY KEY,
    binder_id uuid NOT NULL REFERENCES binders.binders (id),
    title text NOT NULL CHECK (btrim(title) <> ''),
    details text NOT NULL DEFAULT '',
    board_column text NOT NULL DEFAULT 'backlog'
        CHECK (board_column IN ('backlog', 'ready', 'in_progress', 'blocked', 'review', 'done')),
    position double precision NOT NULL DEFAULT 0,
    -- Who has it: a person (holder_member_id) or an agent (holder_agent_id), with the name the board shows.
    holder_kind text CHECK (holder_kind IN ('person', 'agent')),
    holder_member_id uuid,
    holder_agent_id uuid,
    holder_name text,
    -- When an agent's claim on work in progress lapses unless it reports in. People's claims don't lapse.
    lease_until timestamptz,
    meant_for text,
    meant_for_by_agent boolean NOT NULL DEFAULT false,
    due_at timestamptz,
    links text[] NOT NULL DEFAULT '{}',
    source_kind text,
    source_id text,
    source_title text,
    todo_id uuid,
    -- Distilled from a note: the work item it became, the note's section and the note's version it was read at.
    distill_item_id uuid,
    note_section text,
    note_version_id uuid,
    created_by_name text NOT NULL DEFAULT '',
    created_by_member uuid,
    created_by_agent uuid,
    external_key text,
    external_url text,
    -- One more on every change.
    version integer NOT NULL DEFAULT 1,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);
CREATE INDEX cards_binder ON binders.cards (binder_id, board_column);

-- A card that waits for another: an agent can't claim it until every card it waits for is Done.
CREATE TABLE binders.card_dependencies (
    id uuid PRIMARY KEY,
    binder_id uuid NOT NULL REFERENCES binders.binders (id),
    card_id uuid NOT NULL REFERENCES binders.cards (id),
    waits_for_id uuid NOT NULL REFERENCES binders.cards (id),
    created_by uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    UNIQUE (card_id, waits_for_id),
    CHECK (card_id <> waits_for_id)
);
CREATE INDEX card_dependencies_waits_for ON binders.card_dependencies (waits_for_id);

-- A card's timeline, only ever added to: every claim, move, report, question, approval, answer and finish, with who
-- (as TaskEvent: the name and kind the board shows) and when. `number` keeps the order lines were written in;
-- `written_by` is the member whose login wrote it.
CREATE TABLE binders.card_events (
    id uuid PRIMARY KEY,
    number bigint GENERATED ALWAYS AS IDENTITY,
    binder_id uuid NOT NULL REFERENCES binders.binders (id),
    card_id uuid NOT NULL REFERENCES binders.cards (id),
    kind text NOT NULL,
    author_kind text NOT NULL CHECK (author_kind IN ('person', 'agent')),
    author_name text NOT NULL,
    author_member_id uuid,
    author_agent_id uuid,
    written_by uuid,
    text text NOT NULL DEFAULT '',
    from_column text,
    to_column text,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);
CREATE INDEX card_events_card ON binders.card_events (card_id, number);
CREATE INDEX card_events_binder ON binders.card_events (binder_id);

SELECT binders._track('cards', 'binder_id');
SELECT binders._track('card_dependencies', 'binder_id');
SELECT binders._track('card_events', 'binder_id');
SELECT binders._guard('cards', 'binder_id');
SELECT binders._guard('card_dependencies', 'binder_id');
SELECT binders._guard('card_events', 'binder_id');

-- A card's version grows with every change to it.
CREATE FUNCTION binders._card_version() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, binders AS $$
BEGIN
    NEW.version := OLD.version + 1;
    RETURN NEW;
END $$;
CREATE TRIGGER cards_version BEFORE UPDATE ON binders.cards FOR EACH ROW EXECUTE FUNCTION binders._card_version();

-- MARK: The rules (BoardRules)

-- BoardRules.lease: how long an agent's claim lasts without a word from it.
CREATE FUNCTION binders._lease() RETURNS interval
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$ SELECT interval '30 minutes' $$;

-- Where cards are ordered in a column, as the Mac orders them: seconds since 2001 (Date.timeIntervalSinceReferenceDate).
CREATE FUNCTION binders._position_now() RETURNS double precision
LANGUAGE sql STABLE SET search_path = pg_catalog AS $$ SELECT extract(epoch FROM now())::double precision - 978307200 $$;

-- BoardRules.isClaimed: whether someone holds the card right now. A card waiting on you, for an answer in Blocked or a
-- look in Review, keeps its agent.
CREATE FUNCTION binders._is_claimed(p_card binders.cards, p_now timestamptz) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, binders AS $$
    SELECT p_card.holder_kind IS NOT NULL AND p_card.board_column <> 'done'
       AND (p_card.board_column IN ('blocked', 'review') OR p_card.lease_until IS NULL OR p_card.lease_until > p_now)
$$;

-- BoardRules.leaseEnd: when an agent's claim runs out, as a refusal says it. Only work in progress has a lease.
CREATE FUNCTION binders._lease_end(p_card binders.cards) RETURNS timestamptz
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, binders AS $$
    SELECT CASE WHEN p_card.holder_kind = 'agent' AND p_card.board_column = 'in_progress' THEN p_card.lease_until END
$$;

-- Whether `p_actor` is who holds the card (the Swift rules compare names; here the member or the agent).
CREATE FUNCTION binders._holds(p_card binders.cards, p_actor binders.actor) RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, binders AS $$
    SELECT coalesce(p_card.holder_kind = p_actor.kind AND CASE WHEN p_actor.kind = 'agent'
                                                                THEN p_card.holder_agent_id = p_actor.agent_id
                                                                ELSE p_card.holder_member_id = p_actor.member_id END, false)
$$;

-- The card held by `p_actor`.
CREATE FUNCTION binders._held_by(p_card binders.cards, p_actor binders.actor) RETURNS binders.cards
LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog, binders AS $$
DECLARE
    v binders.cards := p_card;
BEGIN
    v.holder_kind := p_actor.kind;
    v.holder_member_id := CASE WHEN p_actor.kind = 'person' THEN p_actor.member_id END;
    v.holder_agent_id := p_actor.agent_id;
    v.holder_name := p_actor.name;
    RETURN v;
END $$;

-- The card held by no one.
CREATE FUNCTION binders._let_go(p_card binders.cards) RETURNS binders.cards
LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog, binders AS $$
DECLARE
    v binders.cards := p_card;
BEGIN
    v.holder_kind := NULL;
    v.holder_member_id := NULL;
    v.holder_agent_id := NULL;
    v.holder_name := NULL;
    v.lease_until := NULL;
    RETURN v;
END $$;

-- BoardError.claimedBy, in its words.
CREATE FUNCTION binders._claimed_by(p_card binders.cards) RETURNS jsonb
LANGUAGE sql STABLE SET search_path = pg_catalog, binders AS $$
    SELECT binders._refusal('claimed_by',
        CASE WHEN binders._lease_end(p_card) IS NULL
             THEN format('%s has this. Pick another card, or ask them to release it.', coalesce(p_card.holder_name, 'Someone'))
             ELSE format('%s has this until %s. Pick another card, or ask them to release it.',
                         coalesce(p_card.holder_name, 'Someone'), to_char(binders._lease_end(p_card), 'FMHH12:MI AM')) END,
        jsonb_build_object('holder', coalesce(p_card.holder_name, 'Someone'), 'until', binders._lease_end(p_card)))
$$;

-- An agent acts only on a card that's free or its own: the refusal when it isn't, or null.
CREATE FUNCTION binders._agent_refusal(p_card binders.cards, p_actor binders.actor) RETURNS jsonb
LANGUAGE sql STABLE SET search_path = pg_catalog, binders AS $$
    SELECT CASE WHEN p_actor.kind = 'agent' AND binders._is_claimed(p_card, now()) AND NOT binders._holds(p_card, p_actor)
                THEN binders._claimed_by(p_card) END
$$;

CREATE FUNCTION binders._finished() RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, binders AS $$
    SELECT binders._refusal('finished', 'This card is done. Move it back to Ready first to work on it again.')
$$;

CREATE FUNCTION binders._not_found() RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, binders AS $$
    SELECT binders._refusal('not_found', 'No card with that id is on a board shared with you.')
$$;

-- The cards `p_card` waits for that aren't Done yet, by title.
CREATE FUNCTION binders._unfinished_waits(p_card uuid) RETURNS jsonb
LANGUAGE sql STABLE SET search_path = pg_catalog, binders AS $$
    SELECT coalesce(jsonb_agg(jsonb_build_object('id', w.id, 'title', w.title, 'column', w.board_column) ORDER BY w.title, w.id), '[]')
    FROM binders.card_dependencies d JOIN binders.cards w ON w.id = d.waits_for_id
    WHERE d.card_id = p_card AND d.deleted_at IS NULL AND w.deleted_at IS NULL AND w.board_column <> 'done'
$$;

-- The new rule: an agent can't take a card until every card it waits for is Done. A person still can.
CREATE FUNCTION binders._waits_refusal(p_card binders.cards, p_actor binders.actor) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = pg_catalog, binders AS $$
DECLARE
    v_waits jsonb;
    v_titles text[];
    v_shown text[];
    v_list text;
BEGIN
    IF p_actor.kind <> 'agent' THEN
        RETURN NULL;
    END IF;
    v_waits := binders._unfinished_waits(p_card.id);
    IF jsonb_array_length(v_waits) = 0 THEN
        RETURN NULL;
    END IF;
    -- In BoardError.waitsFor's words: up to three titles, then how many more.
    v_titles := ARRAY(SELECT '“' || (w ->> 'title') || '”' FROM jsonb_array_elements(v_waits) w);
    v_shown := v_titles[1:3];
    v_list := CASE WHEN cardinality(v_shown) = 1 THEN v_shown[1]
                   ELSE array_to_string(v_shown[1:cardinality(v_shown) - 1], ', ') || ' and ' || v_shown[cardinality(v_shown)] END;
    IF cardinality(v_titles) > 3 THEN
        v_list := v_list || format(' and %s more', cardinality(v_titles) - 3);
    END IF;
    RETURN binders._refusal('waits_for',
        format('This card waits for %s, which %s done yet, so it can''t be taken yet. Pick another card.', v_list,
               CASE WHEN cardinality(v_titles) = 1 THEN 'isn''t' ELSE 'aren''t' END),
        jsonb_build_object('waits_for', v_waits));
END $$;

-- MARK: Reading and writing a card

-- The card, locked for this change, when it's on a board the caller sees; a row of nulls otherwise.
CREATE FUNCTION binders._lock_card(p_card uuid) RETURNS binders.cards
LANGUAGE plpgsql SET search_path = pg_catalog, binders AS $$
DECLARE
    v binders.cards;
BEGIN
    SELECT * INTO v FROM binders.cards WHERE id = p_card AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND OR NOT (v.binder_id = ANY (binders.my_binder_ids())) THEN
        RETURN NULL;
    END IF;
    RETURN v;
END $$;

-- Writes what the rules changed: its column, who has it, the lease, its place and links.
CREATE FUNCTION binders._save(p_card binders.cards) RETURNS void
LANGUAGE sql SET search_path = pg_catalog, binders AS $$
    UPDATE binders.cards SET board_column = p_card.board_column, holder_kind = p_card.holder_kind,
        holder_member_id = p_card.holder_member_id, holder_agent_id = p_card.holder_agent_id, holder_name = p_card.holder_name,
        lease_until = p_card.lease_until, position = p_card.position, links = p_card.links
    WHERE id = p_card.id
$$;

-- A line on the card's timeline, as TaskEvent writes it; the card's updated too. Returns the line.
CREATE FUNCTION binders._log(p_card binders.cards, p_kind text, p_author binders.actor, p_text text,
                             p_from text DEFAULT NULL, p_to text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SET search_path = pg_catalog, binders AS $$
DECLARE
    v_event jsonb;
BEGIN
    INSERT INTO binders.card_events (id, binder_id, card_id, kind, author_kind, author_name, author_member_id, author_agent_id,
                                     written_by, text, from_column, to_column)
    VALUES (gen_random_uuid(), p_card.binder_id, p_card.id, p_kind, p_author.kind, p_author.name,
            CASE WHEN p_author.kind = 'person' THEN p_author.member_id END, p_author.agent_id, binders.me(),
            coalesce(p_text, ''), p_from, p_to)
    RETURNING to_jsonb(card_events.*) INTO v_event;
    UPDATE binders.cards SET updated_at = now() WHERE id = p_card.id;
    RETURN v_event;
END $$;

-- Who writes what Binders itself says on a card: neither you nor an agent.
CREATE FUNCTION binders._binders_actor() RETURNS binders.actor
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, binders AS $$ SELECT ROW('person', NULL, NULL, 'Binders')::binders.actor $$;

-- A change's answer: the card as it is now and the lines it added.
CREATE FUNCTION binders._card_result(p_card uuid, p_events jsonb, p_extra jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE sql STABLE SET search_path = pg_catalog, binders AS $$
    SELECT jsonb_build_object('ok', true, 'card', (SELECT to_jsonb(c) FROM binders.cards c WHERE c.id = p_card),
                              'events', p_events, 'unchanged', jsonb_array_length(p_events) = 0) || p_extra
$$;

-- BoardService.lapseIfQuiet: a card whose agent went quiet is let go before someone else acts on it (BoardRules.expire),
-- with a line by the agent. A card waiting in Blocked or Review, or done, doesn't lapse. Returns the line, or null when
-- nothing lapsed; the caller reads the card again.
CREATE FUNCTION binders._lapse_if_quiet(p_card binders.cards, p_actor binders.actor) RETURNS jsonb
LANGUAGE plpgsql SET search_path = pg_catalog, binders AS $$
DECLARE
    v binders.cards := p_card;
    v_before text := p_card.board_column;
    v_agent binders.actor;
BEGIN
    IF v.holder_kind IS DISTINCT FROM 'agent' OR binders._holds(v, p_actor) OR v.lease_until IS NULL OR v.lease_until > now()
       OR v.board_column IN ('done', 'review', 'blocked') THEN
        RETURN NULL;
    END IF;
    v_agent := ROW('agent', NULL, v.holder_agent_id, v.holder_name)::binders.actor;
    v := binders._let_go(v);
    IF v.board_column = 'in_progress' THEN
        v.board_column := 'ready';
    END IF;
    PERFORM binders._save(v);
    RETURN binders._log(v, 'lapsed', v_agent,
        format('%s went quiet for %s minutes, so the card is free again.', coalesce(v_agent.name, 'The agent'),
               extract(epoch FROM binders._lease())::integer / 60), v_before, v.board_column);
END $$;

-- The card as it is now.
CREATE FUNCTION binders._card(p_card uuid) RETURNS binders.cards
LANGUAGE sql STABLE SET search_path = pg_catalog, binders AS $$ SELECT * FROM binders.cards WHERE id = p_card $$;

-- What a card's timeline waits on you for (BoardRules.waitingAsk): its last question or request for approval, as long
-- as the card hasn't left Blocked since. A row of nulls when nothing waits.
CREATE FUNCTION binders._waiting_ask(p_card uuid) RETURNS binders.card_events
LANGUAGE sql STABLE SET search_path = pg_catalog, binders AS $$
    SELECT l.* FROM (SELECT * FROM binders.card_events WHERE card_id = p_card AND kind IN ('question', 'approval')
                     ORDER BY number DESC LIMIT 1) l
    WHERE NOT EXISTS (SELECT 1 FROM binders.card_events e
                      WHERE e.card_id = p_card AND e.number > l.number AND coalesce(e.to_column, '') NOT IN ('', 'blocked'))
$$;

-- MARK: Actions

-- Taking a card (BoardRules.claim): it moves to In progress if it was waiting, and an agent's claim on work in progress
-- starts its lease. A person can take a card over from anyone; an agent only takes one that's free or its own, and only
-- once every card it waits for is Done.
CREATE FUNCTION binders.claim_card(p_op uuid, p_card uuid, p_agent uuid DEFAULT NULL, p_note text DEFAULT '') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'claim_card', jsonb_build_object('card', p_card, 'agent', p_agent, 'note', p_note));
    v_actor binders.actor;
    v_card binders.cards;
    v_before text;
    v_from text;
    v_refusal jsonb;
    v_events jsonb := '[]';
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    v_actor := binders._acting_as(p_agent);
    v_card := binders._lock_card(p_card);
    IF v_card.id IS NULL THEN
        RETURN binders._op_end(p_op, binders._not_found());
    END IF;
    v_before := v_card.board_column;
    IF v_before = 'done' THEN
        RETURN binders._op_end(p_op, binders._finished());
    END IF;
    v_refusal := coalesce(binders._agent_refusal(v_card, v_actor), binders._waits_refusal(v_card, v_actor));
    IF v_refusal IS NOT NULL THEN
        RETURN binders._op_end(p_op, v_refusal);
    END IF;
    -- Taken over from whoever had it: the timeline says so, for them and for you.
    IF binders._is_claimed(v_card, now()) AND NOT binders._holds(v_card, v_actor) THEN
        v_from := v_card.holder_name;
    END IF;
    v_card := binders._held_by(v_card, v_actor);
    -- A person taking a blocked card over works on it rather than waiting for an answer.
    IF v_before IN ('backlog', 'ready') OR (v_actor.kind = 'person' AND v_before = 'blocked') THEN
        v_card.board_column := 'in_progress';
    END IF;
    v_card.lease_until := CASE WHEN v_actor.kind = 'agent' AND v_card.board_column = 'in_progress' THEN now() + binders._lease() END;
    PERFORM binders._save(v_card);
    v_events := v_events || binders._log(v_card, 'claimed', v_actor,
        CASE WHEN v_from IS NOT NULL THEN format('Took it over from %s.', v_from) ELSE coalesce(p_note, '') END,
        v_before, v_card.board_column);
    RETURN binders._op_end(p_op, binders._card_result(v_card.id, v_events));
END $$;

-- Moving a card (BoardRules.move, after BoardService.lapseIfQuiet). People move anything; agents only cards that are
-- free or theirs, not to Done unless the binder allows it, and not into In progress while it waits for unfinished
-- work. Back to Backlog or Ready lets go of the claim; Review and Done keep who did it but end the lease.
CREATE FUNCTION binders.move_card(p_op uuid, p_card uuid, p_column text, p_agent uuid DEFAULT NULL, p_note text DEFAULT '')
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'move_card', jsonb_build_object('card', p_card, 'column', p_column,
        'agent', p_agent, 'note', p_note));
    v_actor binders.actor;
    v_card binders.cards;
    v_old binders.cards;
    v_before text;
    v_lapse jsonb;
    v_refusal jsonb;
    v_may_finish boolean;
    v_text text;
    v_events jsonb := '[]';
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    IF p_column IS NULL OR p_column NOT IN ('backlog', 'ready', 'in_progress', 'blocked', 'review', 'done') THEN
        RAISE EXCEPTION 'A board has no column %.', coalesce(p_column, 'without a name') USING ERRCODE = '22023';
    END IF;
    v_actor := binders._acting_as(p_agent);
    v_card := binders._lock_card(p_card);
    IF v_card.id IS NULL THEN
        RETURN binders._op_end(p_op, binders._not_found());
    END IF;
    IF v_card.board_column = p_column THEN
        RETURN binders._op_end(p_op, binders._card_result(v_card.id, v_events));
    END IF;
    v_lapse := binders._lapse_if_quiet(v_card, v_actor);
    IF v_lapse IS NOT NULL THEN
        v_events := v_events || v_lapse;
        v_card := binders._card(v_card.id);
    END IF;
    v_before := v_card.board_column;
    IF v_before = p_column THEN
        RETURN binders._op_end(p_op, binders._card_result(v_card.id, v_events));
    END IF;
    SELECT agents_may_finish INTO v_may_finish FROM binders.binders WHERE id = v_card.binder_id;
    IF v_actor.kind = 'agent' THEN
        IF p_column = 'done' AND NOT coalesce(v_may_finish, false) THEN
            RETURN binders._op_end(p_op, binders._refusal('agents_cannot_finish',
                'Agents can''t move cards to Done in this binder. Use complete_task to hand it over for review.'));
        END IF;
        v_refusal := binders._agent_refusal(v_card, v_actor);
        -- Taking it by moving it to In progress is a claim too.
        IF v_refusal IS NULL AND p_column = 'in_progress'
           AND (v_card.holder_kind IS NULL OR NOT binders._is_claimed(v_card, now())) THEN
            v_refusal := binders._waits_refusal(v_card, v_actor);
        END IF;
        IF v_refusal IS NOT NULL THEN
            RETURN binders._op_end(p_op, v_refusal);
        END IF;
    END IF;
    v_old := v_card;
    v_card.board_column := p_column;
    IF p_column IN ('backlog', 'ready') THEN
        v_card := binders._let_go(v_card);
    ELSIF p_column IN ('review', 'done') THEN
        v_card.lease_until := NULL;
    ELSIF p_column = 'in_progress' AND (v_old.holder_kind IS NULL OR NOT binders._is_claimed(v_old, now())) THEN
        -- Starting work means taking it.
        v_card := binders._held_by(v_card, v_actor);
        v_card.lease_until := CASE WHEN v_actor.kind = 'agent' THEN now() + binders._lease() END;
    ELSIF p_column = 'blocked' THEN
        -- Waiting for an answer: an agent's claim holds until then.
        IF v_card.holder_kind = 'agent' THEN
            v_card.lease_until := NULL;
        END IF;
    ELSIF v_actor.kind = 'agent' AND binders._holds(v_old, v_actor) THEN
        v_card.lease_until := now() + binders._lease();
    ELSIF v_actor.kind = 'person' AND v_old.holder_kind = 'agent' THEN
        -- Sent back to the agent that has it: its claim starts over, so the card lapses to Ready if the agent doesn't
        -- pick it up again.
        v_card.lease_until := now() + binders._lease();
    END IF;
    v_card.position := binders._position_now();
    PERFORM binders._save(v_card);
    -- Back from Review to the agent that did it: the timeline tells the agent.
    v_text := CASE WHEN v_actor.kind = 'person' AND v_before = 'review' AND p_column = 'in_progress' AND v_card.holder_kind = 'agent'
                   THEN format('Sent back to %s.', coalesce(v_card.holder_name, 'the agent')) ELSE coalesce(p_note, '') END;
    v_events := v_events || binders._log(v_card, 'moved', v_actor, v_text, v_before, p_column);
    RETURN binders._op_end(p_op, binders._card_result(v_card.id, v_events));
END $$;

-- A progress report, with any links it brings (BoardService.report). Keeps an agent's claim on work in progress alive,
-- unless it's the last word of a run that's ending (`p_renewing` false).
CREATE FUNCTION binders.report(p_op uuid, p_card uuid, p_progress text, p_links jsonb DEFAULT '[]', p_agent uuid DEFAULT NULL,
                               p_renewing boolean DEFAULT true) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'report', jsonb_build_object('card', p_card, 'progress', p_progress,
        'links', p_links, 'agent', p_agent, 'renewing', p_renewing));
    v_actor binders.actor;
    v_card binders.cards;
    v_added text[];
    v_text text;
    v_events jsonb := '[]';
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    v_actor := binders._acting_as(p_agent);
    v_card := binders._lock_card(p_card);
    IF v_card.id IS NULL THEN
        RETURN binders._op_end(p_op, binders._not_found());
    END IF;
    v_added := ARRAY(SELECT btrim(l, E' \t') FROM jsonb_array_elements_text(coalesce(p_links, '[]')) WITH ORDINALITY AS t(l, n)
                     WHERE btrim(l, E' \t') <> '' AND NOT (btrim(l, E' \t') = ANY (v_card.links)) ORDER BY n);
    v_card.links := v_card.links || v_added;
    IF coalesce(p_renewing, true) AND v_actor.kind = 'agent' AND binders._holds(v_card, v_actor) AND v_card.board_column = 'in_progress' THEN
        v_card.lease_until := now() + binders._lease();
    END IF;
    PERFORM binders._save(v_card);
    v_text := btrim(coalesce(p_progress, ''), E' \t\n\r');
    IF cardinality(v_added) > 0 THEN
        v_text := v_text || CASE WHEN v_text = '' THEN '' ELSE E'\n' END
            || array_to_string(ARRAY(SELECT '→ ' || x FROM unnest(v_added) WITH ORDINALITY AS t(x, n) ORDER BY n), E'\n');
    END IF;
    v_events := v_events || binders._log(v_card, 'progress', v_actor, v_text);
    RETURN binders._op_end(p_op, binders._card_result(v_card.id, v_events));
END $$;

-- An agent's word that it's still at it, with nothing new to say (BoardRules.renew): its claim on work in progress is
-- kept alive, and the timeline gets no line for it.
CREATE FUNCTION binders.keep_alive(p_op uuid, p_card uuid, p_agent uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'keep_alive', jsonb_build_object('card', p_card, 'agent', p_agent));
    v_actor binders.actor;
    v_card binders.cards;
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    v_actor := binders._acting_as(p_agent);
    v_card := binders._lock_card(p_card);
    IF v_card.id IS NULL THEN
        RETURN binders._op_end(p_op, binders._not_found());
    END IF;
    IF v_actor.kind = 'agent' AND binders._holds(v_card, v_actor) AND v_card.board_column = 'in_progress' THEN
        v_card.lease_until := now() + binders._lease();
        PERFORM binders._save(v_card);
        RETURN binders._op_end(p_op, binders._card_result(v_card.id, '[]', jsonb_build_object('unchanged', false)));
    END IF;
    RETURN binders._op_end(p_op, binders._card_result(v_card.id, '[]'));
END $$;

-- Asking for help (BoardRules.ask, after BoardService.lapseIfQuiet): the card waits in Blocked until someone answers.
-- An agent's claim holds while it waits; it asks only about a card that's free or its own.
CREATE FUNCTION binders.ask(p_op uuid, p_card uuid, p_question text, p_agent uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'ask', jsonb_build_object('card', p_card, 'question', p_question, 'agent', p_agent));
    v_actor binders.actor;
    v_card binders.cards;
    v_before text;
    v_lapse jsonb;
    v_refusal jsonb;
    v_events jsonb := '[]';
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    v_actor := binders._acting_as(p_agent);
    v_card := binders._lock_card(p_card);
    IF v_card.id IS NULL THEN
        RETURN binders._op_end(p_op, binders._not_found());
    END IF;
    v_lapse := binders._lapse_if_quiet(v_card, v_actor);
    IF v_lapse IS NOT NULL THEN
        v_events := v_events || v_lapse;
        v_card := binders._card(v_card.id);
    END IF;
    v_before := v_card.board_column;
    IF v_before = 'done' THEN
        RETURN binders._op_end(p_op, binders._finished());
    END IF;
    v_refusal := binders._agent_refusal(v_card, v_actor);
    IF v_refusal IS NOT NULL THEN
        RETURN binders._op_end(p_op, v_refusal);
    END IF;
    v_card.board_column := 'blocked';
    IF v_card.holder_kind = 'agent' THEN
        v_card.lease_until := NULL;
    END IF;
    PERFORM binders._save(v_card);
    v_events := v_events || binders._log(v_card, 'question', v_actor, p_question, v_before, 'blocked');
    RETURN binders._op_end(p_op, binders._card_result(v_card.id, v_events));
END $$;

-- A comment (BoardService.comment). From a person on a blocked card it's the answer (BoardRules.answered): the card goes
-- back to work, and the agent that has it gets a fresh lease. From the agent holding work in progress, it keeps the
-- claim alive.
CREATE FUNCTION binders.answer(p_op uuid, p_card uuid, p_text text, p_agent uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'answer', jsonb_build_object('card', p_card, 'text', p_text, 'agent', p_agent));
    v_actor binders.actor;
    v_card binders.cards;
    v_before text;
    v_answered boolean;
    v_events jsonb := '[]';
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    v_actor := binders._acting_as(p_agent);
    v_card := binders._lock_card(p_card);
    IF v_card.id IS NULL THEN
        RETURN binders._op_end(p_op, binders._not_found());
    END IF;
    v_before := v_card.board_column;
    IF v_actor.kind = 'agent' AND binders._holds(v_card, v_actor) AND v_card.board_column = 'in_progress' THEN
        v_card.lease_until := now() + binders._lease();
    END IF;
    IF v_actor.kind = 'person' AND v_card.board_column = 'blocked' THEN
        v_card.board_column := CASE WHEN v_card.holder_kind IS NULL THEN 'ready' ELSE 'in_progress' END;
        IF v_card.holder_kind = 'agent' THEN
            v_card.lease_until := now() + binders._lease();
        END IF;
    END IF;
    PERFORM binders._save(v_card);
    v_answered := v_before = 'blocked' AND v_card.board_column <> 'blocked';
    v_events := v_events || binders._log(v_card, CASE WHEN v_answered THEN 'answer' ELSE 'comment' END, v_actor, p_text,
        CASE WHEN v_answered THEN v_before END, CASE WHEN v_answered THEN v_card.board_column END);
    RETURN binders._op_end(p_op, binders._card_result(v_card.id, v_events));
END $$;

-- An agent asks your approval before it sends, posts, buys or deletes something outside Binders
-- (BoardService.requestApproval): the card waits in Blocked, as for a question, with exactly what it asks on its
-- timeline (`p_text`, AgentApproval.timelineText). Only an agent asks.
CREATE FUNCTION binders.request_approval(p_op uuid, p_card uuid, p_text text, p_agent uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'request_approval', jsonb_build_object('card', p_card, 'text', p_text, 'agent', p_agent));
    v_actor binders.actor;
    v_card binders.cards;
    v_before text;
    v_lapse jsonb;
    v_refusal jsonb;
    v_event jsonb;
    v_events jsonb := '[]';
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    v_actor := binders._acting_as(p_agent);
    IF v_actor.kind <> 'agent' THEN
        RETURN binders._op_end(p_op, binders._refusal('not_an_agent', 'Only an agent asks for the user''s approval.'));
    END IF;
    IF btrim(coalesce(p_text, '')) = '' THEN
        RAISE EXCEPTION 'An approval says exactly what it asks.' USING ERRCODE = '22023';
    END IF;
    v_card := binders._lock_card(p_card);
    IF v_card.id IS NULL THEN
        RETURN binders._op_end(p_op, binders._not_found());
    END IF;
    v_lapse := binders._lapse_if_quiet(v_card, v_actor);
    IF v_lapse IS NOT NULL THEN
        v_events := v_events || v_lapse;
        v_card := binders._card(v_card.id);
    END IF;
    v_before := v_card.board_column;
    IF v_before = 'done' THEN
        RETURN binders._op_end(p_op, binders._finished());
    END IF;
    v_refusal := binders._agent_refusal(v_card, v_actor);
    IF v_refusal IS NOT NULL THEN
        RETURN binders._op_end(p_op, v_refusal);
    END IF;
    v_card.board_column := 'blocked';
    IF v_card.holder_kind = 'agent' THEN
        v_card.lease_until := NULL;
    END IF;
    PERFORM binders._save(v_card);
    v_event := binders._log(v_card, 'approval', v_actor, p_text, v_before, 'blocked');
    v_events := v_events || v_event;
    RETURN binders._op_end(p_op, binders._card_result(v_card.id, v_events, jsonb_build_object('approval', v_event -> 'id')));
END $$;

-- Your decision on what the card waits for your approval on (BoardService.decide): first the receipt, by Binders, with
-- who decided, where, when and exactly what; then your answer, "Approved" or "Declined: <reason>", which sends the card
-- back to work as any answer does. Only a person decides: an agent named (`p_agent`) is refused. `p_approval`, the request's id when the decision came from
-- somewhere that showed it, must still be the one waiting, and a receipt must end with what it waits on.
CREATE FUNCTION binders.decide(p_op uuid, p_card uuid, p_approve boolean, p_reason text DEFAULT '', p_device text DEFAULT '',
                               p_approval uuid DEFAULT NULL, p_receipt text DEFAULT NULL, p_agent uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'decide', jsonb_build_object('card', p_card, 'approve', p_approve,
        'reason', p_reason, 'device', p_device, 'approval', p_approval, 'receipt', p_receipt, 'agent', p_agent));
    v_actor binders.actor;
    v_card binders.cards;
    v_waiting binders.card_events;
    v_reason text := left(btrim(coalesce(p_reason, ''), E' \t\n\r'), 1000);
    v_device text := btrim(coalesce(p_device, ''), E' \t\n\r');
    v_receipt text;
    v_before text;
    v_events jsonb := '[]';
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    v_actor := binders._acting_as(p_agent);
    IF v_actor.kind <> 'person' THEN
        RETURN binders._op_end(p_op, binders._refusal('not_you', 'Only the user decides on an approval.'));
    END IF;
    v_card := binders._lock_card(p_card);
    IF v_card.id IS NULL THEN
        RETURN binders._op_end(p_op, binders._not_found());
    END IF;
    IF v_card.board_column = 'blocked' THEN
        v_waiting := binders._waiting_ask(v_card.id);
    END IF;
    IF v_waiting.id IS NULL OR v_waiting.kind <> 'approval' THEN
        RETURN binders._op_end(p_op, binders._refusal('nothing_waits', 'Nothing on this card waits for your approval now.'));
    END IF;
    IF (p_approval IS NOT NULL AND p_approval <> v_waiting.id)
       OR (p_receipt IS NOT NULL AND right(p_receipt, length(v_waiting.text) + 1) <> E'\n' || v_waiting.text) THEN
        RETURN binders._op_end(p_op, binders._refusal('changed',
            'It asks about something else now. Look at it again before you decide.'));
    END IF;
    v_receipt := coalesce(p_receipt, format('%s %s this on %s, %s%s', v_actor.name,
        CASE WHEN p_approve THEN 'approved' ELSE 'declined' END,
        CASE WHEN v_device = '' THEN 'a device of yours' ELSE v_device END,
        to_char(now(), 'Mon FMDD, YYYY at FMHH12:MI AM'),
        CASE WHEN NOT p_approve AND v_reason <> '' THEN ': ' || regexp_replace(v_reason, '\s*\n\s*', ' ', 'g') ELSE '.' END)
        || E'\n' || v_waiting.text);
    v_events := v_events || binders._log(v_card, 'decision', binders._binders_actor(), v_receipt);
    v_before := v_card.board_column;
    v_card.board_column := CASE WHEN v_card.holder_kind IS NULL THEN 'ready' ELSE 'in_progress' END;
    IF v_card.holder_kind = 'agent' THEN
        v_card.lease_until := now() + binders._lease();
    END IF;
    PERFORM binders._save(v_card);
    v_events := v_events || binders._log(v_card, 'answer', v_actor,
        CASE WHEN p_approve THEN 'Approved' WHEN v_reason = '' THEN 'Declined' ELSE 'Declined: ' || v_reason END,
        v_before, v_card.board_column);
    RETURN binders._op_end(p_op, binders._card_result(v_card.id, v_events, jsonb_build_object('message',
        CASE WHEN p_approve THEN format('Approved. %s can go ahead with exactly that.', v_waiting.author_name)
             ELSE format('Declined. %s hears that it shouldn''t.', v_waiting.author_name) END)));
END $$;

-- Handing work back (BoardRules.release). An agent can only let go of its own card; a person can release anyone's.
CREATE FUNCTION binders.release(p_op uuid, p_card uuid, p_agent uuid DEFAULT NULL, p_note text DEFAULT '') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'release', jsonb_build_object('card', p_card, 'agent', p_agent, 'note', p_note));
    v_actor binders.actor;
    v_card binders.cards;
    v_before text;
    v_events jsonb := '[]';
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    v_actor := binders._acting_as(p_agent);
    v_card := binders._lock_card(p_card);
    IF v_card.id IS NULL THEN
        RETURN binders._op_end(p_op, binders._not_found());
    END IF;
    IF v_actor.kind = 'agent' AND binders._is_claimed(v_card, now()) AND NOT binders._holds(v_card, v_actor) THEN
        RETURN binders._op_end(p_op, binders._refusal('not_yours',
            format('%s has this card, so only they, or a person, can release it.', coalesce(v_card.holder_name, 'Someone')),
            jsonb_build_object('holder', coalesce(v_card.holder_name, 'Someone'))));
    END IF;
    v_before := v_card.board_column;
    v_card := binders._let_go(v_card);
    IF v_before IN ('in_progress', 'blocked') THEN
        v_card.board_column := 'ready';
    END IF;
    PERFORM binders._save(v_card);
    v_events := v_events || binders._log(v_card, 'released', v_actor, p_note, v_before, v_card.board_column);
    RETURN binders._op_end(p_op, binders._card_result(v_card.id, v_events));
END $$;

-- Finishing (BoardRules.complete): a person's card is done; an agent's goes to Review unless the binder lets agents
-- finish. Who did it stays on the card.
CREATE FUNCTION binders.finish(p_op uuid, p_card uuid, p_summary text DEFAULT '', p_agent uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'finish', jsonb_build_object('card', p_card, 'summary', p_summary, 'agent', p_agent));
    v_actor binders.actor;
    v_card binders.cards;
    v_before text;
    v_refusal jsonb;
    v_may_finish boolean;
    v_events jsonb := '[]';
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    v_actor := binders._acting_as(p_agent);
    v_card := binders._lock_card(p_card);
    IF v_card.id IS NULL THEN
        RETURN binders._op_end(p_op, binders._not_found());
    END IF;
    v_refusal := binders._agent_refusal(v_card, v_actor);
    IF v_refusal IS NOT NULL THEN
        RETURN binders._op_end(p_op, v_refusal);
    END IF;
    SELECT agents_may_finish INTO v_may_finish FROM binders.binders WHERE id = v_card.binder_id;
    v_before := v_card.board_column;
    v_card.board_column := CASE WHEN v_actor.kind = 'agent' AND NOT coalesce(v_may_finish, false) THEN 'review' ELSE 'done' END;
    IF v_card.holder_kind IS NULL THEN
        v_card := binders._held_by(v_card, v_actor);
    END IF;
    v_card.lease_until := NULL;
    v_card.position := binders._position_now();
    PERFORM binders._save(v_card);
    v_events := v_events || binders._log(v_card, 'completed', v_actor, p_summary, v_before, v_card.board_column);
    RETURN binders._op_end(p_op, binders._card_result(v_card.id, v_events));
END $$;

-- MARK: Cards

-- A new card (BoardService.create): never straight into Done, with a line saying where it came from. `p_fields` may
-- hold details, column, position, due_at, links, source_kind / source_id / source_title, todo_id, distill_item_id,
-- note_section, note_version_id, external_key, external_url, and waits_for (card ids on the same board).
CREATE FUNCTION binders.create_card(p_op uuid, p_card uuid, p_binder uuid, p_title text, p_fields jsonb DEFAULT '{}',
                                    p_agent uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'create_card', jsonb_build_object('card', p_card, 'binder', p_binder,
        'title', p_title, 'fields', p_fields, 'agent', p_agent));
    v_fields jsonb := coalesce(p_fields, '{}');
    v_actor binders.actor;
    v_card binders.cards;
    v_column text := coalesce(v_fields ->> 'column', 'backlog');
    v_key text;
    v_wait uuid;
    v_refusal jsonb;
    v_events jsonb := '[]';
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    v_actor := binders._acting_as(p_agent);
    PERFORM binders._require_binder(p_binder);
    IF p_card IS NULL OR btrim(coalesce(p_title, '')) = '' THEN
        RAISE EXCEPTION 'A card needs an id and a title.' USING ERRCODE = '22023';
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(v_fields) LOOP
        IF v_key NOT IN ('details', 'column', 'position', 'due_at', 'links', 'source_kind', 'source_id', 'source_title', 'todo_id',
                         'distill_item_id', 'note_section', 'note_version_id', 'external_key', 'external_url', 'waits_for') THEN
            RAISE EXCEPTION 'A new card has no field %.', v_key USING ERRCODE = '22023';
        END IF;
    END LOOP;
    IF v_column NOT IN ('backlog', 'ready', 'in_progress', 'blocked', 'review', 'done') THEN
        RAISE EXCEPTION 'A board has no column %.', v_column USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM binders.cards WHERE id = p_card) THEN
        RETURN binders._op_end(p_op, binders._refusal('exists', 'A card with that id is already on a board.'));
    END IF;
    INSERT INTO binders.cards (id, binder_id, title, details, board_column, position, due_at, links, source_kind, source_id,
                               source_title, todo_id, distill_item_id, note_section, note_version_id, external_key, external_url,
                               created_by_name, created_by_member, created_by_agent)
    VALUES (p_card, p_binder, btrim(p_title), coalesce(v_fields ->> 'details', ''),
            CASE WHEN v_column = 'done' THEN 'backlog' ELSE v_column END,
            coalesce((v_fields ->> 'position')::double precision, binders._position_now()),
            (v_fields ->> 'due_at')::timestamptz,
            coalesce(ARRAY(SELECT jsonb_array_elements_text(v_fields -> 'links')), '{}'),
            v_fields ->> 'source_kind', v_fields ->> 'source_id', v_fields ->> 'source_title',
            (v_fields ->> 'todo_id')::uuid, (v_fields ->> 'distill_item_id')::uuid, v_fields ->> 'note_section',
            (v_fields ->> 'note_version_id')::uuid, v_fields ->> 'external_key', v_fields ->> 'external_url',
            v_actor.name, v_actor.member_id, v_actor.agent_id);
    v_card := binders._card(p_card);
    v_events := v_events || binders._log(v_card, 'created', v_actor,
        CASE WHEN v_fields ->> 'source_title' IS NOT NULL THEN 'From ' || (v_fields ->> 'source_title') ELSE '' END,
        NULL, v_card.board_column);
    FOR v_wait IN SELECT jsonb_array_elements_text(coalesce(v_fields -> 'waits_for', '[]'))::uuid LOOP
        v_refusal := binders._add_wait(v_card, v_wait, v_actor, v_events);
        IF v_refusal ? 'refusal' THEN
            RAISE EXCEPTION '%', v_refusal -> 'refusal' ->> 'message' USING ERRCODE = '22023';
        END IF;
        v_events := v_refusal -> 'events';
    END LOOP;
    RETURN binders._op_end(p_op, binders._card_result(p_card, v_events));
END $$;

-- Changing what a card says (BoardService.edit): its title, details, due date, links, place, or the same card
-- elsewhere. No line on the timeline.
CREATE FUNCTION binders.edit_card(p_op uuid, p_card uuid, p_fields jsonb, p_agent uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'edit_card', jsonb_build_object('card', p_card, 'fields', p_fields, 'agent', p_agent));
    v_fields jsonb := coalesce(p_fields, '{}');
    v_card binders.cards;
    v_key text;
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    PERFORM binders._acting_as(p_agent);
    v_card := binders._lock_card(p_card);
    IF v_card.id IS NULL THEN
        RETURN binders._op_end(p_op, binders._not_found());
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(v_fields) LOOP
        IF v_key NOT IN ('title', 'details', 'due_at', 'links', 'position', 'external_key', 'external_url') THEN
            RAISE EXCEPTION 'A card''s % isn''t changed by an edit.', v_key USING ERRCODE = '22023';
        END IF;
    END LOOP;
    UPDATE binders.cards SET
        title = CASE WHEN btrim(coalesce(v_fields ->> 'title', '')) <> '' THEN v_fields ->> 'title' ELSE title END,
        details = coalesce(v_fields ->> 'details', details),
        due_at = CASE WHEN v_fields ? 'due_at' THEN (v_fields ->> 'due_at')::timestamptz ELSE due_at END,
        links = CASE WHEN v_fields ? 'links' THEN coalesce(ARRAY(SELECT jsonb_array_elements_text(v_fields -> 'links')), '{}') ELSE links END,
        position = coalesce((v_fields ->> 'position')::double precision, position),
        external_key = CASE WHEN v_fields ? 'external_key' THEN v_fields ->> 'external_key' ELSE external_key END,
        external_url = CASE WHEN v_fields ? 'external_url' THEN v_fields ->> 'external_url' ELSE external_url END
    WHERE id = p_card;
    RETURN binders._op_end(p_op, binders._card_result(p_card, '[]', jsonb_build_object('unchanged', false)));
END $$;

-- Who a card is meant for (BoardService.assign): a name, or null for no one in particular. From a person it's an
-- assignment; from an agent, or Binders' own (`p_suggesting`), it's a suggestion, and it never replaces a person's
-- choice: then `assigned` is false.
CREATE FUNCTION binders.assign_card(p_op uuid, p_card uuid, p_name text, p_agent uuid DEFAULT NULL,
                                    p_suggesting boolean DEFAULT false, p_why text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'assign_card', jsonb_build_object('card', p_card, 'name', p_name, 'agent', p_agent,
        'suggesting', p_suggesting, 'why', p_why));
    v_actor binders.actor;
    v_card binders.cards;
    v_name text := nullif(left(btrim(coalesce(p_name, ''), E' \t\n\r'), 80), '');
    v_suggestion boolean;
    v_by_agent boolean;
    v_line text;
    v_events jsonb := '[]';
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    v_actor := binders._acting_as(p_agent);
    v_card := binders._lock_card(p_card);
    IF v_card.id IS NULL THEN
        RETURN binders._op_end(p_op, binders._not_found());
    END IF;
    v_suggestion := v_actor.kind = 'agent' OR coalesce(p_suggesting, false);
    IF v_suggestion AND v_card.meant_for IS NOT NULL AND NOT v_card.meant_for_by_agent THEN
        RETURN binders._op_end(p_op, binders._card_result(p_card, '[]',
            jsonb_build_object('assigned', v_card.meant_for IS NOT DISTINCT FROM v_name)));
    END IF;
    v_by_agent := v_name IS NOT NULL AND v_suggestion;
    IF v_card.meant_for IS NOT DISTINCT FROM v_name AND v_card.meant_for_by_agent = v_by_agent THEN
        RETURN binders._op_end(p_op, binders._card_result(p_card, '[]', jsonb_build_object('assigned', true)));
    END IF;
    UPDATE binders.cards SET meant_for = v_name, meant_for_by_agent = v_by_agent WHERE id = p_card;
    v_line := CASE WHEN v_name IS NULL THEN 'Meant for no one in particular.'
                   WHEN NOT v_by_agent THEN format('Meant for %s.', v_name)
                   WHEN p_why IS NOT NULL THEN format('Suggested for %s: %s', v_name, p_why)
                   ELSE format('Suggested for %s.', v_name) END;
    v_events := v_events || binders._log(binders._card(p_card), 'assigned', v_actor, v_line);
    RETURN binders._op_end(p_op, binders._card_result(p_card, v_events, jsonb_build_object('assigned', true)));
END $$;

-- A person deletes a card; other Macs learn of it from the feed. Its timeline stays, as it's only ever added to.
CREATE FUNCTION binders.delete_card(p_op uuid, p_card uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'delete_card', jsonb_build_object('card', p_card));
    v_card binders.cards;
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    PERFORM binders._person();
    v_card := binders._lock_card(p_card);
    IF v_card.id IS NULL THEN
        RETURN binders._op_end(p_op, binders._not_found());
    END IF;
    UPDATE binders.cards SET deleted_at = now() WHERE id = p_card;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true));
END $$;

-- Makes `p_card` wait for `p_waits_for`, with a line on its timeline. A card never waits for itself, directly or
-- through others, nor for a card on another board. Returns {"events": …} or a refusal.
CREATE FUNCTION binders._add_wait(p_card binders.cards, p_waits_for uuid, p_actor binders.actor, p_events jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path = pg_catalog, binders AS $$
DECLARE
    v_other binders.cards;
BEGIN
    -- One change to a board's waits at a time, so two can't make a loop between them.
    PERFORM pg_advisory_xact_lock(hashtextextended('binders.waits:' || p_card.binder_id::text, 0));
    IF p_waits_for = p_card.id THEN
        RETURN binders._refusal('cycle', 'A card can''t wait for itself.');
    END IF;
    SELECT * INTO v_other FROM binders.cards WHERE id = p_waits_for AND deleted_at IS NULL;
    IF NOT FOUND OR NOT (v_other.binder_id = ANY (binders.my_binder_ids())) THEN
        RETURN binders._not_found();
    END IF;
    IF v_other.binder_id <> p_card.binder_id THEN
        RETURN binders._refusal('other_board', 'A card waits only for cards on the same board.');
    END IF;
    IF EXISTS (WITH RECURSIVE ahead(id) AS (
                   SELECT d.waits_for_id FROM binders.card_dependencies d WHERE d.card_id = p_waits_for AND d.deleted_at IS NULL
                   UNION
                   SELECT d.waits_for_id FROM binders.card_dependencies d JOIN ahead ON d.card_id = ahead.id WHERE d.deleted_at IS NULL)
               SELECT 1 FROM ahead WHERE id = p_card.id) THEN
        RETURN binders._refusal('cycle', format('“%s” already waits for this card, so this card can''t wait for it.', v_other.title));
    END IF;
    IF EXISTS (SELECT 1 FROM binders.card_dependencies WHERE card_id = p_card.id AND waits_for_id = p_waits_for AND deleted_at IS NULL) THEN
        RETURN jsonb_build_object('events', p_events);
    END IF;
    INSERT INTO binders.card_dependencies (id, binder_id, card_id, waits_for_id, created_by)
    VALUES (gen_random_uuid(), p_card.binder_id, p_card.id, p_waits_for, p_actor.member_id)
    ON CONFLICT (card_id, waits_for_id) DO UPDATE SET deleted_at = NULL, created_by = EXCLUDED.created_by;
    RETURN jsonb_build_object('events', p_events || binders._log(p_card, 'edited', p_actor, format('Waits for “%s”.', v_other.title)));
END $$;

-- A card waits for another: an agent can't claim it until that one is Done.
CREATE FUNCTION binders.add_dependency(p_op uuid, p_card uuid, p_waits_for uuid, p_agent uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'add_dependency', jsonb_build_object('card', p_card, 'waits_for', p_waits_for,
        'agent', p_agent));
    v_actor binders.actor;
    v_card binders.cards;
    v_added jsonb;
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    v_actor := binders._acting_as(p_agent);
    v_card := binders._lock_card(p_card);
    IF v_card.id IS NULL THEN
        RETURN binders._op_end(p_op, binders._not_found());
    END IF;
    v_added := binders._add_wait(v_card, p_waits_for, v_actor, '[]');
    IF v_added ? 'refusal' THEN
        RETURN binders._op_end(p_op, v_added);
    END IF;
    RETURN binders._op_end(p_op, binders._card_result(p_card, v_added -> 'events'));
END $$;

-- A card stops waiting for another.
CREATE FUNCTION binders.remove_dependency(p_op uuid, p_card uuid, p_waits_for uuid, p_agent uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'remove_dependency', jsonb_build_object('card', p_card, 'waits_for', p_waits_for,
        'agent', p_agent));
    v_actor binders.actor;
    v_card binders.cards;
    v_title text;
    v_events jsonb := '[]';
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    v_actor := binders._acting_as(p_agent);
    v_card := binders._lock_card(p_card);
    IF v_card.id IS NULL THEN
        RETURN binders._op_end(p_op, binders._not_found());
    END IF;
    UPDATE binders.card_dependencies SET deleted_at = now()
    WHERE card_id = p_card AND waits_for_id = p_waits_for AND deleted_at IS NULL;
    IF FOUND THEN
        SELECT title INTO v_title FROM binders.cards WHERE id = p_waits_for;
        v_events := v_events || binders._log(v_card, 'edited', v_actor, format('No longer waits for “%s”.', coalesce(v_title, 'a card')));
    END IF;
    RETURN binders._op_end(p_op, binders._card_result(p_card, v_events));
END $$;

-- A line that changes nothing on the card: what Binders found in the binder when the card first went to an agent
-- ('context', by Binders, once a card), a note by Binders ('note', written as a comment), the receipt for a wake
-- ('woke', by the woken agent), or an edit ('edited').
CREATE FUNCTION binders.log_card(p_op uuid, p_card uuid, p_kind text, p_text text, p_agent uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'log_card', jsonb_build_object('card', p_card, 'kind', p_kind, 'text', p_text,
        'agent', p_agent));
    v_actor binders.actor;
    v_card binders.cards;
    v_text text := btrim(coalesce(p_text, ''), E' \t\n\r');
    v_events jsonb := '[]';
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    v_actor := binders._acting_as(p_agent);
    IF p_kind NOT IN ('context', 'note', 'woke', 'edited') THEN
        RAISE EXCEPTION 'log_card writes context, note, woke or edited lines, not %.', coalesce(p_kind, 'nothing') USING ERRCODE = '22023';
    END IF;
    IF p_kind = 'woke' AND v_actor.kind <> 'agent' THEN
        RAISE EXCEPTION 'A wake''s receipt is by the agent that was woken.' USING ERRCODE = '22023';
    END IF;
    v_card := binders._lock_card(p_card);
    IF v_card.id IS NULL THEN
        RETURN binders._op_end(p_op, binders._not_found());
    END IF;
    IF v_text = '' OR (p_kind = 'context' AND EXISTS (SELECT 1 FROM binders.card_events WHERE card_id = p_card AND kind = 'context')) THEN
        RETURN binders._op_end(p_op, binders._card_result(p_card, '[]'));
    END IF;
    v_events := v_events || binders._log(v_card, CASE WHEN p_kind = 'note' THEN 'comment' ELSE p_kind END,
        CASE WHEN p_kind IN ('context', 'note') THEN binders._binders_actor() ELSE v_actor END, v_text);
    RETURN binders._op_end(p_op, binders._card_result(p_card, v_events));
END $$;
"""#)
}
