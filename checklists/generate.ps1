# Generates ampharos/data.js and komiya/data.js from the API JSON dumps in raw/.
# Run from the pokemon_checklists/ directory.

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $root) { $root = "C:\Users\justd\OneDrive\Documents\Ultiworld\pokemon\checklists" }

# Canonical variant order used when a card spans both eras (rare, but possible if a set has weird printings).
# Last 3 entries are sourced from PokemonTCG_EmptyChecklist_v11.0.xlsm — cosmos-pattern holo reprints,
# deck-exclusive non-holos, and stamped promo variants (staff stamps, anniversary logos, distributor stamps).
$VARIANT_ORDER = @('1stEdition','1stEditionHolofoil','unlimited','unlimitedHolofoil','normal','holofoil','reverseHolofoil','cosmosHolofoil','nonHoloDeck','stampedPromo')
$VARIANT_LABELS = @{
  '1stEdition'         = '1st Ed'
  '1stEditionHolofoil' = '1st Ed Holo'
  'unlimited'          = 'Unlimited'
  'unlimitedHolofoil'  = 'Unl. Holo'
  'normal'             = 'Regular'
  'holofoil'           = 'Holo'
  'reverseHolofoil'    = 'Reverse'
  'cosmosHolofoil'     = 'Cosmos'
  'nonHoloDeck'        = 'Non-Holo'
  'stampedPromo'       = 'Stamped'
}

# Patches sourced from PokemonTCG_EmptyChecklist_v11.0.xlsm.
# Key is "setId|cardNumber". Value is a hashtable with:
#   add     - array of variant keys to ADD on top of API-detected ones
#   remove  - array of variant keys to REMOVE from API-detected ones (data errors)
#   sources - hashtable mapping variantKey -> source description string (renders as set note)
$VARIANT_PATCHES = @{
  # === Ampharos ===
  'pop7|1'    = @{ add = @('cosmosHolofoil'); sources = @{ cosmosHolofoil = "Collector's Box, December 2008" } }
  'dp3|1'     = @{ add = @('nonHoloDeck');    sources = @{ nonHoloDeck    = "Powerhouse Theme Deck" } }
  'bw6|40'    = @{ add = @('cosmosHolofoil'); sources = @{ cosmosHolofoil = "Legendary Treasures Blisters" } }
  'xy11|40'   = @{ add = @('nonHoloDeck');    sources = @{ nonHoloDeck    = "Ring of Lightning Theme Deck" } }
  'sm8|78'    = @{ add = @('nonHoloDeck');    sources = @{ nonHoloDeck    = "Storm Caller Theme Deck + Lost Thunder Build & Battle Box" } }
  'ex7|2'     = @{ remove = @('normal') }   # Dark Ampharos: TCGplayer lists a 'normal' tier but the card is Holo Rare only
  # === Komiya ===
  'ex8|4'     = @{ add = @('nonHoloDeck');    sources = @{ nonHoloDeck    = "Jetstream Theme Deck" } }
  'ex14|5'    = @{ add = @('nonHoloDeck');    sources = @{ nonHoloDeck    = "Earth Shower Theme Deck" } }
  'pl2|69'    = @{ add = @('stampedPromo');   sources = @{ stampedPromo   = "Annual Distributors Meeting 2009 (Chicago '09 Stamp)" } }
  'g1|14'     = @{ add = @('stampedPromo');   sources = @{ stampedPromo   = "GAME Store UK Giveaway, August 2016 (20th Anniversary Logo Stamp)" } }
  'bw11|23'   = @{ add = @('nonHoloDeck');    sources = @{ nonHoloDeck    = "Battle Arena Decks: Rayquaza vs Keldeo, September 2016" } }
  'swsh3|150' = @{ add = @('stampedPromo');   sources = @{ stampedPromo   = "Q4 Marketing Kit for Vivid Voltage, November 2020 (Thank You + Play! Pokemon Stamps)" } }
  'sv3|13'    = @{ add = @('cosmosHolofoil'); sources = @{ cosmosHolofoil = "Decidueye ex Box, September 2024" } }
  # === Wailmer + Wailord ===
  'sm7|40'    = @{ add = @('cosmosHolofoil'); sources = @{ cosmosHolofoil = "Unbroken Bonds Stage 1 Blister" } }                    # Wailord Celestial Storm #40
  'sv9|41'    = @{ add = @('cosmosHolofoil'); sources = @{ cosmosHolofoil = "Mega Evolution Stage 1 Blister, September 2025" } }    # Wailord Journey Together #41
}

