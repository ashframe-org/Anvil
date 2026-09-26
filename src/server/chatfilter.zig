const std = @import("std");

const main = @import("main");
const User = main.server.User;

// --- ASHFRAME CUSTOM (Chat filter + strikes + bans) ---
// Blocks severe slurs/hate terms in chat, signs and player names. Mild
// profanity (shit, fuck, etc.) is intentionally allowed. Three strikes = ban
// until season end, unless an admin unbans (or sets a permanent ban).

pub const maxStrikes: u8 = 3;

/// Severe terms only. Matched against the normalised (lowercased, stripped)
/// text, so spacing/punctuation obfuscation is caught.
const blocklist = [_][]const u8{
	"faggot", "fag", "fudgepacker", "nigger", "nigga", "niglet", "retard", "tranny", "trannie",
	"chink", "spic", "kike", "wetback", "beaner", "raghead", "towelhead", "paki", "dyke",
	"coon", "gook", "cunt", "cocksucker", "kys", "kill yourself", "gas the", "white power",
	// Widely-recognised non-English severe slurs (matched after the same
	// normalisation, so accents/case don't evade them).
	"schwuchtel", "bougnoule", "maricon",
};

fn isAlnumAny(c: u8) bool {
	return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
}

/// Case-insensitive whole-word search in the raw text (boundaries are non-alnum
/// or string ends). Used for short terms so e.g. "kys" doesn't match "skyscraper".
fn containsWord(text: []const u8, word: []const u8) bool {
	if (word.len == 0 or word.len > text.len) return false;
	var i: usize = 0;
	while (i + word.len <= text.len) : (i += 1) {
		if (std.ascii.eqlIgnoreCase(text[i .. i + word.len], word)) {
			const beforeOk = i == 0 or !isAlnumAny(text[i - 1]);
			const afterOk = i + word.len == text.len or !isAlnumAny(text[i + word.len]);
			if (beforeOk and afterOk) return true;
		}
	}
	return false;
}

/// Lowercases, maps leetspeak to letters (so f4g, n1gger, tr4nny don't evade),
/// and maps every other non-letter to a space so word boundaries survive
/// (otherwise "a f4g" would glue into "afag" and defeat whole-word terms).
/// `one_is_i` selects the `1`/`!`/`|` reading: `l` for storage (canonical),
/// `i` as a second detection pass, since `1` means both (`n1gger`, `loser`).
fn normaliseMapped(out: *main.ListManaged(u8), text: []const u8, one_is_i: bool) void {
	for (text) |c| {
		var lower = c;
		if (c >= 'A' and c <= 'Z') lower = c + 32;
		out.append(switch (lower) {
			'4', '@' => 'a',
			'8' => 'b',
			'(' => 'c',
			'3' => 'e',
			'9', '6' => 'g',
			'1', '!', '|' => if (one_is_i) 'i' else 'l',
			'0' => 'o',
			'5', '$' => 's',
			'7', '+' => 't',
			'2' => 'z',
			'a'...'z' => lower,
			else => ' ',
		});
	}
}

fn normalise(out: *main.ListManaged(u8), text: []const u8) void {
	normaliseMapped(out, text, false);
}

/// Copies `src` to `out` minus spaces (for camelCase-glued long terms like
/// "killYourself", where the spaced normal form wouldn't substring-match).
fn stripSpaces(out: *main.ListManaged(u8), src: []const u8) void {
	for (src) |c| {
		if (c != ' ') out.append(c);
	}
}

/// Returns the matched term, or null if clean.
pub fn findBad(text: []const u8) ?[]const u8 {
	// Strip color codes/markdown first so hex digits from decorations (e.g.
	// `#fff`) can't pollute matching in either direction.
	var stripped = main.ListManaged(u8).init(main.stackAllocator);
	defer stripped.deinit();
	main.server.veterans.appendCleaned(&stripped, text);
	var norm = main.ListManaged(u8).init(main.stackAllocator);
	defer norm.deinit();
	normalise(&norm, stripped.items);
	var normFlat = main.ListManaged(u8).init(main.stackAllocator);
	defer normFlat.deinit();
	stripSpaces(&normFlat, norm.items);
	// Second pass with the `1`/`!`/`|`-as-`i` reading (`n1gger`, `k1ke`).
	var normI = main.ListManaged(u8).init(main.stackAllocator);
	defer normI.deinit();
	normaliseMapped(&normI, stripped.items, true);
	var normIFlat = main.ListManaged(u8).init(main.stackAllocator);
	defer normIFlat.deinit();
	stripSpaces(&normIFlat, normI.items);
	for (blocklist) |term| {
		var termNorm = main.ListManaged(u8).init(main.stackAllocator);
		defer termNorm.deinit();
		normalise(&termNorm, term);
		var termFlat = main.ListManaged(u8).init(main.stackAllocator);
		defer termFlat.deinit();
		stripSpaces(&termFlat, termNorm.items);
		if (termFlat.items.len == 0) continue;
		// Long terms are safe to match as substrings (catches obfuscation);
		// the spaceless pair catches camelCase-glued forms ("killYourself").
		// Short terms are ambiguous ("kys" in "skyscraper"), so require a word.
		// Short terms are checked against the normalised text too, so leet
		// variants ("ky5") don't evade the whole-word rule.
		if (termFlat.items.len >= 5) {
			if (std.mem.indexOf(u8, norm.items, termNorm.items) != null) return term;
			if (std.mem.indexOf(u8, normFlat.items, termFlat.items) != null) return term;
			if (std.mem.indexOf(u8, normI.items, termNorm.items) != null) return term;
			if (std.mem.indexOf(u8, normIFlat.items, termFlat.items) != null) return term;
		} else {
			if (containsWord(text, term) or containsWord(norm.items, termNorm.items) or containsWord(normI.items, termNorm.items)) return term;
		}
	}
	return null;
}

