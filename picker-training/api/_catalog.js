// Training catalog: products created in the SHIPBOTS 3PL child account.
// Barcodes are exactly what's printed on the physical wrappers.

const SHIPBOTS_ACCOUNT_ID = 'QWNjb3VudDo2OTY4Mw=='; // SHIPBOTS (legacy 69683)

const PRODUCTS = {
  'SBT-HERSHEY-KS':   { name: "Hershey's Milk Chocolate King Size", price: '2.49', barcode: '03422007', img: '/img/hersheys.jpg' },
  'SBT-KITKAT':       { name: 'KitKat',                             price: '1.99', barcode: '03424607', img: '/img/kitkat.jpg' },
  'SBT-BUTTERFINGER': { name: 'Butterfinger',                       price: '1.99', barcode: '099900100873', img: '/img/butterfinger.jpg' },
  'SBT-BUBBLETAPE':   { name: 'Hubba Bubba Bubble Tape',            price: '2.29', barcode: '022110079806', img: '/img/bubbletape.jpg' },
  'SBT-MMS-PEANUT':   { name: "Peanut M&M's",                       price: '1.99', barcode: '040000000327', img: '/img/mms.jpg' },
  'SBT-TRIDENT':      { name: 'Trident White Spearmint Gum',        price: '1.79', barcode: '073390055530', img: '/img/trident.jpg' },
};

// Orders ship "to" the Gardena warehouse so a label printed by accident comes right back.
const SHIP_TO = {
  company: 'ShipBots Picker Training',
  address1: '1715 W Rosecrans Ave',
  city: 'Gardena',
  state: 'CA',
  state_code: 'CA',
  zip: '90249',
  country: 'US',
  country_code: 'US',
  phone: '818-305-4263',
};


module.exports = { SHIPBOTS_ACCOUNT_ID, PRODUCTS, SHIP_TO };
