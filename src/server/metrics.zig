const std = @import("std");

const main = @import("main");

// --- ASHFRAME CUSTOM (Server metrics for external monitoring) ---
// Writes a small JSON snapshot of server performance a few times a second to
// `saves/<world>/ashframe_metrics.json`, so an external tool
// (`tools/ashframe_monitor.py`) can display it live and keep history for
// before/after comparison. It opens no ports and changes nothing for clients.
//
// Everything is sampled on the server thread. The only values written from
// other threads are the two atomics below.

/// Ticks between stat samples. 2 @ 20 Hz = 10/s.
const ticksPerWrite: u32 = 2;
/// Ticks between *file* writes. 40 @ 20 Hz = every 2 s. File I/O never runs more
/// often than this on the server (tick) thread, so a slow disk can't stall ticks.
const ticksPerFileWrite: u32 = 40;
/// Ticks between compact log lines. 200 @ 20 Hz = every 10 s.
const ticksPerLog: u32 = 200;
/// Rolling window for the tick-time average/peak (~1 s at 20 Hz).
const tickWindow = 20;

var chunkRequestsReceived: std.atomic.Value(u64) = .init(0);
var chunksSent: std.atomic.Value(u64) = .init(0);
var chunkTasksDropped: std.atomic.Value(u64) = .init(0);
var positionUpdates: std.atomic.Value(u64) = .init(0);
var heldDiscarded: std.atomic.Value(u64) = .init(0);
var anticheatNotes: std.atomic.Value(u64) = .init(0);
var anticheatNotesThrottled: std.atomic.Value(u64) = .init(0);
var anticheatSuspects: std.atomic.Value(u64) = .init(0);

// --- Server-load-driven render distance cap ---
// A single global "how far may anyone stream right now" value, derived from real
// server pressure. `dynamicRenderDistanceFor` takes the min of this, the
// velocity term and the teleport ramp. 0 means "not computed yet" (no cap).
pub var loadRenderDistance: std.atomic.Value(u16) = .init(0);
/// Discrete cap levels. The server sits on one level and only steps after the
/// load has proven it can (or can't) handle it, which stops the old continuous
/// cap from oscillating against its own promotions.
const loadRdLevels = [_]u16{4, 6, 8, 10, 12, 16, 20, 24};
/// Outstanding work (queued + deferred) at which queue pressure reaches 1.
const loadPendingTarget: f64 = 1024;
/// Tick budget; overrun beyond this also counts as pressure.
const loadTickBudgetMs: f64 = 50;
const loadBadPressure: f64 = 0.7;
const loadGoodPressure: f64 = 0.35;
/// Must stay calm this long before stepping up (the "settle" period).
const loadSettleMs: i64 = 1500;
const loadUpCooldownMs: i64 = 1000;
const loadDownCooldownMs: i64 = 300;
/// EMA weight per sample (10 samples/s).
const loadPressureWeight: f64 = 0.15;

var loadRdLevel: usize = 0;
var loadPressureEma: f64 = 1.0;
var loadLastStepMs: i64 = 0;
var loadGoodSinceMs: i64 = 0;

pub fn noteChunkRequest() void {
	_ = chunkRequestsReceived.fetchAdd(1, .monotonic);
}
pub fn noteChunkSent() void {
	_ = chunksSent.fetchAdd(1, .monotonic);
}
/// A queued chunk task was discarded without being generated (pruned by
/// `isStillNeeded`). Should only happen for chunks the client has moved past; a
/// spike while the player is waiting means requested work is being lost.
pub fn noteChunkTaskDropped() void {
	_ = chunkTasksDropped.fetchAdd(1, .monotonic);
}
/// A client position update was received. If this stalls while a player is
/// moving, we are not seeing their movement (so the dynamic distance won't react).
pub fn notePositionUpdate() void {
	_ = positionUpdates.fetchAdd(1, .monotonic);
}
/// A held-back chunk request was discarded as genuinely passed. Should only
/// happen well outside the client's view; a spike means requests are being lost.
pub fn noteHeldDiscarded() void {
	_ = heldDiscarded.fetchAdd(1, .monotonic);
}
/// An anticheat note was actually recorded (after throttling).
pub fn noteAnticheatNote() void {
	_ = anticheatNotes.fetchAdd(1, .monotonic);
}
/// An anticheat note was suppressed by the per-category throttle.
pub fn noteAnticheatThrottled() void {
	_ = anticheatNotesThrottled.fetchAdd(1, .monotonic);
}
/// A suspicion was recorded (log-only, for manual review).
pub fn noteSuspect() void {
	_ = anticheatSuspects.fetchAdd(1, .monotonic);
}

