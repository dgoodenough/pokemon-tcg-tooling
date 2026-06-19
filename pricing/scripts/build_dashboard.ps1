# Builds a static HTML analytics dashboard from the materialized views,
# then prints it to PDF via Chrome headless (same flow as the checklists).
. "$PSScriptRoot\common.ps1"

$reportDir = Join-Path $script:DataRoot 'reports'
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null

# ---------- Helper: run a SQL query and return rows as a list of hashtables ----------
function Invoke-DuckCsv {
    param([string]$Sql)
    $tmp = New-TemporaryFile
    try {
        & $script:DuckDb -csv $script:DbPath $Sql | Set-Content $tmp.FullName -Encoding UTF8
        if ((Get-Item $tmp.FullName).Length -eq 0) { return @() }
        return @(Import-Csv $tmp.FullName)
    } finally { Remove-Item $tmp.FullName -Force -ErrorAction SilentlyContinue }
}

# ---------- Pull the data ----------
Write-Host 'Pulling materialized view data...'

$meta = Invoke-DuckCsv "SELECT snapshot_date, role FROM mv_snapshot_meta ORDER BY captured_at;"
$baseline = ($meta | Where-Object { $_.role -eq 'baseline' }).snapshot_date
$current  = ($meta | Where-Object { $_.role -eq 'current' }).snapshot_date

$topMoversPct  = Invoke-DuckCsv "SELECT name, set_name, number, rarity, artist, price_baseline, price_current, price_delta, pct_change FROM mv_top_movers ORDER BY pct_change DESC LIMIT 20;"
$topMoversAbs  = Invoke-DuckCsv "SELECT name, set_name, number, rarity, price_baseline, price_current, price_delta, pct_change FROM mv_top_movers WHERE price_baseline >= 10 ORDER BY price_delta DESC LIMIT 15;"
$pokemonTop    = Invoke-DuckCsv "SELECT pokemon_name, generation, types, card_count, total_value_baseline, total_value_current, pct_change FROM mv_pokemon_index ORDER BY pct_change DESC LIMIT 25;"
$pokemonByGen  = Invoke-DuckCsv @"
SELECT generation,
       COUNT(*)                                                       AS pokemon_count,
       COUNT(*) FILTER (WHERE pct_change IS NOT NULL)                 AS pokemon_with_trend,
       ROUND(SUM(total_value_current), 0)                             AS total_value_now,
       ROUND(MEDIAN(total_value_current), 0)                          AS median_total_per_pokemon,
       ROUND(AVG(pct_change)    FILTER (WHERE pct_change IS NOT NULL), 1) AS avg_pct_change,
       ROUND(MEDIAN(pct_change) FILTER (WHERE pct_change IS NOT NULL), 1) AS median_pct_change
FROM mv_pokemon_index
WHERE generation IS NOT NULL
GROUP BY generation ORDER BY generation;
"@
$rarityIndex   = Invoke-DuckCsv "SELECT rarity, card_count, median_baseline, median_current, median_pct_change, weighted_pct_change FROM mv_rarity_index;"
$setIndex      = Invoke-DuckCsv "SELECT set_name, release_date, priced_current, total_value_baseline, total_value_current, pct_change FROM mv_set_value WHERE pct_change IS NOT NULL ORDER BY pct_change DESC LIMIT 20;"
$setColdest    = Invoke-DuckCsv "SELECT set_name, release_date, priced_current, total_value_current, pct_change FROM mv_set_value WHERE pct_change IS NOT NULL AND total_value_baseline > 50 ORDER BY pct_change ASC LIMIT 10;"
$artistTop     = Invoke-DuckCsv "SELECT artist, card_count, median_price, premium_x FROM mv_artist_premium ORDER BY median_price DESC LIMIT 15;"
$variantPrem   = Invoke-DuckCsv "SELECT * FROM mv_variant_premium;"

# Inventory views
$inventorySummary = Invoke-DuckCsv @"
SELECT
  COUNT(*) AS lines,
  SUM(qty) AS copies,
  COUNT(DISTINCT card_id) AS distinct_cards,
  ROUND(SUM(line_value), 2) AS total_value
FROM mv_inventory_value WHERE line_value IS NOT NULL;
"@
$inventoryHistory = Invoke-DuckCsv "SELECT snapshot_date, unique_cards, total_copies, distinct_sets, distinct_pokemon, value_at_snapshot_market FROM mv_inventory_snapshot_history ORDER BY snapshot_date;"
$inventoryTopLines = Invoke-DuckCsv @"
SELECT name, set_name, number, variant_key, condition_id, qty,
       unit_market_price, line_value
