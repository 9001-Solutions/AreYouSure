# AreYouSure

An [Ashita v4](https://www.ashitaxi.com/) addon that prevents accidental drops and vendor sales of valuable items in Final Fantasy XI.

When you try to drop or sell a valuable item, a confirmation dialog appears with color-coded buttons and full keyboard support — so you never accidentally lose that Ridill.

## Features

- **Drop protection** — intercepts outgoing drop packets (0x028) for valuable items
- **Sell protection** — intercepts vendor sale confirmations (0x085) for valuable items
- **Smart detection** — automatically flags items that are:
  - Rare or Ex
  - Equippable gear at or above a configurable level threshold (default: 50)
  - Worth more than a configurable vendor price threshold (default: 10,000 gil)
- **Manual protection** — add any item ID to a protected list
- **Per-action whitelisting** — approving an item adds it to a separate drop or sell whitelist, so you won't be asked again for that action
- **Vendor price display** — shows total vendor value (unit price x quantity) in the confirmation dialog
- **Keyboard navigation** — Left/Right arrows to switch buttons, Enter to confirm, Escape to cancel
- **Color-coded buttons** — red for the dangerous action, green for the safe option
- **Per-character settings** — whitelists and thresholds saved separately for each character

## Screenshots

<img width="1014" height="559" alt="image" src="https://github.com/user-attachments/assets/4bbeb918-a95c-4a3e-87c6-9e88b35d98e9" />

<img width="719" height="447" alt="image" src="https://github.com/user-attachments/assets/2a2c56f8-bef0-44da-b3ce-dfd7a9978990" />


## Installation

Download the [latest release](https://github.com/9001-Solutions/AreYouSure/releases/latest) and extract the `AreYouSure` folder into your Ashita `addons/` directory.

Load in-game:
```
/addon load AreYouSure
```

To load automatically, add to your `scripts/default.txt`:
```
/wait 3
/addon load AreYouSure
```

## Commands

| Command | Description |
|---|---|
| `/ays` | Toggle addon on/off |
| `/ays level [n]` | Get or set minimum equipment level threshold |
| `/ays price [n]` | Get or set minimum vendor price threshold (total value) |
| `/ays add <id>` | Manually protect an item by its ID |
| `/ays remove <id>` | Remove an item from the manual protection list |
| `/ays list` | Show all manually protected items |
| `/ays reset [sell\|drop\|all]` | Clear whitelist(s) |

## How It Works

1. You attempt to drop or sell an item
2. The addon checks if the item is "valuable" (Rare/Ex, high-level gear, high vendor price, or manually protected)
3. If valuable and not already whitelisted, the packet is blocked and a confirmation dialog appears
4. **Yes** — the item is dropped/sold and added to the whitelist for that action type (you won't be asked again)
5. **No** / **Escape** — the action is cancelled, item stays in your inventory

## Settings

Settings are saved per-character to `config/addons/AreYouSure/`.

| Setting | Default | Description |
|---|---|---|
| `enabled` | `true` | Master toggle |
| `min_level` | `50` | Minimum equipment level to flag as valuable |
| `min_vendor_price` | `10000` | Minimum total vendor value (price x qty) to flag |
| `protected_items` | `{}` | Manually protected item IDs |
| `drop_whitelist` | `{}` | Items approved for dropping |
| `sell_whitelist` | `{}` | Items approved for selling |

## Vendor Price Data

`vendor_prices.lua` contains base NPC sell prices extracted from [LandSandBoat](https://github.com/LandSandBoat/server). Retail server prices may differ.
