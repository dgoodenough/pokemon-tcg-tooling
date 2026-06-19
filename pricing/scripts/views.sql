-- Analytics materialized views.
-- Refresh via:  duckdb pipeline.duckdb < views.sql
-- Re-runnable: each view is DROP+CREATE.
--
-- Conventions:
--   - "baseline" snapshot = Aug 14 2023 01:47 (oldest full-catalog dump)
--   - "current" snapshot  = May 24 2026 12:59 (newest)
--   - All price comparisons unless otherwise noted: NM condition, normal variant
--   - Cards needing >=$5 baseline to avoid micro-cap noise where signal is meaningful

SET TimeZone = 'UTC';   -- DuckDB will accept this even if not configured

-- =================================================================================
-- mv_snapshot_meta: timestamps and labels we keep referring to in queries.
-- =================================================================================
DROP TABLE IF EXISTS mv_snapshot_meta;
CREATE TABLE mv_snapshot_meta AS
WITH labeled AS (
  SELECT
    captured_at,
    strftime(captured_at, '%Y-%m-%d') AS snapshot_date,
    row_number() OVER (ORDER BY captured_at) AS seq,
    COUNT(*) OVER (PARTITION BY captured_at) AS rowcount
  FROM (SELECT DISTINCT captured_at FROM fact_price)
)
SELECT
  captured_at,
  snapshot_date,
  CASE WHEN seq = 1 THEN 'baseline'
       WHEN seq = (SELECT MAX(seq) FROM labeled) THEN 'current'
       ELSE 'intermediate' END AS role
FROM labeled
ORDER BY captured_at;

-- =================================================================================
-- mv_top_movers: biggest absolute and percentage gainers (NM normal) between
-- baseline and current. Tie-break on absolute change so the top of the list
-- still shows real money even when small cards have crazy percentages.
-- =================================================================================
DROP TABLE IF EXISTS mv_top_movers;
CREATE TABLE mv_top_movers AS
WITH baseline AS (
  SELECT card_id, variant_key, condition_id, price_market AS price_baseline
  FROM fact_price
  WHERE captured_at = (SELECT captured_at FROM mv_snapshot_meta WHERE role = 'baseline')
),
current AS (
  SELECT card_id, variant_key, condition_id, price_market AS price_current
  FROM fact_price
  WHERE captured_at = (SELECT captured_at FROM mv_snapshot_meta WHERE role = 'current')
)
SELECT
  c.card_id,
  c.name,
  s.name AS set_name,
  s.set_id,
  s.release_date AS set_release_date,
  c.number,
  c.rarity,
  c.artist,
  c.pokemon_key,
  b.variant_key,
  b.condition_id,
  ROUND(b.price_baseline, 2) AS price_baseline,
  ROUND(cu.price_current, 2) AS price_current,
  ROUND(cu.price_current - b.price_baseline, 2) AS price_delta,
  ROUND(100.0 * (cu.price_current - b.price_baseline) / b.price_baseline, 1) AS pct_change
FROM baseline b
JOIN current cu USING (card_id, variant_key, condition_id)
JOIN dim_card c ON c.card_id = b.card_id
JOIN dim_set s ON s.set_id  = c.set_id
WHERE b.condition_id = 'NM'
  AND b.variant_key = 'normal'
  AND b.price_baseline >= 5
  AND cu.price_current > 0;

-- =================================================================================
-- mv_pokemon_index: per-Pokemon aggregate value summary.
--
-- Each card contributes ONE price per snapshot via the primary-variant model
-- (normal for Common/Uncommon/Rare; holofoil for everything else). Pokemon are
-- included if they have priced cards in the CURRENT snapshot. The trend columns
-- (baseline_*, pct_change) are populated only when baseline data is also available;
-- for Pokemon whose sets all post-date Aug 2023, those columns are NULL.
-- =================================================================================
DROP TABLE IF EXISTS mv_pokemon_index;
CREATE TABLE mv_pokemon_index AS
WITH primary_variant_price AS (
  SELECT
    fp.card_id, fp.captured_at, c.pokemon_key, c.rarity, fp.price_market,
    CASE
      WHEN c.rarity IN ('Common','Uncommon','Rare') THEN
        CASE fp.variant_key WHEN 'normal' THEN 1 WHEN 'reverseHolofoil' THEN 2 WHEN 'holofoil' THEN 3 ELSE 9 END
      ELSE
        CASE fp.variant_key WHEN 'holofoil' THEN 1 WHEN 'reverseHolofoil' THEN 2 WHEN 'normal' THEN 3 ELSE 9 END
    END AS variant_priority
  FROM fact_price fp JOIN dim_card c ON c.card_id = fp.card_id
  WHERE fp.condition_id='NM'
    AND fp.captured_at IN (SELECT captured_at FROM mv_snapshot_meta WHERE role IN ('baseline','current'))
    AND fp.price_market > 0
    AND c.pokemon_key IS NOT NULL AND c.pokemon_key <> ''
),
card_price AS (
  SELECT card_id, captured_at, pokemon_key, price_market
  FROM primary_variant_price
  QUALIFY ROW_NUMBER() OVER (PARTITION BY card_id, captured_at ORDER BY variant_priority, price_market DESC) = 1
),
current_agg AS (
  SELECT pokemon_key,
         COUNT(*)              AS card_count,
         SUM(price_market)     AS total_value,
         MAX(price_market)     AS max_price
  FROM card_price
  WHERE captured_at = (SELECT captured_at FROM mv_snapshot_meta WHERE role='current')
  GROUP BY pokemon_key
),
baseline_agg AS (
  -- Only counts cards that ALSO exist in the current snapshot, so the change comparison
  -- is apples-to-apples and not biased by missing card sets.
  SELECT b.pokemon_key,
         COUNT(*)              AS card_count_baseline,
         SUM(b.price_market)   AS total_value_baseline,
         MAX(b.price_market)   AS max_price_baseline
  FROM card_price b
  JOIN card_price cu ON cu.card_id = b.card_id
   AND cu.captured_at = (SELECT captured_at FROM mv_snapshot_meta WHERE role='current')
  WHERE b.captured_at = (SELECT captured_at FROM mv_snapshot_meta WHERE role='baseline')
  GROUP BY b.pokemon_key
),
current_matched AS (
  -- Current-side total restricted to the same cards counted in baseline_agg
  SELECT cu.pokemon_key,
         SUM(cu.price_market) AS total_value_current_matched
  FROM card_price cu
  JOIN card_price b ON b.card_id = cu.card_id
   AND b.captured_at = (SELECT captured_at FROM mv_snapshot_meta WHERE role='baseline')
  WHERE cu.captured_at = (SELECT captured_at FROM mv_snapshot_meta WHERE role='current')
  GROUP BY cu.pokemon_key
)
SELECT
  c.pokemon_key,
  COALESCE(p.name, c.pokemon_key)                                AS pokemon_name,
  p.dex_number,
  p.generation,
  p.types,
  p.is_legendary,
  p.is_mythical,
  c.card_count,
  ROUND(c.total_value, 2)                                        AS total_value_current,
  ROUND(c.total_value / c.card_count, 2)                         AS avg_per_card_current,
  ROUND(c.max_price, 2)                                          AS max_card_current,
  b.card_count_baseline,
  ROUND(b.total_value_baseline, 2)                               AS total_value_baseline,
  ROUND(cm.total_value_current_matched, 2)                       AS total_value_current_matched,
  ROUND(cm.total_value_current_matched - b.total_value_baseline, 2) AS total_value_delta,
  ROUND(100.0 * (cm.total_value_current_matched - b.total_value_baseline)
       / NULLIF(b.total_value_baseline, 0), 1)                    AS pct_change
