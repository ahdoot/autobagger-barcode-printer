# Picker Training

Small Vercel app for the peak-season picker training station. Each button
creates real **pending** ShipHero orders in the **SHIPBOTS** 3PL child account,
tagged `picker-training`, using six candy/gum products whose barcodes match the
physical wrappers.

| Product | SKU | Barcode |
|---|---|---|
| Hershey's Milk Chocolate King Size | SBT-HERSHEY-KS | 03422007 |
| KitKat | SBT-KITKAT | 03424607 |
| Butterfinger | SBT-BUTTERFINGER | 099900100873 |
| Hubba Bubba Bubble Tape | SBT-BUBBLETAPE | 022110079806 |
| Peanut M&M's | SBT-MMS-PEANUT | 040000000327 |
| Trident White Spearmint Gum | SBT-TRIDENT | 073390055530 |

Orders ship "to" the Gardena warehouse address, so a label printed by mistake
comes right back.

## Files

- `index.html` – the page: items per order (presets / steppers / random), number of orders, Create; recent orders from ShipHero
- `api/create-orders.js` – creates the orders via the ShipHero Public API
- `api/recent.js` – latest training orders, shown on the page
- `api/reset.js` – resets the station. `mode: auto` (run on page open) only touches training orders a picker has started — picked into a tote or locked — and idle 30+ min: clears their totes (units go back to the bins) and cancels them; untouched orders stay. `mode: all` (Reset button) cancels every open training order.
- `api/catalog.js` / `api/_catalog.js` – the training product list (only these SKUs are allowed)
- `img/` – front-of-pack images

## Deploy on Vercel

1. Vercel → Add New → Project → import `ahdoot/autobagger-barcode-printer`.
2. Root Directory: `picker-training`. Framework Preset: Other. No build command.
3. Environment variables:
   - `SHIPHERO_REFRESH_TOKEN` – refresh token for a ShipHero API (developer) user on the
     3PL parent account. It needs permission to create orders.
   - `SHIPHERO_USERNAME` / `SHIPHERO_PASSWORD` – optional backup login. Used only if the
     refresh token is ever rejected, so the app keeps working without anyone swapping tokens.
   - `TRAINING_PIN` – optional. When set, the page asks for this PIN before creating orders.
4. Deploy.

Live: https://autobagger-barcode-printer-picker-t.vercel.app/

## Token upkeep

ShipHero access tokens last 28 days; the app gets a fresh one from the refresh token
automatically. If the refresh token stops working, the app falls back to the username/password
login. `GET /api/health` reports whether login works (`ok`, and `via` = `refresh_token` or
`password_login`) and is checked weekly by a scheduled Claude task that alerts on failure.
