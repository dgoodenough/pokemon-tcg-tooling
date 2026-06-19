# Imports a TCGPlayer Pricing Custom Export CSV into fact_price.
# Resolution strategy: each row -> (set_id, number) lookup against dim_card,
# then insert into fact_price with source_id='tcgplayer'. Unresolved rows
# accumulate into card_alias as quarantine entries for later manual review.
#
# Usage: .\import_tcgplayer_prices.ps1 -CsvPath "...\file.csv"
# Filename should encode the capture date as YYYYMMDD_HHMMSS.
param(
    [Parameter(Mandatory=$true)][string]$CsvPath
)

. "$PSScriptRoot\common.ps1"

# ---------- Capture date from filename ----------
# Filenames look like: TCGplayer__Pricing_Custom_Export_20230904_120008.csv
$captureAt = $null
if ((Split-Path -Leaf $CsvPath) -match '_(\d{8})_(\d{6})\.csv$') {
    $d = $matches[1]; $t = $matches[2]
    $captureAt = ('{0}-{1}-{2} {3}:{4}:{5}' -f $d.Substring(0,4), $d.Substring(4,2), $d.Substring(6,2), $t.Substring(0,2), $t.Substring(2,2), $t.Substring(4,2))
}
if (-not $captureAt) { throw 'Could not extract capture datetime from filename.' }
Write-Host "Capture timestamp: $captureAt"

# ---------- Set-name resolver ----------
# Strip TCGPlayer's prefixes ("SWSH08: ", "SV01: ", "SM - ") and accept either match.
# We build a (normalized_name -> set_id) lookup from dim_set.
$setLookup = @{}
$rows = & $script:DuckDb -csv $script:DbPath "SELECT set_id, name FROM dim_set;"
foreach ($line in ($rows -split "`n" | Select-Object -Skip 1)) {
    if (-not $line.Trim()) { continue }
    $parts = $line -split ',', 2
    if ($parts.Length -lt 2) { continue }
    $sid = $parts[0].Trim('"')
    $name = $parts[1].Trim('"')
    $normalized = ($name -replace '[^a-zA-Z0-9]', '').ToLower()
    $setLookup[$normalized] = $sid
    # Also alias common shortened forms
    $shortName = ($name -replace '\s*&\s*', 'and') -replace '[^a-zA-Z0-9]', ''
    $setLookup[$shortName.ToLower()] = $sid
}
Write-Host ('  set name lookup: {0} entries' -f $setLookup.Count)

