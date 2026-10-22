import Foundation

// Migration 5 of the team database, as SQL: Teams on the boards. Who an agent sends cards to and who was seen when,
// Distill's part of a card, and the board's rules that were each Mac's own until now: moving a card to another board,
// bringing a card onto a shared board, placing Distill's work items (agents only where the binder lets them), ticking a
// card's to-do, and pruning the feed and the operations. Applied by TeamDatabaseSetup in one transaction with the others,
// as the team's owner role. Never change a migration that has shipped: add the next one.

extension TeamSchema {
    static let migration5 = TeamMigration(version: 5, name: "Teams on the boards: who sends cards where, who was seen when, Distill's part of a card, moving and bringing cards, placing work items, a card's to-do, and pruning", sql: migration5Team + migration5Cards + migration5Placing)

    // MARK: Columns, agents and members

    private static let migration5Team = #"""
-- Migration 5: teams on the boards.
--
-- Columns the team's Macs needed (who an agent sends cards to, when a member's Mac was last seen and how far it read,
-- Distill's part of a card, how far the feed was pruned), and the board's rules that each Mac kept for itself until
-- now: moving a card to another board, bringing a card of yours onto a shared board, placing Distill's work items (an
-- agent only where the binder lets it), a card's to-do ticked when it's done, and pruning what grows.

-- Who the agent sends cards to, as its owner says ("Anthropic"): what a teammate is told before giving it a card.
ALTER TABLE binders.agents ADD COLUMN sends_to text NOT NULL DEFAULT '';
-- When this member's Mac last said it's around, and the feed's number it had applied then: pruning keeps what it needs.
ALTER TABLE binders.members ADD COLUMN seen_at timestamptz;
ALTER TABLE binders.members ADD COLUMN seen_seq bigint;
-- Distill's part of a card the whole team shares: the note, the distill and item, the section, its hash, the version
-- read, whether it asked an agent to distill, when its brief was brought up to date, when it was closed. Each Mac keeps
-- its own notes about it (what it noticed changed) to itself.
ALTER TABLE binders.cards ADD COLUMN distilled jsonb;
-- The feed's last number pruned: a Mac that read less than this reads its binders whole again.
ALTER TABLE binders.team_settings ADD COLUMN changes_pruned_through bigint NOT NULL DEFAULT 0;

-- MARK: Agents and members

-- A person lists one of their agents for the team, or changes what the team sees of it (as in migration 1, with who it
-- sends cards to). Only its owner can. Never how it runs: there's no field for that.
CREATE OR REPLACE FUNCTION binders.put_agent(p_op uuid, p_agent uuid, p_fields jsonb) RETURNS jsonb
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
        IF v_key NOT IN ('name', 'kind', 'purpose', 'binder_ids', 'takes_team_cards', 'status', 'online_at', 'running_card_id',
                         'sends_to') THEN
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
        sends_to = left(btrim(coalesce(p_fields ->> 'sends_to', sends_to)), 120),
        deleted_at = NULL
    WHERE id = p_agent;
    SELECT to_jsonb(a) INTO v_row FROM binders.agents a WHERE a.id = p_agent;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true, 'agent', v_row));
END $$;

-- This member's Mac is around: when, and the feed's number it has applied (pruning keeps the changes after it), with
-- its agents online now. The same every time, so it isn't kept as an operation.
CREATE FUNCTION binders.seen(p_op uuid, p_seq bigint DEFAULT NULL, p_agents uuid[] DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_me uuid := binders._caller();
BEGIN
    UPDATE binders.members SET seen_at = now(),
        seen_seq = CASE WHEN p_seq IS NULL OR p_seq < 0 THEN seen_seq ELSE greatest(coalesce(seen_seq, 0), p_seq) END
    WHERE id = v_me;
    UPDATE binders.agents SET online_at = now()
    WHERE id = ANY (coalesce(p_agents, '{}')) AND deleted_at IS NULL AND (owner_id = v_me OR login_id = v_me);
    RETURN jsonb_build_object('ok', true);
END $$;

-- An admin gives a headless agent (an agent with a login of its own) to another person in the team: its owner, who
-- approves its Auto.
CREATE FUNCTION binders.hand_agent_to(p_op uuid, p_agent uuid, p_owner uuid) RETURNS jsonb
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
    UPDATE binders.agents SET owner_id = p_owner WHERE id = p_agent AND login_id IS NOT NULL AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RETURN binders._op_end(p_op, binders._refusal('not_found', 'No headless agent with that id is in the team.'));
    END IF;
    SELECT to_jsonb(a) INTO v_row FROM binders.agents a WHERE a.id = p_agent;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true, 'agent', v_row));