// --- Ban list ---
const Ban = struct {
	name: []const u8, // normalised name
	key: []const u8, // public key string, or ""
	permanent: bool,
};

var bans: main.ListManaged(Ban) = undefined;
var ready: bool = false;
var lastSave: std.Io.Timestamp = .{.nanoseconds = 0};

/// `bans` is touched from both the server thread (load/save/autosave, and the
/// join ban check) and the network thread (`strike` → `ban`, and the pre-asset
/// handshake ban check), so all access must be serialised.
var bansMutex: main.utils.Mutex = .{};

fn ensure() void {
	if (!ready) {
		bans = main.ListManaged(Ban).init(main.globalAllocator);
		ready = true;
	}
}

fn normName(out: *main.ListManaged(u8), text: []const u8) void {
	// Strip color codes/markdown as units FIRST (shared cleaner with the
	// veterans roster), then leet-normalise. Previously `#rrggbb` hex digits
	// leaked into stored ban names, so bans worked but `/unban` with any
	// differently-decorated spelling reported "no ban found".
	var stripped = main.ListManaged(u8).init(main.stackAllocator);
	defer stripped.deinit();
	main.server.veterans.appendCleaned(&stripped, text);
	normalise(out, stripped.items);
}

pub fn isBanned(name: []const u8, key: ?[]const u8) bool {
	bansMutex.lock();
	defer bansMutex.unlock();
	ensure();
	var n = main.ListManaged(u8).init(main.stackAllocator);
	defer n.deinit();
	normName(&n, name);
	for (bans.items) |*b| {
		if (key) |k| {
			if (b.key.len != 0 and std.mem.eql(u8, b.key, k)) return true;
		}
		if (b.name.len != 0 and std.mem.eql(u8, b.name, n.items)) return true;
	}
	return false;
}

pub fn ban(name: []const u8, key: ?[]const u8, permanent: bool) void {
	{
		bansMutex.lock();
		defer bansMutex.unlock();
		ensure();
		var n = main.ListManaged(u8).init(main.stackAllocator);
		defer n.deinit();
		normName(&n, name);
		bans.append(.{
			.name = main.globalAllocator.dupe(u8, n.items),
			.key = if (key) |k| main.globalAllocator.dupe(u8, k) else "",
			.permanent = permanent,
		});
	}
	main.server.report.recordBan(name, if (permanent) "permanent" else "3 strikes");
}

/// Manual (staff) permanent ban by name and/or public key. Either may be empty.
/// Records the reason in the server report. Returns false if there was nothing
/// to ban (no name and no key).
pub fn banManual(name: []const u8, key: ?[]const u8, reason: ?[]const u8) bool {
	const hasName = name.len != 0;
	const hasKey = key != null and key.?.len != 0;
	if (!hasName and !hasKey) return false;
	{
		bansMutex.lock();
		defer bansMutex.unlock();
		ensure();
		var n = main.ListManaged(u8).init(main.stackAllocator);
		defer n.deinit();
		if (hasName) normName(&n, name);
		bans.append(.{
			.name = if (hasName) main.globalAllocator.dupe(u8, n.items) else "",
			.key = if (hasKey) main.globalAllocator.dupe(u8, key.?) else "",
			.permanent = true,
		});
	}
	if (reason) |r| {
		const detail = main.stackAllocator.print("permanent: {s}", .{r});
		defer main.stackAllocator.free(detail);
		main.server.report.recordBan(if (hasName) name else key.?, detail);
	} else {
		main.server.report.recordBan(if (hasName) name else key.?, "permanent (manual)");
	}
	return true;
}

pub fn unban(name: []const u8) bool {
	bansMutex.lock();
	defer bansMutex.unlock();
	ensure();
	var n = main.ListManaged(u8).init(main.stackAllocator);
	defer n.deinit();
	normName(&n, name);
	var i: usize = 0;
	var found = false;
	while (i < bans.items.len) {
		if (std.mem.eql(u8, bans.items[i].name, n.items)) {
			main.globalAllocator.free(bans.items[i].name);
			if (bans.items[i].key.len != 0) main.globalAllocator.free(bans.items[i].key);
			_ = bans.swapRemove(i);
			found = true;
			continue;
		}
		i += 1;
	}
	return found;
}