// Server-thread state.
var ticksSinceWrite: u32 = 0;
var ticksSinceFile: u32 = 0;
var ticksSinceLog: u32 = 0;
var windowTicks: u32 = 0;
var tickRing: [tickWindow]f32 = @splat(0);
var tickRingIndex: usize = 0;
var tickRingCount: usize = 0;
var sessionPeakMs: f32 = 0;
// Actual tick *work* time (bracketing the whole `update()`), which is what
// matters; `tickRing` above is the wall-clock tick period (~50 ms by design).
var workRing: [tickWindow]f32 = @splat(0);
var workRingIndex: usize = 0;
var workRingCount: usize = 0;
var workSessionPeakMs: f32 = 0;

/// Called once per server tick with the measured duration of `update()`.
pub fn noteTickWork(ms: f32) void {
	workRing[workRingIndex] = ms;
	workRingIndex = (workRingIndex + 1)%tickWindow;
	if (workRingCount < tickWindow) workRingCount += 1;
	if (ms > workSessionPeakMs) workSessionPeakMs = ms;
}

var lastSnapshotMs: i64 = 0;

var prevChunkRequests: u64 = 0;
var prevChunksSent: u64 = 0;
var prevChunkTasksDropped: u64 = 0;
var prevPositionUpdates: u64 = 0;
var prevAnticheatNotes: u64 = 0;
var prevAnticheatNotesThrottled: u64 = 0;
var prevAnticheatSuspects: u64 = 0;
var prevChunkBytes: u64 = 0;
var prevTotalBytes: u64 = 0;
var prevRecvBytes: u64 = 0;
var prevErrors: u64 = 0;
var prevWarns: u64 = 0;
var prevChunkgenTasks: u64 = 0;
var prevChunkgenUtime: i64 = 0;

const Stats = struct {
	tps: f64 = 0,
	tickMsLast: f32 = 0,
	tickMsAvg: f32 = 0,
	tickMsPeak: f32 = 0,
	sessionPeakMs: f32 = 0,
	workMsLast: f32 = 0,
	workMsAvg: f32 = 0,
	workMsPeak: f32 = 0,
	workMsPeakSession: f32 = 0,
	players: u32 = 0,
	threadQueue: usize = 0,
	chunkgenTasks: u64 = 0,
	chunkgenTasksPerS: f64 = 0,
	chunkgenAvgUs: f64 = 0,
	requestsPerS: f64 = 0,
	chunksSentPerS: f64 = 0,
	chunkTasksDroppedTotal: u64 = 0,
	chunkTasksDroppedPerS: f64 = 0,
	chunkBytesPerS: f64 = 0,
	netBytesPerS: f64 = 0,
	netRecvBytesPerS: f64 = 0,
	deferred: usize = 0,
	pendingChunkWork: usize = 0,
	heldDiscardedTotal: u64 = 0,
	anticheatNotesPerS: f64 = 0,
	anticheatNotesThrottledPerS: f64 = 0,
	anticheatSuspectsPerS: f64 = 0,
	capped: u32 = 0,
	observedSpeedMax: f64 = 0,
	positionUpdatesPerS: f64 = 0,
	errors: u64 = 0,
	warnings: u64 = 0,
};

var lastStats: Stats = .{};

fn nowMs() i64 {
	return main.timestamp().toMilliseconds();
}

fn totalBytesSent() u64 {
	var sum: u64 = 0;
	for (&main.network.protocols.bytesSent) |*b| sum += b.load(.monotonic);
	return sum;
}

fn totalBytesReceived() u64 {
	var sum: u64 = 0;
	for (&main.network.protocols.bytesReceived) |*b| sum += b.load(.monotonic);
	return sum;
}