# Manual aliases for TCGPlayer set names that don't normalize cleanly to a single dim_set entry.
# Built from `card_alias` quarantine analysis. Empty string = recognized but no dim_set mapping
# (e.g., WCD reprints aren't in pokemontcg.io's catalog).
$tcgSetAliases = @{
    # ---- Unmappable buckets (recognized but no canonical set in dim_set) ----
    'World Championship Decks'         = ''     # multi-set bundle, original cards live in their own sets
    'Deck Exclusives'                  = ''     # theme-deck non-holos, need Product Name parsing
    'Miscellaneous Cards & Products'   = ''     # catch-all
    'Prize Pack Series Cards'          = ''     # reprints, need Product Name parsing
    'Alternate Art Promos'             = ''     # varied origins
    'Jumbo Cards'                      = ''     # oversized, no standard equivalent
    'League & Championship Cards'      = ''     # varied origins, mostly stamps
    'Blister Exclusives'               = ''     # varied origins
    'Trading Card Game Classic'        = ''     # 2023 boxed product, not in pokemontcg.io
    'Player Placement Trainer Promos'  = ''     # collector-show distribution
    'Kids WB Promos'                   = ''     # tiny set, not catalogued

    # ---- Trainer Kits not in dim_set (left empty until/unless seeded) ----
    'XY Trainer Kit: Bisharp & Wigglytuff'      = ''
    'XY Trainer Kit: Sylveon & Noivern'         = ''
    'XY Trainer Kit: Pikachu Libre & Suicune'   = ''
    'XY Trainer Kit: Latias & Latios'           = ''
    'SM Trainer Kit: Lycanroc & Alolan Raichu'  = ''
    'SM Trainer Kit: Alolan Sandslash & Alolan Ninetales' = ''
    'BW Trainer Kit: Excadrill & Zoroark'       = ''
    'HGSS Trainer Kit: Gyarados & Raichu'       = ''

    # ---- Battle Academy products (not in pokemontcg.io) ----
    'Battle Academy'                   = ''
    'Battle Academy 2022'              = ''
    'Battle Academy 2024'              = ''

    # ---- WOTC ----
    'Base Set'                         = 'base1'
    'Base Set (Shadowless)'            = 'base1'   # shadowless is a printing of Base Set
    'WoTC Promo'                       = 'basep'

    # ---- EX/DP/HGSS era promos ----
    'Nintendo Promos'                  = 'np'
    'Diamond and Pearl Promos'         = 'dpp'
    'HGSS Promos'                      = 'hsp'

    # ---- BW era ----
    'Black and White Promos'           = 'bwp'
    'Black and White'                  = 'bw1'
    'Plasma Storm'                     = 'bw8'    # was wrong: bw9 is Plasma Freeze
    'Plasma Freeze'                    = 'bw9'
    'Plasma Blast'                     = 'bw10'
    'Boundaries Crossed'               = 'bw7'
    'Next Destinies'                   = 'bw4'    # was wrong: bw5 is Dark Explorers
    'Dark Explorers'                   = 'bw5'
    'Emerging Powers'                  = 'bw2'
    'Dragons Exalted'                  = 'bw6'
    'Legendary Treasures'              = 'bw11'
    'Dragon Vault'                     = 'dv1'
    'Noble Victories'                  = 'bw3'

    # ---- XY era ----
    'XY Promos'                        = 'xyp'
    'XY Base Set'                      = 'xy1'
    'Kalos Starter Set'                = 'xy0'

    # ---- SM era ----
    'SM Base Set'                      = 'sm1'
    'SM Promos'                        = 'smp'
    'Shining Legends'                  = 'sm35'
    'Dragon Majesty'                   = 'sm75'
    'Detective Pikachu'                = 'det1'
    'Hidden Fates'                     = 'sm115'
    'Hidden Fates Shiny Vault'         = 'sma'

    # ---- SwSh era ----
    'SWSH01: Sword & Shield Base Set'  = 'swsh1'
    'SWSH10: Astral Radiance'          = 'swsh10'
    'SWSH: Sword & Shield Promo Cards' = 'swshp'
    'SWSH: Crown Zenith'               = 'swsh12pt5'
    'SWSH: Crown Zenith: Galarian Gallery' = 'swsh12pt5gg'
    'Pokemon GO'                       = 'pgo'
    'Shining Fates'                    = 'swsh45'
    'Shining Fates Shiny Vault'        = 'swsh45sv'
    'Celebrations'                     = 'cel25'
    'Celebrations: Classic Collection' = 'cel25c'

    # ---- SV era (the big recovery bucket) ----
    'SV01: Scarlet & Violet Base Set'  = 'sv1'
    'SV02: Paldea Evolved'             = 'sv2'
    'SV03: Obsidian Flames'            = 'sv3'
    'SV: Scarlet & Violet 151'         = 'sv3pt5'
    'SV: Paradox Rift'                 = 'sv4'
    'SV: Paldean Fates'                = 'sv4pt5'
    'SV: Temporal Forces'              = 'sv5'
    'SV: Twilight Masquerade'          = 'sv6'
    'SV: Shrouded Fable'               = 'sv6pt5'
    'SV: Stellar Crown'                = 'sv7'
    'SV: Surging Sparks'               = 'sv8'
    'SV: Prismatic Evolutions'         = 'sv8pt5'
    'SV09: Journey Together'           = 'sv9'
    'SV: Journey Together'             = 'sv9'
    'SV10: Destined Rivals'            = 'sv10'
    'SV: Destined Rivals'              = 'sv10'
    'SV: White Flare'                  = 'rsv10pt5'
    'SV: Black Bolt'                   = 'zsv10pt5'
    'SV: Scarlet & Violet Promo Cards' = 'svp'

    # ---- Mega Evolution era (newest) ----
    'ME01: Mega Evolution'             = 'me1'
    'ME: Mega Evolution'               = 'me1'
    'ME02: Phantasmal Flames'          = 'me2'
    'ME: Phantasmal Flames'            = 'me2'
    'ME: Ascended Heroes'              = 'me2pt5'
    'ME03: Perfect Order'              = 'me3'
    'ME: Perfect Order'                = 'me3'
    'ME: Chaos Rising'                 = 'me4'
    'ME: Mega Evolution Promo'         = ''      # MEP set not in dim_set yet

    # ---- Older direct mappings (carried forward from earlier work) ----
    'Expedition'                       = 'ecard1'
    'Triumphant'                       = 'hgss4'
    'Unleashed'                        = 'hgss2'
    'Undaunted'                        = 'hgss3'
    'HeartGold SoulSilver'             = 'hgss1'
    'Call of Legends'                  = 'col1'
    'McDonald''s Collection 2022'      = 'mcd22'
}