/// Applies a strike. Returns true if the player is now banned.
pub fn strike(user: *User) bool {
	const prof = user.player();
	prof.strikes +|= 1;
	if (prof.strikes >= maxStrikes) {
		ban(user.name, user.newKeyString, false);
		// Record the ban now, but let the server thread do the message, save and
		// disconnect: tearing the connection down from the network thread races
		// with the server thread and crashes.
		prof.pendingBan = true;
		return true;
	}
	user.sendMessage("#e6312cWarning: that language is not allowed here. #8a8a8a(Strike {d}/{d}.)", .{ prof.strikes, maxStrikes });
	return false;
}

fn filePath(allocator: main.heap.NeverFailingAllocator, worldPath: []const u8) []const u8 {
	return allocator.print("saves/{s}/ashframe_bans.zig.zon", .{worldPath});
}

pub fn saveCurrentWorld() void {
	const world = main.server.world orelse return;
	save(world.path);
}

pub fn load(worldPath: []const u8) void {
	bansMutex.lock();
	defer bansMutex.unlock();
	ensure();
	for (bans.items) |*b| {
		main.globalAllocator.free(b.name);
		if (b.key.len != 0) main.globalAllocator.free(b.key);
	}
	bans.clearRetainingCapacity();
	const path = filePath(main.stackAllocator, worldPath);
	defer main.stackAllocator.free(path);
	const zon = main.files.cubyzDir().readToZon(main.stackAllocator, path) catch return;
	defer zon.deinit(main.stackAllocator);
	for (zon.getChild("bans").toSlice()) |entry| {
		const name = entry.get([]const u8, "name") orelse continue;
		const key = entry.get([]const u8, "key") orelse "";
		bans.append(.{
			.name = main.globalAllocator.dupe(u8, name),
			.key = if (key.len != 0) main.globalAllocator.dupe(u8, key) else "",
			.permanent = entry.get(bool, "permanent") orelse false,
		});
	}
}

pub fn save(worldPath: []const u8) void {
	bansMutex.lock();
	defer bansMutex.unlock();
	ensure();
	const path = filePath(main.stackAllocator, worldPath);
	defer main.stackAllocator.free(path);
	var zon = main.ZonElement.initObject(main.stackAllocator);
	defer zon.deinit(main.stackAllocator);
	var arr = main.ZonElement.initArray(main.stackAllocator);
	for (bans.items) |*b| {
		var e = main.ZonElement.initObject(main.stackAllocator);
		e.put("name", b.name);
		if (b.key.len != 0) e.put("key", b.key);
		if (b.permanent) e.put("permanent", b.permanent);
		arr.array.append(e);
	}
	zon.put("bans", arr);
	main.files.cubyzDir().writeZon(path, zon) catch |err| {
		std.log.err("Could not save Ashframe bans: {s}", .{@errorName(err)});
	};
}

pub fn autosave(worldPath: []const u8) void {
	const now = main.timestamp();
	if (lastSave.durationTo(now).toSeconds() > 60) {
		lastSave = now;
		save(worldPath);
	}
}

/// Test-only: frees all ban entries and tears down the list (including its
/// backing buffer). Ban tests must call this when done or the test allocator
/// reports leaks. The next call re-initialises lazily via ensure().
pub fn resetForTests() void {
	if (!ready) return;
	bansMutex.lock();
	defer bansMutex.unlock();
	for (bans.items) |*b| {
		main.globalAllocator.free(b.name);
		if (b.key.len != 0) main.globalAllocator.free(b.key);
	}
	bans.deinit();
	ready = false;
}

/// Appends one line per active ban for the admin `/bans` command. Never
/// prints key material — keyed entries are just marked as such.
pub fn appendBanList(msg: *main.ListManaged(u8)) void {
	bansMutex.lock();
	defer bansMutex.unlock();
	ensure();
	if (bans.items.len == 0) {
		msg.appendSlice("#8a8a8aNo active bans.");
		return;
	}
	for (bans.items, 0..) |*b, i| {
		if (i != 0) msg.appendSlice("\n");
		msg.appendSlice("#cfcfcf");
		if (b.name.len != 0) {
			msg.appendSlice(b.name);
		} else {
			msg.appendSlice("(keyed, no name)");
		}
		msg.appendSlice(" #8a8a8a(");
		msg.appendSlice(if (b.permanent) "permanent" else "3 strikes");
		if (b.key.len != 0) msg.appendSlice(", keyed");
		msg.appendSlice(")");
	}
}
// --- ASHFRAME CUSTOM (Chat filter + strikes + bans) ---
