const std = @import("std");

const main = @import("main");
const User = main.server.User;

// --- ASHFRAME CUSTOM (Discord account link) ---
// Links a game account (public key + player index) to one Discord account
// through the relay bot, so a player who loses their key can move their
// progress to a new account from Discord. One Discord account <-> one game
// account; a recovery bans the old key, so it can't be kept as an alt.
//
// Link:    /link (game) -> code -> Discord slash command "/verify CODE"
//          (ephemeral, only the user sees it) -> the bot runs
//          "/relay link <req> <code> <discordId> <discordName>" -> stored.
// Recover: Discord "/recover" -> "/relay recover <req> <discordId>" -> code
//          shown privately -> "/recover CODE" on the new account -> rejoin -> the new key
//          takes over the old player index (`recoveryIndexFor`, at identify),
//          key-owned data moves over and the old key is banned
//          (`finishRecovery`, at join).
//
// Codes are only shown/entered privately (ephemeral slash commands): a code
// posted publicly could be redeemed by someone else first, linking the
// victim's account to their Discord. The relay voids codes posted as text.

pub const linkCodeTtlMs: i64 = 10*60*1000;
pub const recoveryCodeTtlMs: i64 = 15*60*1000;
/// Time to rejoin after `/recover` before the recovery is dropped.
pub const pendingRecoveryTtlMs: i64 = 30*60*1000;
const codeLen = 8;
/// No 0/O, 1/I/L: codes are read off a screen and typed.
const codeAlphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";

const Link = struct {
	discordId: []const u8,
	discordName: []const u8,
	key: []const u8,
	index: usize,
	name: []const u8,
	linkedAt: i64,
};
const PendingLink = struct {
	code: [codeLen]u8,
	key: []const u8,
	index: usize,
	name: []const u8,
	expiresMs: i64,
};
const RecoveryCode = struct {
	code: [codeLen]u8,
	discordId: []const u8,
	expiresMs: i64,
};
/// Accepted `/recover`, applied when the new key next joins.
const PendingRecovery = struct {
	newKey: []const u8,
	discordId: []const u8,
	/// The new account's own player index, set aside once recovered.
	staleIndex: usize,
	expiresMs: i64,
};

var links: main.ListManaged(Link) = undefined;
var pendingLinks: main.ListManaged(PendingLink) = undefined;
var recoveryCodes: main.ListManaged(RecoveryCode) = undefined;
var pendingRecoveries: main.ListManaged(PendingRecovery) = undefined;
var ready: bool = false;
/// Identify (network thread) reads pending recoveries; everything else runs on
/// the server thread.
var mutex: main.utils.Mutex = .{};
var worldPathStore: []const u8 = "";

fn nowMs() i64 {
	return main.timestamp().toMilliseconds();
}

fn ensure() void {
	if (ready) return;
	links = .init(main.globalAllocator);
	pendingLinks = .init(main.globalAllocator);
	recoveryCodes = .init(main.globalAllocator);
	pendingRecoveries = .init(main.globalAllocator);
	ready = true;
}

fn dupe(s: []const u8) []const u8 {
	return main.globalAllocator.dupe(u8, s);
}
fn free(s: []const u8) void {
	if (s.len != 0) main.globalAllocator.free(s);
}

fn freeLink(l: Link) void {
	free(l.discordId);
	free(l.discordName);
	free(l.key);
	free(l.name);
}

/// Unit tests run without the game's Io (main.io.random would block), so they
/// use a seeded generator; the server always uses main.io.random.
var testRng = std.Random.DefaultPrng.init(0x5eed);

fn newCode() [codeLen]u8 {
	var bytes: [codeLen]u8 = undefined;
	if (@import("builtin").is_test) testRng.random().bytes(&bytes) else main.io.random(&bytes);
	var code: [codeLen]u8 = undefined;
	for (&code, bytes) |*c, b| c.* = codeAlphabet[b%codeAlphabet.len];
	return code;
}

/// Uppercases `input` into a code, ignoring spaces/dashes. null if malformed.
fn parseCode(input: []const u8) ?[codeLen]u8 {
	var code: [codeLen]u8 = undefined;
	var n: usize = 0;
	for (input) |ch| {
		if (ch == ' ' or ch == '-') continue;
		if (n == codeLen) return null;
		code[n] = std.ascii.toUpper(ch);
		n += 1;
	}
	if (n != codeLen) return null;
	return code;
}

