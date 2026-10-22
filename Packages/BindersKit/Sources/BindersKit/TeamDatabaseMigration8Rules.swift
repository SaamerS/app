import Foundation

// Migration 8 of the team database, as SQL: The board's rules, finished. Cards that wait for others, handed over for review
// or finished by an agent that doesn't hold them; a headless agent's Auto, which only its owner turns on; and who decides
// on an approval an agent asked for. Applied by TeamDatabaseSetup in one transaction with the others, as the team's owner
// role, on a database made with migrations 1 to 7 too (an update, in Settings → Team). Never change a migration that has
// shipped: add the next one.

extension TeamSchema {
    static let migration8 = TeamMigration(version: 8, name: "The board's rules, finished: waiting cards, a headless agent's Auto, and who decides on an approval",
                                          sql: migration8Rules + migration8Taking + migration8Deciding)

    // MARK: A headless agent's Auto, and who decides

    private static let migration8Rules = #"""
-- Migration 8: the board's rules, finished.
--
-- Three rules the database didn't have as Binders' own rules (BoardRules) have them: an agent that doesn't hold a card
-- that still waits for others can't hand it over for review or finish it either, as it can't take it; a headless agent
-- (one with a login of its own) takes a card only once its owner has turned its Auto on; and what an agent asks approval
-- for is decided by the agent's owner, or by the person the card is meant for. The shared board cases
-- (Fixtures/team/board-cases.json) run against both.

-- A headless agent's Auto: whether its owner lets it take cards on its own, in the binders shared with its login. Off
-- until its owner turns it on, for headless agents listed before this migration too. Agents on a Mac keep their Auto in
-- their owner's Keychain, decided on the owner's Mac: for them it stays false, and nothing reads it.
ALTER TABLE binders.agents ADD COLUMN auto boolean NOT NULL DEFAULT false;

-- While a headless agent's Auto is off, it can't take a card: the refusal, naming the owner who can turn it on, or null.
-- Agents on a Mac, and people, aren't held here.
CREATE FUNCTION binders._auto_refusal(p_actor binders.actor) RETURNS jsonb
LANGUAGE sql STABLE SET search_path = pg_catalog, binders AS $$
    SELECT CASE WHEN p_actor.kind = 'agent' AND a.login_id IS NOT NULL AND NOT a.auto THEN
        binders._refusal('auto_off',
            format('%s can''t take cards until its owner, %s, turns on its Auto in Binders'' Settings → Team. Until then it can read the board, report, comment and ask.',
                   a.name, coalesce(m.name, 'a person in the team')),
            jsonb_build_object('owner', m.name)) END
    FROM binders.agents a LEFT JOIN binders.members m ON m.id = a.owner_id AND m.deleted_at IS NULL
    WHERE a.id = p_actor.agent_id
$$;

-- Who decides on what an agent asked approval for (BoardRules.deciders), as members: the asking agent's owner, and the
-- person the card is meant for (or the owner of the agent it's meant for), unless an agent or Binders only suggested who
-- it's for. People in the team only, the owner first: [{id, name, owner}].
CREATE FUNCTION binders._deciders(p_card binders.cards, p_asked binders.card_events) RETURNS jsonb
LANGUAGE sql STABLE SET search_path = pg_catalog, binders AS $$
    SELECT coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'name', d.name, 'owner', d.rank = 1) ORDER BY d.rank, d.name, d.id), '[]')
    FROM (SELECT DISTINCT ON (m.id) m.id, m.name, w.rank
          FROM (SELECT a.owner_id AS member, 1 AS rank FROM binders.agents a WHERE a.id = p_asked.author_agent_id
                UNION ALL
                SELECT p.id, 2 FROM binders.members p
                WHERE NOT p_card.meant_for_by_agent AND p.kind = 'person' AND lower(btrim(p.name)) = lower(btrim(p_card.meant_for))
                UNION ALL
                SELECT a.owner_id, 2 FROM binders.agents a
                WHERE NOT p_card.meant_for_by_agent AND a.deleted_at IS NULL AND lower(btrim(a.name)) = lower(btrim(p_card.meant_for))) w
          JOIN binders.members m ON m.id = w.member
          WHERE m.deleted_at IS NULL AND m.kind = 'person'
          ORDER BY m.id, w.rank) d
$$;