# Errata: notable cards that exist outside normal collecting scope (test cards, FPO, oddities).
# Sourced from PokemonTCG_EmptyChecklist_v11.0.xlsm 'Additional Cards' sheet.
$ERRATA = @{
  'Ampharos' = @(
    @{ setName = "Expedition Base Set"; num = "34"; name = "Ampharos"; note = "'For Position Only' test card. Per the source workbook: 'Test cards meant to be destroyed. Prominently display For Position Only on card image.' Extreme rarity if any survived; functionally a collector curiosity rather than a playable print." }
  )
  'Komiya' = @()
  'WailmerWailord' = @(
    @{ setName = "SM Black Star Promos"; num = "SM166"; name = "Magikarp + Wailord-GX (Jumbo)"; note = "Oversized 'jumbo' print of the SM166 promo card, included in the Towering Splash-GX Box. Not a standard-size playable variant; collectible only." }
    @{ setName = "World Championship Deck 2015"; num = "Honorstoise"; name = "Wailord-EX"; note = "Reprint of Wailord-EX (Primal Clash #38) in the 2015 World Championships 'Honorstoise' deck (Jacob Van Wagner). Cards in this deck carry a stamp marking them as not tournament-legal." }
    @{ setName = "Silver Tempest"; num = "38"; name = "Wailord (Prize Pack)"; note = "Distribution variant: the standard Silver Tempest #38 Wailord was also seeded into the Play! Pokemon Prize Pack Series 3 lineup. Same card art and number; no stamp or print difference - tracked here only because the source workbook treats it as a distinct distribution." }
  )
}

function Get-CardVariants($card) {
  # If pokemontcg has tcgplayer.prices, use the keys. Otherwise fall back from rarity.
  $keys = @()
  if ($card.tcgplayer -and $card.tcgplayer.prices) {
    $keys = $card.tcgplayer.prices | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
  }
  if ($keys.Count -eq 0) {
    # Fallback rules for cards without price data (mostly old promos / e-card / McDonald's / Trainer Kits)
    $rarity = if ($card.rarity) { $card.rarity } else { '' }
    $setName = $card.set.name
    if ($setName -match 'McDonald') {
      $keys = @('holofoil')          # McDonald's promos are all holo-pattern
    } elseif ($rarity -match 'Holo') {
      $keys = @('holofoil')          # e-card "Rare Holo" without prices: holo-only
    } elseif ($setName -match 'Trainer Kit') {
      $keys = @('normal')
    } else {
      $keys = @('normal')             # Generic promo fallback
    }
  }
  # Filter to known keys only
  return @($keys | Where-Object { $VARIANT_ORDER -contains $_ })
}

function Order-Variants($keys) {
  return @($VARIANT_ORDER | Where-Object { $keys -contains $_ })
}

function ConvertTo-JsString($s) {
  if ($null -eq $s) { return '""' }
  $escaped = $s -replace '\\','\\' -replace '"','\"' -replace "`r",'' -replace "`n",'\n'
  return '"' + $escaped + '"'
}