/// Discord snowflakes are 17-20 digit numbers.
pub fn validDiscordId(id: []const u8) bool {
	if (id.len < 15 or id.len > 21) return false;
	for (id) |ch| if (ch < '0' or ch > '9') return false;
	return true;
}

fn pruneExpired(now: i64) void {
	var i: usize = 0;
	while (i < pendingLinks.items.len) {
		if (pendingLinks.items[i].expiresMs < now) {
			const p = pendingLinks.swapRemove(i);
			free(p.key);
			free(p.name);
		} else i += 1;
	}
	i = 0;
	while (i < recoveryCodes.items.len) {
		if (recoveryCodes.items[i].expiresMs < now) {
			free(recoveryCodes.swapRemove(i).discordId);
		} else i += 1;
	}
	i = 0;
	while (i < pendingRecoveries.items.len) {
		if (pendingRecoveries.items[i].expiresMs < now) {
			const p = pendingRecoveries.swapRemove(i);
			free(p.newKey);
			free(p.discordId);
		} else i += 1;
	}
}

fn linkByKey(key: []const u8) ?*Link {
	for (links.items) |*l| if (std.mem.eql(u8, l.key, key)) return l;
	return null;
}
fn linkByDiscord(discordId: []const u8) ?*Link {
	for (links.items) |*l| if (std.mem.eql(u8, l.discordId, discordId)) return l;
	return null;
}

// --- Linking ---

pub const StartLinkResult = union(enum) {
	code: [codeLen]u8,
	alreadyLinked: []const u8, // discord name
	noKey,
};

/// `/link`: a fresh code for this account (replacing any earlier one).
pub fn startLink(user: *User) StartLinkResult {
	const key = user.newKeyString orelse return .noKey;
	mutex.lock();
	defer mutex.unlock();
	ensure();
	const now = nowMs();
	pruneExpired(now);
	if (linkByKey(key)) |l| return .{.alreadyLinked = l.discordName};
	var i: usize = 0;
	while (i < pendingLinks.items.len) {
		if (std.mem.eql(u8, pendingLinks.items[i].key, key)) {
			const p = pendingLinks.swapRemove(i);
			free(p.key);
			free(p.name);
		} else i += 1;
	}
	const code = newCode();
	pendingLinks.append(.{.code = code, .key = dupe(key), .index = user.playerIndex, .name = dupe(user.name), .expiresMs = now + linkCodeTtlMs});
	return .{.code = code};
}

pub const ConfirmResult = union(enum) {
	ok: []const u8, // linked player's name (valid until the next save/load)
	badCode,
	discordAlreadyLinked,
	accountAlreadyLinked,
	badDiscordId,
};

/// Bot: `!verify CODE` from `discordId`.
pub fn confirmLink(codeText: []const u8, discordId: []const u8, discordName: []const u8) ConfirmResult {
	if (!validDiscordId(discordId)) return .badDiscordId;
	const code = parseCode(codeText) orelse return .badCode;
	mutex.lock();
	defer mutex.unlock();
	ensure();
	pruneExpired(nowMs());
	for (pendingLinks.items, 0..) |p, i| {
		if (!std.mem.eql(u8, &p.code, &code)) continue;
		if (linkByDiscord(discordId) != null) return .discordAlreadyLinked;
		if (linkByKey(p.key) != null) return .accountAlreadyLinked;
		_ = pendingLinks.swapRemove(i);
		links.append(.{
			.discordId = dupe(discordId),
			.discordName = dupe(discordName),
			.key = p.key, // ownership moves from the pending entry
			.index = p.index,
			.name = p.name,
			.linkedAt = @intCast(@divTrunc(std.Io.Clock.Timestamp.now(main.io, .real).raw.toNanoseconds(), 1000000000)),
		});
		saveLocked();
		std.log.info("[discordlink] linked {s} to Discord {s} ({s})", .{p.name, discordName, discordId});
		return .{.ok = p.name};
	}
	return .badCode;
}

