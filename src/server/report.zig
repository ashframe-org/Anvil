const std = @import("std");

const main = @import("main");
const User = main.server.User;

// --- ASHFRAME CUSTOM (Server report + operator notifications) ---
// Records server events (anticheat violations, bans, kicks, errors/warnings,
// restarts, joins) and performance samples, persists them per world, notifies
// online operators live, and shows a "server report" when an operator returns.
//
// Access is gated by the `/ashframe/admin/report` permission (disjoint from the
// command path so granting `/command/report` never grants the report itself).
//
// THREADING: some events arrive on the network thread (chat bans, movement
// reach/movement checks) while `hasPermission` may only be called on the server
// thread. So `record`/`notifyAggregated` are mutex-guarded and notifications are
// queued; `flushNotifications` (called from the server tick) actually resolves
// operators and sends.

pub const permissionPath = "/ashframe/admin/report";

pub const Kind = enum { violation, ban, kick, restart, join, leave };

const Event = struct {
	time: i64, // ms
	kind: Kind,
	player: []const u8,
	detail: []const u8,
};

const maxEvents = 2000;
var events: main.ListManaged(Event) = undefined;
var ready: bool = false;

// Performance aggregates (persisted, server-thread only).
var startTime: i64 = 0;
var peakTickMs: u32 = 0;
var spikeCount: u32 = 0;
var errorCount: std.atomic.Value(u64) = .init(0);
var warnCount: std.atomic.Value(u64) = .init(0);

// Last few log lines, for the "why" of a degraded tick.
const maxLogSamples = 20;
const logSampleLenMax = 160;
var logSampleText: [maxLogSamples][logSampleLenMax]u8 = undefined;
var logSampleLen: [maxLogSamples]u16 = [_]u16{0} ** maxLogSamples;
var logSampleIsError: [maxLogSamples]bool = [_]bool{false} ** maxLogSamples;
var logSampleTime: [maxLogSamples]i64 = [_]i64{0} ** maxLogSamples;
var logSampleWrite: usize = 0;
var logSampleCount: usize = 0;
var logSampleMutex: main.utils.Mutex = .{};

// Per-operator last-report time (persisted, server-thread only).
const LastSeen = struct { playerIndex: usize, time: i64 };
var lastSeen: main.ListManaged(LastSeen) = undefined;

// Live-notification aggregation (session only).
const Agg = struct {
	player: []const u8,
	category: []const u8,
	count: u32,
	lastNotify: i64,
};
var agg: main.ListManaged(Agg) = undefined;

// Pending notifications, flushed on the server thread.
const maxPending = 100;
var pending: main.ListManaged([]const u8) = undefined;

/// Guards `events`, `agg` and `pending` (touched from several threads).
var stateMutex: main.utils.Mutex = .{};

var cleanShutdown: bool = false;
var lastSave: std.Io.Timestamp = .{.nanoseconds = 0};

/// How long before a returning operator is shown a report even with no events.
pub const joinReportThresholdMs: i64 = 60*60*1000;
/// Summary window for `/report`.
pub const summaryWindowMs: i64 = 24*60*60*1000;

fn ensure() void {
	if (!ready) {
		events = main.ListManaged(Event).init(main.globalAllocator);
		lastSeen = main.ListManaged(LastSeen).init(main.globalAllocator);
		agg = main.ListManaged(Agg).init(main.globalAllocator);
		pending = main.ListManaged([]const u8).init(main.globalAllocator);
		ready = true;
	}
}

/// Test-only: tears down everything recorded so far (events, pending
/// notifications, aggregation, including backing buffers). Tests that trigger
/// recording (e.g. ban tests) must call this when done or the test allocator
/// reports leaks. The next call re-initialises lazily via ensure().
pub fn resetForTests() void {
	if (!ready) return;
	stateMutex.lock();
	defer stateMutex.unlock();
	for (events.items) |e| {
		main.globalAllocator.free(e.player);
		main.globalAllocator.free(e.detail);
	}
	events.deinit();
	for (pending.items) |msg| main.globalAllocator.free(msg);
	pending.deinit();
	for (agg.items) |*a| {
		main.globalAllocator.free(a.player);
		main.globalAllocator.free(a.category);
	}
	agg.deinit();
	lastSeen.deinit();
	ready = false;
}

