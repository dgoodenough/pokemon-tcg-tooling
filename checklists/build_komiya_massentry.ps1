# Builds a TCGplayer Mass Entry list for one LP copy of every Tomokazu Komiya card.
#
# Mass Entry line format (verified by probes):  <count> <Product Name> [<SET CODE>] <Number>
#   - count and [brackets] are REQUIRED
#   - the Product Name and Number must match TCGplayer's catalog EXACTLY. These are wildly
#     irregular ("Bulbasaur (95)", "Vibrava - 024/101 (Delta Species)", "Sandile - 115/198")
#     and the number padding differs per set ("067/147" vs "50/100"). So we pull both verbatim
#     from the pipeline's TCGplayer staging export (_stage_tcgplayer.csv via _csv_lookup.csv).
#   - condition is NOT in the text; set the "Lightly Played" floor in the optimize step.

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $root) { $root = "C:\Users\justd\OneDrive\Documents\Ultiworld\pokemon\checklists" }

$dataPath   = Join-Path $root 'komiya\data.js'
$lookupPath = Join-Path $root '_csv_lookup_raw.csv'   # distinct (set_name, product_name, number_raw) from the raw pull
$outPath    = Join-Path $root 'komiya_massentry_LP.txt'

# Exact TCGplayer "Set Name" string -> set_id, for every set Komiya appears in.
# (Taken verbatim from the raw pull's distinct set names; note RC cards live in the
# "Generations: Radiant Collection" set, and SV04-10 are numbered.)
$setName2Id = @{
  'WoTC Promo'='basep'
  'Neo Genesis'='neo1'; 'Neo Discovery'='neo2'; 'Neo Revelation'='neo3'; 'Neo Destiny'='neo4'
  'Expedition'='ecard1'; 'Aquapolis'='ecard2'; 'Skyridge'='ecard3'
  'Sandstorm'='ex2'; 'Dragon'='ex3'; 'Hidden Legends'='ex5'; 'FireRed & LeafGreen'='ex6'
  'Team Rocket Returns'='ex7'; 'Deoxys'='ex8'; 'Unseen Forces'='ex10'; 'Delta Species'='ex11'
  'Legend Maker'='ex12'; 'Crystal Guardians'='ex14'; 'Dragon Frontiers'='ex15'; 'Power Keepers'='ex16'
  'EX Trainer Kit 1: Latias & Latios'='tk1b'; 'POP Series 2'='pop2'
  'Majestic Dawn'='dp5'; 'Stormfront'='dp7'
  'Platinum'='pl1'; 'Rising Rivals'='pl2'; 'Supreme Victors'='pl3'; 'Arceus'='pl4'
  'HeartGold SoulSilver'='hgss1'; 'Unleashed'='hgss2'; 'Undaunted'='hgss3'; 'Triumphant'='hgss4'
  'Black and White Promos'='bwp'; 'Noble Victories'='bw3'; 'Dark Explorers'='bw5'; 'Dragons Exalted'='bw6'
  'Boundaries Crossed'='bw7'; 'Plasma Storm'='bw8'; 'Legendary Treasures'='bw11'
  'XY Promos'='xyp'; 'XY Base Set'='xy1'; 'XY - Flashfire'='xy2'; 'XY - Furious Fists'='xy3'
  'XY - Phantom Forces'='xy4'; 'XY - Primal Clash'='xy5'; 'XY - Roaring Skies'='xy6'; 'XY - Ancient Origins'='xy7'
  'XY - BREAKthrough'='xy8'; 'XY - BREAKpoint'='xy9'; 'XY - Fates Collide'='xy10'; 'XY - Steam Siege'='xy11'
  'Generations'='g1'; 'Generations: Radiant Collection'='g1'
  "McDonald's Promos 2015"='mcd15'; "McDonald's Promos 2016"='mcd16'; "McDonald's Promos 2022"='mcd22'
  'SM Promos'='smp'; 'SM Base Set'='sm1'; 'SM - Guardians Rising'='sm2'; 'Shining Legends'='sm35'
  'SM - Ultra Prism'='sm5'; 'SM - Forbidden Light'='sm6'; 'SM - Lost Thunder'='sm8'; 'SM - Team Up'='sm9'
  'SM - Unbroken Bonds'='sm10'; 'SM - Unified Minds'='sm11'; 'SM - Cosmic Eclipse'='sm12'
  'SWSH01: Sword & Shield Base Set'='swsh1'; 'SWSH02: Rebel Clash'='swsh2'; 'SWSH03: Darkness Ablaze'='swsh3'
  'SWSH04: Vivid Voltage'='swsh4'; 'SWSH05: Battle Styles'='swsh5'; 'SWSH06: Chilling Reign'='swsh6'
  'SWSH07: Evolving Skies'='swsh7'; 'SWSH08: Fusion Strike'='swsh8'; 'SWSH09: Brilliant Stars'='swsh9'
  'SWSH10: Astral Radiance'='swsh10'; 'SWSH11: Lost Origin'='swsh11'; 'SWSH12: Silver Tempest'='swsh12'
  'SWSH: Crown Zenith'='swsh12pt5'; 'SWSH: Crown Zenith: Galarian Gallery'='swsh12pt5gg'; 'Pokemon GO'='pgo'
  'SV01: Scarlet & Violet Base Set'='sv1'; 'SV02: Paldea Evolved'='sv2'; 'SV03: Obsidian Flames'='sv3'
  'SV: Scarlet & Violet 151'='sv3pt5'; 'SV04: Paradox Rift'='sv4'; 'SV05: Temporal Forces'='sv5'
  'SV06: Twilight Masquerade'='sv6'; 'SV07: Stellar Crown'='sv7'; 'SV08: Surging Sparks'='sv8'
  'SV09: Journey Together'='sv9'; 'SV10: Destined Rivals'='sv10'; 'SV: Black Bolt'='zsv10pt5'
  'ME02: Phantasmal Flames'='me2'
}

