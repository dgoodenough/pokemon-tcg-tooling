-- Phase 1 schema for the Pokemon TCG pricing + inventory pipeline.
-- Run via: duckdb pipeline.duckdb < schema.sql
-- Re-runnable: every CREATE uses IF NOT EXISTS.

-- ============================================================================
-- DIMENSIONS
-- ============================================================================

-- dim_set: each English Pokemon TCG set. Sourced from pokemontcg.io /sets.
CREATE TABLE IF NOT EXISTS dim_set (
  set_id          VARCHAR PRIMARY KEY,             -- pokemontcg.io id, e.g. 'sv2'
  name            VARCHAR NOT NULL,
  series          VARCHAR,
  printed_total   INTEGER,                         -- the printed set size (e.g. 198)
  total           INTEGER,                         -- API's count including secret rares
  release_date    DATE,
  ptcgo_code      VARCHAR,
  symbol_url      VARCHAR,
  logo_url        VARCHAR,
  updated_at      TIMESTAMP
);

-- dim_card: canonical English card. PK = pokemontcg.io card id, e.g. 'swsh6-99'.
CREATE TABLE IF NOT EXISTS dim_card (
  card_id         VARCHAR PRIMARY KEY,
  set_id          VARCHAR NOT NULL REFERENCES dim_set(set_id),
  number          VARCHAR NOT NULL,                -- string because of promos like 'SM166', 'H1'
  number_sort     INTEGER,                         -- best-effort numeric extraction for sorting
  name            VARCHAR NOT NULL,
  supertype       VARCHAR,                         -- 'Pokemon', 'Trainer', 'Energy'
  subtypes        VARCHAR,                         -- comma-joined: 'Basic,EX', 'V-UNION', etc.
  rarity          VARCHAR,
  hp              INTEGER,
  types           VARCHAR,                         -- comma-joined: 'Lightning', 'Water,Lightning'
  evolves_from    VARCHAR,
  artist          VARCHAR,
  nat_dex_numbers VARCHAR,                         -- comma-joined dex numbers (for Pokemon supertype only)
  pokemon_key     VARCHAR,                         -- normalized base pokemon name (for joining to dim_pokemon)
  flavor_text     VARCHAR,
  image_small     VARCHAR,
  image_large     VARCHAR,
  tcgplayer_id    INTEGER                          -- TCGPlayer product ID when present in the API
);

-- dim_variant: the printing variants the checklists already track.
-- Display order matters for view output; lower display_order renders first.
CREATE TABLE IF NOT EXISTS dim_variant (
  variant_key     VARCHAR PRIMARY KEY,
  label           VARCHAR NOT NULL,
  display_order   INTEGER NOT NULL,
  era             VARCHAR,                         -- 'wotc', 'modern', 'reprint' — informational
  description     VARCHAR
);

-- dim_pokemon: Pokemon species registry. Sourced from PokeAPI.
CREATE TABLE IF NOT EXISTS dim_pokemon (
  pokemon_key     VARCHAR PRIMARY KEY,             -- normalized name: lowercase, no punctuation
  name            VARCHAR NOT NULL,                -- canonical English display name
  dex_number      INTEGER,                         -- National Pokedex number
  generation      INTEGER,                         -- 1..9
  types           VARCHAR,                         -- comma-joined: 'Electric', 'Water,Ground'
  evolution_chain INTEGER,                         -- PokeAPI evolution_chain id (groups family)
  is_legendary    BOOLEAN,
  is_mythical     BOOLEAN
);

-- dim_condition: card condition + grading. Hardcoded; rare to change.
CREATE TABLE IF NOT EXISTS dim_condition (
  condition_id    VARCHAR PRIMARY KEY,             -- 'NM', 'LP', 'MP', 'HP', 'DMG', 'PSA-10', etc.
  label           VARCHAR NOT NULL,
  is_graded       BOOLEAN NOT NULL,
  grading_company VARCHAR,                         -- 'PSA','BGS','CGC' for graded; null for raw
  grade           DECIMAL(3,1),                    -- 10.0, 9.5, 9.0, etc.
  rank_order      INTEGER NOT NULL                 -- lower = better condition (NM=1, LP=2, ...)
);

-- dim_source: data sources for prices and inventory.
CREATE TABLE IF NOT EXISTS dim_source (
  source_id       VARCHAR PRIMARY KEY,
  label           VARCHAR NOT NULL,
  description     VARCHAR,
  is_actual_sale  BOOLEAN NOT NULL                 -- true for 130point/eBay; false for listings/marketplaces
);

-- ============================================================================
-- CROSSWALK
-- ============================================================================

-- card_alias: maps external source IDs to internal card_id.
-- One row per (source, external_id). Built incrementally — unknown aliases
-- get queued for manual review rather than blocking ingestion.
CREATE TABLE IF NOT EXISTS card_alias (
  source_id       VARCHAR NOT NULL REFERENCES dim_source(source_id),
  external_id     VARCHAR NOT NULL,
  card_id         VARCHAR REFERENCES dim_card(card_id),  -- NULL = quarantined for manual review
  variant_key     VARCHAR REFERENCES dim_variant(variant_key),
  confidence      VARCHAR NOT NULL DEFAULT 'auto',       -- 'auto', 'manual', 'reviewed'
  notes           VARCHAR,
  created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (source_id, external_id)
);

-- ============================================================================
-- FACTS (Phase 1 leaves these empty; Phase 1 ingestion fills fact_inventory_snapshot)
-- ============================================================================