fn nowMs() i64 {
	return main.timestamp().toMilliseconds();
}

fn hasReportPermission(user: *User) bool {
	return main.entity.components.@"cubyz:permissions".server.hasPermission(user.id, permissionPath);
}

// --- Recording ---

pub fn record(kind: Kind, player: []const u8, detail: []const u8) void {
	ensure();
	stateMutex.lock();
	defer stateMutex.unlock();
	recordLocked(kind, player, detail);
}

fn recordLocked(kind: Kind, player: []const u8, detail: []const u8) void {
	while (events.items.len >= maxEvents) {
		const old = events.swapRemove(0);
		main.globalAllocator.free(old.player);
		main.globalAllocator.free(old.detail);
	}
	events.append(.{
		.time = nowMs(),
		.kind = kind,
		.player = main.globalAllocator.dupe(u8, player),
		.detail = main.globalAllocator.dupe(u8, detail),
	});
}

/// Queues a notification for online operators (delivered on the server thread).
pub fn notifyOperators(comptime fmt: []const u8, args: anytype) void {
	ensure();
	var buf: [512]u8 = undefined;
	const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
	stateMutex.lock();
	defer stateMutex.unlock();
	queueLocked(msg);
}

fn queueLocked(msg: []const u8) void {
	while (pending.items.len >= maxPending) {
		main.globalAllocator.free(pending.swapRemove(0));
	}
	pending.append(main.globalAllocator.dupe(u8, msg));
}

/// Delivers queued notifications to every online operator. Server thread only.
pub fn flushNotifications() void {
	if (!ready) return;
	stateMutex.lock();
	defer stateMutex.unlock();
	if (pending.items.len == 0) return;
	const users = main.server.getUserList(main.stackAllocator);
	defer main.stackAllocator.free(users);
	for (pending.items) |msg| {
		for (users) |user| {
			if (!hasReportPermission(user)) continue;
			user.sendMessage("{s}", .{msg});
		}
	}
	for (pending.items) |msg| main.globalAllocator.free(msg);
	pending.clearRetainingCapacity();
}

/// Aggregated per-player/category notification: the first hit is announced, then
/// repeats are rolled up every 10 hits or after 5 minutes, so one cheater
/// can't flood operator chat.
pub fn notifyAggregated(player: []const u8, category: []const u8, detail: []const u8) void {
	ensure();
	stateMutex.lock();
	defer stateMutex.unlock();
	const now = nowMs();
	for (agg.items) |*a| {
		if (std.mem.eql(u8, a.player, player) and std.mem.eql(u8, a.category, category)) {
			a.count += 1;
			// Throttled: fast-repeat categories (movement on the hot path)
			// must not spam operators — one update per 10 hits or 5 minutes.
			if (a.count % 10 == 0 or now - a.lastNotify > 300_000) {
				a.lastNotify = now;
				var buf: [256]u8 = undefined;
				const msg = std.fmt.bufPrint(&buf, "#e6312c[anticheat] #cfcfcf{s} #8a8a8a{s} \u{00d7}{d} #cfcfcf{s}", .{ player, category, a.count, detail }) catch return;
				queueLocked(msg);
			}
			return;
		}
	}
	agg.append(.{
		.player = main.globalAllocator.dupe(u8, player),
		.category = main.globalAllocator.dupe(u8, category),
		.count = 1,
		.lastNotify = now,
	});
	var buf: [256]u8 = undefined;
	const msg = std.fmt.bufPrint(&buf, "#e6312c[anticheat] #cfcfcf{s} #8a8a8a{s} #cfcfcf{s}", .{ player, category, detail }) catch return;
	queueLocked(msg);
}

pub fn recordBan(player: []const u8, detail: []const u8) void {
	record(.ban, player, detail);
	notifyOperators("#e6312c[server] #cfcfcf{s} #e6312cwas banned #8a8a8a({s})", .{ player, detail });
}

pub fn recordKick(player: []const u8, detail: []const u8) void {
	record(.kick, player, detail);
	notifyOperators("#e6312c[server] #cfcfcf{s} #e6312cwas kicked #8a8a8a({s})", .{ player, detail });
}

pub fn recordJoin(player: []const u8) void {
	record(.join, player, "");
}

pub fn recordLeave(player: []const u8) void {
	record(.leave, player, "");
}