/// Bot: a code showed up in the public channel; void it.
pub fn cancelCode(codeText: []const u8) bool {
	const code = parseCode(codeText) orelse return false;
	mutex.lock();
	defer mutex.unlock();
	ensure();
	for (pendingLinks.items, 0..) |p, i| {
		if (std.mem.eql(u8, &p.code, &code)) {
			_ = pendingLinks.swapRemove(i);
			free(p.key);
			free(p.name);
			return true;
		}
	}
	for (recoveryCodes.items, 0..) |r, i| {
		if (std.mem.eql(u8, &r.code, &code)) {
			_ = recoveryCodes.swapRemove(i);
			free(r.discordId);
			return true;
		}
	}
	return false;
}

/// Discord name this account is linked to, if any (for `/link` status).
pub fn linkedDiscordName(user: *User, buf: []u8) ?[]const u8 {
	const key = user.newKeyString orelse return null;
	mutex.lock();
	defer mutex.unlock();
	ensure();
	const l = linkByKey(key) orelse return null;
	const n = @min(buf.len, l.discordName.len);
	@memcpy(buf[0..n], l.discordName[0..n]);
	return buf[0..n];
}

// --- Recovery ---

pub const StartRecoveryResult = union(enum) {
	code: struct { code: [codeLen]u8, name: []const u8 },
	notLinked,
	badDiscordId,
};

/// Bot: `!recover` from `discordId`. The returned name is valid until the next
/// save/load (the bot reply is sent immediately).
pub fn startRecovery(discordId: []const u8) StartRecoveryResult {
	if (!validDiscordId(discordId)) return .badDiscordId;
	mutex.lock();
	defer mutex.unlock();
	ensure();
	const now = nowMs();
	pruneExpired(now);
	const l = linkByDiscord(discordId) orelse return .notLinked;
	var i: usize = 0;
	while (i < recoveryCodes.items.len) {
		if (std.mem.eql(u8, recoveryCodes.items[i].discordId, discordId)) {
			free(recoveryCodes.swapRemove(i).discordId);
		} else i += 1;
	}
	const code = newCode();
	recoveryCodes.append(.{.code = code, .discordId = dupe(discordId), .expiresMs = now + recoveryCodeTtlMs});
	return .{.code = .{.code = code, .name = l.name}};
}

pub const RedeemResult = union(enum) {
	/// Accepted; the old account's name. Rejoin to finish.
	ok: []const u8,
	badCode,
	sameAccount,
	/// This (new) account is already linked to a Discord account.
	newAccountLinked,
	noKey,
};

/// `/recover CODE` on the new account. Records the recovery; it is applied
/// when this key next joins (the player index can't change mid-session).
pub fn redeemRecovery(user: *User, codeText: []const u8) RedeemResult {
	var oldKeyBuf: [256]u8 = undefined;
	var oldKey: []const u8 = "";
	const result = redeemRecoveryLocked(user, codeText, &oldKeyBuf, &oldKey);
	if (result == .ok and oldKey.len != 0) {
		// The old account must not stay online: it would keep saving its
		// player file under the old key.
		const userList = main.server.getUserList(main.stackAllocator);
		defer main.stackAllocator.free(userList);
		for (userList) |other| {
			if (other == user) continue;
			const k = other.newKeyString orelse continue;
			if (std.mem.eql(u8, k, oldKey)) other.conn.disconnect();
		}
	}
	return result;
}

fn redeemRecoveryLocked(user: *User, codeText: []const u8, oldKeyBuf: *[256]u8, oldKey: *[]const u8) RedeemResult {
	const key = user.newKeyString orelse return .noKey;
	const code = parseCode(codeText) orelse return .badCode;
	mutex.lock();
	defer mutex.unlock();
	ensure();
	const now = nowMs();
	pruneExpired(now);
	for (recoveryCodes.items, 0..) |r, i| {
		if (!std.mem.eql(u8, &r.code, &code)) continue;
		const l = linkByDiscord(r.discordId) orelse return .badCode;
		if (std.mem.eql(u8, l.key, key)) return .sameAccount;
		if (linkByKey(key) != null) return .newAccountLinked;
		_ = recoveryCodes.swapRemove(i);
		var j: usize = 0;
		while (j < pendingRecoveries.items.len) {
			if (std.mem.eql(u8, pendingRecoveries.items[j].newKey, key)) {
				const p = pendingRecoveries.swapRemove(j);
				free(p.newKey);
				free(p.discordId);
			} else j += 1;
		}
		pendingRecoveries.append(.{.newKey = dupe(key), .discordId = r.discordId, .staleIndex = user.playerIndex, .expiresMs = now + pendingRecoveryTtlMs});
		saveLocked();
		const n = @min(oldKeyBuf.len, l.key.len);
		@memcpy(oldKeyBuf[0..n], l.key[0..n]);
		oldKey.* = oldKeyBuf[0..n];
		std.log.info("[discordlink] recovery of {s} accepted for new key {s}; applies on rejoin", .{l.name, key});
		return .{.ok = l.name};
	}
	return .badCode;
}