CREATE TABLE IF NOT EXISTS fact_price (
  captured_at     TIMESTAMP NOT NULL,
  card_id         VARCHAR NOT NULL REFERENCES dim_card(card_id),
  variant_key     VARCHAR NOT NULL REFERENCES dim_variant(variant_key),
  condition_id   VARCHAR NOT NULL REFERENCES dim_condition(condition_id),
  source_id       VARCHAR NOT NULL REFERENCES dim_source(source_id),
  price_low       DECIMAL(10,2),
  price_market    DECIMAL(10,2),
  price_mid       DECIMAL(10,2),
  price_high      DECIMAL(10,2),
  listing_count   INTEGER,
  PRIMARY KEY (captured_at, card_id, variant_key, condition_id, source_id)
);

CREATE TABLE IF NOT EXISTS fact_inventory_snapshot (
  snapshot_date   DATE NOT NULL,
  card_id         VARCHAR NOT NULL REFERENCES dim_card(card_id),
  variant_key     VARCHAR NOT NULL REFERENCES dim_variant(variant_key),
  condition_id    VARCHAR NOT NULL REFERENCES dim_condition(condition_id),
  qty             INTEGER NOT NULL,
  unit_cost_paid  DECIMAL(10,2),                   -- nullable; null = unknown cost basis
  notes           VARCHAR,
  PRIMARY KEY (snapshot_date, card_id, variant_key, condition_id)
);

-- ============================================================================
-- CURATION
-- ============================================================================

CREATE TABLE IF NOT EXISTS outlier_flag (
  flag_id         INTEGER PRIMARY KEY,             -- assigned by application
  scope           VARCHAR NOT NULL,                -- 'price' | 'inventory' | 'alias'
  scope_key       VARCHAR NOT NULL,                -- json-encoded composite key of the flagged row
  reason          VARCHAR NOT NULL,
  flagged_by      VARCHAR,                         -- 'auto:mad', 'manual', etc.
  flagged_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  is_active       BOOLEAN NOT NULL DEFAULT true
);

CREATE TABLE IF NOT EXISTS card_note (
  card_id         VARCHAR NOT NULL REFERENCES dim_card(card_id),
  note            VARCHAR NOT NULL,
  created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS card_override (
  card_id         VARCHAR NOT NULL REFERENCES dim_card(card_id),
  field_name      VARCHAR NOT NULL,
  value           VARCHAR NOT NULL,
  reason          VARCHAR,
  created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (card_id, field_name)
);

-- ============================================================================
-- Seed dim_variant (small enough to inline)
-- ============================================================================

INSERT INTO dim_variant (variant_key, label, display_order, era, description) VALUES
  ('1stEdition',         '1st Ed',      10, 'wotc',    'WOTC-era first edition non-holo'),
  ('1stEditionHolofoil', '1st Ed Holo', 20, 'wotc',    'WOTC-era first edition holofoil'),
  ('unlimited',          'Unlimited',   30, 'wotc',    'WOTC-era unlimited non-holo'),
  ('unlimitedHolofoil',  'Unl. Holo',   40, 'wotc',    'WOTC-era unlimited holofoil'),
  ('normal',             'Regular',     50, 'modern',  'Standard non-foil printing'),
  ('holofoil',           'Holo',        60, 'modern',  'Standard holofoil printing'),
  ('reverseHolofoil',    'Reverse',     70, 'modern',  'Reverse-holofoil printing'),
  ('cosmosHolofoil',     'Cosmos',      80, 'reprint', 'Cosmos-pattern holo (POP, Collector Boxes, blisters)'),
  ('nonHoloDeck',        'Non-Holo',    90, 'reprint', 'Non-foil deck or blister exclusive of a normally-holo card'),
  ('stampedPromo',       'Stamped',    100, 'reprint', 'Stamped variant (staff stamps, anniversary logos, distributor stamps)')
ON CONFLICT (variant_key) DO NOTHING;

-- ============================================================================
-- Seed dim_condition
-- ============================================================================

INSERT INTO dim_condition (condition_id, label, is_graded, grading_company, grade, rank_order) VALUES
  ('NM',       'Near Mint',       false, NULL, NULL, 10),
  ('LP',       'Lightly Played',  false, NULL, NULL, 20),
  ('MP',       'Moderately Played', false, NULL, NULL, 30),
  ('HP',       'Heavily Played',  false, NULL, NULL, 40),
  ('DMG',      'Damaged',         false, NULL, NULL, 50),
  ('PSA-10',   'PSA 10 Gem Mint', true,  'PSA', 10.0, 1),
  ('PSA-9',    'PSA 9 Mint',      true,  'PSA',  9.0, 2),
  ('PSA-8',    'PSA 8 NM-Mint',   true,  'PSA',  8.0, 3),
  ('BGS-10',   'BGS 10 Pristine', true,  'BGS', 10.0, 1),
  ('BGS-9.5',  'BGS 9.5 Gem Mint',true,  'BGS',  9.5, 2),
  ('CGC-10',   'CGC 10 Pristine', true,  'CGC', 10.0, 1),
  ('CGC-9.5',  'CGC 9.5 Mint+',   true,  'CGC',  9.5, 2)
ON CONFLICT (condition_id) DO NOTHING;

-- ============================================================================
-- Seed dim_source
-- ============================================================================

INSERT INTO dim_source (source_id, label, description, is_actual_sale) VALUES
  ('pokemontcg',   'pokemontcg.io',    'Free API. Bundled TCGPlayer/Cardmarket prices, refreshed daily.', false),
  ('tcgplayer',    'TCGPlayer CSV',    'User-supplied inventory and pricing CSVs.',                       false),
  ('pricecharting','PriceCharting API','Paid tier. Historical pricing including graded slab prices.',     false),
  ('point130',     '130point',         'Scraped auction sales aggregate.',                                true),
  ('ebay',         'eBay Browse API',  'Direct eBay sold-listings ingestion.',                            true)
ON CONFLICT (source_id) DO NOTHING;