function Format-SetData($setCards) {
  # Group: produce a single set object
  $setName = $setCards[0].set.name
  $releaseDate = $setCards[0].set.releaseDate
  $series = $setCards[0].set.series
  $setId   = $setCards[0].set.id
  # Symbol path is a relative URL from the checklist HTML to ../symbols/<setId>.png
  $symbol  = "../symbols/$setId.png"

  $allKeys = @{}
  $setNotes = New-Object System.Collections.ArrayList
  foreach ($c in $setCards) {
    $cv = Get-CardVariants $c
    # Apply xlsm-sourced patches
    $patchKey = "$($c.set.id)|$($c.number)"
    if ($VARIANT_PATCHES.ContainsKey($patchKey)) {
      $patch = $VARIANT_PATCHES[$patchKey]
      # ContainsKey explicitly — bare .add on a hashtable resolves to the System.Collections.IDictionary.Add method.
      if ($patch.ContainsKey('add')) {
        foreach ($v in $patch['add']) { if ($cv -notcontains $v) { $cv += $v } }
      }
      if ($patch.ContainsKey('remove')) {
        $cv = @($cv | Where-Object { $patch['remove'] -notcontains $_ })
      }
      if ($patch.ContainsKey('sources')) {
        foreach ($vKey in $patch['sources'].Keys) {
          $label = $VARIANT_LABELS[$vKey]
          $src = $patch['sources'][$vKey]
          [void]$setNotes.Add("$label (#$($c.number) $($c.name)): $src")
        }
      }
    }
    foreach ($k in $cv) { $allKeys[$k] = $true }
    Add-Member -InputObject $c -NotePropertyName '_variants' -NotePropertyValue $cv -Force
  }
  $orderedKeys = Order-Variants($allKeys.Keys)

  # Sort cards by number (handle string/numeric promo numbers)
  $sortedCards = $setCards | Sort-Object @{
    Expression = {
      $n = $_.number -replace '^[A-Za-z]+',''
      $n = $n -replace '\D.*$',''
      if ($n -match '^\d+$') { [int]$n } else { 999999 }
    }
  }, number

  # Build JS card array
  $cardJs = @()
  foreach ($c in $sortedCards) {
    $variants = ($c._variants | ForEach-Object { ConvertTo-JsString $_ }) -join ','
    $rarity = if ($c.rarity) { $c.rarity } else { '' }
    $cardJs += "      { num: $(ConvertTo-JsString $c.number), name: $(ConvertTo-JsString $c.name), rarity: $(ConvertTo-JsString $rarity), variants: [$variants] }"
  }

  $variantJs = @()
  foreach ($k in $orderedKeys) {
    $variantJs += "      { key: $(ConvertTo-JsString $k), label: $(ConvertTo-JsString $VARIANT_LABELS[$k]) }"
  }

  $notesJs = ''
  if ($setNotes.Count -gt 0) {
    $noteItems = ($setNotes | ForEach-Object { '      ' + (ConvertTo-JsString $_) }) -join ",`n"
    $notesJs = ",`n    notes: [`n$noteItems`n    ]"
  }

  return @"
  {
    name: $(ConvertTo-JsString $setName),
    series: $(ConvertTo-JsString $series),
    releaseDate: $(ConvertTo-JsString $releaseDate),
    symbol: $(ConvertTo-JsString $symbol),
    variants: [
$($variantJs -join ",`n")
    ],
    cards: [
$($cardJs -join ",`n")
    ]$notesJs
  }
"@
}

function Generate-Checklist($jsonPath, $outPath, $title, $subtitle, $description, $footnotes, $extraSets, $errata) {
  # Force UTF-8 decode — PowerShell 5.1's Get-Content defaults to the system code page,
  # which mangles é, ô, etc. into Ã©, Ã´. Read raw bytes and decode explicitly.
  $jsonText = [System.IO.File]::ReadAllText($jsonPath, [System.Text.UTF8Encoding]::new($false))
  $data = $jsonText | ConvertFrom-Json
  $cards = $data.data

  # Group by set, preserve API order within group, sort groups by release date
  $byset = @{}
  foreach ($c in $cards) {
    $sid = $c.set.id
    if (-not $byset.ContainsKey($sid)) { $byset[$sid] = @() }
    $byset[$sid] += $c
  }

  $setObjs = @()
  foreach ($sid in $byset.Keys) {
    $setCards = $byset[$sid]
    $obj = [PSCustomObject]@{
      ReleaseDate = $setCards[0].set.releaseDate
      Js = Format-SetData $setCards
      Count = $setCards.Count
      Name = $setCards[0].set.name
    }
    $setObjs += $obj
  }
  $setObjs = $setObjs | Sort-Object ReleaseDate, Name

  $setsBlock = ($setObjs | ForEach-Object { $_.Js }) -join ",`n"

  $footnotesJs = ($footnotes | ForEach-Object { '    ' + (ConvertTo-JsString $_) }) -join ",`n"

  $totalCards = ($setObjs | Measure-Object Count -Sum).Sum

  $extraSetsJs = if ($extraSets) { ",`n$extraSets" } else { '' }

  $errataJs = ''
  if ($errata -and $errata.Count -gt 0) {
    $items = @()
    foreach ($e in $errata) {
      $items += "    { setName: $(ConvertTo-JsString $e.setName), num: $(ConvertTo-JsString $e.num), name: $(ConvertTo-JsString $e.name), note: $(ConvertTo-JsString $e.note) }"
    }
    $errataJs = ",`n  errata: [`n$($items -join ",`n")`n  ]"
  }

  $out = @"
