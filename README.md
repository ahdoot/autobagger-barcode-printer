# Autobagger Barcode Printer

Windows app for a warehouse autobagger station: scan a QR code
(`SKU|Barcode|Quantity`), the product is queued, and each Ctrl+P prints one
ShipHero-style Code128 label to the selected thermal printer.

`AutobaggerBarcodePrinter.ps1` is the whole app (PowerShell 5.1 + WinForms,
no install needed). Deployed stations check this repository's raw file and
self-update automatically when `$script:AppVersion` here is newer.

No credentials are stored in this repository. Station-specific configuration
(SQL connection, printer, language) lives in each station's
`%APPDATA%\AutobaggerBarcodePrinter\settings.json`.