/// (errors, warnings) since start. For the external metrics snapshot.
pub fn logCounts() struct { errors: u64, warnings: u64 } {
	return .{
		.errors = errorCount.load(.monotonic),
		.warnings = warnCount.load(.monotonic),
	};
}

// --- Performance ---

pub fn sampleTick(deltaSeconds: f32) void {
	const ms: u32 = @intFromFloat(@max(0.0, deltaSeconds)*1000.0);
	if (ms > peakTickMs) peakTickMs = ms;
	if (deltaSeconds > 0.3) spikeCount += 1;
}

/// Called from `log.logFn` on any thread. Counts errors/warnings and keeps the
/// last few lines. Uses fixed buffers + a mutex so it's thread-safe.
pub fn countLog(isError: bool, text: []const u8) void {
	if (isError) {
		_ = errorCount.fetchAdd(1, .monotonic);
	} else {
		_ = warnCount.fetchAdd(1, .monotonic);
	}
	logSampleMutex.lock();
	defer logSampleMutex.unlock();
	const i = logSampleWrite;
	logSampleWrite = (logSampleWrite + 1) % maxLogSamples;
	const len = @min(text.len, logSampleLenMax);
	@memcpy(logSampleText[i][0..len], text[0..len]);
	logSampleLen[i] = @intCast(len);
	logSampleIsError[i] = isError;
	logSampleTime[i] = nowMs();
	logSampleCount = @min(logSampleCount + 1, maxLogSamples);
}

// --- Last-seen ---

fn getLastSeen(playerIndex: usize) i64 {
	ensure();
	for (lastSeen.items) |s| {
		if (s.playerIndex == playerIndex) return s.time;
	}
	return 0;
}

fn setLastSeen(playerIndex: usize, time: i64) void {
	ensure();
	for (lastSeen.items) |*s| {
		if (s.playerIndex == playerIndex) {
			s.time = time;
			return;
		}
	}
	lastSeen.append(.{.playerIndex = playerIndex, .time = time});
}

fn countEventsSinceLocked(sinceMs: i64, kind: Kind) u32 {
	var n: u32 = 0;
	for (events.items) |e| {
		if (e.time > sinceMs and e.kind == kind) n += 1;
	}
	return n;
}

// --- Reporting ---

/// Called when an operator joins. Sends a one-line summary + prompt if there is
/// something to report (new events, or they've been away a while). Server thread.
pub fn maybeShowReport(user: *User) void {
	ensure();
	if (!hasReportPermission(user)) return;
	const now = nowMs();
	const since = getLastSeen(user.playerIndex);
	stateMutex.lock();
	const newEvents = countEventsSinceLocked(since, .violation) + countEventsSinceLocked(since, .ban) + countEventsSinceLocked(since, .kick) + countEventsSinceLocked(since, .restart);
	const violations = countEventsSinceLocked(since, .violation);
	const bans = countEventsSinceLocked(since, .ban);
	const kicks = countEventsSinceLocked(since, .kick);
	const restarts = countEventsSinceLocked(since, .restart);
	stateMutex.unlock();
	if (newEvents == 0 and now - since < joinReportThresholdMs) return;
	const hours = @divTrunc(now - since, 3600*1000);
	user.sendMessage("#e6312c[server report] #cfcfcf{d}h since your last report: #e6312c{d} violations#cfcfcf, #e6312c{d} bans#cfcfcf, #e6312c{d} kicks#cfcfcf, #e6312c{d} restarts#cfcfcf. #8a8a8a/report yes to view, /report no to skip.", .{
		hours, violations, bans, kicks, restarts,
	});
}

pub fn acknowledge(user: *User) void {
	setLastSeen(user.playerIndex, nowMs());
	saveCurrentWorld();
}

const Tally = struct { player: []const u8, category: []const u8, count: u32 };

