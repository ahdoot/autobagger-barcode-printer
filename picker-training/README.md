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

- `index.html` – the page (scenario tickets, random batch, order builder, session log)
- `api/create-orders.js` – creates the orders via the ShipHero Public API
- `api/catalog.js` / `api/_catalog.js` – the training product list (only these SKUs are allowed)
- `img/` – front-of-pack images

## Deploy on Vercel

1. Vercel → Add New → Project → import `ahdoot/autobagger-barcode-printer`.
2. Root Directory: `picker-training`. Framework Preset: Other. No build command.
3. Environment variables:
   - `SHIPHERO_REFRESH_TOKEN` – refresh token for a ShipHero API (developer) user on the
     3PL parent account. It needs permission to create orders.
   - `TRAINING_PIN` – optional. When set, the page asks for this PIN before creating orders.
4. Deploy.
