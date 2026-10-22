import Foundation

// Migration 4 of the team database, as SQL: Knowledge vectors, as long as the pinned embedding model's. Applied by TeamDatabaseSetup in one transaction with the
// others, as the team's owner role. Never change a migration that has shipped: add the next one.

extension TeamSchema {
    static let migration4 = TeamMigration(version: 4, name: "Knowledge vectors, as long as the pinned embedding model's", sql: #"""
-- Migration 4: knowledge vectors (pgvector). The column takes the dimension of the embedding model the team pinned
-- (team_settings); pinning another model later empties the vectors, retypes the column and adds one to the epoch, and
-- every Mac embeds its own chunks again with the new model.

ALTER TABLE binders.knowledge_chunks ADD COLUMN embedding vector;

-- Types the vector column for `p_model`'s `p_dimension` numbers, with an HNSW index by cosine distance, and records
-- the pin. Rewriting the column clears every vector at once, without a change in the feed for each row: Macs learn of
-- it from team_settings, whose epoch grows (`p_new_epoch`) when it isn't the first pin.
CREATE FUNCTION binders._pin_embedding(p_model text, p_dimension integer, p_new_epoch boolean) RETURNS integer
LANGUAGE plpgsql SET search_path = pg_catalog, binders AS $$
DECLARE
    v_schema text := (SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'vector');
    v_epoch integer;
BEGIN
    IF v_schema IS NULL THEN
        RAISE EXCEPTION 'pgvector isn''t installed in this database.' USING ERRCODE = '0A000';
    END IF;
    IF btrim(coalesce(p_model, '')) = '' OR p_dimension IS NULL OR p_dimension NOT BETWEEN 1 AND 2000 THEN
        RAISE EXCEPTION 'An embedding model needs a name and between 1 and 2,000 numbers.' USING ERRCODE = '22023';
    END IF;
    DROP INDEX IF EXISTS binders.knowledge_chunks_embedding;
    EXECUTE format('ALTER TABLE binders.knowledge_chunks ALTER COLUMN embedding TYPE %I.vector(%s) USING NULL, '
                   'ALTER COLUMN embedding_model TYPE text USING NULL', v_schema, p_dimension);
    EXECUTE format('CREATE INDEX knowledge_chunks_embedding ON binders.knowledge_chunks USING hnsw (embedding %I.vector_cosine_ops)',
                   v_schema);
    UPDATE binders.team_settings
    SET embedding_model = btrim(p_model), embedding_dimension = p_dimension,
        embedding_epoch = embedding_epoch + CASE WHEN p_new_epoch THEN 1 ELSE 0 END
    RETURNING embedding_epoch INTO v_epoch;
    RETURN v_epoch;
END $$;

-- An admin pins another embedding model for the team.
CREATE FUNCTION binders.pin_embedding_model(p_op uuid, p_model text, p_dimension integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_done jsonb := binders._op_begin(p_op, 'pin_embedding_model', jsonb_build_object('model', p_model, 'dimension', p_dimension));
    v_epoch integer;
BEGIN
    IF v_done IS NOT NULL THEN
        RETURN v_done;
    END IF;
    PERFORM binders._admin();
    v_epoch := binders._pin_embedding(p_model, p_dimension, true);
    RETURN binders._op_end(p_op, jsonb_build_object('ok', true, 'model', btrim(p_model), 'dimension', p_dimension, 'epoch', v_epoch));
END $$;

-- Search in the team's knowledge for headless agents, which have no index of their own: by meaning when given an
-- embedding from the pinned model (`p_embedding`, an array of numbers), by words otherwise. Runs as the caller, so it
-- finds only what's in binders shared with them.
CREATE FUNCTION binders.search_knowledge(p_query text, p_embedding jsonb DEFAULT NULL, p_binder uuid DEFAULT NULL,
                                         p_limit integer DEFAULT 10) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = pg_catalog, binders AS $$
DECLARE
    v_schema text := (SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'vector');
    v_hits jsonb;
BEGIN
    IF p_embedding IS NOT NULL THEN
        EXECUTE format('SELECT coalesce(jsonb_agg(h), ''[]'') FROM ('
                       'SELECT id, binder_id, source_kind, source_id, chunk_index, text, '
                       '1 - (embedding OPERATOR(%1$I.<=>) $1::text::%1$I.vector) AS score '
                       'FROM binders.knowledge_chunks WHERE deleted_at IS NULL AND embedding IS NOT NULL '
                       'AND ($2::uuid IS NULL OR binder_id = $2) '
                       'ORDER BY embedding OPERATOR(%1$I.<=>) $1::text::%1$I.vector LIMIT $3) h', v_schema)
            INTO v_hits USING p_embedding, p_binder, greatest(1, least(coalesce(p_limit, 10), 100));
    ELSE
        SELECT coalesce(jsonb_agg(h), '[]') INTO v_hits FROM (
            SELECT id, binder_id, source_kind, source_id, chunk_index, text,
                   ts_rank(tsv, websearch_to_tsquery('simple', coalesce(p_query, ''))) AS score
            FROM binders.knowledge_chunks
            WHERE deleted_at IS NULL AND tsv @@ websearch_to_tsquery('simple', coalesce(p_query, ''))
              AND (p_binder IS NULL OR binder_id = p_binder)
            ORDER BY score DESC LIMIT greatest(1, least(coalesce(p_limit, 10), 100))) h;
    END IF;
    RETURN v_hits;
END $$;

-- A team set up before this migration gets its column typed for the model it pinned.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM binders.team_settings) THEN
        PERFORM binders._pin_embedding(embedding_model, embedding_dimension, false) FROM binders.team_settings;
    END IF;
END $$;
"""#)
}