/// Called from `ServerWorld.update` on the server thread with the tick delta.
pub fn sampleTick(deltaSeconds: f32) void {
	if (!main.settings.launchConfig.ashframeMetrics) return;
	if (main.server.world == null) return;

	const ms: f32 = @max(0, deltaSeconds)*1000.0;
	tickRing[tickRingIndex] = ms;
	tickRingIndex = (tickRingIndex + 1)%tickWindow;
	if (tickRingCount < tickWindow) tickRingCount += 1;
	if (ms > sessionPeakMs) sessionPeakMs = ms;
	windowTicks += 1;

	ticksSinceWrite += 1;
	ticksSinceFile += 1;
	ticksSinceLog += 1;
	const doSample = ticksSinceWrite >= ticksPerWrite;
	const doFile = ticksSinceFile >= ticksPerFileWrite;
	const doLog = ticksSinceLog >= ticksPerLog;
	if (doSample) ticksSinceWrite = 0;
	if (doFile) ticksSinceFile = 0;
	if (doLog) ticksSinceLog = 0;
	if (!doSample and !doFile and !doLog) return;

	var stats = lastStats;
	if (doSample) {
		const now = nowMs();
		if (lastSnapshotMs == 0) lastSnapshotMs = now;
		const elapsed = @max(0.001, @as(f64, @floatFromInt(now - lastSnapshotMs))/1000.0);
		stats = computeStats(elapsed);
		lastStats = stats;
		lastSnapshotMs = now;
		windowTicks = 0;
		updateLoadCap(stats, now);
	}

	// File I/O only once a second (reuses the latest sample between writes).
	if (doFile) writeSnapshot(stats, nowMs());
	if (doLog) logSummary(stats);
}