function Resolve-SetId {
    param([string]$TcgSetName)
    if (-not $TcgSetName) { return $null }
    # Hard alias first (covers special cases that don't normalize cleanly)
    if ($tcgSetAliases.ContainsKey($TcgSetName)) { return $tcgSetAliases[$TcgSetName] }
    # Strip code prefix like "SWSH08: ", "SV01: ", "SM - ", "XY - "
    $stripped = $TcgSetName `
        -replace '^[A-Z]+\d+:\s*', '' `
        -replace '^[A-Z]+\s*-\s*', '' `
        -replace '^Sw_Shield\s*-\s*', '' `
        -replace '^Sw_Sh\s*-\s*', ''
    # Strip trailing "Base Set" (the "SV01: ... Base Set" form usually means the base/main set of that series)
    $stripped = $stripped -replace '\s+Base\s+Set\s*$',''
    $norm = ($stripped -replace '[^a-zA-Z0-9]', '').ToLower()
    if ($setLookup.ContainsKey($norm)) { return $setLookup[$norm] }
    # Try the original name too (some are already clean)
    $norm2 = ($TcgSetName -replace '[^a-zA-Z0-9]', '').ToLower()
    if ($setLookup.ContainsKey($norm2)) { return $setLookup[$norm2] }
    return $null
}

# ---------- Condition + variant mapping ----------
$conditionMap = @{
    'Near Mint'         = 'NM'
    'Lightly Played'    = 'LP'
    'Moderately Played' = 'MP'
    'Heavily Played'    = 'HP'
    'Damaged'           = 'DMG'
}

# TCGPlayer condition strings can carry a variant suffix, e.g.
#   "Lightly Played Reverse Holofoil", "Near Mint 1st Edition Holofoil".
# Longest-match-first so '1st Edition Holofoil' beats '1st Edition'.
$conditionVariantSuffixes = @(
    @{ suffix='1st Edition Holofoil'; variant='1stEditionHolofoil' }
    @{ suffix='Unlimited Holofoil';   variant='unlimitedHolofoil' }
    @{ suffix='Reverse Holofoil';     variant='reverseHolofoil' }
    @{ suffix='1st Edition';          variant='1stEdition' }
    @{ suffix='Unlimited';            variant='unlimited' }
    @{ suffix='Holofoil';             variant='holofoil' }
)

function Split-ConditionAndVariant {
    # Returns @{ condId; variant } or $null if condition is unparseable / sealed.
    param([string]$ConditionRaw)
    if (-not $ConditionRaw) { return $null }
    if ($ConditionRaw -eq 'Unopened') { return $null }   # Sealed product — out of scope for fact_price.
    foreach ($s in $conditionVariantSuffixes) {
        if ($ConditionRaw -match ("\s+" + [regex]::Escape($s.suffix) + "\s*$")) {
            $baseCond = ($ConditionRaw -replace ("\s+" + [regex]::Escape($s.suffix) + "\s*$"), '').Trim()
            if ($conditionMap.ContainsKey($baseCond)) {
                return @{ condId = $conditionMap[$baseCond]; variant = $s.variant }
            }
            return $null
        }
    }
    # No variant suffix — Condition is just the grade.
    if ($conditionMap.ContainsKey($ConditionRaw.Trim())) {
        return @{ condId = $conditionMap[$ConditionRaw.Trim()]; variant = $null }
    }
    return $null
}

function Get-VariantFromProductName {
    param([string]$ProductName, [string]$Number)
    # The Product Name occasionally encodes the printing in parentheses at the end:
    #   "Foo (Holo)", "Foo (Non-Holo)", "Foo (Reverse Holo)", "Foo (Cosmos Holo)",
    #   "Foo (1st Edition)", "Foo (#15 - Non-Holo)" etc.
    # Default to 'normal' when no marker is present.
    if (-not $ProductName) { return 'normal' }
    if ($ProductName -match '(?i)\(.*Reverse\s+Holo.*\)')       { return 'reverseHolofoil' }
    if ($ProductName -match '(?i)\(.*Cosmos\s+Holo.*\)')        { return 'cosmosHolofoil' }
    if ($ProductName -match '(?i)\(.*Non[\-\s]?Holo.*\)')       { return 'nonHoloDeck' }
    if ($ProductName -match '(?i)\(.*1st\s+Edition\s+Holo.*\)') { return '1stEditionHolofoil' }
    if ($ProductName -match '(?i)\(.*1st\s+Edition.*\)')        { return '1stEdition' }
    if ($ProductName -match '(?i)\(.*Unlimited\s+Holo.*\)')     { return 'unlimitedHolofoil' }
    if ($ProductName -match '(?i)\(.*Unlimited.*\)')            { return 'unlimited' }
    if ($ProductName -match '(?i)\(.*Holo.*\)')                 { return 'holofoil' }
    if ($ProductName -match '(?i)\(.*Stamp.*\)')                { return 'stampedPromo' }
    return 'normal'
}