// Auto-generated checklist data. Source: pokemontcg.io v2 API (English-language sets).
// Generated: $(Get-Date -Format 'yyyy-MM-dd')
window.CHECKLIST = {
  title: $(ConvertTo-JsString $title),
  subtitle: $(ConvertTo-JsString $subtitle),
  description: $(ConvertTo-JsString $description),
  totalCards: $totalCards,
  footnotes: [
$footnotesJs
  ],
  sets: [
$setsBlock$extraSetsJs
  ]$errataJs
};
"@
  # Write as UTF-8 without BOM (PowerShell 5.1's -Encoding UTF8 emits a BOM that some
  # browsers / build tools choke on; explicit write avoids it).
  [System.IO.File]::WriteAllText($outPath, $out, [System.Text.UTF8Encoding]::new($false))
  Write-Host "Wrote $outPath  ($totalCards cards across $($setObjs.Count) sets)"
}

# === Ampharos ===
$ampharosOut = Join-Path $root 'ampharos\data.js'
New-Item -ItemType Directory -Force -Path (Split-Path $ampharosOut) | Out-Null

# Manually add Chaos Rising entries (not yet in pokemontcg.io API as of May 2026; sourced from Bulbapedia).
$chaosRisingExtra = @"
  {
    name: "Chaos Rising",
    series: "Scarlet & Violet",
    releaseDate: "2026/03/01",
    symbol: "../symbols/chaos-rising.png",
    variants: [
      { key: "normal", label: "Regular" },
      { key: "holofoil", label: "Holo" },
      { key: "reverseHolofoil", label: "Reverse" },
      { key: "nonHoloDeck", label: "Non-Holo" }
    ],
    cards: [
      { num: "29", name: "Ampharos", rarity: "Rare", variants: ["normal","reverseHolofoil","nonHoloDeck"] },
      { num: "90", name: "Ampharos", rarity: "Illustration Rare", variants: ["holofoil"] }
    ]
  },
  {
    name: "MEP Black Star Promos",
    series: "Mega Evolution Promo",
    releaseDate: "2026/03/01",
    symbol: "../symbols/mep-promos.png",
    variants: [
      { key: "holofoil", label: "Holo" },
      { key: "stampedPromo", label: "Stamped" }
    ],
    cards: [
      { num: "075", name: "Ampharos", rarity: "Promo", variants: ["holofoil","stampedPromo"] }
    ]
  }
"@

$today = Get-Date -Format 'yyyy-MM-dd'
$ampharosFootnotes = @()
$ampharosFootnotes += "Source: pokemontcg.io API (cached $today) plus manual Bulbapedia cross-check."
$ampharosFootnotes += "Variant columns per set reflect the printings that actually exist for that release era. Filled square = collected; em-dash means that variant does not exist for that card."
$ampharosFootnotes += "Chaos Rising and MEP Black Star Promos sourced manually from Bulbapedia; the API had not indexed that set yet at generation time."
$ampharosFootnotes += "Cosmos-holo, deck-exclusive non-holo, and stamped-promo variants cross-referenced against PokemonTCG_EmptyChecklist_v11.0.xlsm. First-pass coverage only - review and add any missing prerelease, build-and-battle, or blister reprints by hand."

