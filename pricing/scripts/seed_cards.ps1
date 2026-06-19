# Seeds dim_card from pokemontcg.io. Paginates the /cards endpoint and caches each page
# to raw/cards_pageNNN.json so re-runs are free (delete the page files to refetch).
. "$PSScriptRoot\common.ps1"

$pageDir = Join-Path $script:RawDir 'cards_pages'
New-Item -ItemType Directory -Force -Path $pageDir | Out-Null

$pageSize = 250
$page = 1
$total = $null

# ---------- Fetch all pages ----------
do {
    $pageFile = Join-Path $pageDir ('cards_page{0:D3}.json' -f $page)
    if ((Test-Path $pageFile) -and ((Get-Item $pageFile).Length -gt 100)) {
        Write-Host ('Page {0}: cached' -f $page)
    } else {
        $uri = "https://api.pokemontcg.io/v2/cards?pageSize=$pageSize&page=$page"
        $attempt = 0
        $maxAttempts = 5
        while ($attempt -lt $maxAttempts) {
            $attempt++
            try {
                Write-Host ('Page {0}: fetching (attempt {1})...' -f $page, $attempt)
                Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $pageFile -TimeoutSec 60
                Start-Sleep -Milliseconds 200
                break
            } catch {
                $wait = [int][math]::Pow(2, $attempt)
                Write-Host ('  attempt {0} failed: {1}. Retrying in {2}s...' -f $attempt, $_.Exception.Message, $wait)
                if (Test-Path $pageFile) { Remove-Item $pageFile -Force }
                if ($attempt -ge $maxAttempts) { throw "Failed to fetch page $page after $maxAttempts attempts." }
                Start-Sleep -Seconds $wait
            }
        }
    }
    $j = Read-Utf8Json -Path $pageFile
    if ($null -eq $total) { $total = $j.totalCount }
    $count = ($j.data | Measure-Object).Count
    Write-Host ('  page {0}: count={1} totalCount={2}' -f $page, $count, $total)
    if ($count -lt $pageSize) { break }
    $page++
} while ($true)

Write-Host ('Total pages fetched: {0}' -f $page)