END $$;

"""#

    // MARK: Moving and bringing cards

    private static let migration5Cards = #"""
-- MARK: Moving a card to another board

-- A card moves to another binder's board (BoardService.moveBinder): not while someone holds it, and not once it's done.
-- The caller sees both binders. What it waited for on the old board, and what waited for it there, goes, with a line on
-- each card (a card waits only for cards on its own board). A suggestion of who it's for goes with it only when
-- `p_keep_suggestion` says the agent takes the new board's cards (the Mac knows). Its timeline goes with it.
CREATE FUNCTION binders.move_card_to_binder(p_op uuid, p_card uuid, p_binder uuid, p_keep_suggestion boolean DEFAULT false,
                                            p_agent uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'move_card_to_binder', jsonb_build_object('card', p_card, 'binder', p_binder,
        'keep_suggestion', p_keep_suggestion, 'agent', p_agent));
    v_actor binders.actor;
    v_card binders.cards;
    v_other binders.cards;
    v_from text;
    v_to text;
    v_dep record;
    v_dropped text;
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
    PERFORM binders._require_binder(p_binder);
    SELECT name INTO v_to FROM binders.binders WHERE id = p_binder AND deleted_at IS NULL;
    IF v_to IS NULL THEN
        RETURN binders._op_end(p_op, binders._refusal('not_found', 'No binder with that id is shared with you.'));
    END IF;
    IF v_card.binder_id = p_binder THEN
        RETURN binders._op_end(p_op, binders._card_result(v_card.id, v_events));
    END IF;
    SELECT name INTO v_from FROM binders.binders WHERE id = v_card.binder_id;
    IF binders._is_claimed(v_card, now()) THEN
        RETURN binders._op_end(p_op, binders._refusal('held',
            format('Someone is working on it, so it stays on the %s board until they let it go.', coalesce(v_from, 'its'))));
    END IF;
    IF v_card.board_column = 'done' THEN
        RETURN binders._op_end(p_op, binders._refusal('done', 'It''s done, so it stays where it was finished.'));
    END IF;
    -- One change to a board's waits at a time, as _add_wait takes them.
    PERFORM pg_advisory_xact_lock(hashtextextended('binders.waits:' || v_card.binder_id::text, 0));
    FOR v_dep IN SELECT d.id, d.card_id, d.waits_for_id FROM binders.card_dependencies d
                 WHERE (d.card_id = p_card OR d.waits_for_id = p_card) AND d.deleted_at IS NULL ORDER BY d.created_at, d.id LOOP
        UPDATE binders.card_dependencies SET deleted_at = now() WHERE id = v_dep.id;
        IF v_dep.card_id = p_card THEN
            SELECT * INTO v_other FROM binders.cards WHERE id = v_dep.waits_for_id;
            v_events := v_events || binders._log(v_card, 'edited', v_actor,
                format('No longer waits for “%s”: it moved to the %s board.', coalesce(v_other.title, 'a card'), v_to));
        ELSE
            SELECT * INTO v_other FROM binders.cards WHERE id = v_dep.card_id;
            IF v_other.id IS NOT NULL THEN
                PERFORM binders._log(v_other, 'edited', v_actor,
                    format('No longer waits for “%s”: it moved to the %s board.', v_card.title, v_to));
            END IF;
        END IF;
    END LOOP;
    IF v_card.meant_for_by_agent AND NOT coalesce(p_keep_suggestion, false) THEN
        v_dropped := v_card.meant_for;
    END IF;
    UPDATE binders.cards SET binder_id = p_binder,
        meant_for = CASE WHEN v_dropped IS NOT NULL THEN NULL ELSE meant_for END,
        meant_for_by_agent = CASE WHEN v_dropped IS NOT NULL THEN false ELSE meant_for_by_agent END,
        position = binders._position_now()
    WHERE id = p_card;
    -- Its timeline belongs to the card: it's read by the members of the binder it's in now.
    UPDATE binders.card_events SET binder_id = p_binder WHERE card_id = p_card;
    v_card := binders._card(p_card);
    v_events := v_events || binders._log(v_card, 'edited', v_actor,
        format('Moved from the %s board to the %s board.', coalesce(v_from, 'old'), v_to));
    IF v_dropped IS NOT NULL THEN
        v_events := v_events || binders._log(v_card, 'assigned', binders._binders_actor(),
            format('Meant for no one in particular: %s doesn''t take the %s board''s cards.', v_dropped, v_to));
    END IF;
    RETURN binders._op_end(p_op, binders._card_result(p_card, v_events));