/// Identify (network thread): the player index a recovering key takes over.
pub fn recoveryIndexFor(key: []const u8) ?usize {
	mutex.lock();
	defer mutex.unlock();
	ensure();
	for (pendingRecoveries.items) |p| {
		if (!std.mem.eql(u8, p.newKey, key)) continue;
		if (p.expiresMs < nowMs()) return null;
		const l = linkByDiscord(p.discordId) orelse return null;
		return l.index;
	}
	return null;
}

/// Join (server thread, after the player file was loaded): completes a
/// recovery for this user. loadPlayer has already rebound the old index to
/// the new key (players.rebindKey); this moves key-owned data, bans the old
/// key and sets the new account's own player file aside.
pub fn finishRecovery(user: *User) void {
	const key = user.newKeyString orelse return;
	var oldKeyBuf: [256]u8 = undefined;
	var oldKey: []const u8 = "";
	var staleIndex: usize = undefined;
	var name: []const u8 = "";
	{
		mutex.lock();
		defer mutex.unlock();
		ensure();
		const pi = for (pendingRecoveries.items, 0..) |p, i| {
			if (std.mem.eql(u8, p.newKey, key)) break i;
		} else return;
		const p = pendingRecoveries.swapRemove(pi);
		defer free(p.newKey);
		defer free(p.discordId);
		const l = linkByDiscord(p.discordId) orelse return;
		if (l.index != user.playerIndex) return; // identify didn't take the old index
		const n = @min(oldKeyBuf.len, l.key.len);
		@memcpy(oldKeyBuf[0..n], l.key[0..n]);
		oldKey = oldKeyBuf[0..n];
		staleIndex = p.staleIndex;
		free(l.key);
		l.key = dupe(key);
		name = l.name;
		saveLocked();
	}
	const server = main.server;
	const path = server.world.?.path;
	const moved = server.claims.rekey(oldKey, key) + server.alliances.rekey(oldKey, key) + server.shops.rekey(oldKey, key) + server.veterans.rekey(oldKey, key);
	server.claims.save(path);
	server.alliances.save(path);
	server.shops.save(path);
	// Key-only ban: the new account may use the same name.
	_ = server.chatfilter.banManual("", oldKey, "account recovered via Discord");
	server.chatfilter.saveCurrentWorld();
	if (staleIndex != user.playerIndex) setAsidePlayerFile(path, staleIndex, key);
	std.log.info("[discordlink] recovered {s}: old key banned, {d} key-owned records moved", .{name, moved});
	user.sendMessage("#00ff00Account recovered! #cfcfcfYour old account's progress is now on this one, and the old key is banned.", .{});
}

/// Renames players/<index>.zon to <index>.zon.recovered if it belongs to `key`,
/// so it isn't loaded again at startup (two files with the same key).
fn setAsidePlayerFile(worldPath: []const u8, index: usize, key: []const u8) void {
	const dir = main.files.cubyzDir();
	const path = main.stackAllocator.print("saves/{s}/players/{}.zon", .{worldPath, index});
	defer main.stackAllocator.free(path);
	const zon = dir.readToZon(main.stackAllocator, path) catch return;
	defer zon.deinit(main.stackAllocator);
	const fileKey = zon.get([]const u8, "publicKey") orelse "";
	if (fileKey.len != 0 and !std.mem.eql(u8, fileKey, key)) return; // not ours
	const aside = main.stackAllocator.print("{s}.recovered", .{path});
	defer main.stackAllocator.free(aside);
	dir.writeZon(aside, zon) catch |err| {
		std.log.err("[discordlink] couldn't set aside {s}: {s}", .{path, @errorName(err)});
		return;
	};
	dir.deleteFile(path) catch |err| {
		std.log.err("[discordlink] couldn't remove {s}: {s}", .{path, @errorName(err)});
	};
}