fn computeStats(elapsed: f64) Stats {
	var stats: Stats = .{};
	var sum: f32 = 0;
	var peak: f32 = 0;
	for (tickRing[0..tickRingCount]) |v| {
		sum += v;
		if (v > peak) peak = v;
	}
	if (tickRingCount > 0) stats.tickMsAvg = sum/@as(f32, @floatFromInt(tickRingCount));
	stats.tickMsPeak = peak;
	stats.tickMsLast = tickRing[(tickRingIndex + tickWindow - 1)%tickWindow];
	stats.sessionPeakMs = sessionPeakMs;
	stats.tps = @as(f64, @floatFromInt(windowTicks))/elapsed;

	var workSum: f32 = 0;
	var workPeak: f32 = 0;
	for (workRing[0..workRingCount]) |v| {
		workSum += v;
		if (v > workPeak) workPeak = v;
	}
	if (workRingCount > 0) stats.workMsAvg = workSum/@as(f32, @floatFromInt(workRingCount));
	stats.workMsPeak = workPeak;
	stats.workMsLast = workRing[(workRingIndex + tickWindow - 1)%tickWindow];
	stats.workMsPeakSession = workSessionPeakMs;

	const users = main.server.getUserList(main.stackAllocator);
	defer main.stackAllocator.free(users);
	stats.players = @intCast(users.len);
	for (users) |user| {
		stats.deferred += user.deferredChunks.items.len;
		stats.pendingChunkWork += user.jobQueue.size;
		const eff = user.dynamicRenderDistance.load(.monotonic);
		if (eff != 0 and eff < user.renderDistance) stats.capped += 1;
		if (user.observedSpeed > stats.observedSpeedMax) stats.observedSpeedMax = user.observedSpeed;
	}

	stats.threadQueue = main.threadPool.queueSize();

	const perf = main.threadPool.performance.read();
	const chunkgenIndex = @intFromEnum(main.utils.ThreadPool.TaskType.chunkgen);
	const chunkgenTasks: u64 = perf.tasks[chunkgenIndex];
	const chunkgenUtime: i64 = perf.utime[chunkgenIndex];
	const taskDelta = if (chunkgenTasks >= prevChunkgenTasks) chunkgenTasks - prevChunkgenTasks else chunkgenTasks;
	const utimeDelta = if (chunkgenUtime >= prevChunkgenUtime) chunkgenUtime - prevChunkgenUtime else chunkgenUtime;
	stats.chunkgenTasks = chunkgenTasks;
	stats.chunkgenTasksPerS = @as(f64, @floatFromInt(taskDelta))/elapsed;
	stats.chunkgenAvgUs = if (taskDelta > 0) @as(f64, @floatFromInt(utimeDelta))/@as(f64, @floatFromInt(taskDelta)) else 0;
	prevChunkgenTasks = chunkgenTasks;
	prevChunkgenUtime = chunkgenUtime;

	const reqCount = chunkRequestsReceived.load(.monotonic);
	const sentCount = chunksSent.load(.monotonic);
	const reqDelta = if (reqCount >= prevChunkRequests) reqCount - prevChunkRequests else reqCount;
	const sentDelta = if (sentCount >= prevChunksSent) sentCount - prevChunksSent else sentCount;
	stats.requestsPerS = @as(f64, @floatFromInt(reqDelta))/elapsed;
	stats.chunksSentPerS = @as(f64, @floatFromInt(sentDelta))/elapsed;
	prevChunkRequests = reqCount;
	prevChunksSent = sentCount;

	const droppedCount = chunkTasksDropped.load(.monotonic);
	const droppedDelta = if (droppedCount >= prevChunkTasksDropped) droppedCount - prevChunkTasksDropped else droppedCount;
	stats.chunkTasksDroppedTotal = droppedCount;
	stats.chunkTasksDroppedPerS = @as(f64, @floatFromInt(droppedDelta))/elapsed;
	prevChunkTasksDropped = droppedCount;

	const posUpdates = positionUpdates.load(.monotonic);
	const posDelta = if (posUpdates >= prevPositionUpdates) posUpdates - prevPositionUpdates else posUpdates;
	stats.positionUpdatesPerS = @as(f64, @floatFromInt(posDelta))/elapsed;
	prevPositionUpdates = posUpdates;
	stats.heldDiscardedTotal = heldDiscarded.load(.monotonic);

	const notesCount = anticheatNotes.load(.monotonic);
	const notesDelta = if (notesCount >= prevAnticheatNotes) notesCount - prevAnticheatNotes else notesCount;
	stats.anticheatNotesPerS = @as(f64, @floatFromInt(notesDelta))/elapsed;
	prevAnticheatNotes = notesCount;
	const throttledCount = anticheatNotesThrottled.load(.monotonic);
	const throttledDelta = if (throttledCount >= prevAnticheatNotesThrottled) throttledCount - prevAnticheatNotesThrottled else throttledCount;
	stats.anticheatNotesThrottledPerS = @as(f64, @floatFromInt(throttledDelta))/elapsed;
	prevAnticheatNotesThrottled = throttledCount;
	const suspectCount = anticheatSuspects.load(.monotonic);
	const suspectDelta = if (suspectCount >= prevAnticheatSuspects) suspectCount - prevAnticheatSuspects else suspectCount;
	stats.anticheatSuspectsPerS = @as(f64, @floatFromInt(suspectDelta))/elapsed;
	prevAnticheatSuspects = suspectCount;

	const chunkBytes = main.network.protocols.bytesSent[main.network.protocols.chunkTransmission.id].load(.monotonic);
	const totalBytes = totalBytesSent();
	const recvBytes = totalBytesReceived();
	const chunkDelta = if (chunkBytes >= prevChunkBytes) chunkBytes - prevChunkBytes else chunkBytes;
	const totalDelta = if (totalBytes >= prevTotalBytes) totalBytes - prevTotalBytes else totalBytes;
	const recvDelta = if (recvBytes >= prevRecvBytes) recvBytes - prevRecvBytes else recvBytes;
	stats.chunkBytesPerS = @as(f64, @floatFromInt(chunkDelta))/elapsed;
	stats.netBytesPerS = @as(f64, @floatFromInt(totalDelta))/elapsed;
	stats.netRecvBytesPerS = @as(f64, @floatFromInt(recvDelta))/elapsed;
	prevChunkBytes = chunkBytes;
	prevTotalBytes = totalBytes;
	prevRecvBytes = recvBytes;

	const logCounts = main.server.report.logCounts();
	stats.errors = logCounts.errors;
	stats.warnings = logCounts.warnings;
	prevErrors = logCounts.errors;
	prevWarns = logCounts.warnings;

	return stats;
}