function Normalize-Number {
    param([string]$Number)
    # Examples in the CSV: "067/147", "182b/214", "098a/122", "SM166"
    # Goal: produce a key that matches dim_card.number, which strips the "/total" and zero padding.
    if (-not $Number) { return $null }
    $n = $Number.Trim()
    if ($n -match '^(.+?)/') { $n = $matches[1] }
    # Strip leading zeros from the numeric portion only (keep any letter suffix like 'a', 'b')
    if ($n -match '^(\d+)([A-Za-z]?)$') {
        $num = [int]$matches[1]; $suffix = $matches[2]
        return "$num$suffix"
    }
    return $n
}

# ---------- Pass 1: extract distinct (set_name, number) keys and resolve them in DuckDB in one shot ----------
# Reading 14k rows row-by-row through CLI calls would be glacial. Instead, build a staging CSV
# containing { row_id, set_name_raw, set_id_guessed, number_raw, number_norm, product_name,
#              condition, market, low, low_with_ship, direct_low, total_qty }, COPY it into a
# temp table, then do all the joins in SQL.

$stagingCsv = Join-Path $script:RawDir '_stage_tcgplayer.csv'
$rows = New-Object System.Collections.ArrayList
[void]$rows.Add('row_id,set_name_raw,set_id_guessed,number_raw,number_norm,product_name,variant_key,condition_id_guessed,condition_raw,market,low,low_with_ship,direct_low,total_qty')

Write-Host 'Reading and pre-resolving rows...'
$csvRows = Import-Csv -Path $CsvPath
$rowId = 0; $skippedNonPokemon = 0; $skippedSealed = 0
foreach ($r in $csvRows) {
    $rowId++
    if ($r.'Product Line' -ne 'Pokemon') { $skippedNonPokemon++; continue }

    # Condition column is authoritative: it encodes both grade and variant (e.g.,
    # "Lightly Played Reverse Holofoil"). Falls back to Product Name parsing when the
    # condition has no variant suffix (older catalogs, sealed/Promo rows).
    $cv = Split-ConditionAndVariant -ConditionRaw $r.Condition
    if (-not $cv) { $skippedSealed++; continue }
    $condId = $cv.condId
    $variant = if ($cv.variant) { $cv.variant } else { Get-VariantFromProductName -ProductName $r.'Product Name' -Number $r.Number }

    $setId = Resolve-SetId -TcgSetName $r.'Set Name'
    $numNorm = Normalize-Number -Number $r.Number

    # tcgplayer_id is just the source row's TCGplayer Id, used as the external_id for card_alias
    $row = @(
        ConvertTo-CsvField $r.'TCGplayer Id'
        ConvertTo-CsvField $r.'Set Name'
        ConvertTo-CsvField $setId
        ConvertTo-CsvField $r.Number
        ConvertTo-CsvField $numNorm
        ConvertTo-CsvField $r.'Product Name'
        ConvertTo-CsvField $variant
        ConvertTo-CsvField $condId
        ConvertTo-CsvField $r.Condition
        ConvertTo-CsvField $r.'TCG Market Price'
        ConvertTo-CsvField $r.'TCG Low Price'
        ConvertTo-CsvField $r.'TCG Low Price With Shipping'
        ConvertTo-CsvField $r.'TCG Direct Low'
        ConvertTo-CsvField $r.'Total Quantity'
    ) -join ','
    [void]$rows.Add($row)
}

Write-Utf8 -Path $stagingCsv -Content ($rows -join "`n")
Write-Host ('  staged {0} Pokemon rows ({1} non-Pokemon skipped)' -f ($rows.Count - 1), $skippedNonPokemon)