-- Whether this member decides on it.
CREATE FUNCTION binders._decides(p_card binders.cards, p_asked binders.card_events, p_member uuid) RETURNS boolean
LANGUAGE sql STABLE SET search_path = pg_catalog, binders AS $$
    SELECT EXISTS (SELECT 1 FROM jsonb_array_elements(binders._deciders(p_card, p_asked)) d WHERE (d ->> 'id')::uuid = p_member)
$$;

-- Someone else decides on it: the refusal, in BoardRules.onlyDeciders' words, with who does. A card meant for the agent's
-- owner has one decider, the owner.
CREATE FUNCTION binders._not_deciding(p_deciders jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = pg_catalog, binders AS $$
DECLARE
    v_owner text := (SELECT d ->> 'name' FROM jsonb_array_elements(p_deciders) d WHERE (d ->> 'owner')::boolean LIMIT 1);
    v_meant text := (SELECT d ->> 'name' FROM jsonb_array_elements(p_deciders) d WHERE NOT (d ->> 'owner')::boolean LIMIT 1);
BEGIN
    RETURN binders._refusal('not_yours_to_decide',
        CASE WHEN v_owner IS NOT NULL AND v_meant IS NOT NULL
                 THEN format('Only %s, whose agent is asking, or %s, who the card is for, can decide on this.', v_owner, v_meant)
             WHEN v_owner IS NOT NULL THEN format('Only %s can decide on this: it''s their agent asking.', v_owner)
             WHEN v_meant IS NOT NULL THEN format('Only %s can decide on this: the card is for them.', v_meant)
             ELSE 'No one in the team can decide on this now: the agent''s owner isn''t in the team any more. Choose who the card is for, and they can.' END,
        jsonb_build_object('owner', v_owner, 'meant_for', v_meant, 'deciders', p_deciders));
END $$;

-- A headless agent's owner turns its Auto on or off: on, it takes cards on its own in the binders shared with its login;
-- off, it can't take one. Only its owner, a person: never the agent's own login, and never a teammate. An agent on a Mac
-- keeps its Auto on its owner's Mac, so this is refused for one.
CREATE FUNCTION binders.set_agent_auto(p_op uuid, p_agent uuid, p_on boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'set_agent_auto', jsonb_build_object('agent', p_agent, 'on', p_on));
    v_person binders.actor;
    v_agent binders.agents;
    v_owner text;
    v_row jsonb;
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    v_person := binders._person();
    SELECT * INTO v_agent FROM binders.agents WHERE id = p_agent AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RETURN binders._op_end(p_op, binders._refusal('not_found', 'No agent with that id is listed in the team.'));
    END IF;
    IF v_agent.login_id IS NULL THEN
        RETURN binders._op_end(p_op, binders._refusal('on_a_mac',
            format('%s runs on its owner''s Mac, which keeps its Auto.', v_agent.name)));
    END IF;
    IF v_agent.owner_id <> v_person.member_id THEN
        SELECT name INTO v_owner FROM binders.members WHERE id = v_agent.owner_id AND deleted_at IS NULL;
        RETURN binders._op_end(p_op, binders._refusal('not_owner',
            format('Only %s, its owner, turns %s''s Auto on or off.', coalesce(v_owner, 'its owner'), v_agent.name),
            jsonb_build_object('owner', v_owner)));
    END IF;
    UPDATE binders.agents SET auto = coalesce(p_on, false) WHERE id = p_agent;
    SELECT to_jsonb(a) INTO v_row FROM binders.agents a WHERE a.id = p_agent;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true, 'agent', v_row, 'unchanged', v_agent.auto = coalesce(p_on, false)));
END $$;

-- An admin gives a headless agent to another person in the team (as in migration 5): its owner, who approves its Auto.
-- Its Auto goes off when its owner changes, for the new owner to turn on.
CREATE OR REPLACE FUNCTION binders.hand_agent_to(p_op uuid, p_agent uuid, p_owner uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'hand_agent_to', jsonb_build_object('agent', p_agent, 'owner', p_owner));
    v_row jsonb;
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    PERFORM binders._admin();
    IF NOT EXISTS (SELECT 1 FROM binders.members WHERE id = p_owner AND kind = 'person' AND deleted_at IS NULL) THEN
        RETURN binders._op_end(p_op, binders._refusal('not_found', 'No person with that id is in the team.'));
    END IF;
    UPDATE binders.agents SET auto = CASE WHEN owner_id = p_owner THEN auto ELSE false END, owner_id = p_owner
    WHERE id = p_agent AND login_id IS NOT NULL AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RETURN binders._op_end(p_op, binders._refusal('not_found', 'No headless agent with that id is in the team.'));
    END IF;
    SELECT to_jsonb(a) INTO v_row FROM binders.agents a WHERE a.id = p_agent;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true, 'agent', v_row));
