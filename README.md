# Anvil - Custom Server Enviroment for Cubyz

Custom server modification specifically for hosting and running the **Ashframe** community server.

---

## Player Commands

| Syntax / Usage | Description |
| :--- | :--- |
| `/home add <name>` | Saves your current location into 1 of 3 custom home slots. (Names like `"list"`, `"add"`, or `"remove"` are restricted). |
| `/home <name>` | Teleports you back to that specific saved home location. |
| `/home list` | Displays a scannable list of all your currently saved home locations. |
| `/home remove <name>` | Deletes the specified home location and frees its slot memory. |
| `/home spawn <name>` | Sets that specific home as your active respawn point whenever you die in the world. |
| `/tpa <player>` | Sends a teleport request using smart name matching. Automatically filters out game color codes and handles case-insensitive partial names or explicit `@id` fallbacks. |
| `/tpaccept` | Accepts a pending incoming teleport request. |
| `/back` | Teleports you back to your last position, including your exact spot of death right before you respawn. |
| `/spawn` | Teleports you instantly to the absolute global world spawn point. |
| `/playtime` | Displays your total accumulated playtime on this server. |
| `/playtime list` | Opens the server-wide playtime leaderboard. |
| `/avatar <skin>` | Modifies your character's active 3D model skin. *(e.g., `/avatar base:skin_name`)* |
| `/afk` | Toggles your status to away-from-keyboard and notifies the chat. |
| `/players` | Displays a list of all currently connected online players. |
| `/help` | Displays a personalized list of commands showing only what you have permission to use. |

---

## Admin Commands

### Prefix Management
*   **Add a Prefix:**
    ```bash
    /prefix add @<playerIndex> <text>
    ```
    *Example:* `/prefix add @2 Admin` — Assigns a bracketed visual title to a player in chat.
*   **Remove a Prefix:**
    ```bash
    /prefix remove @<playerIndex>
    ```
    *Example:* `/prefix remove @2` — Strips the title and safely deallocates the string memory from the server.

> **Note:** Admin commands are dynamically filtered out of `/help` and hidden from regular users who lack permission.