# set_id -> TCGplayer Mass Entry SET CODE (== dim_set.ptcgo_code where it exists; community
# abbreviations for the pre-PTCGO vintage; best-guess for promos/McDonald's/etc.).
$code = @{
  'neo1'='N1'; 'neo2'='N2'; 'neo3'='N3'; 'neo4'='N4'
  'ecard1'='EX'; 'ecard2'='AQ'; 'ecard3'='SK'
  'ex2'='SS'; 'ex3'='DR'; 'ex5'='HL'; 'ex6'='RG'; 'ex7'='RR'; 'ex8'='DX'; 'ex10'='UF'
  'ex11'='DS'; 'ex12'='LM'; 'ex14'='CG'; 'ex15'='DF'; 'ex16'='PK'
  'dp5'='MD'; 'dp7'='SF'
  'pl1'='PL'; 'pl2'='RR'; 'pl3'='SV'; 'pl4'='AR'
  'hgss1'='HS'; 'hgss2'='UL'; 'hgss3'='UD'; 'hgss4'='TM'
  'bw3'='NVI'; 'bw5'='DEX'; 'bw6'='DRX'; 'bw7'='BCR'; 'bw8'='PLS'; 'bw11'='LTR'
  'xy1'='XY'; 'xy2'='FLF'; 'xy3'='FFI'; 'xy4'='PHF'; 'xy5'='PRC'; 'xy6'='ROS'; 'xy7'='AOR'
  'xy8'='BKT'; 'xy9'='BKP'; 'xy10'='FCO'; 'xy11'='STS'; 'g1'='GEN'
  # SM era: dialog uses "SM##" but padding is INCONSISTENT - SM02..SM06 are padded,
  # but Lost Thunder is "SM8" and Team Up is "SM9" (no leading zero). CONFIRMED: SM02,
  # SM05, SM06, SM8, SM9, SM10. Guessed: sm1 base, sm35 Shining Legends, smp promos.
  'sm1'='SM01'; 'sm2'='SM02'; 'sm35'='SHL'; 'sm5'='SM05'; 'sm6'='SM06'; 'sm8'='SM8'; 'sm9'='SM9'
  'sm10'='SM10'; 'sm11'='SM11'; 'sm12'='SM12'
  # SwSh era: dialog uses "SWSH##" (CONFIRMED from the Set Codes dialog).
  'swsh1'='SWSH01'; 'swsh2'='SWSH02'; 'swsh3'='SWSH03'; 'swsh4'='SWSH04'; 'swsh5'='SWSH05'; 'swsh6'='SWSH06'
  'swsh7'='SWSH07'; 'swsh8'='SWSH08'; 'swsh9'='SWSH09'; 'swsh10'='SWSH10'; 'swsh11'='SWSH11'; 'swsh12'='SWSH12'
  'swsh12pt5'='CRZ'; 'pgo'='PGO'
  'sv1'='SVI'; 'sv2'='PAL'; 'sv3'='OBF'; 'sv3pt5'='MEW'; 'sv4'='PAR'; 'sv5'='TEF'; 'sv6'='TWM'
  'sv7'='SCR'; 'sv8'='SSP'; 'sv9'='JTG'; 'sv10'='DRI'; 'zsv10pt5'='BLK'
  'me2'='PFL'
  # --- promos / specials ---
  # TCGplayer lumps many promo/exclusive/trainer-kit sets under the shared code "PR"
  # (CONFIRMED: WoTC Promo, XY Promos, XY Trainer Kits). McDonald's uses "M##" (M16/M22 seen).
  # smp (SM Promos)=SMP and swsh12pt5gg (Galarian Gallery)=CRZ:GG both already verified working.
  # bwp / tk1b / pop2 are best-guess "PR" by the same pattern. sm35 (Shining Legends) still unknown.
  'basep'='PR'; 'pop2'='POP'; 'tk1b'='PR'; 'bwp'='PR'; 'xyp'='PR'; 'smp'='SMP'
  'mcd15'='M15'; 'mcd16'='M16'; 'mcd22'='M22'; 'swsh12pt5gg'='CRZ:GG'
}

