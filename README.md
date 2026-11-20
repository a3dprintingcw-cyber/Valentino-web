# Valentino The Barber

Booking website for Valentino The Barbershop, Franklin D. Rooseveltweg 307N (Dupont), Curaçao.

- Services and prices, with booking handed off to Fresha
- House call request form that sends a WhatsApp message
- Opening hours with live open or closed status (Curaçao time)

Static site: `index.html` and `logo.png`, no build step. Works on GitHub Pages.

## Settings to update

At the top of the script in `index.html`:

- `FRESHA`: Fresha booking link
- `SHOP`: shop phone number
- `HOUSECALL`: house call number (currently the shop number, replace it)

Services and prices are in the `MENU` array.