# ---------- Pokemon-key normalizer ----------
function Get-PokemonKey {
    param([string]$CardName)
    if (-not $CardName) { return $null }
    $n = $CardName

    # 1. Replace gender symbols (must happen BEFORE non-alphanumeric stripping).
    #    ♀ = 0x2640, ♂ = 0x2642. Using [char] avoids script-source encoding issues.
    $n = $n -replace [char]0x2640, 'f'
    $n = $n -replace [char]0x2642, 'm'

    # 2. Normalize diacritics: é -> e, etc. (NFD decomposition + strip combining marks).
    $n = ($n.Normalize([System.Text.NormalizationForm]::FormD) -replace '\p{M}', '')

    # 3. Strip bracketed content: "Unown [R]" -> "Unown".
    $n = $n -replace '\[[^\]]*\]', ''

    # 4. Strip embellishments
    $n = $n -replace '\s*\(Delta Species\)\s*', ''
    $n = $n -replace '\s+d\s*$', ''   # delta symbol normalized to 'd' by step 2; strip trailing

    # Strip Greek delta (δ, U+03B4) — used as Delta Species marker even when not in parens.
    $n = $n -replace [char]0x03b4, ''

    # 5. Strip suffix modifiers (suffix first, then prefix)
    foreach ($pat in @(
        '\s+ex\s*$', '-EX\s*$', '-GX\s*$', '-V\s*$', '\s+V\s*$',
        '\s+VMAX\s*$', '\s+VSTAR\s*$', '\s+V-UNION\s*$',
        '\s+BREAK\s*$', '-BREAK\s*$', '\s+LV\.X\s*$',
        '\s+\{?\*\}?\s*$',
        # Form-name suffixes
        '\s+(Sandy|Plant|Trash) Cloak\s*$',           # Burmy / Wormadam cloak forms
        '\s+(Sunny|Rainy|Snowy|Rain|Snow-Cloud) Form\s*$',  # Castform weather forms (canonical + card variants)
        '\s+(Attack|Defense|Speed|Normal) Forme\s*$', # Deoxys formes
        '\s+(East|West) Sea\s*$',                     # Shellos / Gastrodon sea forms
        '\s+[XY]\s*$',                                # Mega Charizard X / Y, Mega Mewtwo X / Y
        '\s+LEGEND\s*$',                              # HGSS LEGEND tag cards (post tag-team split)
        # Set-specific stamps that aren't part of the species name
        '\s+E4\s*$',   # Elite Four stamp (HGSS-era)
        '\s+GL\s*$',   # Galactic Leader (DP-era)
        '\s+FB\s*$',   # Frontier Brain (DP-era)
        '\s+(G|C|4)\s*$',                       # G = Galactic / C = Champion / 4 = E4 single-letter stamps
        '\s+on the Ball\s*$'                    # Sun-and-Moon mascot variants
    )) {
        $n = $n -replace $pat, ''
    }

    # 6. Owner possessives: "Jasmine's Ampharos", "Team Rocket's Ampharos",
    #    "N's Zoroark", "Lt. Surge's Pikachu" (periods), "_____'s Pikachu"
    #    (underscores), "Imakuni?'s Doduo" (question marks).
    $n = $n -replace "^[A-Za-z_][A-Za-z._?]*(?:\s[A-Za-z_][A-Za-z._?]*)*'s\s+", ''

    # 7. Prefix modifiers. ORDER MATTERS: multi-word patterns MUST come before
    # single-word ones (e.g. '^Shadow Rider\s+' must beat '^Shadow\s+', else
    # 'Shadow Rider Calyrex' becomes 'Rider Calyrex' which then has no match).
    foreach ($pat in @(
        # ---- Multi-word form prefixes (must run first) ----
        '^Single Strike\s+', '^Rapid Strike\s+',            # Urshifu styles
        '^Teal Mask\s+', '^Hearthflame Mask\s+',
        '^Wellspring Mask\s+', '^Cornerstone Mask\s+',      # Ogerpon masks
        '^Ice Rider\s+', '^Shadow Rider\s+',                # Calyrex riders
        '^Dawn Wings\s+', '^Dusk Mane\s+',                  # Necrozma forms
        '^Special Delivery\s+',                             # SD distribution variants
        '^Origin Forme\s+', '^Altered Forme\s+', '^Therian Forme\s+',
        # ---- Single-word form prefixes ----
        '^Dark\s+', '^Light\s+', '^Shining\s+', '^Crystal\s+',
        '^Radiant\s+', '^Shadow\s+', '^Mega\s+', '^M\s+',
        '^Hisuian\s+', '^Galarian\s+', '^Alolan\s+', '^Paldean\s+',
        '^White\s+', '^Black\s+',                           # White/Black Kyurem
        '^Bloodmoon\s+',                                    # Ursaluna form
        '^Ultra\s+',                                        # Ultra Necrozma
        '^Primal\s+',                                       # Primal Groudon/Kyogre
        '^Flying\s+', '^Surfing\s+',                        # Pikachu costume variants
        '^Detective\s+',                                    # Detective Pikachu
        '^Fan\s+', '^Wash\s+', '^Heat\s+', '^Frost\s+', '^Mow\s+',  # Rotom forms
        '^Rain\s+', '^Sunny\s+', '^Snow-cloud\s+',          # Castform card-naming variants (form as prefix)
        '^Armored\s+',                                      # Armored Mewtwo
        '^Ash-',                                            # Ash-Greninja (hyphen, no space)
        '^Cool\s+', '^Buried\s+',                           # one-offs: Cool Porygon, Buried Fossil (rare)
        '^Iron Tail\s+'                                     # appendage modifier (rare)
    )) {
        $n = $n -replace $pat, ''
    }

    # 8. Tag teams: take the rightmost Pokemon name. Use a while loop so 3-way
    # tag teams like "Arceus & Dialga & Palkia-GX" resolve to "Palkia" not
    # "Dialga & Palkia" (the regex is leftmost-first and would otherwise stop
    # at the first &).
    while ($n -match '\s+&\s+(.+)$') { $n = $matches[1] }

    # 8b. After tag-team split the rightmost name may carry suffix modifiers
    # AND/OR a regional form prefix (e.g. "Alolan Muk-GX"). Re-run both.
    foreach ($pat in @('\s+LEGEND\s*$', '-GX\s*$', '-EX\s*$', '\s+ex\s*$', '\s+V\s*$', '\s+VMAX\s*$', '\s+VSTAR\s*$')) {
        $n = $n -replace $pat, ''
    }
    foreach ($pat in @(
        '^Hisuian\s+', '^Galarian\s+', '^Alolan\s+', '^Paldean\s+',
        '^Dark\s+', '^Light\s+', '^Shining\s+', '^Crystal\s+',
        '^Radiant\s+', '^Shadow\s+', '^Mega\s+', '^M\s+'
    )) {
        $n = $n -replace $pat, ''
    }

    # 9. Final: strip non-alphanumeric, lowercase
    $key = ($n.Trim() -replace '[^a-zA-Z0-9]', '').ToLower()
    return $key
}

# ---------- Build CSV ----------
$csvPath = Join-Path $script:RawDir '_seed_cards.csv'
$lines = New-Object System.Collections.ArrayList
[void]$lines.Add('card_id,set_id,number,number_sort,name,supertype,subtypes,rarity,hp,types,evolves_from,artist,nat_dex_numbers,pokemon_key,flavor_text,image_small,image_large,tcgplayer_id')