FROM mv_inventory_value
WHERE line_value IS NOT NULL
ORDER BY line_value DESC LIMIT 15;
"@
$inventoryBySet = Invoke-DuckCsv @"
SELECT set_name, distinct_cards_owned, total_copies_owned,
       owned_value, priced_cards_in_set, completion_pct, total_set_value_nm, value_completion_pct
FROM mv_set_completion
ORDER BY owned_value DESC LIMIT 15;
"@
$inventoryByGen = Invoke-DuckCsv @"
SELECT generation, COUNT(*) AS lines, SUM(qty) AS copies, ROUND(SUM(line_value),2) AS value
FROM mv_inventory_value
WHERE generation IS NOT NULL AND line_value IS NOT NULL
GROUP BY generation ORDER BY generation;
"@

# Buy / sell signals
$buySignals = Invoke-DuckCsv @"
SELECT name, set_name, number, rarity, pokemon_name, generation, current_price, cohort_median,
       below_cohort_ratio, pokemon_premium_delta, composite_buy_score
FROM mv_buy_signals
WHERE current_price >= 1
ORDER BY composite_buy_score DESC LIMIT 15;
"@
$sellSignals = Invoke-DuckCsv @"
SELECT name, set_name, number, rarity, pokemon_name, generation, current_price, cohort_median,
       above_cohort_ratio, pokemon_premium_delta, composite_sell_score
FROM mv_sell_signals
ORDER BY composite_sell_score DESC LIMIT 15;
"@

# Pokemon premium views (rarity-controlled)
$pokemonPremium = Invoke-DuckCsv "SELECT pokemon_name, generation, card_count, median_price, median_premium, avg_premium, p75_premium, max_premium FROM mv_pokemon_premium WHERE card_count >= 10 ORDER BY median_premium DESC LIMIT 25;"
$pokemonPremiumChange = Invoke-DuckCsv "SELECT pokemon_name, generation, card_count_baseline AS n_b, card_count_current AS n_c, premium_baseline, premium_current, premium_delta, pct_change FROM mv_pokemon_premium_change WHERE card_count_baseline >= 8 AND card_count_current >= 8 ORDER BY premium_delta DESC LIMIT 20;"
$pokemonPremiumLosers = Invoke-DuckCsv "SELECT pokemon_name, generation, card_count_baseline AS n_b, card_count_current AS n_c, premium_baseline, premium_current, premium_delta, pct_change FROM mv_pokemon_premium_change WHERE card_count_baseline >= 8 AND card_count_current >= 8 ORDER BY premium_delta ASC LIMIT 15;"
$pokemonByRarity = Invoke-DuckCsv "SELECT pokemon_name, rarity, card_count, median_price, rarity_median, median_premium FROM mv_pokemon_premium_by_rarity WHERE median_price >= 5 AND card_count >= 3 ORDER BY median_premium DESC LIMIT 30;"

# ---------- Encode all data as a single JSON blob for the HTML to consume ----------
$payload = @{
    baselineDate = $baseline
    currentDate  = $current
    generatedAt  = (Get-Date -Format 'yyyy-MM-dd HH:mm')
    topMoversPct = $topMoversPct
    topMoversAbs = $topMoversAbs
    pokemonTop   = $pokemonTop
    pokemonByGen = $pokemonByGen
    rarityIndex  = $rarityIndex
    setIndex     = $setIndex
    setColdest   = $setColdest
    artistTop             = $artistTop
    variantPrem           = $variantPrem
    pokemonPremium        = $pokemonPremium
    pokemonPremiumChange  = $pokemonPremiumChange
    pokemonPremiumLosers  = $pokemonPremiumLosers
    pokemonByRarity       = $pokemonByRarity
    buySignals            = $buySignals
    sellSignals           = $sellSignals
    inventorySummary      = $inventorySummary
    inventoryHistory      = $inventoryHistory
    inventoryTopLines     = $inventoryTopLines
    inventoryBySet        = $inventoryBySet
    inventoryByGen        = $inventoryByGen
}
$jsonPath = Join-Path $reportDir 'dashboard_data.json'
Write-Utf8 -Path $jsonPath -Content ($payload | ConvertTo-Json -Depth 8)
Write-Host "  Wrote $jsonPath"