// --- Persistence (links and accepted recoveries; codes are memory-only) ---

fn filePath(allocator: main.heap.NeverFailingAllocator, worldPath: []const u8) []const u8 {
	return allocator.print("saves/{s}/ashframe_discord_links.zig.zon", .{worldPath});
}

pub fn load(worldPath: []const u8) void {
	mutex.lock();
	defer mutex.unlock();
	ensure();
	free(worldPathStore);
	worldPathStore = dupe(worldPath);
	for (links.items) |l| freeLink(l);
	links.clearRetainingCapacity();
	for (pendingRecoveries.items) |p| {
		free(p.newKey);
		free(p.discordId);
	}
	pendingRecoveries.clearRetainingCapacity();
	const path = filePath(main.stackAllocator, worldPath);
	defer main.stackAllocator.free(path);
	const zon = main.files.cubyzDir().readToZon(main.stackAllocator, path) catch return;
	defer zon.deinit(main.stackAllocator);
	for (zon.getChild("links").toSlice()) |e| {
		const discordId = e.get([]const u8, "discordId") orelse continue;
		const key = e.get([]const u8, "key") orelse continue;
		links.append(.{
			.discordId = dupe(discordId),
			.discordName = dupe(e.get([]const u8, "discordName") orelse ""),
			.key = dupe(key),
			.index = e.get(usize, "index") orelse continue,
			.name = dupe(e.get([]const u8, "name") orelse ""),
			.linkedAt = e.get(i64, "linkedAt") orelse 0,
		});
	}
	// Accepted recoveries survive a restart (relative expiry is lost; give
	// them a fresh window).
	const now = nowMs();
	for (zon.getChild("pendingRecoveries").toSlice()) |e| {
		const newKey = e.get([]const u8, "newKey") orelse continue;
		const discordId = e.get([]const u8, "discordId") orelse continue;
		pendingRecoveries.append(.{
			.newKey = dupe(newKey),
			.discordId = dupe(discordId),
			.staleIndex = e.get(usize, "staleIndex") orelse continue,
			.expiresMs = now + pendingRecoveryTtlMs,
		});
	}
}

fn saveLocked() void {
	if (worldPathStore.len == 0) return;
	var zon = main.ZonElement.initObject(main.stackAllocator);
	defer zon.deinit(main.stackAllocator);
	var arr = main.ZonElement.initArray(main.stackAllocator);
	for (links.items) |l| {
		var e = main.ZonElement.initObject(main.stackAllocator);
		e.put("discordId", l.discordId);
		e.put("discordName", l.discordName);
		e.put("key", l.key);
		e.put("index", l.index);
		e.put("name", l.name);
		e.put("linkedAt", l.linkedAt);
		arr.array.append(e);
	}
	zon.put("links", arr);
	var rec = main.ZonElement.initArray(main.stackAllocator);
	for (pendingRecoveries.items) |p| {
		var e = main.ZonElement.initObject(main.stackAllocator);
		e.put("newKey", p.newKey);
		e.put("discordId", p.discordId);
		e.put("staleIndex", p.staleIndex);
		rec.array.append(e);
	}
	zon.put("pendingRecoveries", rec);
	const path = filePath(main.stackAllocator, worldPathStore);
	defer main.stackAllocator.free(path);
	main.files.cubyzDir().writeZon(path, zon) catch |err| {
		std.log.err("Could not save Discord links: {s}", .{@errorName(err)});
	};
}

pub fn save() void {
	mutex.lock();
	defer mutex.unlock();
	ensure();
	saveLocked();
}
// --- ASHFRAME CUSTOM (Discord account link) ---

// --- Tests ---