/// Appends a formatted report of everything since `sinceMs` to `msg`.
/// Locks `stateMutex` internally. Server thread only.
fn appendReport(msg: *main.ListManaged(u8), sinceMs: i64, title: []const u8) void {
	ensure();
	const now = nowMs();
	const span = now - sinceMs;
	msg.appendSlice("#f2f2f2--- ");
	msg.appendSlice(title);
	msg.print(" ({d}h) ---\n", .{@divTrunc(span, 3600*1000)});

	msg.appendSlice("#f2f2f2Safety\n");
	stateMutex.lock();
	{
		var seen: main.ListManaged(Tally) = .init(main.stackAllocator);
		defer seen.deinit();
		for (events.items) |e| {
			if (e.kind != .violation or e.time <= sinceMs) continue;
			const category = categoryOf(e.detail);
			var found = false;
			for (seen.items) |*s| {
				if (std.mem.eql(u8, s.player, e.player) and std.mem.eql(u8, s.category, category)) {
					s.count += 1;
					found = true;
					break;
				}
			}
			if (!found) seen.append(.{.player = e.player, .category = category, .count = 1});
		}
		if (seen.items.len == 0) {
			msg.appendSlice("#8a8a8a  none\n");
		} else {
			for (seen.items) |s| {
				msg.print("#e6312c{s} #cfcfcf- {d} violations #8a8a8a({s})\n", .{ s.player, s.count, s.category });
			}
		}
	}
	appendEventListLocked(msg, sinceMs, .ban, "Bans");
	appendEventListLocked(msg, sinceMs, .kick, "Kicks");
	appendEventListLocked(msg, sinceMs, .restart, "Restarts");
	stateMutex.unlock();

	msg.appendSlice("#f2f2f2Performance\n");
	const uptimeH = @divTrunc(now - startTime, 3600*1000);
	msg.print("#cfcfcf  uptime {d}h · peak tick #e6312c{d}ms#cfcfcf · spikes {d} · errors {d} · warnings {d}\n", .{ uptimeH, peakTickMs, spikeCount, errorCount.load(.monotonic), warnCount.load(.monotonic) });
	logSampleMutex.lock();
	defer logSampleMutex.unlock();
	if (logSampleCount > 0) {
		msg.appendSlice("#8a8a8a  recent log:\n");
		var idx = (logSampleWrite + maxLogSamples - logSampleCount) % maxLogSamples;
		var shown: usize = 0;
		while (shown < logSampleCount) : (shown += 1) {
			if (logSampleLen[idx] > 0) {
				msg.appendSlice(if (logSampleIsError[idx]) "#e6312c    " else "#8a8a8a    ");
				msg.appendSlice(logSampleText[idx][0..logSampleLen[idx]]);
				msg.append('\n');
			}
			idx = (idx + 1) % maxLogSamples;
		}
	}
}

fn categoryOf(detail: []const u8) []const u8 {
	const end = std.mem.indexOfScalar(u8, detail, ' ') orelse detail.len;
	return detail[0..end];
}

fn appendEventListLocked(msg: *main.ListManaged(u8), sinceMs: i64, kind: Kind, label: []const u8) void {
	msg.appendSlice("#f2f2f2");
	msg.appendSlice(label);
	msg.append('\n');
	var any = false;
	for (events.items) |e| {
		if (e.kind != kind or e.time <= sinceMs) continue;
		msg.print("#e6312c{s} #8a8a8a{s}\n", .{ e.player, e.detail });
		any = true;
	}
	if (!any) msg.appendSlice("#8a8a8a  none\n");
}

pub fn sendSummary(user: *User) void {
	var msg = main.ListManaged(u8).init(main.stackAllocator);
	defer msg.deinit();
	appendReport(&msg, nowMs() - summaryWindowMs, "Server report");
	user.sendMessage("{s}", .{msg.items});
}

pub fn sendAll(user: *User) void {
	var msg = main.ListManaged(u8).init(main.stackAllocator);
	defer msg.deinit();
	appendReport(&msg, 0, "Server report (full history)");
	user.sendMessage("{s}", .{msg.items});
}

pub fn clear(user: *User) void {
	ensure();
	stateMutex.lock();
	for (events.items) |e| {
		main.globalAllocator.free(e.player);
		main.globalAllocator.free(e.detail);
	}
	events.clearRetainingCapacity();
	stateMutex.unlock();
	errorCount.store(0, .monotonic);
	warnCount.store(0, .monotonic);
	peakTickMs = 0;
	spikeCount = 0;
	saveCurrentWorld();
	user.sendMessage("#00ff00Server report log cleared.", .{});
}

// --- Persistence ---

fn filePath(allocator: main.heap.NeverFailingAllocator, worldPath: []const u8) []const u8 {
	return allocator.print("saves/{s}/ashframe_report.zig.zon", .{worldPath});
}

