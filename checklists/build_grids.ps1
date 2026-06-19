# Builds 3x3 "nine-pocket binder" planning sheets for each collection.
# One box per card (by number): set symbol, set name, card number, card name.
# Cards flow in release-date order, left-to-right / top-to-bottom, so a filled
# binder reads chronologically. A new era (series) never starts in pocket 8 or 9 -
# the page flushes early at 7 or 8 instead. Lone trailing cards merge up.
#
# Renders via Chrome headless to %TEMP% (Chrome can't write into OneDrive folders),
# then copies the finished PDF back next to the checklists.

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $root) { $root = "C:\Users\justd\OneDrive\Documents\Ultiworld\pokemon\checklists" }

$chrome = "C:\Program Files\Google\Chrome\Application\chrome.exe"
$gridsDir = Join-Path $root 'grids'
New-Item -ItemType Directory -Force -Path $gridsDir | Out-Null

$collections = @(
  @{ key = 'ampharos';        dir = 'ampharos';        title = 'Ampharos' }
  @{ key = 'komiya';          dir = 'komiya';          title = 'Tomokazu Komiya' }
  @{ key = 'wailmer_wailord'; dir = 'wailmer_wailord'; title = 'Wailmer & Wailord' }
)

# --- HTML/JS template (single-quoted here-string: no PS interpolation). ---
# Tokens replaced per collection: __TITLE__ , __DATASRC__
$template = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>__TITLE__ - Binder Layout</title>
<style>
  @page { size: letter; margin: 0.4in; }
  * { box-sizing: border-box; }
  html, body { margin: 0; padding: 0; background: #fff; color: #000; }
  body { font-family: "Helvetica", "Arial", sans-serif;
         -webkit-print-color-adjust: exact; print-color-adjust: exact; }

  .binder-page { page-break-after: always; height: 9.9in; display: flex; flex-direction: column; }
  .binder-page:last-child { page-break-after: auto; }

  .page-head { display: flex; align-items: baseline; gap: 8pt;
     border-bottom: 1.2pt solid #000; padding-bottom: 3pt; margin-bottom: 7pt; }
  .page-head .title  { font-size: 13pt; font-weight: bold; letter-spacing: .02em; white-space: nowrap; }
  .page-head .eras   { font-size: 8pt; color: #555; text-transform: uppercase; letter-spacing: .04em;
     flex: 1; text-align: center; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .page-head .pageno { font-size: 9pt; color: #333; font-variant-numeric: tabular-nums; white-space: nowrap; }

  .grid { flex: 1; display: grid; grid-template-columns: repeat(3, 1fr);
     grid-template-rows: repeat(3, 1fr); gap: 0.16in; }

  .pocket { border: 1pt solid #000; border-radius: 7pt; position: relative;
     display: flex; flex-direction: column; padding: 7pt 9pt 9pt; overflow: hidden; }
  .pocket .seq { position: absolute; top: 5pt; right: 8pt; font-size: 7.5pt; color: #aaa;
     font-variant-numeric: tabular-nums; }
  .pocket .set-row { display: flex; align-items: center; gap: 5pt; min-height: 16pt; padding-right: 16pt; }
  .pocket .set-row img { height: 15pt; width: auto; max-width: 26pt; object-fit: contain;
     flex-shrink: 0; image-rendering: -webkit-optimize-contrast; }
  .pocket .set-name { font-size: 7.6pt; text-transform: uppercase; letter-spacing: .03em;
     color: #444; line-height: 1.06; font-weight: 600; }
  .pocket .spacer { flex: 1; min-height: 4pt; }
  .pocket .num { font-size: 21pt; font-weight: bold; line-height: 1; font-variant-numeric: tabular-nums; }
  .pocket .num .hash { font-size: 12pt; color: #aaa; font-weight: normal; }
  .pocket .cname { font-size: 12.5pt; font-weight: bold; line-height: 1.1; margin-top: 2pt; }
  .pocket .rarity { font-size: 7.5pt; color: #777; margin-top: 3pt; font-style: italic; }

  .pocket.empty { border: 1pt dashed #d2d2d2; }

  .legend { margin-top: 6pt; font-size: 6.6pt; color: #8a8a8a; text-align: center; letter-spacing: .02em; }
</style>
</head>
<body>
<div id="root"></div>
<script src="__DATASRC__" charset="utf-8"></script>
<script>
(function () {
  var data = window.CHECKLIST || { sets: [] };
  var COLL = "__TITLE__";

  function esc(s){ return String(s==null?'':s)
    .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }

  // Flatten cards in chronological order (set release date, then data order within set).
  var sets = (data.sets || []).slice().sort(function (a, b) {
    return (a.releaseDate||'').localeCompare(b.releaseDate||'') || (a.name||'').localeCompare(b.name||'');
  });
  var items = [];
  sets.forEach(function (s) {
    (s.cards || []).forEach(function (c) {
      items.push({ setName: s.name, symbol: s.symbol, series: s.series||'',
                   num: c.num, name: c.name, rarity: c.rarity||'' });
    });
  });

  // Pack into pages of up to 9. Never START a new era in pocket 8 or 9:
  // if the page already holds 7+ cards and the next card opens a different era, flush early.
  var pages = [], cur = [], lastEra = null;
  items.forEach(function (it) {
    if (cur.length === 9) { pages.push(cur); cur = []; lastEra = null; }
    else if (cur.length >= 7 && lastEra !== null && it.series !== lastEra) { pages.push(cur); cur = []; lastEra = null; }
    cur.push(it); lastEra = it.series;
  });
  if (cur.length) pages.push(cur);
  // A lone trailing card doesn't deserve its own sheet - merge it up.
  while (pages.length >= 2 && pages[pages.length-1].length === 1 && pages[pages.length-2].length <= 8) {
    var orphan = pages.pop()[0];
    pages[pages.length-1].push(orphan);
  }

  var root = document.getElementById('root');
  var total = pages.length, seq = 0;
  pages.forEach(function (pg, pi) {
    var page = document.createElement('div'); page.className = 'binder-page';

    var eras = [];
    pg.forEach(function (it) { if (eras.indexOf(it.series) < 0) eras.push(it.series); });

    var head = document.createElement('div'); head.className = 'page-head';
    head.innerHTML =
      '<span class="title">' + esc(COLL) + '</span>' +
      '<span class="eras">' + esc(eras.join('  ·  ')) + '</span>' +
      '<span class="pageno">Page ' + (pi+1) + ' / ' + total + '</span>';
    page.appendChild(head);

    var grid = document.createElement('div'); grid.className = 'grid';
    for (var i = 0; i < 9; i++) {
      var cell = document.createElement('div');
      if (i < pg.length) {
        seq++;
        var it = pg[i];
        cell.className = 'pocket';
        var rar = it.rarity ? '<div class="rarity">' + esc(it.rarity) + '</div>' : '';
        cell.innerHTML =
          '<span class="seq">' + seq + '</span>' +
          '<div class="set-row">' +
            (it.symbol ? '<img src="' + esc(it.symbol) + '" alt="">' : '') +
            '<div class="set-name">' + esc(it.setName) + '</div></div>' +
          '<div class="spacer"></div>' +
          '<div class="num"><span class="hash">#</span>' + esc(it.num) + '</div>' +
          '<div class="cname">' + esc(it.name) + '</div>' + rar;
      } else {
        cell.className = 'pocket empty';
      }
      grid.appendChild(cell);
    }
    page.appendChild(grid);

    var legend = document.createElement('div'); legend.className = 'legend';
    legend.textContent = 'Nine-pocket binder layout - cards in release order; corner number = slot sequence. Dashed cells are empty pockets.';
    page.appendChild(legend);

    root.appendChild(page);
  });
})();
</script>
</body>
</html>
'@

foreach ($c in $collections) {
  $html = $template.Replace('__TITLE__', $c.title).Replace('__DATASRC__', "../$($c.dir)/data.js")
  $htmlPath = Join-Path $gridsDir "$($c.key)_grid.html"
  [System.IO.File]::WriteAllText($htmlPath, $html, [System.Text.UTF8Encoding]::new($false))

  $tmpPdf = Join-Path $env:TEMP "$($c.key)_grid.pdf"
  if (Test-Path $tmpPdf) { Remove-Item $tmpPdf -Force }
  $fileUrl = 'file:///' + ($htmlPath -replace '\\','/')

  # Chrome writes a "NNN bytes written to file" line to stderr on success. Do NOT redirect
  # it (2>...) under ErrorActionPreference='Stop' - PS 5.1 wraps native stderr into a
  # terminating NativeCommandError even on exit 0. Just relax error handling around the call.
  $prevEAP = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  & $chrome --headless --disable-gpu --no-sandbox `
    --run-all-compositor-stages-before-draw `
    --virtual-time-budget=15000 `
    --allow-file-access-from-files `
    --print-to-pdf="$tmpPdf" `
    --no-pdf-header-footer `
    $fileUrl | Out-Null
  $ErrorActionPreference = $prevEAP

  if (-not (Test-Path $tmpPdf)) { throw "Chrome did not produce $tmpPdf for $($c.key)" }

  $outPdf = Join-Path $root "$($c.key)_grid_pages.pdf"
  Copy-Item $tmpPdf $outPdf -Force
  $kb = [math]::Round((Get-Item $outPdf).Length / 1KB)
  Write-Host "Wrote $outPdf  (${kb} KB)"
}