function Norm-Number {
  param([string]$n)
  $n = $n.Trim()
  if ($n -match '^(.+?)/') { $n = $matches[1] }              # drop "/total"
  if ($n -match '^(\d+)([A-Za-z]?)$') { return ([int]$matches[1]).ToString() + $matches[2] }  # strip leading zeros
  return $n
}

# --- Load the raw-pull lookup into a multimap: "set_id|number_norm" -> list of {name, numraw} ---
$lookup = @{}
foreach ($row in (Import-Csv -Path $lookupPath -Encoding UTF8)) {
  $sn = $row.set_name; $pn = $row.product_name; $nr = $row.number_raw
  $sid = $setName2Id[$sn]
  if (-not $sid) { continue }                     # set not one of Komiya's - skip
  $nn = Norm-Number $nr
  $k = "$sid|$nn"
  if (-not $lookup.ContainsKey($k)) { $lookup[$k] = New-Object System.Collections.ArrayList }
  [void]$lookup[$k].Add(@{ name = $pn; numraw = $nr })
}

# Variant/promo markers we want to AVOID when several products share a number (we want the base card).
$avoid = 'Reverse|Cosmos|Staff|Prerelease|Promo|Stamp|Jumbo|Error|Theme Deck|Deck Exclusive|Gold Star'

function Pick-Best {
  param($cands, [string]$komiyaName)
  $first = ($komiyaName -split '\s+')[0].ToLower()
  # prefer candidates whose product name contains the Komiya first word
  $named = @($cands | Where-Object { $_.name.ToLower().Contains($first) })
  $pool  = if ($named.Count) { $named } else { @($cands) }
  # prefer those without variant/promo markers
  $clean = @($pool | Where-Object { $_.name -notmatch $avoid })
  $pool  = if ($clean.Count) { $clean } else { $pool }
  # shortest name = most "base" form. @() so [0] indexes an array, not a lone hashtable's key 0.
  return @($pool | Sort-Object { $_.name.Length })[0]
}

$lines  = [System.IO.File]::ReadAllLines($dataPath, [System.Text.UTF8Encoding]::new($false))
$curSet = $null
$out    = New-Object System.Collections.ArrayList
$missingCsv = New-Object System.Collections.ArrayList
$missingCode = @{}
$count = 0
foreach ($ln in $lines) {
  if ($ln -match 'symbol:\s*"\.\./symbols/(.+?)\.png"') { $curSet = $matches[1]; continue }
  if ($ln -match '^\s*\{\s*num:\s*"([^"]*)",\s*name:\s*"([^"]*)"') {
    $num = $matches[1]; $name = $matches[2]
    $cd  = if ($curSet -and $code.ContainsKey($curSet)) { $code[$curSet] }
           else { if ($curSet) { $missingCode[$curSet] = $true }; "??$curSet" }
    $kn  = Norm-Number $num
    $key = "$curSet|$kn"
    if ($lookup.ContainsKey($key)) {
      $best   = Pick-Best $lookup[$key] $name
      $pname  = $best.name
      $numout = $best.numraw
    } else {
      # Not in the TCGplayer export - fall back to the raw name/number and flag it.
      $pname  = $name
      $numout = $num
      [void]$missingCsv.Add("1 $pname [$cd] $numout   (set $curSet, no CSV match)")
    }
    [void]$out.Add("1 $pname [$cd] $numout")
    $count++
  }
}

[System.IO.File]::WriteAllText($outPath, ($out -join "`r`n") + "`r`n", [System.Text.UTF8Encoding]::new($false))
Write-Host "Wrote $outPath  ($count lines; $($count - $missingCsv.Count) matched from CSV, $($missingCsv.Count) fallbacks)"
if ($missingCode.Keys.Count) { Write-Host "Unmapped set codes: $($missingCode.Keys -join ', ')" }
if ($missingCsv.Count) {
  Write-Host ""
  Write-Host "NOT IN CSV (using raw name/number - may need manual fix):"
  $missingCsv | ForEach-Object { Write-Host "  $_" }
}
