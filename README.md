# Pokémon TCG Tooling

Two related tools for working with the Pokémon Trading Card Game:

- **`checklists/`** — generates printable collector checklists and binder-grid
  layouts (PDF + HTML) from card data, e.g. *every Ampharos card ever printed*
  or *every card illustrated by Komiya*.
- **`pricing/`** — a DuckDB-based pricing & collection-analytics pipeline that
  ingests data from pokemontcg.io, PokeAPI, and TCGplayer exports, then derives
  inventory valuation, set-completion, artist/variant premiums, and buy/sell
  signals.

## `checklists/`

A PowerShell + HTML generator. For a given theme (a Pokémon, an illustrator, a
set), it builds:

- a **subset checklist** (`generate.ps1` → `*_checklist.pdf`)
- a **binder-grid layout** (`build_grids.ps1` → `*_grid_pages.pdf`)
- a **TCGplayer Mass Entry** string for buying the missing cards
  (`build_komiya_massentry.ps1`)

Per-theme card data lives in `checklists/<theme>/data.js`; the HTML templates
render it and Chrome headless prints to PDF. Set-symbol icons live in
`checklists/symbols/`. Sample outputs for Ampharos, Komiya, and Wailmer/Wailord
are included.

## `pricing/`

A local analytics pipeline — no service, no cloud. Full design is in
[`pricing/ARCHITECTURE.md`](pricing/ARCHITECTURE.md); in brief:

```
external sources ─► PowerShell ingestion ─► raw/ cache ─► DuckDB ─► views ─► HTML/PDF
(pokemontcg.io,        (seed_*.ps1,         (idempotent)  (dims +   (SQL    (Chrome
 PokeAPI, TCGplayer     import_*.ps1)                      facts +   window   headless)
 CSV exports)                                              crosswalk) fns)
```

- **`scripts/schema.sql`** — dimensions (`dim_card`, `dim_set`, `dim_pokemon`,
  …), append-only facts (`fact_price`, `fact_inventory_snapshot`), a crosswalk
  (`card_alias`) and a curation layer (`card_override`, `outlier_flag`).
- **`scripts/views.sql`** — the materialized analytics: inventory value, set
  completion, rarity/Pokémon price indices, artist & variant premiums, and
  buy/sell signals.
- **`scripts/*.ps1`** — ingestion + report rendering.

The architecture doc also documents the pipeline's known data-quality limits
(thin top-of-market pricing, promo-set cohort distortion, meta-relevance
confounds) and the planned mitigations — worth a read.

## What's included (and what isn't)

To keep the repo lean and avoid redistributing third-party data or anything
personal, these are intentionally git-ignored:

- **`pipeline.duckdb`** — large, rebuildable from cache, and holds personal
  inventory.
- **`*/raw/`** — pokemontcg.io / PokeAPI dumps, TCGplayer CSV exports, and
  Bulbapedia HTML scrapes (third-party data).
- **`pricing/reports/`** — generated dashboards that include personal collection
  valuation and cost-paid figures.
- **`refs/`** — personal order documents.

Included: all original code, the SQL schema/views, the architecture doc, and a
few sample generated checklists so the tools are understandable end-to-end.

## Stack

PowerShell · DuckDB · SQL · HTML/CSS (Chrome headless → PDF) · JavaScript.

## A note on Pokémon IP

Pokémon, the set symbols, and card data are © The Pokémon Company / Nintendo /
Game Freak. This is a personal, non-commercial fan tool. The set-symbol images in
`checklists/symbols/` are included solely as UI assets for rendering checklists.

## License

[MIT](LICENSE) — covers the original code in this repo, not the third-party data
or imagery it references.