fn resetForTests() void {
	if (!ready) return;
	for (links.items) |l| freeLink(l);
	for (pendingLinks.items) |p| {
		free(p.key);
		free(p.name);
	}
	for (recoveryCodes.items) |r| free(r.discordId);
	for (pendingRecoveries.items) |p| {
		free(p.newKey);
		free(p.discordId);
	}
	links.deinit();
	pendingLinks.deinit();
	recoveryCodes.deinit();
	pendingRecoveries.deinit();
	free(worldPathStore);
	worldPathStore = "";
	ready = false;
}

fn testUser(key: []const u8, index: usize, name: []const u8) User {
	var u: User = undefined;
	u.newKeyString = key;
	u.playerIndex = index;
	u.name = name;
	return u;
}

test "discord link: codes parse case-insensitively and ignore dashes" {
	const a = parseCode("abcd-ef23").?;
	try std.testing.expectEqualStrings("ABCDEF23", &a);
	try std.testing.expect(parseCode("ABC") == null);
	try std.testing.expect(parseCode("ABCDEFGHJ") == null);
	const c = newCode();
	for (c) |ch| try std.testing.expect(std.mem.indexOfScalar(u8, codeAlphabet, ch) != null);
	try std.testing.expect(validDiscordId("123456789012345678"));
	try std.testing.expect(!validDiscordId("12345"));
	try std.testing.expect(!validDiscordId("12345678901234567x"));
}

test "discord link: link, one-to-one, recover" {
	defer resetForTests();
	const dc = "123456789012345678";
	var alice = testUser("ed25519:alice", 7, "Alice");
	var bob = testUser("ed25519:bob", 8, "Bob");
	var aliceNew = testUser("ed25519:alice2", 20, "Alice");

	// Link Alice.
	const code = startLink(&alice).code;
	try std.testing.expect(confirmLink(&code, "999", "x") == .badDiscordId);
	try std.testing.expect(confirmLink("ZZZZZZZZ", dc, "alice_dc") == .badCode);
	try std.testing.expectEqualStrings("Alice", confirmLink(&code, dc, "alice_dc").ok);
	try std.testing.expect(confirmLink(&code, dc, "alice_dc") == .badCode); // single use
	try std.testing.expectEqualStrings("alice_dc", startLink(&alice).alreadyLinked);

	// One Discord account links one game account.
	const bobCode = startLink(&bob).code;
	try std.testing.expect(confirmLink(&bobCode, dc, "alice_dc") == .discordAlreadyLinked);
	// A code posted publicly is voided.
	try std.testing.expect(cancelCode(&bobCode));
	try std.testing.expect(confirmLink(&bobCode, "223456789012345678", "bob_dc") == .badCode);

	// Recovery: only the linked Discord gets a code.
	try std.testing.expect(startRecovery("323456789012345678") == .notLinked);
	const rec = startRecovery(dc).code;
	try std.testing.expectEqualStrings("Alice", rec.name);

	var oldKeyBuf: [256]u8 = undefined;
	var oldKey: []const u8 = "";
	// Not on the linked account itself.
	try std.testing.expect(redeemRecoveryLocked(&alice, &rec.code, &oldKeyBuf, &oldKey) == .sameAccount);
	try std.testing.expect(redeemRecoveryLocked(&aliceNew, "WRONGCDE", &oldKeyBuf, &oldKey) == .badCode);
	try std.testing.expectEqualStrings("Alice", redeemRecoveryLocked(&aliceNew, &rec.code, &oldKeyBuf, &oldKey).ok);
	try std.testing.expectEqualStrings("ed25519:alice", oldKey);
	// Single use.
	try std.testing.expect(redeemRecoveryLocked(&aliceNew, &rec.code, &oldKeyBuf, &oldKey) == .badCode);
	// On rejoin the new key takes over Alice's player index; others don't.
	try std.testing.expectEqual(@as(?usize, 7), recoveryIndexFor("ed25519:alice2"));
	try std.testing.expectEqual(@as(?usize, null), recoveryIndexFor("ed25519:bob"));

	// A new account that is itself linked can't take over another one.
	const bobCode2 = startLink(&bob).code;
	_ = confirmLink(&bobCode2, "223456789012345678", "bob_dc");
	const rec2 = startRecovery(dc).code;
	try std.testing.expect(redeemRecoveryLocked(&bob, &rec2.code, &oldKeyBuf, &oldKey) == .newAccountLinked);
}
