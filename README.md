# Anvil

Custom Cubyz **0.4.1** server ([upstream](https://github.com/PixelGuys/Cubyz)). Runs the Ashframe community server. Build: `zig build -Doptimize=ReleaseSafe`. Tests: `zig build test -Doptimize=ReleaseSafe`.

## Player Commands

| Command | What it costs / does |
| :--- | :--- |
| `/home` | Teleport home. Free. |
| `/sethome` | Set home. First time 20 Orbs, moving after is free. |
| `/delhome` | Delete home. |
| `/homes` | Show home location. |
| `/waypoint` | Show waypoint anchors + coordinates. Stand on either to teleport (3s cooldown). |
| `/tpa <player>` | Teleport request. 1 Orb on accept. Expires in 30s. |
| `/tpaccept` / `/tpdeny` | Accept / decline request. |
| `/back` | Return to last position (also works on death). 1 Orb. |
| `/spawn` | Teleport to spawn. Free. |
| `/msg <player> <message>` | Private message (filtered). |
| `/claim` | Claim 16×16×32. First free, then Ruby Ore doubling (max 10). |
| `/claim list` / `info` / `members` | Your claims / who owns where you stand / who can build here. |
| `/claim trust / untrust <player>` | Let someone build here / remove them. |
| `/claim accept / deny <player>` | Approve / decline neighbour request (2 min). |
| `/claim abandon` | Give up the claim. |
| `/claim show` | Nearby claim outlines: white yours, green buildable, red others. |
| `/alliance` | Villages, pooled claim slots (max 5 members). See `/alliance help`. |
| `/shop sell / buy <a> <item> for <b> <item>` | Chest + sign shop. Owner-bound registry, confirm menu, payout reserve, owner-only break. |
| `/eat` | Eat an apple (3.5hp, fails at full health). |
| `/titles` | Title list. Secret ones hidden until earned. |
| `/title <name>` / `/title clear` | Wear a gameplay title (above head) / remove it. Season badges (S0–S3) show in chat automatically. |
| `/playtime` / `/playtime list` | Your playtime / leaderboard. |
| `/stats` | Your stats. |
| `/avatar` | Change model (also name lookup). |
| `/afk` | Toggle AFK (also auto after 5 min idle). |
| `/players` | Online players. |
| `/kill @<i>` or `/kill <name>` | Kill a player. |
| `/help` | Commands you can use. |

Chat supports `:emoji:` shortcodes and `@player` mention pings.

## Added Content

Blocks: `waypoint` (link pairs by placing 2), `sky_core` (place to reach the sky islands, min 128 apart, 3s cooldown — first use builds a pad with an unbreakable `return_core` back), `broken_sky_core` (ancient shrine loot). Items: Amber Orb (teleport currency), core fragment. Particles: claim blocked/friend poofs. Structure: ancient sky shrine.

## Recipes

- `4 glass + 6 amber ore → 10 Amber Orbs`
- `4 core fragment + 16 iron + 4 glass → 1 Sky Core`
- `16 nimbusite tile + 8 glass + 6 Amber Orbs → 2 Waypoints`

## Admin Commands

| Command | Does |
| :--- | :--- |
| `/ban <name\|@index\|key> [reason]` | Permanent ban. |
| `/unban <name>` | Lift ban + reset strikes. |
| `/unstrike <name>` | Clear chat-filter strikes live. |
| `/bans` | List bans. |
| `/report` / `all` / `yes` / `no` / `clear` | Violation review queue. |
| `/veteran grant / revoke / name / limbo / key` | Season badges. See `/veteran help`. |
| `/prefix add / remove @<i> [text]` | Chat prefixes. |
| `/claim remove` | Remove someone's claim. |
| `/skyscan` | Debug sky-island column trace. |

Sensitive actions additionally gate behind `/ashframe/admin/*` (never granted by default).

## Ops / Config (`launchConfig.zon`)

`serverOwnerKey` (admin bootstrap), `cpuThreads` (chunk gen workers), `ashframeMetrics` (default on), `ashframePackSkip` (default on), `serverAuthoritativeCharges` (default on), `titlesInNametag` (default on, vanilla clients force off), `customParticles` / `customStructures` (default on), `antiXray` (default off), `dynamicRenderDistance` (default off).

## Notes

- Chat/signs/names filtered (3 strikes = ban). Mild profanity allowed.
- Anticheat logs to `saves/<world>/ashframe_anticheat.zig.zon`. Test suite: `tools/run_anticheat_tests.sh`.
- Metrics snapshot: `saves/<world>/ashframe_metrics.json`. Dashboard: `tools/ashframe_monitor.py`.
- Networking is vanilla-compatible: interest-gated broadcasts (same packets, fewer recipients), asset-pack skip, slow-channel chunks/lightmaps.