END $$;

"""#

    // MARK: Taking a card: claim, move and finish

    private static let migration8Taking = #"""
-- Taking a card (BoardRules.claim), as in migration 2, and a headless agent only while its Auto is on.
CREATE OR REPLACE FUNCTION binders.claim_card(p_op uuid, p_card uuid, p_agent uuid DEFAULT NULL, p_note text DEFAULT '') RETURNS jsonb
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
    v_refusal := binders._auto_refusal(v_actor);
    IF v_refusal IS NOT NULL THEN
        RETURN binders._op_end(p_op, v_refusal);
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

-- Moving a card (BoardRules.move, after BoardService.lapseIfQuiet), as in migration 2, with BoardRules' wait rule: an
-- agent that doesn't hold a card that still waits for others can't move it into In progress, Review or Done (it would
-- take it, or finish it). A headless agent whose Auto is off can't take one by moving it into In progress.
CREATE OR REPLACE FUNCTION binders.move_card(p_op uuid, p_card uuid, p_column text, p_agent uuid DEFAULT NULL, p_note text DEFAULT '')
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
            v_refusal := binders._auto_refusal(v_actor);
        END IF;
        -- And it hands over or finishes only a waiting card it holds.
        IF v_refusal IS NULL AND p_column IN ('in_progress', 'review', 'done')
           AND NOT (binders._is_claimed(v_card, now()) AND binders._holds(v_card, v_actor)) THEN
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

-- Finishing (BoardRules.complete), as in migration 2, with BoardRules' wait rule: an agent that doesn't hold a card that
-- still waits for others can't finish it either. A headless agent whose Auto is off finishes only a card it holds.
CREATE OR REPLACE FUNCTION binders.finish(p_op uuid, p_card uuid, p_summary text DEFAULT '', p_agent uuid DEFAULT NULL) RETURNS jsonb
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
    IF v_refusal IS NULL AND v_actor.kind = 'agent' AND NOT (binders._is_claimed(v_card, now()) AND binders._holds(v_card, v_actor)) THEN
        v_refusal := coalesce(CASE WHEN NOT binders._holds(v_card, v_actor) THEN binders._auto_refusal(v_actor) END,
                              binders._waits_refusal(v_card, v_actor));
    END IF;
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

"""#

    // MARK: Approvals: deciding, and answering

    private static let migration8Deciding = #"""
-- A comment (BoardService.comment), as in migration 2; a person's answer to a card that waits for an approval sends it
-- back to work only from who decides on it (BoardRules.deciders): anyone else's words are a comment, and the card keeps
-- waiting for them.
CREATE OR REPLACE FUNCTION binders.answer(p_op uuid, p_card uuid, p_text text, p_agent uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'answer', jsonb_build_object('card', p_card, 'text', p_text, 'agent', p_agent));
    v_actor binders.actor;
    v_card binders.cards;
    v_waiting binders.card_events;
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
        v_waiting := binders._waiting_ask(v_card.id);
    END IF;
    IF v_actor.kind = 'person' AND v_card.board_column = 'blocked'
       AND (v_waiting.id IS NULL OR v_waiting.kind <> 'approval' OR binders._decides(v_card, v_waiting, v_actor.member_id)) THEN
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

-- A decision on what the card waits for approval on (BoardService.decide), as in migration 2, by who decides on it
-- (BoardRules.deciders): the asking agent's owner, or the person the card is meant for. Anyone else is refused, with who
-- does.
CREATE OR REPLACE FUNCTION binders.decide(p_op uuid, p_card uuid, p_approve boolean, p_reason text DEFAULT '', p_device text DEFAULT '',
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
    IF NOT binders._decides(v_card, v_waiting, v_actor.member_id) THEN
        RETURN binders._op_end(p_op, binders._not_deciding(binders._deciders(v_card, v_waiting)));
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
"""#
}
