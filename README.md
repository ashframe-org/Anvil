# Cubyz-Ashframe-Server

Custom server modification specifically for hosting and running the **Ashframe** community server.

This branch targets Cubyz **0.4.0** (built on current [PixelGuys/Cubyz](https://github.com/PixelGuys/Cubyz) master). It contains only the files that differ from a clean 0.4.0 checkout — download or clone upstream Cubyz separately, then copy these files over the matching paths and build as normal (`zig build`).

---

## Player Commands

| Syntax / Usage | Description |
| :--- | :--- |
| `/home` | Teleports you to your saved home location. |
| `/home set` | Saves your current location as your home. |
| `/home remove` | Deletes your saved home. |
| `/tpa <player>` | Sends a teleport request using smart name matching. Automatically filters out game color codes and handles case-insensitive partial names or explicit `@id` fallbacks. |
| `/tpaccept` | Accepts a pending incoming teleport request. |
| `/tpdeny` | Declines a pending incoming teleport request. |
| `/back` | Teleports you back to your last position, including your exact spot of death right before you respawn. |
| `/spawn` | Teleports you instantly to the world spawn point. |
| `/msg <player> <message>` | Sends a private message to another player. Uses the same smart name matching as `/tpa`. |
| `/playtime` | Displays your total accumulated playtime on this server. |
| `/playtime list` | Opens the server-wide playtime leaderboard. |
| `/avatar <skin>` | Modifies your character's active 3D model skin. *(e.g., `/avatar base:skin_name`)* |
| `/afk` | Toggles your status to away-from-keyboard and notifies the chat. Also triggers automatically after 5 minutes idle. |
| `/players` | Displays a list of all currently connected online players. |
| `/kill @<playerIndex>` or `/kill <name>` | Kills the specified player (self, by index, or by smart name match). |
| `/help` | Lists commands you have permission to use, split into "Default" (Cubyz) and "Custom" (Ashframe) sections. |

---

## Admin Commands

### Prefix Management
*   **Add a Prefix:**
    ```bash
    /prefix add @<playerIndex> <text>
    ```
    *Example:* `/prefix add @2 Admin` — Assigns a bracketed visual title to a player in chat. `<text>` may span multiple words, and can embed its own `§#rrggbb` color code (defaults to red if omitted).
*   **Remove a Prefix:**
    ```bash
    /prefix remove @<playerIndex>
    ```
    *Example:* `/prefix remove @2` — Strips the title and safely deallocates the string memory from the server.

> **Note:** Admin commands are dynamically filtered out of `/help` and hidden from regular users who lack permission.

---

## Notes on this port

- `/home` was simplified from the old 3-slot system down to a single home. `/home spawn` (setting your home as your respawn point) was dropped — it never actually hooked into how death/respawn works in current upstream, so it wasn't worth carrying forward broken. Old 3-slot save data still loads correctly.
- `/spawn` (no arguments) now actually teleports you, instead of just printing coordinates like it did before this port.
- All command output (success, errors, usage hints, chat prefixes, join/leave messages) uses one consistent Ashframe color palette instead of the old mix of plain red/green/yellow.
- Chest-locking and other older fork features are intentionally not part of this pass.
- `/help` now groups commands into "Default" and "Custom" sections; a couple of overly long or awkward built-in command descriptions (`/perm`, `/tickspeed`, `/mask`) were also tightened up for readability.
- `/spawn` (bare, teleport to spawn) is granted to every player by default. Setting another player's spawn point or moving world spawn (`/spawn @<player> <x> <y> <z>`, `/spawn world ...`) still requires the separate `/command/spawn/admin` permission, same pattern as `/prefix`'s admin gate.