END $$;

-- MARK: Bringing a card onto a shared board

-- A person brings one of their own cards onto a board shared through the team database, as it is: its column (Done
-- included), who has it (them, or one of their agents, or no one), the lease an agent's claim has left, who it's meant
-- for, when it's due, its links, where it came from, its to-do, Distill's part, who made it and when. One line says so.
-- A card already on a board is refused (`exists`): bringing a binder's board in again makes nothing twice.
CREATE FUNCTION binders.bring_card(p_op uuid, p_card uuid, p_binder uuid, p_title text, p_fields jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'bring_card', jsonb_build_object('card', p_card, 'binder', p_binder, 'title', p_title,
        'fields', p_fields));
    v_fields jsonb := coalesce(p_fields, '{}');
    v_person binders.actor;
    v_column text := coalesce(v_fields ->> 'column', 'backlog');
    v_holder text := nullif(btrim(coalesce(v_fields ->> 'holder', '')), '');
    v_agent binders.agents;
    v_maker binders.agents;
    v_card binders.cards;
    v_key text;
    v_events jsonb := '[]';
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    v_person := binders._person();
    PERFORM binders._require_binder(p_binder);
    IF p_card IS NULL OR btrim(coalesce(p_title, '')) = '' THEN
        RAISE EXCEPTION 'A card needs an id and a title.' USING ERRCODE = '22023';
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(v_fields) LOOP
        IF v_key NOT IN ('details', 'column', 'position', 'holder', 'lease_until', 'meant_for', 'meant_for_by_agent', 'due_at', 'links',
                         'source_kind', 'source_id', 'source_title', 'todo_id', 'external_key', 'external_url', 'distilled',
                         'created_by_name', 'created_by_agent', 'created_at') THEN
            RAISE EXCEPTION 'A card brought in has no field %.', v_key USING ERRCODE = '22023';
        END IF;
    END LOOP;
    IF v_column NOT IN ('backlog', 'ready', 'in_progress', 'blocked', 'review', 'done') THEN
        RAISE EXCEPTION 'A board has no column %.', v_column USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM binders.cards WHERE id = p_card) THEN
        RETURN binders._op_end(p_op, binders._refusal('exists', 'A card with that id is already on a board.'));
    END IF;
    -- Who made it, when that was one of this person's agents.
    IF v_fields ? 'created_by_agent' THEN
        SELECT * INTO v_maker FROM binders.agents
        WHERE id = (v_fields ->> 'created_by_agent')::uuid AND owner_id = v_person.member_id AND deleted_at IS NULL;
    END IF;
    INSERT INTO binders.cards (id, binder_id, title, details, board_column, position, due_at, links, source_kind, source_id,
                               source_title, todo_id, external_key, external_url, distilled, meant_for, meant_for_by_agent,
                               created_by_name, created_by_member, created_by_agent, created_at)
    VALUES (p_card, p_binder, btrim(p_title), coalesce(v_fields ->> 'details', ''), v_column,
            coalesce((v_fields ->> 'position')::double precision, binders._position_now()),
            (v_fields ->> 'due_at')::timestamptz,
            coalesce(ARRAY(SELECT jsonb_array_elements_text(v_fields -> 'links')), '{}'),
            v_fields ->> 'source_kind', v_fields ->> 'source_id', v_fields ->> 'source_title',
            (v_fields ->> 'todo_id')::uuid, v_fields ->> 'external_key', v_fields ->> 'external_url',
            CASE WHEN jsonb_typeof(v_fields -> 'distilled') = 'object' THEN v_fields -> 'distilled' END,
            nullif(left(btrim(coalesce(v_fields ->> 'meant_for', ''), E' \t\n\r'), 80), ''),
            coalesce((v_fields ->> 'meant_for_by_agent')::boolean, false) AND nullif(btrim(coalesce(v_fields ->> 'meant_for', '')), '') IS NOT NULL,
            CASE WHEN v_maker.id IS NOT NULL THEN v_maker.name
                 ELSE coalesce(nullif(btrim(coalesce(v_fields ->> 'created_by_name', '')), ''), v_person.name) END,
            v_person.member_id, v_maker.id,
            coalesce((v_fields ->> 'created_at')::timestamptz, now()));
    -- Who has it: the person bringing it, or one of their agents. An agent's claim on work in progress keeps what's left
    -- of its lease, never more than a fresh one.
    IF v_holder = 'you' AND v_column <> 'backlog' AND v_column <> 'ready' THEN
        UPDATE binders.cards SET holder_kind = 'person', holder_member_id = v_person.member_id, holder_name = v_person.name
        WHERE id = p_card;
    ELSIF v_holder IS NOT NULL AND v_holder <> 'you' AND v_column <> 'backlog' AND v_column <> 'ready' THEN
        SELECT * INTO v_agent FROM binders.agents
        WHERE id = v_holder::uuid AND owner_id = v_person.member_id AND deleted_at IS NULL;
        IF v_agent.id IS NOT NULL THEN
            UPDATE binders.cards SET holder_kind = 'agent', holder_agent_id = v_agent.id, holder_name = v_agent.name,
                lease_until = CASE WHEN v_column = 'in_progress'
                                   THEN least(coalesce((v_fields ->> 'lease_until')::timestamptz, now() + binders._lease()),
                                              now() + binders._lease()) END
            WHERE id = p_card;
        END IF;
    END IF;
    v_card := binders._card(p_card);
    v_events := v_events || binders._log(v_card, 'created', v_person,
        format('Brought onto the team''s board by %s.', v_person.name), NULL, v_card.board_column);
    RETURN binders._op_end(p_op, binders._card_result(p_card, v_events));
