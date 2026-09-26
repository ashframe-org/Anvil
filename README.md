# Cubyz-Ashframe-Server

Ashframe community server. Targets Cubyz **0.4.1** ([upstream](https://github.com/PixelGuys/Cubyz)). Overlay branch: only files differing from clean upstream. Build: `zig build -Doptimize=ReleaseSafe`. Tests: `zig build test -Doptimize=ReleaseSafe`.

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
| `/back` | Return to last position. 1 Orb. |
| `/spawn` | Teleport to spawn. Free. |
| `/msg <player> <message>` | Private message. |
| `/claim` | Claim 16×16×32. First free, then Ruby Ore doubling (max 10). |
| `/claim list` / `info` | Your claims / who owns where you stand. |
| `/claim trust / untrust <player>` | Let someone build here / remove them. |
| `/claim accept / deny <player>` | Approve / decline neighbour request (2 min). |
| `/claim abandon` | Give up the claim. |
| `/claim show` | Nearby claim outlines: white yours, green buildable, red others. |
| `/alliance` | Villages, pooled claim slots. See `/alliance help`. |
| `/shop sell / buy <a> <item> for <b> <item>` | Chest + sign shop. |
| `/eat` | Eat an apple. |
| `/titles` | Title list. Secret ones hidden until earned. |
| `/title <name>` / `/title clear` | Wear a gameplay title (above head) / remove it. Season badges (S0–S3) show in chat automatically. |
| `/playtime` / `/playtime list` | Your playtime / leaderboard. |
| `/stats` | Your stats. |
| `/avatar <skin>` | Change model. |
| `/afk` | Toggle AFK (also auto after 5 min idle). |
| `/players` | Online players. |
| `/kill @<i>` or `/kill <name>` | Kill a player. |
| `/help` | Commands you can use. |

## Recipes

- `4 glass + 6 amber ore → 10 Amber Orbs`
- `4 core fragment + 16 iron + 4 glass → 1 Sky Core`
- `16 nimbusite tile + 8 glass + 6 Amber Orbs → 2 Waypoints`

## Admin Commands

| Command | Does |
| :--- | :--- |
| `/ban <name\|@index\|key> [reason]` | Permanent ban. |
| `/unban <name>` | Lift ban + reset strikes. |
| `/bans` | List bans. |
| `/report` | Violations, bans, kicks, performance. |
| `/veteran` | Grant/revoke season badges. See `/veteran help`. |
| `/prefix add / remove @<i> [text]` | Chat prefixes. |
| `/claim remove` | Remove someone's claim. |

## Notes

- Chat/signs/names filtered (3 strikes = ban). Mild profanity allowed.
- Anticheat logs to `saves/<world>/ashframe_anticheat.zig.zon`. Test suite: `tools/run_anticheat_tests.sh`.
- Metrics snapshot: `saves/<world>/ashframe_metrics.json`. Dashboard: `tools/ashframe_monitor.py`.
- Dynamic render distance ships **off** (`dynamicRenderDistance = false`).
