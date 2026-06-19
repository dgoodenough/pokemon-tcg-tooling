# Seeds dim_set from pokemontcg.io. Caches raw JSON to raw/sets.json.
# Idempotent: re-running clears and reloads dim_set.

. "$PSScriptRoot\common.ps1"

$rawFile = Join-Path $script:RawDir 'sets.json'

Write-Host 'Fetching all sets from pokemontcg.io...'
Invoke-WebRequest -UseBasicParsing -Uri 'https://api.pokemontcg.io/v2/sets?pageSize=500' -OutFile $rawFile
$data = Read-Utf8Json -Path $rawFile
Write-Host "  Fetched $($data.data.Count) sets."

# Write CSV
$csvPath = Join-Path $script:RawDir '_seed_sets.csv'
$lines = New-Object System.Collections.ArrayList
[void]$lines.Add('set_id,name,series,printed_total,total,release_date,ptcgo_code,symbol_url,logo_url,updated_at')

foreach ($s in $data.data) {
    # Normalize dates. The source occasionally emits malformed strings (e.g. "2026/003/26"),
    # so we validate against a strict pattern and null-out anything that doesn't match.
    $relDate = ''
    if ($s.releaseDate) {
        $candidate = $s.releaseDate -replace '/','-'
        if ($candidate -match '^\d{4}-\d{2}-\d{2}$') { $relDate = $candidate }
    }
    $updated = ''
    if ($s.updatedAt) {
        $candidate = ($s.updatedAt -replace '/','-') -replace ' ', 'T'
        if ($candidate -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$') { $updated = $candidate }
    }
    $row = @(
        ConvertTo-CsvField $s.id
        ConvertTo-CsvField $s.name
        ConvertTo-CsvField $s.series
        ConvertTo-CsvField $s.printedTotal
        ConvertTo-CsvField $s.total
        ConvertTo-CsvField $relDate
        ConvertTo-CsvField $s.ptcgoCode
        ConvertTo-CsvField $s.images.symbol
        ConvertTo-CsvField $s.images.logo
        ConvertTo-CsvField $updated
    ) -join ','
    [void]$lines.Add($row)
}

Write-Utf8 -Path $csvPath -Content ($lines -join "`n")
Write-Host "  Wrote CSV: $csvPath"

# Load into DuckDB
$sql = @"
DELETE FROM dim_set;
COPY dim_set FROM '$($csvPath -replace '\\','/')' (FORMAT CSV, HEADER, NULLSTR '');
SELECT COUNT(*) AS set_count, MIN(release_date) AS earliest, MAX(release_date) AS latest FROM dim_set;
"@
Invoke-Duck -Sql $sql
