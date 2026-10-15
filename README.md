# Autobagger Barcode Printer

Windows app for a warehouse autobagger station: scan a QR code
(`SKU|Barcode|Quantity`), the product is queued, and each Ctrl+P prints one
ShipHero-style Code128 label to the selected thermal printer.

`AutobaggerBarcodePrinter.ps1` is the whole app (PowerShell 5.1 + WinForms,
no install needed). Deployed stations check this repository's raw file and
self-update automatically when `$script:AppVersion` here is newer.

`picker-training/` is a separate Vercel web app for the picker training
station (creates training orders in the SHIPBOTS ShipHero account). See
`picker-training/README.md`.

No credentials are stored in this repository. Station-specific configuration
(SQL connection, printer, language) lives in each station's
`%APPDATA%\AutobaggerBarcodePrinter\settings.json`.