FROM current_agg c
LEFT JOIN baseline_agg  b  USING (pokemon_key)
LEFT JOIN current_matched cm USING (pokemon_key)
LEFT JOIN dim_pokemon   p ON p.pokemon_key = c.pokemon_key
WHERE c.card_count >= 3;

-- =================================================================================
-- mv_rarity_index: rarity-tier price performance, baseline -> current.
--
-- For each card in each snapshot, we pick a SINGLE "primary" price using the variant
-- most natural for that rarity:
--   - Common / Uncommon / Rare           -> normal > reverseHolo > holofoil
--   - Everything else (holo, EX, GX, etc.) -> holofoil > normal > reverseHolo
-- Then we group by rarity. Cards must have a primary price in BOTH snapshots
-- to be eligible (so we're comparing apples to apples).
-- =================================================================================
DROP TABLE IF EXISTS mv_rarity_index;
CREATE TABLE mv_rarity_index AS
WITH primary_variant_price AS (
  SELECT
    fp.card_id,
    fp.captured_at,
    c.rarity,
    fp.price_market,
    CASE
      WHEN c.rarity IN ('Common','Uncommon','Rare') THEN
        CASE fp.variant_key
          WHEN 'normal'           THEN 1
          WHEN 'reverseHolofoil'  THEN 2
          WHEN 'holofoil'         THEN 3
          WHEN '1stEdition'       THEN 4
          WHEN 'unlimited'        THEN 5
          ELSE 9 END
      ELSE
        CASE fp.variant_key
          WHEN 'holofoil'           THEN 1
          WHEN 'reverseHolofoil'    THEN 2
          WHEN 'normal'             THEN 3
          WHEN '1stEditionHolofoil' THEN 4
          WHEN 'unlimitedHolofoil'  THEN 5
          ELSE 9 END
    END AS variant_priority
  FROM fact_price fp
  JOIN dim_card c ON c.card_id = fp.card_id
  WHERE fp.condition_id = 'NM'
    AND fp.price_market > 0
    AND c.rarity IS NOT NULL AND c.rarity <> ''
),
best_per_card AS (
  SELECT card_id, captured_at, rarity, price_market
  FROM primary_variant_price
  QUALIFY ROW_NUMBER() OVER (PARTITION BY card_id, captured_at ORDER BY variant_priority, price_market DESC) = 1
),
baseline AS (
  SELECT card_id, rarity, price_market AS p
  FROM best_per_card
  WHERE captured_at = (SELECT captured_at FROM mv_snapshot_meta WHERE role = 'baseline')
),
current AS (
  SELECT card_id, rarity, price_market AS p
  FROM best_per_card
  WHERE captured_at = (SELECT captured_at FROM mv_snapshot_meta WHERE role = 'current')
),
joined AS (
  SELECT b.rarity, b.card_id, b.p AS p_baseline, cu.p AS p_current
  FROM baseline b JOIN current cu USING (card_id)
)
SELECT
  rarity,
  COUNT(*) AS card_count,
  ROUND(MEDIAN(p_baseline), 2)            AS median_baseline,
  ROUND(MEDIAN(p_current),  2)            AS median_current,
  ROUND(AVG(p_baseline), 2)               AS avg_baseline,
  ROUND(AVG(p_current),  2)               AS avg_current,
  ROUND(SUM(p_baseline), 2)               AS total_baseline,
  ROUND(SUM(p_current),  2)               AS total_current,
  ROUND(100.0 * (MEDIAN(p_current) - MEDIAN(p_baseline)) / NULLIF(MEDIAN(p_baseline), 0), 1)
                                          AS median_pct_change,
  ROUND(100.0 * (AVG(p_current)    - AVG(p_baseline))    / NULLIF(AVG(p_baseline),    0), 1)
                                          AS avg_pct_change,
  ROUND(100.0 * (SUM(p_current)    - SUM(p_baseline))    / NULLIF(SUM(p_baseline),    0), 1)
                                          AS weighted_pct_change
FROM joined
GROUP BY rarity
HAVING COUNT(*) >= 5
ORDER BY weighted_pct_change DESC;

-- =================================================================================
-- mv_set_value: per-set total value at each snapshot, set completion arithmetic.
-- Useful for "what does it cost to buy this entire set NM?"
-- =================================================================================
DROP TABLE IF EXISTS mv_set_value;
CREATE TABLE mv_set_value AS
WITH baseline AS (
  SELECT c.set_id, SUM(fp.price_market) AS total, COUNT(*) AS priced_cards
  FROM fact_price fp JOIN dim_card c ON c.card_id = fp.card_id
  WHERE captured_at = (SELECT captured_at FROM mv_snapshot_meta WHERE role = 'baseline')
    AND condition_id = 'NM' AND variant_key = 'normal' AND price_market > 0
  GROUP BY c.set_id
),
current AS (
  SELECT c.set_id, SUM(fp.price_market) AS total, COUNT(*) AS priced_cards
  FROM fact_price fp JOIN dim_card c ON c.card_id = fp.card_id
  WHERE captured_at = (SELECT captured_at FROM mv_snapshot_meta WHERE role = 'current')
    AND condition_id = 'NM' AND variant_key = 'normal' AND price_market > 0
  GROUP BY c.set_id
)
SELECT
  s.set_id,
  s.name AS set_name,
  s.series,
  s.release_date,
  s.printed_total,
  s.total AS catalog_total,
  COALESCE(b.priced_cards, 0) AS priced_baseline,
  COALESCE(cu.priced_cards, 0) AS priced_current,
  ROUND(b.total,  2) AS total_value_baseline,
  ROUND(cu.total, 2) AS total_value_current,
  ROUND(100.0 * (cu.total - b.total) / NULLIF(b.total, 0), 1) AS pct_change,
  ROUND(cu.total / NULLIF(cu.priced_cards, 0), 2) AS avg_card_value_current
FROM dim_set s
LEFT JOIN baseline b ON b.set_id = s.set_id
LEFT JOIN current  cu ON cu.set_id = s.set_id
WHERE cu.priced_cards IS NOT NULL;   -- only show sets present in the current snapshot

-- =================================================================================
-- mv_pokemon_premium: rarity-controlled Pokemon valuations.
--
-- Each card gets a "premium" defined as its primary-variant price divided by the
-- median price of cards in the SAME (set, rarity) cohort. Cohorts with fewer than
-- 3 cards fall back to the rarity-wide median (so a singleton Trainer Gallery card
-- still gets a sensible baseline). Premium of 1.0 = exactly the cohort median;
-- 3.0 = three times the cohort median.
--
-- Aggregated to Pokemon level: median + mean + p75 + p90 + max premium across all
-- of that Pokemon's priced printings in the current snapshot.
--
-- This answers: "Does Pikachu trade at a premium to its rarity peers? How much?"
-- Tag teams (e.g. Magikarp & Wailord-GX) attribute to the rightmost-named species
-- because that's what dim_card.pokemon_key resolves to.
-- =================================================================================
DROP TABLE IF EXISTS mv_pokemon_premium;
CREATE TABLE mv_pokemon_premium AS
WITH primary_variant_price AS (
  SELECT
    fp.card_id, c.rarity, c.set_id, c.pokemon_key, c.name AS card_name, c.number,
    fp.price_market,
    CASE
      WHEN c.rarity IN ('Common','Uncommon','Rare') THEN
        CASE fp.variant_key
          WHEN 'normal'           THEN 1
          WHEN 'reverseHolofoil'  THEN 2
          WHEN 'holofoil'         THEN 3
          WHEN '1stEdition'       THEN 4
          WHEN 'unlimited'        THEN 5
          ELSE 9 END
      ELSE
        CASE fp.variant_key
          WHEN 'holofoil'           THEN 1
          WHEN 'reverseHolofoil'    THEN 2
          WHEN 'normal'             THEN 3
          WHEN '1stEditionHolofoil' THEN 4
          WHEN 'unlimitedHolofoil'  THEN 5
          ELSE 9 END
    END AS variant_priority
  FROM fact_price fp
  JOIN dim_card c ON c.card_id = fp.card_id
  WHERE fp.condition_id = 'NM'
    AND fp.captured_at = (SELECT captured_at FROM mv_snapshot_meta WHERE role = 'current')
    AND fp.price_market > 0
    AND c.rarity IS NOT NULL AND c.rarity <> ''
    AND c.pokemon_key IS NOT NULL AND c.pokemon_key <> ''
    -- Exclude promo sets: their (set,rarity) cohort spans million-print blister
    -- inserts to 500-print tournament awards, so the cohort median is meaningless
    -- and a promo card's "premium" is a supply artifact. Excluding them gives a
    -- cleaner per-Pokemon premium from booster-pack cards only. (Note: this lifts
    -- the premium of popular Pokemon, whose bulk promos were diluting the median.)
    AND c.set_id NOT IN (SELECT set_id FROM dim_set WHERE name ILIKE '%Promo%' OR name ILIKE '%Black Star%')
),
card_price AS (
  SELECT card_id, rarity, set_id, pokemon_key, card_name, number, price_market
  FROM primary_variant_price
  QUALIFY ROW_NUMBER() OVER (PARTITION BY card_id ORDER BY variant_priority, price_market DESC) = 1
),
set_rarity_median AS (
  SELECT set_id, rarity, MEDIAN(price_market) AS m, COUNT(*) AS n
  FROM card_price GROUP BY set_id, rarity
),
rarity_median AS (
  SELECT rarity, MEDIAN(price_market) AS m, COUNT(*) AS n
  FROM card_price GROUP BY rarity
),
card_premium AS (
  SELECT
    cp.card_id, cp.pokemon_key, cp.rarity, cp.set_id, cp.card_name, cp.number, cp.price_market,
    CASE
      WHEN srm.n >= 3 AND srm.m > 0 THEN cp.price_market / srm.m
      WHEN rm.m > 0                 THEN cp.price_market / rm.m
      ELSE NULL END AS premium,
    CASE WHEN srm.n >= 3 THEN 'set_plus_rarity' ELSE 'rarity_only' END AS baseline_source
  FROM card_price cp
  LEFT JOIN set_rarity_median srm ON srm.set_id = cp.set_id AND srm.rarity = cp.rarity
  LEFT JOIN rarity_median       rm ON rm.rarity  = cp.rarity
),
agg AS (
  SELECT
    pokemon_key,
    COUNT(*)                                AS card_count,
    ROUND(MEDIAN(price_market), 2)          AS median_price,
    ROUND(MAX(price_market), 2)             AS max_price,
    ROUND(SUM(price_market), 2)             AS total_value,
    ROUND(MEDIAN(premium), 2)               AS median_premium,
    ROUND(AVG(premium), 2)                  AS avg_premium,
    ROUND(QUANTILE_CONT(premium, 0.75), 2)  AS p75_premium,
    ROUND(QUANTILE_CONT(premium, 0.90), 2)  AS p90_premium,
    ROUND(MAX(premium), 2)                  AS max_premium
  FROM card_premium
  WHERE premium IS NOT NULL
  GROUP BY pokemon_key
  HAVING COUNT(*) >= 5
)
SELECT
  a.pokemon_key,
  COALESCE(p.name, a.pokemon_key) AS pokemon_name,
  p.dex_number,
  p.generation,
  p.types,
  p.is_legendary,
  p.is_mythical,
  a.card_count,
  a.median_price,
  a.max_price,
  a.total_value,
  a.median_premium,
  a.avg_premium,
  a.p75_premium,
  a.p90_premium,
  a.max_premium
FROM agg a
LEFT JOIN dim_pokemon p ON p.pokemon_key = a.pokemon_key;

-- =================================================================================
-- mv_pokemon_premium_change: Pokemon premium trajectory between baseline and current.
--
-- For each snapshot we recompute the (set, rarity) medians and each card's premium
-- relative to its OWN snapshot's medians. Then we compare each Pokemon's median
-- premium in Aug 2023 vs May 2026.
--
-- A rising premium means the Pokemon OUTPERFORMED its rarity peers between the two
-- snapshots; a falling premium means it under-performed. This is the cleanest
-- single signal for "is this Pokemon getting popular?" because raw price change
-- alone confounds Pokemon-specific demand with broad rarity-tier appreciation.
-- =================================================================================
DROP TABLE IF EXISTS mv_pokemon_premium_change;
CREATE TABLE mv_pokemon_premium_change AS
WITH primary_variant_price AS (
  SELECT
    fp.card_id, fp.captured_at, c.rarity, c.set_id, c.pokemon_key, fp.price_market,
    CASE
      WHEN c.rarity IN ('Common','Uncommon','Rare') THEN
        CASE fp.variant_key WHEN 'normal' THEN 1 WHEN 'reverseHolofoil' THEN 2 WHEN 'holofoil' THEN 3 ELSE 9 END
      ELSE
        CASE fp.variant_key WHEN 'holofoil' THEN 1 WHEN 'reverseHolofoil' THEN 2 WHEN 'normal' THEN 3 ELSE 9 END
    END AS variant_priority
  FROM fact_price fp JOIN dim_card c ON c.card_id = fp.card_id
  WHERE fp.condition_id='NM'
    AND fp.captured_at IN (
      SELECT captured_at FROM mv_snapshot_meta WHERE role IN ('baseline','current')
    )
    AND fp.price_market > 0
    AND c.rarity IS NOT NULL AND c.rarity<>''
    AND c.pokemon_key IS NOT NULL AND c.pokemon_key<>''
    -- Exclude promo sets (heterogeneous supply makes cohort median meaningless).
    AND c.set_id NOT IN (SELECT set_id FROM dim_set WHERE name ILIKE '%Promo%' OR name ILIKE '%Black Star%')
),
card_price AS (
  SELECT card_id, captured_at, rarity, set_id, pokemon_key, price_market
  FROM primary_variant_price
  QUALIFY ROW_NUMBER() OVER (PARTITION BY card_id, captured_at ORDER BY variant_priority, price_market DESC) = 1
),
set_rarity_median AS (
  SELECT set_id, rarity, captured_at, MEDIAN(price_market) AS m, COUNT(*) AS n
  FROM card_price GROUP BY set_id, rarity, captured_at
),
rarity_median AS (
  SELECT rarity, captured_at, MEDIAN(price_market) AS m
  FROM card_price GROUP BY rarity, captured_at
),
card_premium AS (
  SELECT
    cp.card_id, cp.captured_at, cp.pokemon_key,
    CASE
      WHEN srm.n >= 3 AND srm.m > 0 THEN cp.price_market / srm.m
      WHEN rm.m  > 0                THEN cp.price_market / rm.m
      ELSE NULL END AS premium
  FROM card_price cp
  LEFT JOIN set_rarity_median srm ON srm.set_id=cp.set_id AND srm.rarity=cp.rarity AND srm.captured_at=cp.captured_at
  LEFT JOIN rarity_median       rm ON rm.rarity =cp.rarity AND rm.captured_at =cp.captured_at
),
pokemon_snapshot AS (
  SELECT pokemon_key, captured_at,
         COUNT(*)        AS card_count,
         MEDIAN(premium) AS median_premium
  FROM card_premium WHERE premium IS NOT NULL
  GROUP BY pokemon_key, captured_at
),
joined AS (
  SELECT
    b.pokemon_key,
    b.card_count        AS card_count_baseline,
    cu.card_count       AS card_count_current,
    b.median_premium    AS premium_baseline,
    cu.median_premium   AS premium_current
  FROM pokemon_snapshot b JOIN pokemon_snapshot cu USING (pokemon_key)
  WHERE b.captured_at  = (SELECT captured_at FROM mv_snapshot_meta WHERE role='baseline')
    AND cu.captured_at = (SELECT captured_at FROM mv_snapshot_meta WHERE role='current')
)
SELECT
  j.pokemon_key,
  COALESCE(p.name, j.pokemon_key) AS pokemon_name,
  p.dex_number,
  p.generation,
  p.types,
  j.card_count_baseline,
  j.card_count_current,
  ROUND(j.premium_baseline, 2)                                                   AS premium_baseline,
  ROUND(j.premium_current,  2)                                                   AS premium_current,
  ROUND(j.premium_current - j.premium_baseline, 2)                               AS premium_delta,
  ROUND(100.0 * (j.premium_current - j.premium_baseline) / NULLIF(j.premium_baseline, 0), 1) AS pct_change
FROM joined j
LEFT JOIN dim_pokemon p ON p.pokemon_key = j.pokemon_key
WHERE j.card_count_baseline >= 5 AND j.card_count_current >= 5;

-- =================================================================================
-- mv_pokemon_premium_by_rarity: same idea but broken out (pokemon, rarity).
-- Lets us answer "Tyranitar specifically: how does its Rare Holo trade vs other
-- Rare Holos? How does its Rare Ultra trade vs others?"
-- =================================================================================
DROP TABLE IF EXISTS mv_pokemon_premium_by_rarity;
CREATE TABLE mv_pokemon_premium_by_rarity AS
WITH primary_variant_price AS (
  SELECT
    fp.card_id, c.rarity, c.set_id, c.pokemon_key, fp.price_market,
    CASE
      WHEN c.rarity IN ('Common','Uncommon','Rare') THEN
        CASE fp.variant_key WHEN 'normal' THEN 1 WHEN 'reverseHolofoil' THEN 2 WHEN 'holofoil' THEN 3 ELSE 9 END
      ELSE
        CASE fp.variant_key WHEN 'holofoil' THEN 1 WHEN 'reverseHolofoil' THEN 2 WHEN 'normal' THEN 3 ELSE 9 END
    END AS variant_priority
  FROM fact_price fp JOIN dim_card c ON c.card_id = fp.card_id
  WHERE fp.condition_id='NM'
    AND fp.captured_at = (SELECT captured_at FROM mv_snapshot_meta WHERE role='current')
    AND fp.price_market > 0
    AND c.rarity IS NOT NULL AND c.rarity<>''
    AND c.pokemon_key IS NOT NULL AND c.pokemon_key<>''
    -- Exclude promo sets (heterogeneous supply makes cohort/rarity median meaningless).
    AND c.set_id NOT IN (SELECT set_id FROM dim_set WHERE name ILIKE '%Promo%' OR name ILIKE '%Black Star%')
),
card_price AS (
  SELECT card_id, rarity, set_id, pokemon_key, price_market
  FROM primary_variant_price
  QUALIFY ROW_NUMBER() OVER (PARTITION BY card_id ORDER BY variant_priority, price_market DESC) = 1
),
rarity_median AS (SELECT rarity, MEDIAN(price_market) AS m FROM card_price GROUP BY rarity)
SELECT
  cp.pokemon_key,
  COALESCE(p.name, cp.pokemon_key) AS pokemon_name,
  cp.rarity,
  COUNT(*) AS card_count,
  ROUND(MEDIAN(cp.price_market), 2) AS median_price,
  ROUND(rm.m, 2) AS rarity_median,
  ROUND(MEDIAN(cp.price_market) / NULLIF(rm.m, 0), 2) AS median_premium,
  ROUND(MAX(cp.price_market), 2) AS max_price
FROM card_price cp
JOIN rarity_median rm ON rm.rarity = cp.rarity
LEFT JOIN dim_pokemon p ON p.pokemon_key = cp.pokemon_key
GROUP BY cp.pokemon_key, p.name, cp.rarity, rm.m
HAVING COUNT(*) >= 3;

-- =================================================================================
-- mv_artist_premium: per artist, the median NM-normal market price of their cards
-- in the current snapshot. Lets us ask: does Komiya / Arita / etc. command a premium
-- after controlling for what their cards look like in the catalog?
-- =================================================================================
DROP TABLE IF EXISTS mv_artist_premium;
CREATE TABLE mv_artist_premium AS
WITH current AS (
  SELECT c.artist, c.rarity, fp.price_market
  FROM fact_price fp JOIN dim_card c ON c.card_id = fp.card_id
  WHERE captured_at = (SELECT captured_at FROM mv_snapshot_meta WHERE role = 'current')
    AND condition_id = 'NM' AND variant_key = 'normal'
    AND price_market > 0
    AND c.artist IS NOT NULL AND c.artist <> ''
),
artist_agg AS (
  SELECT
    artist,
    COUNT(*) AS card_count,
    ROUND(MEDIAN(price_market), 2) AS median_price,
    ROUND(AVG(price_market), 2)    AS avg_price,
    ROUND(MAX(price_market), 2)    AS max_price
  FROM current
  GROUP BY artist
  HAVING COUNT(*) >= 10        -- need at least 10 priced cards to be a fair sample
)
SELECT
  a.artist,
  a.card_count,
  a.median_price,
  a.avg_price,
  a.max_price,
  -- baseline reference: the catalog-wide median NM-normal market right now
  (SELECT ROUND(MEDIAN(price_market), 2) FROM current) AS market_median,
  ROUND(a.median_price / (SELECT MEDIAN(price_market) FROM current), 2) AS premium_x
FROM artist_agg a
ORDER BY a.median_price DESC;

-- =================================================================================
-- mv_variant_premium: for cards that appear in BOTH normal and reverseHolofoil (and
-- where both have prices), how much premium does reverse holo command on average?
-- =================================================================================
DROP TABLE IF EXISTS mv_variant_premium;
CREATE TABLE mv_variant_premium AS
WITH snap AS (
  SELECT card_id, variant_key, price_market
  FROM fact_price
  WHERE captured_at = (SELECT captured_at FROM mv_snapshot_meta WHERE role = 'current')
    AND condition_id = 'NM' AND price_market > 0
),
variant_pivot AS (
  SELECT
    n.card_id,
    n.price_market AS price_normal,
    r.price_market AS price_reverse,
    h.price_market AS price_holo,
    cos.price_market AS price_cosmos,
    nh.price_market AS price_nonholo
  FROM (SELECT * FROM snap WHERE variant_key = 'normal') n
  LEFT JOIN (SELECT * FROM snap WHERE variant_key = 'reverseHolofoil') r USING (card_id)
  LEFT JOIN (SELECT * FROM snap WHERE variant_key = 'holofoil')        h USING (card_id)
  LEFT JOIN (SELECT * FROM snap WHERE variant_key = 'cosmosHolofoil')  cos USING (card_id)
  LEFT JOIN (SELECT * FROM snap WHERE variant_key = 'nonHoloDeck')     nh USING (card_id)
)
SELECT
  COUNT(*) FILTER (WHERE price_reverse IS NOT NULL) AS card_pairs_normal_reverse,
  ROUND(MEDIAN(price_reverse / price_normal)  FILTER (WHERE price_reverse > 0),  2) AS reverse_to_normal_median_x,
  ROUND(AVG(price_reverse / price_normal)     FILTER (WHERE price_reverse > 0),  2) AS reverse_to_normal_avg_x,
  COUNT(*) FILTER (WHERE price_holo IS NOT NULL) AS card_pairs_normal_holo,
  ROUND(MEDIAN(price_holo    / price_normal)  FILTER (WHERE price_holo    > 0),  2) AS holo_to_normal_median_x,
  COUNT(*) FILTER (WHERE price_cosmos IS NOT NULL) AS card_pairs_normal_cosmos,
  ROUND(MEDIAN(price_cosmos  / price_normal)  FILTER (WHERE price_cosmos  > 0),  2) AS cosmos_to_normal_median_x,
  COUNT(*) FILTER (WHERE price_nonholo IS NOT NULL) AS card_pairs_normal_nonholo,
  ROUND(MEDIAN(price_nonholo / price_normal)  FILTER (WHERE price_nonholo > 0),  2) AS nonholo_to_normal_median_x
FROM variant_pivot
WHERE price_normal > 0;

-- =================================================================================
-- mv_meta_relevance: per (card, variant) condition-compression score.
--
-- Tournament-played cards retain value across condition tiers because players treat
-- any playable copy as functionally interchangeable. Collector-only cards have steep
-- condition discounts because grade is everything.
--
-- composite_score = avg(HP/NM, DMG/NM). Higher = more meta-relevant.
-- Empirically: > 0.6 = meta, < 0.3 = collector, 0.3-0.6 = gray zone.
--
-- Confounder mitigation: requires release_date <= 18 months before current snapshot
-- (so the played-condition population has had time to enter the market) AND monotonic
-- price decay with 15% slack (NM >= LP >= MP >= HP >= DMG within tolerance) so we
-- filter out cards where thin marketplace data has produced inverted ratios.
-- =================================================================================
DROP TABLE IF EXISTS mv_meta_relevance;
CREATE TABLE mv_meta_relevance AS
WITH pivoted AS (
  SELECT
    fp.card_id, fp.variant_key,
    c.name, c.number, c.rarity, c.supertype, c.pokemon_key, c.set_id,
    s.name AS set_name, s.release_date,
    DATEDIFF('day', s.release_date,
             (SELECT captured_at::DATE FROM mv_snapshot_meta WHERE role='current')) AS days_since_release,
    MAX(CASE WHEN condition_id='NM'  THEN price_market END) AS nm,
    MAX(CASE WHEN condition_id='LP'  THEN price_market END) AS lp,
    MAX(CASE WHEN condition_id='MP'  THEN price_market END) AS mp,
    MAX(CASE WHEN condition_id='HP'  THEN price_market END) AS hp,
    MAX(CASE WHEN condition_id='DMG' THEN price_market END) AS dmg
  FROM fact_price fp
  JOIN dim_card c ON c.card_id = fp.card_id
  JOIN dim_set  s ON s.set_id  = c.set_id
  WHERE captured_at = (SELECT captured_at FROM mv_snapshot_meta WHERE role='current')
  GROUP BY fp.card_id, fp.variant_key, c.name, c.number, c.rarity, c.supertype, c.pokemon_key,
           c.set_id, s.name, s.release_date
  HAVING nm IS NOT NULL AND lp IS NOT NULL AND mp IS NOT NULL AND hp IS NOT NULL AND dmg IS NOT NULL
     AND nm >= 3
)
SELECT
  card_id,
  variant_key,
  name,
  set_id,
  set_name,
  number,
  rarity,
  supertype,
  pokemon_key,
  release_date,
  days_since_release,
  ROUND(nm,2)         AS nm_price,
  ROUND(lp,2)         AS lp_price,
  ROUND(mp,2)         AS mp_price,
  ROUND(hp,2)         AS hp_price,
  ROUND(dmg,2)        AS dmg_price,
  ROUND(lp/nm, 3)     AS lp_to_nm,
  ROUND(mp/nm, 3)     AS mp_to_nm,
  ROUND(hp/nm, 3)     AS hp_to_nm,
  ROUND(dmg/nm,3)     AS dmg_to_nm,
  ROUND((hp/nm + dmg/nm)/2.0, 3) AS composite_score,
  -- Monotonic-decay sanity check: NM >= LP >= MP >= HP >= DMG within 15% slack
  (lp <= nm * 1.15 AND mp <= lp * 1.15 AND hp <= mp * 1.15 AND dmg <= hp * 1.15) AS monotonic_ok,
  -- Confounder gate: cards >= 18 months old are reliable; younger cards are flagged
  (days_since_release >= 540) AS old_enough,
  -- Class bucket
  CASE
    WHEN (hp/nm + dmg/nm)/2.0 >= 0.6 THEN 'meta'
    WHEN (hp/nm + dmg/nm)/2.0 <= 0.3 THEN 'collector'
    ELSE 'gray' END AS meta_class,
  -- Trustworthy = passed both sanity gates
  ((lp <= nm * 1.15 AND mp <= lp * 1.15 AND hp <= mp * 1.15 AND dmg <= hp * 1.15)
   AND days_since_release >= 540) AS reliable
FROM pivoted;

-- =================================================================================
-- mv_buy_signals: cards that look undervalued vs their (set, rarity) cohort,
-- screened to exclude tournament-meta cards (which can rotate) and require positive
-- Pokemon-level demand momentum.
--
-- A buy signal is the intersection of:
--   1. Card current price below its (set, rarity) cohort median
--   2. Pokemon premium delta >= 0 (rising or stable popularity)
--   3. NOT classified as reliable-meta (avoid rotation risk)
--   4. Basic liquidity: has both NM and at least one played-condition price
--
-- Composite score: undervaluation * (1 + pokemon_momentum). Cards that are both
-- deeply discounted AND attached to a rising Pokemon score the highest.
-- =================================================================================
DROP TABLE IF EXISTS mv_buy_signals;
CREATE TABLE mv_buy_signals AS
WITH primary_variant_price AS (
  SELECT
    fp.card_id, fp.variant_key, c.set_id, c.rarity, c.pokemon_key, c.name, c.number,
    c.supertype, s.name AS set_name, s.release_date,
    fp.price_market,
    CASE
      WHEN c.rarity IN ('Common','Uncommon','Rare') THEN
        CASE fp.variant_key
          WHEN 'normal' THEN 1 WHEN 'reverseHolofoil' THEN 2 WHEN 'holofoil' THEN 3 ELSE 9 END
      ELSE
        CASE fp.variant_key
          WHEN 'holofoil' THEN 1 WHEN 'reverseHolofoil' THEN 2 WHEN 'normal' THEN 3 ELSE 9 END
    END AS variant_priority
  FROM fact_price fp
  JOIN dim_card c ON c.card_id = fp.card_id
  JOIN dim_set  s ON s.set_id  = c.set_id
  WHERE fp.captured_at = (SELECT captured_at FROM mv_snapshot_meta WHERE role='current')
    AND fp.condition_id = 'NM' AND fp.price_market > 0
    AND c.rarity IS NOT NULL AND c.rarity <> ''
    AND c.supertype IN ('Pokémon','Trainer')  -- exclude Energy: foil Energies in old sets distort the Common-rarity cohort
),
card_primary AS (
  SELECT * FROM primary_variant_price
  QUALIFY ROW_NUMBER() OVER (PARTITION BY card_id ORDER BY variant_priority, price_market DESC) = 1
),
-- Cohort median per (set, rarity); require >= 5 cards so the median is informative.
-- Excludes promo sets because their cards have wildly heterogeneous supply (from
-- million-print blister inserts to 500-print tournament awards under the same set_id),
-- so the cohort median is structurally meaningless. Promo cards need either per-card
-- supply data or a different scoring approach we don't have yet.
cohort AS (
  SELECT cp.set_id, cp.rarity,
         MEDIAN(cp.price_market) AS cohort_median,
         COUNT(*) AS cohort_size
  FROM card_primary cp
  JOIN dim_set s ON s.set_id = cp.set_id
  WHERE s.name NOT ILIKE '%Promo%'
    AND s.name NOT ILIKE '%Black Star%'
  GROUP BY cp.set_id, cp.rarity
  HAVING COUNT(*) >= 5
),
-- Liquidity proxy: card has both NM and at least one played-condition price
liquidity AS (
  SELECT DISTINCT card_id, variant_key
  FROM fact_price
  WHERE captured_at = (SELECT captured_at FROM mv_snapshot_meta WHERE role='current')
    AND price_market > 0
    AND condition_id IN ('LP','MP','HP','DMG')
),
-- Meta exclusion: only exclude cards we can reliably score as meta (composite >= 0.6 AND reliable)
meta_excluded AS (
  SELECT DISTINCT card_id, variant_key
  FROM mv_meta_relevance
  WHERE reliable = TRUE AND composite_score >= 0.6
),
scored AS (
  SELECT
    cp.card_id, cp.variant_key, cp.name, cp.set_id, cp.set_name, cp.number, cp.rarity,
    cp.supertype, cp.pokemon_key, cp.release_date,
    cp.price_market,
    co.cohort_median, co.cohort_size,
    cp.price_market / co.cohort_median AS below_cohort_ratio,
    COALESCE(pc.premium_delta, 0) AS pokemon_premium_delta,
    COALESCE(mr.composite_score, NULL) AS meta_score
  FROM card_primary cp
  JOIN cohort co ON co.set_id = cp.set_id AND co.rarity = cp.rarity
  JOIN liquidity li ON li.card_id = cp.card_id AND li.variant_key = cp.variant_key
  LEFT JOIN mv_pokemon_premium_change pc ON pc.pokemon_key = cp.pokemon_key
  LEFT JOIN mv_meta_relevance mr ON mr.card_id = cp.card_id AND mr.variant_key = cp.variant_key
  WHERE cp.price_market / co.cohort_median < 0.8
    AND COALESCE(pc.premium_delta, 0) >= 0
    AND NOT EXISTS (
      SELECT 1 FROM meta_excluded me
      WHERE me.card_id = cp.card_id AND me.variant_key = cp.variant_key
    )
)
SELECT
  s.card_id,
  s.variant_key,
  s.name,
  s.set_name,
  s.set_id,
  s.number,
  s.rarity,
  s.supertype,
  s.pokemon_key,
  COALESCE(p.name, s.pokemon_key) AS pokemon_name,
  p.generation,
  p.types,
  s.release_date,
  ROUND(s.price_market, 2)            AS current_price,
  ROUND(s.cohort_median, 2)           AS cohort_median,
  s.cohort_size,
  ROUND(s.below_cohort_ratio, 3)      AS below_cohort_ratio,
  ROUND(s.pokemon_premium_delta, 2)   AS pokemon_premium_delta,
  ROUND(s.meta_score, 3)              AS meta_score,
  -- composite_buy_score: how undervalued * (1 + pokemon momentum)
  -- undervalue weight: (1 - below_cohort_ratio) — bigger when price is way under median
  -- momentum weight: clamped to (0, 5) range to avoid runaway from huge premium deltas
  ROUND(
    (1 - s.below_cohort_ratio) * (1 + LEAST(GREATEST(s.pokemon_premium_delta, 0), 5)),
    3
  ) AS composite_buy_score
FROM scored s
LEFT JOIN dim_pokemon p ON p.pokemon_key = s.pokemon_key;

-- =================================================================================
-- mv_sell_signals: mirror of mv_buy_signals - cards trading ABOVE their cohort,
-- on Pokemon whose premium is FALLING. If you own these, consider listing.
-- =================================================================================
DROP TABLE IF EXISTS mv_sell_signals;
CREATE TABLE mv_sell_signals AS
WITH primary_variant_price AS (
  SELECT
    fp.card_id, fp.variant_key, c.set_id, c.rarity, c.pokemon_key, c.name, c.number,
    c.supertype, s.name AS set_name, s.release_date,
    fp.price_market,
    CASE
      WHEN c.rarity IN ('Common','Uncommon','Rare') THEN
        CASE fp.variant_key WHEN 'normal' THEN 1 WHEN 'reverseHolofoil' THEN 2 WHEN 'holofoil' THEN 3 ELSE 9 END
      ELSE
        CASE fp.variant_key WHEN 'holofoil' THEN 1 WHEN 'reverseHolofoil' THEN 2 WHEN 'normal' THEN 3 ELSE 9 END
    END AS variant_priority
  FROM fact_price fp
  JOIN dim_card c ON c.card_id = fp.card_id
  JOIN dim_set  s ON s.set_id  = c.set_id
  WHERE fp.captured_at = (SELECT captured_at FROM mv_snapshot_meta WHERE role='current')
    AND fp.condition_id='NM' AND fp.price_market > 0
    AND c.rarity IS NOT NULL AND c.rarity<>''
    AND c.supertype IN ('Pokémon','Trainer')  -- exclude Energy: foil Energies distort Common-rarity cohorts
),
card_primary AS (
  SELECT * FROM primary_variant_price
  QUALIFY ROW_NUMBER() OVER (PARTITION BY card_id ORDER BY variant_priority, price_market DESC) = 1
),
cohort AS (
  -- (set_id, rarity) cohort baseline. Excludes promo sets because their cards
  -- have wildly heterogeneous supply (from million-print blister inserts to
  -- 500-print tournament awards under the same set_id), so the cohort median
  -- is structurally meaningless. Promo cards are scoreable, just not via this
  -- cohort baseline — they need either per-card supply data or a different
  -- scoring approach we don't have yet.
  SELECT cp.set_id, cp.rarity,
         MEDIAN(cp.price_market) AS cohort_median,
         COUNT(*) AS cohort_size
  FROM card_primary cp
  JOIN dim_set s ON s.set_id = cp.set_id
  WHERE s.name NOT ILIKE '%Promo%'
    AND s.name NOT ILIKE '%Black Star%'
  GROUP BY cp.set_id, cp.rarity
  HAVING COUNT(*) >= 5
),
scored AS (
  SELECT
    cp.card_id, cp.variant_key, cp.name, cp.set_id, cp.set_name, cp.number, cp.rarity,
    cp.supertype, cp.pokemon_key, cp.release_date,
    cp.price_market, co.cohort_median, co.cohort_size,
    cp.price_market / co.cohort_median AS above_cohort_ratio,
    COALESCE(pc.premium_delta, 0) AS pokemon_premium_delta,
    COALESCE(mr.composite_score, NULL) AS meta_score
  FROM card_primary cp
  JOIN cohort co ON co.set_id = cp.set_id AND co.rarity = cp.rarity
  LEFT JOIN mv_pokemon_premium_change pc ON pc.pokemon_key = cp.pokemon_key
  LEFT JOIN mv_meta_relevance mr ON mr.card_id = cp.card_id AND mr.variant_key = cp.variant_key
  WHERE cp.price_market / co.cohort_median > 1.5  -- trading at >=1.5x cohort median
    AND COALESCE(pc.premium_delta, 0) <= 0        -- Pokemon premium flat or falling
)
SELECT
  s.card_id, s.variant_key, s.name, s.set_name, s.set_id, s.number, s.rarity, s.supertype,
  s.pokemon_key,
  COALESCE(p.name, s.pokemon_key) AS pokemon_name,
  p.generation, p.types, s.release_date,
  ROUND(s.price_market, 2)            AS current_price,
  ROUND(s.cohort_median, 2)           AS cohort_median,
  s.cohort_size,
  ROUND(s.above_cohort_ratio, 3)      AS above_cohort_ratio,
  ROUND(s.pokemon_premium_delta, 2)   AS pokemon_premium_delta,
  ROUND(s.meta_score, 3)              AS meta_score,
  -- composite_sell_score: how overvalued * (1 + magnitude of Pokemon decline)
  ROUND(
    (s.above_cohort_ratio - 1) * (1 + LEAST(GREATEST(-s.pokemon_premium_delta, 0), 5)),
    3
  ) AS composite_sell_score
FROM scored s
LEFT JOIN dim_pokemon p ON p.pokemon_key = s.pokemon_key;

-- =================================================================================
-- mv_inventory_value: current-snapshot value of the user's inventory, joined
-- against the latest fact_price for the matching (card, variant, condition).
-- One row per inventory line. Downstream rollups (by set / pokemon / rarity)
-- are easy queries from here.
-- =================================================================================
DROP TABLE IF EXISTS mv_inventory_value;
CREATE TABLE mv_inventory_value AS
WITH latest_inventory AS (
  -- Canonical "what you currently own" = your most recent snapshot.
  -- If a row from an older snapshot isn't in the latest, it's been sold or removed.
  SELECT * FROM fact_inventory_snapshot
  WHERE snapshot_date = (SELECT MAX(snapshot_date) FROM fact_inventory_snapshot)
),
latest_price AS (
  SELECT card_id, variant_key, condition_id, price_market
  FROM fact_price
  WHERE captured_at = (SELECT captured_at FROM mv_snapshot_meta WHERE role='current')
)
SELECT
  i.snapshot_date AS inventory_as_of,
  i.card_id, i.variant_key, i.condition_id,
  c.name, c.set_id, s.name AS set_name, s.release_date AS set_release_date,
  c.number, c.rarity, c.supertype, c.pokemon_key, p.name AS pokemon_name, p.generation,
  i.qty,
  ROUND(lp.price_market, 2) AS unit_market_price,
  ROUND(i.qty * lp.price_market, 2) AS line_value,
  i.unit_cost_paid,
  CASE WHEN i.unit_cost_paid IS NOT NULL
       THEN ROUND(i.qty * (lp.price_market - i.unit_cost_paid), 2)
       ELSE NULL END AS line_pl
FROM latest_inventory i
LEFT JOIN dim_card c ON c.card_id = i.card_id
LEFT JOIN dim_set s ON s.set_id = c.set_id
LEFT JOIN dim_pokemon p ON p.pokemon_key = c.pokemon_key
LEFT JOIN latest_price lp ON lp.card_id = i.card_id
                          AND lp.variant_key = i.variant_key
                          AND lp.condition_id = i.condition_id;

-- =================================================================================
-- mv_inventory_snapshot_history: per-snapshot total inventory value, lets you
-- see how the collection has moved over time.
-- =================================================================================
DROP TABLE IF EXISTS mv_inventory_snapshot_history;
CREATE TABLE mv_inventory_snapshot_history AS
SELECT
  i.snapshot_date,
  COUNT(DISTINCT i.card_id)                                  AS unique_cards,
  SUM(i.qty)                                                 AS total_copies,
  COUNT(DISTINCT c.set_id)                                   AS distinct_sets,
  COUNT(DISTINCT c.pokemon_key) FILTER (WHERE c.supertype LIKE 'Pok%') AS distinct_pokemon,
  ROUND(SUM(i.qty * fp.price_market), 2)                     AS value_at_snapshot_market,
  ROUND(SUM(i.qty * fp.price_low),    2)                     AS value_at_snapshot_low,
  ROUND(SUM(i.qty * fp.price_high),   2)                     AS value_at_snapshot_high
FROM fact_inventory_snapshot i
JOIN dim_card c ON c.card_id = i.card_id
JOIN fact_price fp ON fp.card_id = i.card_id
                  AND fp.variant_key = i.variant_key
                  AND fp.condition_id = i.condition_id
                  AND fp.captured_at::DATE = i.snapshot_date
GROUP BY i.snapshot_date
ORDER BY i.snapshot_date;

-- =================================================================================
-- mv_set_completion: for every set that has at least one card you own, how
-- many distinct cards do you have / how many are in the set / what's the
-- value of your holdings / what's the total set value (NM at primary variant).
-- =================================================================================
DROP TABLE IF EXISTS mv_set_completion;
CREATE TABLE mv_set_completion AS
WITH primary_variant_price AS (
  SELECT
    fp.card_id, c.set_id, fp.price_market,
    CASE
      WHEN c.rarity IN ('Common','Uncommon','Rare') THEN
        CASE fp.variant_key WHEN 'normal' THEN 1 WHEN 'reverseHolofoil' THEN 2 WHEN 'holofoil' THEN 3 ELSE 9 END
      ELSE
        CASE fp.variant_key WHEN 'holofoil' THEN 1 WHEN 'reverseHolofoil' THEN 2 WHEN 'normal' THEN 3 ELSE 9 END
    END AS variant_priority
  FROM fact_price fp JOIN dim_card c ON c.card_id = fp.card_id
  WHERE fp.captured_at = (SELECT captured_at FROM mv_snapshot_meta WHERE role='current')
    AND fp.condition_id='NM' AND fp.price_market > 0
),
canonical_price AS (
  SELECT card_id, set_id, price_market
  FROM primary_variant_price
  QUALIFY ROW_NUMBER() OVER (PARTITION BY card_id ORDER BY variant_priority, price_market DESC) = 1
),
set_totals AS (
  SELECT set_id,
         COUNT(*)                 AS priced_cards_in_set,
         ROUND(SUM(price_market), 2) AS total_set_value_nm
  FROM canonical_price GROUP BY set_id
),
inventory_per_set AS (
  SELECT c.set_id,
         COUNT(DISTINCT i.card_id) AS distinct_cards_owned,
         SUM(i.qty)                AS total_copies_owned,
         ROUND(SUM(i.qty * mv.unit_market_price), 2) AS owned_value
  FROM mv_inventory_value mv
  JOIN fact_inventory_snapshot i USING (card_id, variant_key, condition_id)
  JOIN dim_card c ON c.card_id = mv.card_id
  WHERE i.snapshot_date = (
    SELECT MAX(snapshot_date) FROM fact_inventory_snapshot
  )
  GROUP BY c.set_id
)
SELECT
  s.set_id,
  s.name AS set_name,
  s.series,
  s.release_date,
  s.printed_total,
  COALESCE(st.priced_cards_in_set, 0) AS priced_cards_in_set,
  COALESCE(ips.distinct_cards_owned, 0) AS distinct_cards_owned,
  COALESCE(ips.total_copies_owned, 0) AS total_copies_owned,
  ROUND(100.0 * COALESCE(ips.distinct_cards_owned, 0)
       / NULLIF(COALESCE(st.priced_cards_in_set, s.printed_total), 0), 1) AS completion_pct,
  COALESCE(ips.owned_value, 0) AS owned_value,
  st.total_set_value_nm,
  ROUND(100.0 * COALESCE(ips.owned_value, 0)
       / NULLIF(st.total_set_value_nm, 0), 1) AS value_completion_pct
FROM dim_set s
JOIN inventory_per_set ips ON ips.set_id = s.set_id
LEFT JOIN set_totals    st  ON st.set_id  = s.set_id
ORDER BY ips.owned_value DESC;

-- =================================================================================
-- Summary: counts of each materialized view, sanity check.
-- =================================================================================
SELECT 'mv_top_movers'                AS view, COUNT(*) AS rows FROM mv_top_movers
UNION ALL SELECT 'mv_pokemon_index',           COUNT(*) FROM mv_pokemon_index
UNION ALL SELECT 'mv_pokemon_premium',         COUNT(*) FROM mv_pokemon_premium
UNION ALL SELECT 'mv_pokemon_premium_by_rarity',COUNT(*) FROM mv_pokemon_premium_by_rarity
UNION ALL SELECT 'mv_pokemon_premium_change',  COUNT(*) FROM mv_pokemon_premium_change
UNION ALL SELECT 'mv_meta_relevance',           COUNT(*) FROM mv_meta_relevance
UNION ALL SELECT 'mv_buy_signals',              COUNT(*) FROM mv_buy_signals
UNION ALL SELECT 'mv_sell_signals',             COUNT(*) FROM mv_sell_signals
UNION ALL SELECT 'mv_inventory_value',          COUNT(*) FROM mv_inventory_value
UNION ALL SELECT 'mv_inventory_snapshot_history', COUNT(*) FROM mv_inventory_snapshot_history
UNION ALL SELECT 'mv_set_completion',           COUNT(*) FROM mv_set_completion
UNION ALL SELECT 'mv_rarity_index',            COUNT(*) FROM mv_rarity_index
UNION ALL SELECT 'mv_set_value',               COUNT(*) FROM mv_set_value
UNION ALL SELECT 'mv_artist_premium',          COUNT(*) FROM mv_artist_premium
UNION ALL SELECT 'mv_variant_premium',         COUNT(*) FROM mv_variant_premium
ORDER BY view;
