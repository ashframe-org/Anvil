# Cubyz-Ashframe-Server

Custom server modification specifically for hosting and running the **Ashframe** community server.

This branch targets Cubyz **0.4.0** (built on current [PixelGuys/Cubyz](https://github.com/PixelGuys/Cubyz) master). It contains only the files that differ from a clean 0.4.0 checkout — download or clone upstream Cubyz separately, then copy these files over the matching paths and build as normal (`zig build`).

---

## Player Commands

| Syntax / Usage | Description |
| :--- | :--- |
| `/home` | Teleports you to your saved home. Free. |
| `/sethome` | Sets your home here. First time costs 20 Orbs (one-time unlock); moving it afterwards is free. |
| `/delhome` | Deletes your saved home. |
| `/homes` | Shows your saved home location. |
| `/waypoint` | Shows your waypoint anchors with coordinates (Waypoint A / Waypoint B). Place two Waypoints to link them; stand on either to teleport (3s cooldown). |
| `/tpa <player>` | Sends a teleport request using smart name matching. Costs 1 Orb on accept; expires after 30 seconds. |
| `/tpaccept` | Accepts a pending incoming teleport request. |
| `/tpdeny` | Declines a pending incoming teleport request. |
| `/back` | Teleports you back to your last position. Costs 1 Orb. |
| `/spawn` | Teleports you instantly to the world spawn point. Free. |
| `/msg <player> <message>` | Sends a private message to another player. Uses the same smart name matching as `/tpa`. |
| `/claim` | Claims a 16×16×32 area around you. First is free; extras cost Ruby Ore (doubling each time, max 10). |
| `/claim list` | Lists the land you own. |
| `/claim info` | Shows who owns the land you're standing on. |
| `/claim trust <player>` | Lets another player build in the claim you're standing in. |
| `/claim untrust <player>` | Removes them again. |
| `/claim accept <player>` | Approves a neighbour's claim request (within 2 minutes). |
| `/claim deny <player>` | Declines it. |
| `/claim abandon` | Gives up the claim you're standing in. |
| `/claim show` | Toggles particle outlines around all nearby claims — white yours, green ones you can build on, red everyone else's. |
| `/ban <name\|@index\|publicKey> [reason]` | (Admin) Permanently bans a player by name, player index or public key (for untypable names). `/unban <name>` lifts it. |
| `/bans` | (Admin) Lists active bans. |
| `/unban <name>` | (Admin) Lifts a ban and resets the player's strike counter. |
| `/report` | (Admin) Shows the server report: recent violations, bans, kicks, restarts and performance. `/report all` for full history, `/report clear` to wipe it. |
| `/eat` | Eats one apple from your inventory, restoring 3.5 health. |
| `/titles` | Lists every title, showing which ones you've unlocked. Secret titles stay hidden as `[Secret]` until earned. |
| `/title <name>` | Wears one of your unlocked gameplay titles above your character's head, e.g. `[Chatty]` on its own line above the name. Season badges (S0–S3) can't be worn — they show automatically in chat. |
| `/title clear` | Removes your active title. |
| `/shop sell <amount> <item> for <amount> <item>` | Turns the chest + sign you're looking at into a shop that sells goods. |
| `/shop buy <amount> <item> for <amount> <item>` | Same, but the shop buys goods from players. |
| `/playtime` | Displays your total accumulated playtime on this server. |
| `/playtime list` | Opens the server-wide playtime leaderboard. |
| `/stats` | Shows your personal stats: playtime, blocks mined/placed, distance, depth, messages, apples, trades. |
| `/avatar <skin>` | Modifies your character's active 3D model skin. *(e.g., `/avatar base:skin_name`)* |
| `/afk` | Toggles your status to away-from-keyboard and notifies the chat. Also triggers automatically after 5 minutes idle. |
| `/players` | Displays a list of all currently connected online players. |
| `/kill @<playerIndex>` or `/kill <name>` | Kills the specified player (self, by index, or by smart name match). |
| `/help` | Lists commands you have permission to use, split into "Default" (Cubyz) and "Custom" (Ashframe) sections. |

### Teleporting

`/spawn` and `/home` are free. `/back` and `/tpa` cost **1 Orb** each. Orbs are made from Amber: `4 glass + 6 amber ore → 10 Amber Orbs`. Setting your home with `/sethome` is a one-time **20 Orbs** (the first use unlocks the slot and sets it); moving it afterwards is free. `/tpa` requests expire after 30 seconds if the other player doesn't answer.

### Waypoints

Place a Waypoint, then a second one to link them. Stand on either anchor to teleport to the other (anyone can use anyone's pair; 3s cooldown, with a message telling you when it's ready). You may own one pair. Breaking an anchor drops it — place it again and it relinks free. Craft: `16 nimbusite tile + 8 glass + 6 Amber Orbs → 2 Waypoints`.

### Sky cores & shrines

Core Fragments come from Broken Sky Cores found inside shrines (each Broken Sky Core drops 4 fragments); `4 core fragment + 16 iron + 4 glass → 1 Sky Core`. Place a Sky Core in your base and stand on it: it builds a one-time landing platform in the sky islands with a return core, then teleports you up. Stand on the return core to come back. Free and unlimited once placed.

### Land claims

Stand where you want your base and type `/claim` — it protects a **16×16×32** box around you. Nobody else can build there, use your chests, or WorldEdit over it. A claim reserves its whole vertical column (nobody can claim above or below you), though protection covers ±16 blocks around your claim height. The first claim is free; extra claims cost more each time (2nd: 1 ruby ore, doubling each time, up to 10 claims). You can't claim within **8 blocks** of someone else's claim unless they approve with `/claim accept <you>`. Share with `/claim trust <player>`, take it back with `/claim untrust`, walk away with `/claim abandon`. Creating a claim and `/claim info` flash its border as particles; `/claim show` keeps redrawing the outlines of all nearby claims (white yours, green buildable, red others).

### Sign shops

Place a chest, put a sign on any side of it, then look at the chest (or the sign) and run one of:

- `/shop sell <amount> <item> for <amount> <item>` — the shop **sells** goods (e.g. `/shop sell 1 ruby_ore for 8 amber_ore`). Customers pay the price and receive the goods.
- `/shop buy <amount> <item> for <amount> <item>` — the shop **buys** goods (e.g. `/shop buy 1 ruby_ore for 8 amber_ore`). Customers hand over the goods and receive the price.

The word `for` is optional. Items can be written without their namespace and are case-insensitive (`ruby_ore`, `Ruby_ore`, `Ruby Ore` all work). On the sign, lines 2-3 are shown from the **customer's** point of view — `-` is what they give, `+` is what they get — with the price line first and the goods line second (e.g. a shop that buys 10 blocks for 10 amber shows `+10x amber` / `-10x blocks`). This writes the offer onto the sign for you and locks the chest and sign to you — only you can open or break them. Anyone else who right-clicks the chest trades with it instead. The last 2 slots are meant to stay free for payouts, so keep them clear or the shop can't trade — you'll be warned when you close the chest if they're occupied. The sign can't be edited or broken by anyone else.

### Chat filter

Chat, signs, private messages (`/msg`), alliance names and player names are filtered for severe slurs and hate terms (mild profanity is allowed, leetspeak like `f4g` is caught). Each hit is a strike; **3 strikes = ban** until season end. Admins can also ban directly with `/ban <name|@index|publicKey> [reason]` (permanent), list bans with `/bans`, and lift any ban with `/unban <name>`.

### Titles

Titles are small collectable achievements. Gameplay titles (Explorer, Skyborn, …) appear **above your character's head** in the world (on their own line, above the name) — never in chat. **Season badges** (S0–S3, granted for playing past seasons) are the reverse: they show automatically as `[S0]` etc. in front of your name **in chat** — lowest season first, since S0 is the flex — and can never be worn above the head. The conditions to unlock them are intentionally never revealed — `/titles` simply lists every title and whether you have earned it, with secret titles remaining labelled `[Secret]` until unlocked. The first title you unlock is worn automatically; use `/title <name>` to switch between the ones you own and `/title clear` to take it off. Titles are purely cosmetic — they grant no rewards.

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

## Dynamic render distance

> **Off by default.** Stock streaming is the known-good behaviour, so the server
> ships with `dynamicRenderDistance = false`. Set it to `true` in
> `launchConfig.zon` to enable the feature below.

When enabled, chunk streaming (the main server cost) is throttled: each player's
effective render distance becomes `min(their own setting, velocity, teleport
ramp, server load)`, with an absolute floor so the immediate area always
streams. This is a *scheduling* throttle only: every request a client makes
while it is within its own render distance (plus a latency margin sized from the
connection RTT) is always eventually delivered, never dropped, so throttling can
make the far view coarser for a moment but can never leave permanent holes.
Keep/drop decisions use the player's fresh server-side position, never
`clientUpdatePos` (which freezes when the client stalls).

- **Server load** is a global, discrete stepper (levels 4→24 chunks). It counts
  *both* queued and held-back chunk work plus tick overrun, holds its level while
  it's borderline, steps **down** as soon as load is high, and only steps **up**
  after the server has stayed calm for a settle period. This is what protects the
  server from teleport bursts and many fast players.
- **Teleport ramp:** every teleport (all commands, shrines, waypoints, sky cores
  — they all go through `genericUpdate.sendTPCoordinates`) starts the target at a
  low distance and expands over ~3 s.
- Requests beyond the effective distance are **held back, never dropped**, and
  re-queued as the cap grows — a requested chunk the client is still waiting for
  is always eventually sent (the client never re-requests).

## Anticheat

Two tiers, both logged and persisted to `saves/<world>/ashframe_anticheat.zig.zon`:

- **Violations** — actions a legitimate client cannot produce (malformed packets,
  out-of-range reach, creative item fills while the server says survival, speed
  beyond the plausible maximum). Reach is **enforced** (8-block radius); other
  checks are logged and operator-notified.
- **Suspects** — things we can't be certain about (heuristic xray/automation
  signals, staff movement, identity edge cases). Info-level only, never notified,
  never enforced — for manual review.

Staff are not exempt from movement logging (a much higher threshold applies) so
egregious cheating by a staff account is still recorded; singleplayer is exempt.
`/report` and the monitor show notes/suspects per second.

### Testing the anticheat

`tools/run_anticheat_tests.sh` runs a scripted "cheat" suite (`src/server/anticheat_test.zig`)
and writes `tools/anticheat-test-report.txt` listing, per case, what was sent,
the result, and whether it was **BLOCKED** or ALLOWED. It covers malformed
position/velocity/rotation, checked float→int, rate-limit bursts, reach,
command coordinate/rotation validation, crafted blueprint headers, and the chat
filter. Run directly with `zig build test -Doptimize=ReleaseSafe`.

It exercises the validation/deserialization layer directly — the network wire is
not simulated, so cases that need a live server/user are verified by hand.

## Server monitoring

The server writes a small JSON performance snapshot a few times a second to
`saves/<world>/ashframe_metrics.json` (disable with `ashframeMetrics = false` in
`launchConfig.zon`). It opens no ports and does not affect clients.

Bundle an external dashboard with `tools/ashframe_monitor.py` (no third-party
packages):

```bash
python3 tools/ashframe_monitor.py              # live terminal dashboard
python3 tools/ashframe_monitor.py --log run.csv # also record history for A/B comparison
python3 tools/ashframe_monitor.py --web 8080    # local web page (http://127.0.0.1:8080/)
```

Tracked: TPS and tick last/avg/peak ms, thread-pool queue, chunk-generation rate
and cost, chunk request/send rate and **chunk bandwidth** (the number that shows
whether the dynamic render distance is helping), chunk tasks dropped per second
(should only be chunks a player has moved past — a spike while stuck means
requested work is being lost), deferred chunk requests and how many players are
currently view-capped, net bandwidth, players, errors/warnings.

Operators (holding `/ashframe/admin/report`) also get a throttled chat line when
their own dynamic render distance changes, e.g.
`[perf] view 24 → 14 chunks (speed 96 b/s; full ≤40, min 10)`.

---

## Notes on this port

- One home per player (`/home` to go, `/sethome` to set — first use costs 20 Orbs, moving is free — `/delhome` to remove, `/homes` to view). Old multi-slot saves fold into the single home.
- `/spawn` (no arguments) now actually teleports you, instead of just printing coordinates like it did before this port.
- All command output (success, errors, usage hints, chat prefixes, join/leave messages) uses one consistent Ashframe color palette instead of the old mix of plain red/green/yellow.
- Chest-locking and other older fork features are intentionally not part of this pass.
- `/help` now groups commands into "Default" and "Custom" sections; a couple of overly long or awkward built-in command descriptions (`/perm`, `/tickspeed`, `/mask`) were also tightened up for readability.
- Invalid command usage now prints a consistent, friendlier error: `Incorrect use of /<command>: <reason>`, followed by the command's options in the `→` list style.
- `/spawn` (bare, teleport to spawn) is granted to every player by default. Setting another player's spawn point or moving world spawn (`/spawn @<player> <x> <y> <z>`, `/spawn world ...`) still requires the separate `/ashframe/admin/spawn` permission, same pattern as `/prefix`'s admin gate.
