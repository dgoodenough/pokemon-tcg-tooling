# Seeds dim_pokemon from PokeAPI GraphQL.
# Single round trip: all ~1025 species with types, generation, evolution chain, legendary/mythical flags.
. "$PSScriptRoot\common.ps1"

$rawFile = Join-Path $script:RawDir 'pokemon_species.json'

$query = @'
{
  pokemonspecies(order_by: {id: asc}) {
    id
    name
    generation_id
    is_legendary
    is_mythical
    evolution_chain_id
    pokemons(where: {is_default: {_eq: true}}, limit: 1) {
      pokemontypes(order_by: {slot: asc}) {
        type { name }
      }
    }
  }
}
'@

$body = @{ query = $query } | ConvertTo-Json -Compress
Write-Host 'Querying PokeAPI GraphQL...'
$resp = Invoke-WebRequest -UseBasicParsing -Method POST `
    -Uri 'https://graphql.pokeapi.co/v1beta2' `
    -Body $body `
    -ContentType 'application/json'
Write-Utf8 -Path $rawFile -Content $resp.Content

$data = $resp.Content | ConvertFrom-Json
$species = $data.data.pokemonspecies
Write-Host "  Got $($species.Count) species."

$csvPath = Join-Path $script:RawDir '_seed_pokemon.csv'
$lines = New-Object System.Collections.ArrayList
[void]$lines.Add('pokemon_key,name,dex_number,generation,types,evolution_chain,is_legendary,is_mythical')

foreach ($sp in $species) {
    # Build a normalized key: lowercase, strip punctuation, replace hyphens/spaces.
    # "Nidoran-f" -> "nidoranf"; "Mr. Mime" -> "mrmime"; matches how we'd normalize card name lookups.
    $name = ($sp.name -replace '-', ' ')
    # Title-case the display name
    $words = $name -split ' '
    $displayName = ($words | ForEach-Object { (Get-Culture).TextInfo.ToTitleCase($_.ToLower()) }) -join ' '
    $key = ($sp.name -replace '[^a-zA-Z0-9]','').ToLower()

    $typeNames = @()
    if ($sp.pokemons.Count -gt 0) {
        foreach ($t in $sp.pokemons[0].pokemontypes) {
            $typeNames += (Get-Culture).TextInfo.ToTitleCase($t.type.name)
        }
    }
    $typesField = $typeNames -join ','

    $row = @(
        ConvertTo-CsvField $key
        ConvertTo-CsvField $displayName
        ConvertTo-CsvField $sp.id
        ConvertTo-CsvField $sp.generation_id
        ConvertTo-CsvField $typesField
        ConvertTo-CsvField $sp.evolution_chain_id
        if ($sp.is_legendary) { 'true' } else { 'false' }
        if ($sp.is_mythical)  { 'true' } else { 'false' }
    ) -join ','
    [void]$lines.Add($row)
}

Write-Utf8 -Path $csvPath -Content ($lines -join "`n")
Write-Host "  Wrote CSV: $csvPath"

$sql = @"
DELETE FROM dim_pokemon;
COPY dim_pokemon FROM '$($csvPath -replace '\\','/')' (FORMAT CSV, HEADER, NULLSTR '');
SELECT
  COUNT(*) AS pokemon_count,
  MIN(generation) AS min_gen,
  MAX(generation) AS max_gen,
  SUM(CASE WHEN is_legendary THEN 1 ELSE 0 END) AS legendaries,
  SUM(CASE WHEN is_mythical THEN 1 ELSE 0 END) AS mythicals
FROM dim_pokemon;
"@
Invoke-Duck -Sql $sql