Generate-Checklist `
  -jsonPath (Join-Path $root 'raw\ampharos.json') `
  -outPath  $ampharosOut `
  -title    "Ampharos" `
  -subtitle "Every English-language Pokemon TCG card featuring Ampharos" `
  -description "Includes every card with 'Ampharos' in the title across all English print sets, plus secret-rare/full-art variants. Art-only cameos on cards with other names are not catalogued by any data source the build pipeline uses; this checklist tracks named-Ampharos cards only. Cross-checked against Bulbapedia (May 2026)." `
  -footnotes $ampharosFootnotes `
  -extraSets $chaosRisingExtra `
  -errata    $ERRATA['Ampharos']

# === Komiya ===
$komiyaOut = Join-Path $root 'komiya\data.js'
New-Item -ItemType Directory -Force -Path (Split-Path $komiyaOut) | Out-Null
$komiyaFootnotes = @()
$komiyaFootnotes += "Source: pokemontcg.io API (cached $today). Komiya has no co-illustrator credits in the API; every entry is solo."
$komiyaFootnotes += "Two cards have empty artist field in the API but are attributed to Komiya by Bulbapedia and have been manually included: Impidimp (Stellar Crown 94) and Morelull (Surging Sparks 8). Pikachu V-UNION (SWSH 139-142) was investigated and confirmed NOT a Komiya credit (illustrators: 5ban Graphics, Taira Akitsu, Hitoshi Ariga, Mitsuhiro Arita)."
$komiyaFootnotes += "Variant columns per set reflect the printings that actually exist for that release era."
$komiyaFootnotes += "Cosmos-holo, deck-exclusive non-holo, and stamped-promo variants cross-referenced against PokemonTCG_EmptyChecklist_v11.0.xlsm; first-pass coverage only (8 cards updated). Older Komiya cards likely have additional cosmos-holo blister reprints not yet catalogued here."

Generate-Checklist `
  -jsonPath (Join-Path $root 'raw\komiya.json') `
  -outPath  $komiyaOut `
  -title    "Tomokazu Komiya" `
  -subtitle "Every English-language Pokemon TCG card illustrated by Tomokazu Komiya" `
  -description "Komiya has illustrated cards since 1999 (Japanese Expansion Sheet 1; first English appearance in Neo Genesis). This checklist covers all English-language printings credited to him in the pokemontcg.io database. Bulbapedia's broader category lists ~267 entries including Japanese-only sets (Vending, VS, Mega Evolution) and a handful of disputed/composite credits; those are intentionally excluded." `
  -footnotes $komiyaFootnotes `
  -errata    $ERRATA['Komiya']

# === Wailmer + Wailord ===
$wwOut = Join-Path $root 'wailmer_wailord\data.js'
New-Item -ItemType Directory -Force -Path (Split-Path $wwOut) | Out-Null

$wwFootnotes = @()
$wwFootnotes += "Source: pokemontcg.io API (cached $today). Covers both Wailmer and Wailord across every English print set, including ex/EX/V/GX evolutions and tag-team forms (Magikarp & Wailord-GX)."
$wwFootnotes += "Variant columns per set reflect the printings that actually exist for that release era."
$wwFootnotes += "Cosmos-holo and other reprint variants cross-referenced against PokemonTCG_EmptyChecklist_v11.0.xlsm catch-all sheets; first-pass coverage."

Generate-Checklist `
  -jsonPath (Join-Path $root 'raw\wailmer_wailord.json') `
  -outPath  $wwOut `
  -title    "Wailmer & Wailord" `
  -subtitle "Every English-language Pokemon TCG card featuring either member of the Wailmer evolution family" `
  -description "Includes every named-Wailmer and named-Wailord card across all English print sets: base Pokemon, ex/EX, V, GX, Wailord ex, Magikarp + Wailord-GX tag team, plus full-art and illustration-rare variants. Cards grouped by set in chronological order." `
  -footnotes $wwFootnotes `
  -errata    $ERRATA['WailmerWailord']