END $$;

-- Distill's part of a card the whole team shares (`distilled`), as its Mac has it now: its brief brought up to date,
-- closed as its section went. No line: the change that did it writes its own.
CREATE FUNCTION binders.set_card_distilled(p_op uuid, p_card uuid, p_distilled jsonb, p_agent uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'set_card_distilled', jsonb_build_object('card', p_card, 'distilled', p_distilled,
        'agent', p_agent));
    v_card binders.cards;
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    PERFORM binders._acting_as(p_agent);
    v_card := binders._lock_card(p_card);
    IF v_card.id IS NULL THEN
        RETURN binders._op_end(p_op, binders._not_found());
    END IF;
    IF p_distilled IS NOT NULL AND jsonb_typeof(p_distilled) <> 'object' THEN
        RAISE EXCEPTION 'Distill''s part of a card is an object.' USING ERRCODE = '22023';
    END IF;
    UPDATE binders.cards SET distilled = p_distilled WHERE id = p_card;
    RETURN binders._op_end(p_op, binders._card_result(p_card, '[]', jsonb_build_object('unchanged', false)));
END $$;

"""#

    // MARK: Placing work items, to-dos and pruning

    private static let migration5Placing = #"""
-- MARK: Placing Distill's work items

-- Place on Board, in one transaction (DistillService.place): every card is made first, then what each waits for (a wait
-- that would make a circle, or is on another board, is left out with a line saying so), then who each is meant for. A
-- person places in Ready or Backlog, meant for whoever was picked, by them. An agent places only when the binder's
-- Agents may place work items is on, and then as Place on Board does: in Ready, each meant for whoever it picked (an
-- assignment, written by Binders and saying who placed it, so agents take them in order as their waits allow).
-- `p_items`: [{card, title, details, position, note, note_title, item, section, distilled, waits_for: [card ids],
-- meant_for}], in order; a wait may name a card placed before.
CREATE FUNCTION binders.place_work_items(p_op uuid, p_binder uuid, p_items jsonb, p_column text DEFAULT 'ready',
                                         p_agent uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'place_work_items', jsonb_build_object('binder', p_binder, 'items', p_items,
        'column', p_column, 'agent', p_agent));
    v_actor binders.actor;
    v_column text := coalesce(p_column, 'ready');
    v_may_place boolean;
    v_item jsonb;
    v_id uuid;
    v_card binders.cards;
    v_wait text;
    v_added jsonb;
    v_name text;
    v_ids uuid[] := '{}';
    v_events jsonb := '[]';
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    v_actor := binders._acting_as(p_agent);
    PERFORM binders._require_binder(p_binder);
    IF jsonb_typeof(coalesce(p_items, 'null'::jsonb)) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'Placing needs at least one work item.' USING ERRCODE = '22023';
    END IF;
    IF v_column NOT IN ('backlog', 'ready') THEN
        RAISE EXCEPTION 'Work items go to Ready or Backlog, not %.', v_column USING ERRCODE = '22023';
    END IF;
    IF v_actor.kind = 'agent' THEN
        SELECT agents_may_place INTO v_may_place FROM binders.binders WHERE id = p_binder;
        IF NOT coalesce(v_may_place, false) THEN
            RETURN binders._op_end(p_op, binders._refusal('agents_may_not_place',
                'This binder doesn''t let agents place work items, so they wait as a proposal for a person to review and place.'));
        END IF;
        v_column := 'ready';
    END IF;
    -- Every item checked before anything is made, so a refusal leaves nothing behind.
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        v_id := (v_item ->> 'card')::uuid;
        IF v_id IS NULL OR btrim(coalesce(v_item ->> 'title', '')) = '' THEN
            RAISE EXCEPTION 'Each work item needs a card id and a title.' USING ERRCODE = '22023';
        END IF;
        IF v_id = ANY (v_ids) OR EXISTS (SELECT 1 FROM binders.cards WHERE id = v_id) THEN
            RETURN binders._op_end(p_op, binders._refusal('exists', 'A card with that id is already on a board.'));
        END IF;
        v_ids := v_ids || v_id;
    END LOOP;
    -- The cards.
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        v_id := (v_item ->> 'card')::uuid;
        INSERT INTO binders.cards (id, binder_id, title, details, board_column, position, source_kind, source_id, source_title,
                                   distill_item_id, note_section, distilled, created_by_name, created_by_member, created_by_agent)
        VALUES (v_id, p_binder, btrim(v_item ->> 'title'), coalesce(v_item ->> 'details', ''), v_column,
                coalesce((v_item ->> 'position')::double precision, binders._position_now()),
                CASE WHEN v_item ? 'note' THEN 'note' END, v_item ->> 'note', v_item ->> 'note_title',
                (v_item ->> 'item')::uuid, v_item ->> 'section',
                CASE WHEN jsonb_typeof(v_item -> 'distilled') = 'object' THEN v_item -> 'distilled' END,
                v_actor.name, v_actor.member_id, v_actor.agent_id);
        v_card := binders._card(v_id);
        v_events := v_events || binders._log(v_card, 'created', v_actor,
            CASE WHEN v_item ->> 'note_title' IS NOT NULL THEN 'From ' || (v_item ->> 'note_title') ELSE '' END, NULL, v_column);
    END LOOP;
    -- What each waits for.
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        v_card := binders._card((v_item ->> 'card')::uuid);
        FOR v_wait IN SELECT jsonb_array_elements_text(coalesce(v_item -> 'waits_for', '[]')) LOOP
            v_added := binders._add_wait(v_card, v_wait::uuid, v_actor, '[]');
            IF v_added ? 'refusal' THEN
                v_events := v_events || binders._log(v_card, 'comment', binders._binders_actor(),
                    format('A wait was left out: %s', v_added -> 'refusal' ->> 'message'));
            ELSE
                v_events := v_events || (v_added -> 'events');
            END IF;
        END LOOP;
    END LOOP;
    -- Who each is meant for.
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        v_name := nullif(left(btrim(coalesce(v_item ->> 'meant_for', ''), E' \t\n\r'), 80), '');
        CONTINUE WHEN v_name IS NULL;
        v_id := (v_item ->> 'card')::uuid;
        UPDATE binders.cards SET meant_for = v_name, meant_for_by_agent = false WHERE id = v_id;
        v_card := binders._card(v_id);
        IF v_actor.kind = 'agent' THEN
            v_events := v_events || binders._log(v_card, 'assigned', binders._binders_actor(),
                format('Meant for %s: placed by %s, which this binder lets place work items.', v_name, v_actor.name));
        ELSE
            v_events := v_events || binders._log(v_card, 'assigned', v_actor, format('Meant for %s.', v_name));
        END IF;
    END LOOP;
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true, 'unchanged', false, 'events', v_events,
        'cards', (SELECT coalesce(jsonb_agg(to_jsonb(c) ORDER BY array_position(v_ids, c.id)), '[]')
                  FROM binders.cards c WHERE c.id = ANY (v_ids))));
