# nzkfc_drone
A deployable drone resource for FiveM using the **Qbox** framework. Players can deploy a personal drone that follows them, provides healing and can be flown manually in FPV mode.

Licensed under **GNU GPL v3** — free to use, modify and share. Commercial sale is prohibited.

---

## Preview

<a href="https://i.imgur.com/oMCiSsK.png" target="_blank"><img src="https://i.imgur.com/oMCiSsK.png" width="30%" alt="Drone deployed"></a>&nbsp;<a href="https://i.imgur.com/7zt3Pnm.png" target="_blank"><img src="https://i.imgur.com/7zt3Pnm.png" width="30%" alt="Drone FPV"></a>&nbsp;<a href="https://i.imgur.com/13ESXZk.jpeg" target="_blank"><img src="https://i.imgur.com/13ESXZk.jpeg" width="30%" alt="Drone aerial view"></a>

---

## Features
- **Deploy & Recall** — Pull out your drone with a kneel animation. The drone spawns on the ground in front of you and lifts off to your shoulder. Pack it away the same way.
- **Shoulder Follow** — When deployed, the drone hovers at your left shoulder and follows you smoothly with a natural bob and heading delay.
- **FPV Control** — Take manual control of the drone in first-person view. Fly freely up to a configurable range before signal is lost.
- **Healing Mode** — Activate healing to have the drone restore health to all players within a configurable radius. Shows a pulsing green AOE marker.
- **Drone Storage** — Each drone has its own persistent stash inventory. Store items, batteries and equipment. Drone items cannot be placed inside the stash.
- **Battery System** — The drone requires a `drone_battery` in its stash to operate. Battery drains over time. When depleted the drone lands and powers down until a new battery is inserted.
- **Damage System** — The drone can be shot down. Health degrades with hits and is displayed on each strike. Configurable max health.
- **Destruction & Recovery** — When destroyed the drone swaps to a wrecked model and falls to the ground. Storage remains accessible for a configurable time before being cleared.
- **Battery Removal** — Removing the battery mid-flight causes the drone to drop and power down. Reinserting a battery brings it back to life automatically.
- **Unique Serial Numbers** — Each drone is assigned a unique serial `DRN-XXXXXX` on first use, stored in item metadata. Visible in your inventory.
- **Collision Detection** — FPV control includes raycast-based collision detection to prevent flying through walls and terrain.
- **Native GTA Audio** — Uses GTA's built-in `DLC_BTL_Drone_Sounds` audio bank. No external sound files required.
- **Fully Configurable** — All behaviour, offsets, speeds, battery drain, healing settings and more are in a single `config.lua`.

---

## Dependencies

| Resource | Notes |
|---|---|
| [qbx_core](https://github.com/Qbox-project/qbx_core) | Framework |
| [ox_inventory](https://github.com/overextended/ox_inventory) | Inventory (2.45.0+) |
| [ox_lib](https://github.com/overextended/ox_lib) | UI notifications and animations |
| [ox_target](https://github.com/overextended/ox_target) | Drone interaction targeting |
| [oxmysql](https://github.com/overextended/oxmysql) | Database (used by ox_inventory) |

---

## Installation

### 1. Add the resource

Drop the `nzkfc_drone` folder into your `resources` directory (or in whatever subfolder you want) and add the following to your `server.cfg`:

```
ensure nzkfc_drone
```

### 2. Add items to ox_inventory

Open `ox_inventory/data/items.lua` and add the following entries:

```lua
-- nzkfc_drone
['drone'] = {
    label       = 'Drone',
    weight      = 2000,
    stack       = false,
    close       = true,
    consume     = 0,
    limit       = 1,
    description = 'A deployable drone.',
    client      = {
        export = 'nzkfc_drone.useDrone'
    }
},
['drone_battery'] = {
    label       = 'Drone Battery',
    weight      = 300,
    stack       = false,
    close       = true,
    consume     = 0,
    description = 'Battery for a drone. Place inside the drone storage to power it.',
},
['drone_battery_empty'] = {
    label       = 'Empty Drone Battery',
    weight      = 300,
    stack       = false,
    close       = true,
    consume     = 0,
    description = 'Empty battery for a drone. Might be worth something?',
},
```

### 3. Add item images to ox_inventory

Place your item images in the `ox_inventory/web/images/` folder. Images must be **`.png`** format and named exactly after the item:

| File | Item |
|---|---|
| `drone.png` | Drone |
| `drone_battery.png` | Drone Battery |
| `drone_battery_empty.png` | Empty Drone Battery |

> If you don't have custom images, you can use any 128×128 PNG placeholder. ox_inventory will display a fallback icon if no image is found.

### 4. Give yourself a drone (testing)

Using an admin command:
```
/giveitem [playerid] drone 1
```

---

## Controls

### General

| Action | Control |
|---|---|
| Deploy / Pack away drone | Use the `drone` item from inventory |
| Recall drone (cancel stay) | `/calldrone` |

### Drone Target Menu (look at drone + interact key)

| Option | Description |
|---|---|
| **Drone Storage** | Open the drone's personal stash inventory |
| **Activate Healing** | Toggle healing aura for nearby players |
| **Check Battery** | Display current battery percentage |
| **Tell Drone to Stay** | Park the drone at its current position |
| **Take Control** | Enter FPV control mode |
| **Drone Flip** | Perform a 360° flip trick |
| **Pack Drone** | Pack the drone away (grounded state only) |

### FPV Control Mode

| Key | Action |
|---|---|
| `W` | Fly forward |
| `S` | Fly backward |
| `A` | Strafe left |
| `D` | Strafe right |
| `Q` | Ascend |
| `E` | Descend |
| `Mouse` | Look / Yaw |
| `Space` | Disconnect and return to player |

---

## Configuration

All settings are in `shared/config.lua`. Key options:

| Option | Description |
|---|---|
| `DroneModel` | GTA prop model for the drone |
| `TargetOffsetLocal` | Shoulder follow position offset |
| `KneelDuration` | Deploy/recall animation length (ms) |
| `StorageSlots` / `StorageWeight` | Drone stash capacity |
| `HealEnabled` / `HealRadius` / `HealAmount` | Healing configuration |
| `DamageEnabled` / `DroneMaxHealth` | Damage system |
| `BatteryEnabled` / `BatteryDrainMoving` | Battery system |
| `WreckCleanupMinutes` | Time before destroyed drone stash is cleared |
| `ControlMaxRange` / `ControlMoveSpeed` | FPV control settings |

---

## License

Copyright (C) 2025 nzkfc

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

See the [LICENSE](LICENSE) file for full details.