# ---------- Pass 2: load into a temp DuckDB table, resolve to card_id, write fact_price + quarantine ----------
# Clear prior runs of THIS snapshot so re-imports are idempotent
$cleanup = @"
DELETE FROM fact_price   WHERE captured_at = TIMESTAMP '$captureAt' AND source_id = 'tcgplayer';
DELETE FROM card_alias   WHERE source_id = 'tcgplayer' AND card_id IS NULL;
"@
Invoke-Duck -Sql $cleanup

$sql = @"
DROP TABLE IF EXISTS stage_tcg;
CREATE TABLE stage_tcg AS SELECT * FROM read_csv_auto('$($stagingCsv -replace '\\','/')', header=true);

-- Resolve to card_id via (set_id, number_norm)
DROP TABLE IF EXISTS resolved_tcg;
CREATE TABLE resolved_tcg AS
SELECT
  s.*,
  c.card_id
FROM stage_tcg s
LEFT JOIN dim_card c
  ON c.set_id = s.set_id_guessed
  AND c.number = s.number_norm;

SELECT
  COUNT(*) AS total_rows,
  COUNT(card_id) AS matched,
  COUNT(*) - COUNT(card_id) AS unmatched,
  SUM(CASE WHEN set_id_guessed IS NULL OR set_id_guessed = '' THEN 1 ELSE 0 END) AS unmatched_set,
  SUM(CASE WHEN condition_id_guessed IS NULL OR condition_id_guessed = '' THEN 1 ELSE 0 END) AS unmatched_condition
FROM resolved_tcg;

-- Insert matched rows into fact_price
INSERT INTO fact_price (captured_at, card_id, variant_key, condition_id, source_id, price_low, price_market, price_mid, price_high, listing_count)
SELECT
  TIMESTAMP '$captureAt' AS captured_at,
  card_id,
  variant_key,
  condition_id_guessed AS condition_id,
  'tcgplayer'          AS source_id,
  TRY_CAST(low AS DECIMAL(10,2))           AS price_low,
  TRY_CAST(market AS DECIMAL(10,2))        AS price_market,
  NULL                                     AS price_mid,
  TRY_CAST(low_with_ship AS DECIMAL(10,2)) AS price_high,
  TRY_CAST(total_qty AS INTEGER)           AS listing_count
FROM resolved_tcg
WHERE card_id IS NOT NULL
  AND condition_id_guessed <> ''
ON CONFLICT (captured_at, card_id, variant_key, condition_id, source_id) DO NOTHING;

-- Dual-write: rows with Total Quantity > 0 are the seller's actual inventory.
-- Upsert into fact_inventory_snapshot keyed by snapshot_date (no time-of-day).
INSERT INTO fact_inventory_snapshot (snapshot_date, card_id, variant_key, condition_id, qty)
SELECT
  DATE_TRUNC('day', TIMESTAMP '$captureAt')::DATE AS snapshot_date,
  card_id,
  variant_key,
  condition_id_guessed AS condition_id,
  TRY_CAST(total_qty AS INTEGER) AS qty
FROM resolved_tcg
WHERE card_id IS NOT NULL
  AND condition_id_guessed <> ''
  AND TRY_CAST(total_qty AS INTEGER) > 0
ON CONFLICT (snapshot_date, card_id, variant_key, condition_id) DO UPDATE SET qty = excluded.qty;

-- Quarantine unmatched rows into card_alias so we can review patterns
INSERT INTO card_alias (source_id, external_id, card_id, variant_key, confidence, notes)
SELECT
  'tcgplayer' AS source_id,
  row_id      AS external_id,
  NULL        AS card_id,
  variant_key,
  'auto-quarantined' AS confidence,
  'set=' || COALESCE(set_name_raw,'')
  || ' | guessed_set=' || COALESCE(set_id_guessed,'NULL')
  || ' | num=' || COALESCE(number_raw,'')
  || ' | product=' || COALESCE(product_name,'') AS notes
FROM resolved_tcg
WHERE card_id IS NULL
ON CONFLICT (source_id, external_id) DO NOTHING;

-- Stats
SELECT 'fact_price total rows' AS metric, COUNT(*) AS n FROM fact_price
UNION ALL SELECT 'distinct cards with prices', COUNT(DISTINCT card_id) FROM fact_price
UNION ALL SELECT 'card_alias quarantine rows', COUNT(*) FROM card_alias WHERE card_id IS NULL;
"@
Write-Host 'Loading staging table and resolving...'
Invoke-Duck -Sql $sql