fn saveCurrentWorld() void {
	const world = main.server.world orelse return;
	save(world.path);
}

pub fn load(worldPath: []const u8) void {
	ensure();
	stateMutex.lock();
	defer stateMutex.unlock();
	for (events.items) |e| {
		main.globalAllocator.free(e.player);
		main.globalAllocator.free(e.detail);
	}
	events.clearRetainingCapacity();
	lastSeen.clearRetainingCapacity();
	for (agg.items) |a| {
		main.globalAllocator.free(a.player);
		main.globalAllocator.free(a.category);
	}
	agg.clearRetainingCapacity();

	const path = filePath(main.stackAllocator, worldPath);
	defer main.stackAllocator.free(path);
	const zon = main.files.cubyzDir().readToZon(main.stackAllocator, path) catch {
		startTime = nowMs();
		cleanShutdown = false;
		return;
	};
	defer zon.deinit(main.stackAllocator);

	// Crash detection: the previous session didn't finish a clean shutdown.
	const previousStart = zon.get(i64, "start_time") orelse 0;
	const previousClean = zon.get(bool, "clean_shutdown") orelse false;
	if (previousStart != 0 and !previousClean) {
		recordLocked(.restart, "", "previous session did not shut down cleanly");
	} else if (previousStart != 0) {
		recordLocked(.restart, "", "server restarted");
	}

	for (zon.getChild("events").toSlice()) |entry| {
		const kindStr = entry.get([]const u8, "kind") orelse continue;
		const kind = std.meta.stringToEnum(Kind, kindStr) orelse continue;
		const player = entry.get([]const u8, "player") orelse "";
		const detail = entry.get([]const u8, "detail") orelse "";
		const time = entry.get(i64, "time") orelse 0;
		if (events.items.len >= maxEvents) break;
		events.append(.{
			.time = time,
			.kind = kind,
			.player = main.globalAllocator.dupe(u8, player),
			.detail = main.globalAllocator.dupe(u8, detail),
		});
	}
	for (zon.getChild("last_seen").toSlice()) |entry| {
		const idx = entry.get(usize, "player_index") orelse continue;
		const time = entry.get(i64, "time") orelse 0;
		lastSeen.append(.{.playerIndex = idx, .time = time});
	}

	startTime = nowMs();
	cleanShutdown = false;
	peakTickMs = zon.get(u32, "peak_tick_ms") orelse 0;
	spikeCount = zon.get(u32, "spike_count") orelse 0;
}

pub fn save(worldPath: []const u8) void {
	ensure();
	const path = filePath(main.stackAllocator, worldPath);
	defer main.stackAllocator.free(path);
	var zon = main.ZonElement.initObject(main.stackAllocator);
	defer zon.deinit(main.stackAllocator);

	zon.put("start_time", startTime);
	zon.put("clean_shutdown", cleanShutdown);
	zon.put("peak_tick_ms", peakTickMs);
	zon.put("spike_count", spikeCount);

	stateMutex.lock();
	defer stateMutex.unlock();

	var evArr = main.ZonElement.initArray(main.stackAllocator);
	for (events.items) |*e| {
		var obj = main.ZonElement.initObject(main.stackAllocator);
		obj.put("time", e.time);
		obj.put("kind", @tagName(e.kind));
		obj.put("player", e.player);
		obj.put("detail", e.detail);
		evArr.array.append(obj);
	}
	zon.put("events", evArr);

	var lsArr = main.ZonElement.initArray(main.stackAllocator);
	for (lastSeen.items) |s| {
		var obj = main.ZonElement.initObject(main.stackAllocator);
		obj.put("player_index", s.playerIndex);
		obj.put("time", s.time);
		lsArr.array.append(obj);
	}
	zon.put("last_seen", lsArr);

	main.files.cubyzDir().writeZon(path, zon) catch |err| {
		std.log.err("Could not save Ashframe report: {s}", .{@errorName(err)});
	};
}

pub fn autosave(worldPath: []const u8) void {
	const now = main.timestamp();
	if (lastSave.durationTo(now).toSeconds() > 60) {
		lastSave = now;
		save(worldPath);
	}
}

/// Marks the session as cleanly shut down and persists it.
pub fn markCleanShutdown(worldPath: []const u8) void {
	cleanShutdown = true;
	save(worldPath);
}
// --- ASHFRAME CUSTOM (Server report) ---