$totalProcessed = 0
foreach ($pf in (Get-ChildItem $pageDir -Filter 'cards_page*.json' | Sort-Object Name)) {
    $j = Read-Utf8Json -Path $pf.FullName
    foreach ($c in $j.data) {
        # number_sort: best effort numeric for ORDER BY
        $numClean = $c.number -replace '^[A-Za-z]+', ''
        $numClean = $numClean -replace '\D.*$', ''
        $numberSort = if ($numClean -match '^\d+$') { [int]$numClean } else { 99999 }

        $subtypes      = if ($c.subtypes)      { ($c.subtypes -join ',') }      else { '' }
        $types         = if ($c.types)         { ($c.types -join ',') }         else { '' }
        $natDexNumbers = if ($c.nationalPokedexNumbers) { ($c.nationalPokedexNumbers -join ',') } else { '' }
        # Use prefix match to avoid script-source UTF-8 vs Windows-1252 mismatch on the é literal.
        $pokemonKey    = if ($c.supertype -and $c.supertype.StartsWith('Pok')) { Get-PokemonKey -CardName $c.name } else { '' }
        $hp            = if ($c.hp -and $c.hp -match '^\d+$') { $c.hp } else { '' }
        $tcgId         = if ($c.tcgplayer.url) {
            # tcgplayer URL contains /product/<id>/. Pull it.
            if ($c.tcgplayer.url -match '/product/(\d+)') { $matches[1] } else { '' }
        } else { '' }

        $row = @(
            ConvertTo-CsvField $c.id
            ConvertTo-CsvField $c.set.id
            ConvertTo-CsvField $c.number
            ConvertTo-CsvField $numberSort
            ConvertTo-CsvField $c.name
            ConvertTo-CsvField $c.supertype
            ConvertTo-CsvField $subtypes
            ConvertTo-CsvField $c.rarity
            ConvertTo-CsvField $hp
            ConvertTo-CsvField $types
            ConvertTo-CsvField $c.evolvesFrom
            ConvertTo-CsvField $c.artist
            ConvertTo-CsvField $natDexNumbers
            ConvertTo-CsvField $pokemonKey
            ConvertTo-CsvField $c.flavorText
            ConvertTo-CsvField $c.images.small
            ConvertTo-CsvField $c.images.large
            ConvertTo-CsvField $tcgId
        ) -join ','
        [void]$lines.Add($row)
        $totalProcessed++
    }
}
Write-Host ('Total cards built: {0}' -f $totalProcessed)

Write-Utf8 -Path $csvPath -Content ($lines -join "`n")
Write-Host ('  Wrote CSV: {0}' -f $csvPath)

# ---------- Load into DuckDB ----------
$sql = @"
-- Load into a temp staging table so we don't have to fight foreign-key constraints
-- on dim_card. Then UPSERT: update existing rows, insert any new ones.
CREATE OR REPLACE TEMP TABLE _staging_card AS
SELECT * FROM read_csv_auto('$($csvPath -replace '\\','/')', header = true, nullstr = '');

-- Insert any cards not already present
INSERT INTO dim_card
SELECT s.* FROM _staging_card s
LEFT JOIN dim_card d ON d.card_id = s.card_id
WHERE d.card_id IS NULL;

-- Update mutable derivable fields on existing rows (pokemon_key is the one most likely
-- to drift; refresh others too in case the source JSON gained data).
UPDATE dim_card AS d
SET pokemon_key = s.pokemon_key,
    name        = s.name,
    rarity      = s.rarity,
    artist      = s.artist,
    supertype   = s.supertype,
    subtypes    = s.subtypes,
    types       = s.types,
    flavor_text = s.flavor_text
FROM _staging_card s
WHERE d.card_id = s.card_id;

SELECT
  COUNT(*) AS total_cards,
  COUNT(DISTINCT set_id) AS distinct_sets,
  SUM(CASE WHEN supertype LIKE 'Pok%' THEN 1 ELSE 0 END) AS pokemon_cards,
  SUM(CASE WHEN pokemon_key <> '' THEN 1 ELSE 0 END) AS with_pokemon_key,
  SUM(CASE WHEN artist IS NOT NULL AND artist <> '' THEN 1 ELSE 0 END) AS with_artist
FROM dim_card;

SELECT 'unjoined_pokemon_cards' AS metric,
       COUNT(*) AS n
FROM dim_card c
LEFT JOIN dim_pokemon p ON p.pokemon_key = c.pokemon_key
WHERE c.supertype LIKE 'Pok%' AND c.pokemon_key <> '' AND p.pokemon_key IS NULL;
"@
Invoke-Duck -Sql $sql
