# Batch 2: stock supply chain + 12-hour months

**Apply batch 1 (`2026-09-26-cars`) first.** This batch's CitizenService builds on it.

## What changes

- **Time:** a game day is 24 real minutes, so a 30-day month is 12 h at 1x, 6 h at 2x,
  4 h at 3x. Day/night follows the same clock (short nights kept). Money per MONTH is
  unchanged: taxes are now tuned per month, so a shorter month does not tip the budget.
- **One good, "Stock":** every factory makes it, every shop sells it, any factory can
  supply any shop. The building panel shows "Produces/Sells: Stock" and how much is held
  (factories: "In yard").
- **Realistic restocking:** each shop learns its own daily sales and reorders when stock
  plus what is already coming falls to 2.5 days of sales, back up to 6 days. That is about
  2 deliveries per game week per shop; bigger shops get bigger trucks (van 40, box 80/120,
  semi 260 units). Factories hold up to 2 weeks of output, keep 3 days back for local
  shops, and export the rest in full trucks. No factory stock means imports.
- **Realistic shopping:** each household shops about 2.5 times per game week, 08:00-20:00,
  instead of every ~17 seconds whenever someone is idle.
- **Saves:** factory and shop stock is now saved with the city (older saves still load).

## Scripts

| File | Script in Studio |
|---|---|
| `ServerScriptService.Services.City.CitySimConstants.luau` | ServerScriptService > Services > City > CitySimConstants |
| `ServerScriptService.Services.City.TimeService.luau` | ServerScriptService > Services > City > TimeService |
| `ServerScriptService.Services.City.Economy.CityEconomyService.luau` | ServerScriptService > Services > City > Economy > CityEconomyService |
| `ServerScriptService.Services.City.Economy.SupplyService.luau` | ServerScriptService > Services > City > Economy > SupplyService |
| `ServerScriptService.Services.City.Simulation.CitizenService.luau` | ServerScriptService > Services > City > Simulation > CitizenService |
| `StarterPlayer.StarterPlayerScripts.HUD.BuildingInfoController.luau` | StarterPlayer > StarterPlayerScripts > HUD > BuildingInfoController |

## Applying

Tell your local Claude:

> Apply `Roblox/pending-fixes/2026-09-26-stock-and-time/changes.diff` to the six scripts it
> names in Studio, after batch 1 is applied. Only change the lines in the diff.

Pasting whole files works too, only if you have not edited these scripts since the place
file you sent (the CitizenService file here already includes batch 1's change).

## What to check in a playtest

- The clock: a full day takes 24 minutes at 1x.
- Click a shop: "Sells: Stock", stock going down as people shop, then a truck refilling it
  roughly twice a game week. Click a factory: "In yard" filling up.
- Far fewer delivery trucks; the ones you see are bigger for bigger shops.
- Budget panel: monthly figures in the same range as before. Retail and export income will
  differ (shopping is now realistic) -- tell me if the balance feels off.
