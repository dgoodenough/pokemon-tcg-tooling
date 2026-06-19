# Pokémon TCG Checklist Generator

Generates **printable collector checklists and binder-grid layouts** (PDF + HTML)
for the Pokémon Trading Card Game — e.g. *every Ampharos card ever printed* or
*every card illustrated by Komiya*.

## How it works

A PowerShell + HTML generator. For a given theme (a Pokémon, an illustrator, a
set), it builds:

- a **subset checklist** (`checklists/generate.ps1` → `*_checklist.pdf`)
- a **binder-grid layout** (`checklists/build_grids.ps1` → `*_grid_pages.pdf`)
- a **TCGplayer Mass Entry** string for buying the missing cards
  (`checklists/build_komiya_massentry.ps1`)

Per-theme card data lives in `checklists/<theme>/data.js`; the HTML templates
render it and Chrome headless prints to PDF. Set-symbol icons live in
`checklists/symbols/`. Sample outputs for Ampharos, Komiya, and Wailmer/Wailord
are included.

## Layout

```
checklists/
├── generate.ps1                 subset checklist generator (theme → PDF)
├── build_grids.ps1              binder-grid layout generator
├── build_komiya_massentry.ps1   TCGplayer Mass Entry string builder
├── <theme>/                     per-theme checklist.html + data.js
│                                (ampharos, komiya, wailmer_wailord)
├── grids/                       per-theme binder-grid HTML
├── symbols/                     Pokémon set-symbol icons (UI assets)
└── *_checklist.pdf,
    *_grid_pages.pdf             sample generated outputs
```

## Stack

PowerShell · HTML/CSS · JavaScript · Chrome headless (HTML → PDF).

## Related

Companion repo: **[pokemon-tcg-pricing](https://github.com/dgoodenough/pokemon-tcg-pricing)**
— a DuckDB pricing & collection-analytics pipeline over the same card domain.

## A note on Pokémon IP

Pokémon, the set symbols, and card data are © The Pokémon Company / Nintendo /
Game Freak. This is a personal, non-commercial fan tool. The set-symbol images in
`checklists/symbols/` are included solely as UI assets for rendering checklists.

## License

[MIT](LICENSE).