END $$;

-- MARK: A card's to-do

-- A card reaching Done ticks the to-do it was made from (`todo_id`), and leaving Done opens it again: on every Mac, as
-- each one's own board did. A to-do dismissed stays dismissed.
CREATE FUNCTION binders._card_todo() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, binders AS $$
DECLARE
    v_status text := CASE WHEN NEW.board_column = 'done' THEN 'done' ELSE 'open' END;
BEGIN
    IF NEW.todo_id IS NOT NULL AND (OLD.board_column = 'done') <> (NEW.board_column = 'done') THEN
        UPDATE binders.todos SET status = v_status
        WHERE id = NEW.todo_id AND binder_id = NEW.binder_id AND deleted_at IS NULL AND status IN ('open', 'done')
          AND status <> v_status;
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER cards_todo AFTER UPDATE OF board_column ON binders.cards FOR EACH ROW EXECUTE FUNCTION binders._card_todo();

-- MARK: Pruning

-- What grows, kept `p_keep_days` (30 unless asked for more): operations older than that go (a Mac never sends an
-- outbox item older than that), and changes older than that which every Mac seen in that time has read (`seen_seq`).
-- The last number pruned is kept in team_settings: a Mac that read less than it reads its binders whole again, so
-- nothing it missed (a deletion) is lost. Any person may ask; one prune runs at a time.
CREATE FUNCTION binders.prune(p_op uuid, p_keep_days integer DEFAULT 30) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_cutoff timestamptz := now() - make_interval(days => greatest(coalesce(p_keep_days, 30), 30));
    v_needed bigint;
    v_through bigint;
    v_changes integer := 0;
    v_operations integer := 0;
BEGIN
    PERFORM binders._person();
    IF NOT pg_try_advisory_xact_lock(7311960516743086923) THEN
        RETURN jsonb_build_object('ok', true, 'unchanged', true, 'changes', 0, 'operations', 0);
    END IF;
    SELECT min(seen_seq) INTO v_needed FROM binders.members
    WHERE deleted_at IS NULL AND seen_at >= v_cutoff AND seen_seq IS NOT NULL;
    WITH gone AS (
        DELETE FROM binders.changes WHERE at < v_cutoff AND (v_needed IS NULL OR seq <= v_needed) RETURNING seq)
    SELECT count(*), max(seq) INTO v_changes, v_through FROM gone;
    IF v_through IS NOT NULL THEN
        UPDATE binders.team_settings SET changes_pruned_through = greatest(changes_pruned_through, v_through);
    END IF;
    DELETE FROM binders.operations WHERE created_at < v_cutoff;
    GET DIAGNOSTICS v_operations = ROW_COUNT;
    RETURN jsonb_build_object('ok', true, 'unchanged', v_changes = 0 AND v_operations = 0, 'changes', v_changes,
        'operations', v_operations, 'pruned_through', (SELECT changes_pruned_through FROM binders.team_settings));
END $$;
"""#
}