/// Updates the global render-distance cap as a discrete stepper. Pressure counts
/// BOTH queued and deferred work, so promoting held-back chunks doesn't change
/// the total and can't re-trigger a down-step (the old oscillation).
fn updateLoadCap(stats: Stats, now: i64) void {
	// Count QUEUED work only. Counting held-back (deferred) work gave the cap a
	// deadlock: a big deferred backlog kept pressure high, which kept the cap low,
	// which prevented the promotions needed to drain that backlog.
	// Promotions are rate-limited (see `User.processDeferredChunks`), so draining
	// a backlog raises the queue smoothly instead of spiking it.
	const outstanding = stats.pendingChunkWork;
	const queuePressure = @as(f64, @floatFromInt(outstanding))/loadPendingTarget;
	const tickOverrun = @max(0.0, (@as(f64, stats.tickMsAvg) - loadTickBudgetMs)/loadTickBudgetMs);
	const pressure = @min(1.0, @max(queuePressure, tickOverrun));
	loadPressureEma = loadPressureEma*(1.0 - loadPressureWeight) + pressure*loadPressureWeight;

	if (loadPressureEma > loadBadPressure) {
		loadGoodSinceMs = 0;
		if (loadRdLevel > 0 and now - loadLastStepMs > loadDownCooldownMs) {
			loadRdLevel -= 1;
			loadLastStepMs = now;
		}
	} else if (loadPressureEma < loadGoodPressure) {
		if (loadGoodSinceMs == 0) loadGoodSinceMs = now;
		if (loadRdLevel + 1 < loadRdLevels.len and
			now - loadGoodSinceMs >= loadSettleMs and
			now - loadLastStepMs > loadUpCooldownMs)
		{
			loadRdLevel += 1;
			loadLastStepMs = now;
			loadGoodSinceMs = now;
		}
	} else {
		loadGoodSinceMs = 0;
	}
	loadRenderDistance.store(loadRdLevels[loadRdLevel], .monotonic);
}


fn writeSnapshot(stats: Stats, now: i64) void {
	const world = main.server.world orelse return;
	var buf: main.ListManaged(u8) = .init(main.stackAllocator);
	defer buf.deinit();
	buf.appendSlice("{\"time\":");
	buf.print("{d}", .{now});
	buf.appendSlice(",\"tps\":");
	buf.print("{d:.2}", .{stats.tps});
	buf.appendSlice(",\"tick_ms_last\":");
	buf.print("{d:.2}", .{stats.tickMsLast});
	buf.appendSlice(",\"tick_ms_avg\":");
	buf.print("{d:.2}", .{stats.tickMsAvg});
	buf.appendSlice(",\"tick_ms_peak\":");
	buf.print("{d:.2}", .{stats.tickMsPeak});
	buf.appendSlice(",\"tick_ms_peak_session\":");
	buf.print("{d:.2}", .{stats.sessionPeakMs});
	buf.appendSlice(",\"tick_work_ms_last\":");
	buf.print("{d:.2}", .{stats.workMsLast});
	buf.appendSlice(",\"tick_work_ms_avg\":");
	buf.print("{d:.2}", .{stats.workMsAvg});
	buf.appendSlice(",\"tick_work_ms_peak\":");
	buf.print("{d:.2}", .{stats.workMsPeak});
	buf.appendSlice(",\"tick_work_ms_peak_session\":");
	buf.print("{d:.2}", .{stats.workMsPeakSession});
	buf.appendSlice(",\"players\":");
	buf.print("{d}", .{stats.players});
	buf.appendSlice(",\"thread_queue\":");
	buf.print("{d}", .{stats.threadQueue});
	buf.appendSlice(",\"chunkgen_tasks\":");
	buf.print("{d}", .{stats.chunkgenTasks});
	buf.appendSlice(",\"chunkgen_tasks_per_s\":");
	buf.print("{d:.2}", .{stats.chunkgenTasksPerS});
	buf.appendSlice(",\"chunkgen_avg_us\":");
	buf.print("{d:.1}", .{stats.chunkgenAvgUs});
	buf.appendSlice(",\"chunk_requests_per_s\":");
	buf.print("{d:.2}", .{stats.requestsPerS});
	buf.appendSlice(",\"chunks_sent_per_s\":");
	buf.print("{d:.2}", .{stats.chunksSentPerS});
	buf.appendSlice(",\"chunk_tasks_dropped\":");
	buf.print("{d}", .{stats.chunkTasksDroppedTotal});
	buf.appendSlice(",\"chunk_tasks_dropped_per_s\":");
	buf.print("{d:.2}", .{stats.chunkTasksDroppedPerS});
	buf.appendSlice(",\"chunk_bytes_per_s\":");
	buf.print("{d:.0}", .{stats.chunkBytesPerS});
	buf.appendSlice(",\"net_bytes_per_s\":");
	buf.print("{d:.0}", .{stats.netBytesPerS});
	buf.appendSlice(",\"net_recv_bytes_per_s\":");
	buf.print("{d:.0}", .{stats.netRecvBytesPerS});
	buf.appendSlice(",\"deferred_chunk_requests\":");
	buf.print("{d}", .{stats.deferred});
	buf.appendSlice(",\"pending_chunk_work\":");
	buf.print("{d}", .{stats.pendingChunkWork});
	buf.appendSlice(",\"held_discarded\":");
	buf.print("{d}", .{stats.heldDiscardedTotal});
	buf.appendSlice(",\"anticheat_notes_per_s\":");
	buf.print("{d:.2}", .{stats.anticheatNotesPerS});
	buf.appendSlice(",\"anticheat_notes_throttled_per_s\":");
	buf.print("{d:.2}", .{stats.anticheatNotesThrottledPerS});
	buf.appendSlice(",\"anticheat_suspects_per_s\":");
	buf.print("{d:.2}", .{stats.anticheatSuspectsPerS});
	buf.appendSlice(",\"load_rd\":");
	buf.print("{d}", .{loadRenderDistance.load(.monotonic)});
	buf.appendSlice(",\"players_view_capped\":");
	buf.print("{d}", .{stats.capped});
	buf.appendSlice(",\"observed_speed_max\":");
	buf.print("{d:.1}", .{stats.observedSpeedMax});
	buf.appendSlice(",\"position_updates_per_s\":");
	buf.print("{d:.2}", .{stats.positionUpdatesPerS});
	buf.appendSlice(",\"errors\":");
	buf.print("{d}", .{stats.errors});
	buf.appendSlice(",\"warnings\":");
	buf.print("{d}", .{stats.warnings});
	buf.appendSlice("}\n");

	const path = main.stackAllocator.print("saves/{s}/ashframe_metrics.json", .{world.path});
	defer main.stackAllocator.free(path);
	main.files.cubyzDir().write(path, buf.items) catch |err| {
		std.log.err("Could not write Ashframe metrics: {s}", .{@errorName(err)});
	};
}

fn logSummary(stats: Stats) void {
		std.log.info("[perf] tps {d:.1} | period {d:.1}/{d:.1}/{d:.1} work {d:.1}/{d:.1}/{d:.1} ms | queue {d} loadRD {d} pending {d} | chunkgen {d:.0}/s {d:.0}us dropped {d:.0}/s | chunks {d:.0}/s {d:.0} KB/s | net {d:.0} KB/s in {d:.0} KB/s | deferred {d} heldDiscarded {d} (capped {d}) | pos {d:.0}/s speed {d:.0} | notes {d:.0}/s muted {d:.0}/s susp {d:.1}/s | players {d} | err {d} warn {d} | peakWork {d:.1} ms", .{
		stats.tps,
		stats.tickMsLast,
		stats.tickMsAvg,
		stats.tickMsPeak,
		stats.workMsLast,
		stats.workMsAvg,
		stats.workMsPeak,
		stats.threadQueue,
		loadRenderDistance.load(.monotonic),
		stats.pendingChunkWork,
		stats.chunkgenTasksPerS,
		stats.chunkgenAvgUs,
		stats.chunkTasksDroppedPerS,
		stats.chunksSentPerS,
		stats.chunkBytesPerS/1024.0,
		stats.netBytesPerS/1024.0,
		stats.netRecvBytesPerS/1024.0,
		stats.deferred,
		stats.heldDiscardedTotal,
		stats.capped,
		stats.positionUpdatesPerS,
		stats.observedSpeedMax,
		stats.anticheatNotesPerS,
		stats.anticheatNotesThrottledPerS,
		stats.anticheatSuspectsPerS,
		stats.players,
		stats.errors,
		stats.warnings,
		stats.workMsPeakSession,
	});
}
// --- ASHFRAME CUSTOM (Server metrics) ---
