const std = @import("std");

const main = @import("main");
const chunk = main.chunk;
const game = main.game;
const graphics = main.graphics;
const ZonElement = main.ZonElement;
const renderer = main.renderer;
const settings = main.settings;
const utils = main.utils;
const BinaryReader = utils.BinaryReader;
const vec = main.vec;
const Mat4f = vec.Mat4f;
const Vec3d = vec.Vec3d;
const Vec3f = vec.Vec3f;
const Vec4f = vec.Vec4f;
const NeverFailingAllocator = main.heap.NeverFailingAllocator;

const c = @import("c");

var lastTime: i16 = 0;
var timeDifference: utils.TimeDifference = utils.TimeDifference{};

pub var entities: main.utils.VirtualList(main.client.Entity, 1 << 20) = undefined;
pub var idMapping: main.ListManaged(?u32) = undefined;
pub var mutex: main.utils.Mutex = .{};

/// Session totals for ghost detection (see clear()). Guarded by mutex.
var addedEntities: u64 = 0;
var removedEntities: u64 = 0;

pub fn init() void {
	entities = .init();
	idMapping = .init(main.globalAllocator);
}

pub fn deinit() void {
	mutex.lock();
	defer mutex.unlock();
	for (entities.items()) |ent| {
		ent.deinit(main.globalAllocator);
	}
	entities.deinit();
	idMapping.deinit();
}

pub fn clear() void {
	mutex.lock();
	defer mutex.unlock();
	// Session add/remove balance: a growing surplus of adds over removes
	// means ghost entities accumulate client-side (stale renders, stale
	// names). Logged here where the evidence is complete.
	if (addedEntities != removedEntities) {
		std.log.warn("[ashframe] entity add/remove imbalance: added {} removed {} (possible ghosts)", .{ addedEntities, removedEntities });
	}
	for (entities.items()) |ent| {
		ent.deinit(main.globalAllocator);
	}
	entities.clearRetainingCapacity();
	idMapping.clearRetainingCapacity();
	timeDifference = utils.TimeDifference{};
	addedEntities = 0;
	removedEntities = 0;
}

pub fn update() void {
	mutex.lock();
	defer mutex.unlock();

	var time: i16 = @truncate(main.timestamp().toMilliseconds() -% settings.entityLookback);
	time -%= timeDifference.difference.load(.monotonic);
	for (entities.items()) |*ent| {
		ent.update(time, lastTime);
	}
	lastTime = time;
}

pub fn addEntity(zon: ZonElement) !void {
	mutex.lock();
	defer mutex.unlock();

	const id = zon.get(u32, "id") orelse return error.entityIdMissing;
	// Duplicate add for a live id: ignore it. Overwriting the mapping would
	// leak the old slot (a ghost that renders forever).
	if (id < idMapping.items.len and idMapping.items[id] != null) return;
	const index = entities.len;
	var ent = entities.addOne();
	// If init fails below, roll the slot back: a half-built entity carries a
	// garbage name, and rendering it panics the text parser on invalid UTF-8.
	// (Only loadComponentsFromBase64 can fail, after name was duped.)
	errdefer {
		main.globalAllocator.free(ent.name);
		_ = entities.pop();
	}

	if (idMapping.items.len <= id) {
		idMapping.appendNTimes(null, id - idMapping.items.len + 1);
	}
	try ent.init(zon, main.globalAllocator);
	idMapping.items[id] = index;
	addedEntities += 1;
}
pub fn getEntity(entity: main.entity.Entity) ?*main.client.Entity {
	mutex.assertLocked();
	if (@intFromEnum(entity) >= idMapping.items.len) return null;
	return &entities.items()[idMapping.items[@intFromEnum(entity)] orelse return null];
}
pub fn removeEntity(entity: main.entity.Entity) void {
	mutex.lock();
	defer mutex.unlock();

	if (idMapping.items.len <= @intFromEnum(entity)) return;
	const index: u32 = idMapping.items[@intFromEnum(entity)] orelse return;
	const ent = entities.items()[index];

	// remove id
	idMapping.items[@intFromEnum(entity)] = null;

	// remove entity
	{
		std.debug.assert(ent.id == entity);
		ent.deinit(main.globalAllocator);
		_ = entities.swapRemove(index);

		if (index != entities.len) {
			idMapping.items[@intFromEnum(entities.items()[index].id)] = index;
			entities.items()[index].interpolatedValues.outPos = &entities.items()[index]._interpolationPos;
			entities.items()[index].interpolatedValues.outVel = &entities.items()[index]._interpolationVel;
		}
		removedEntities += 1;
	}
}

pub fn serverUpdate(time: i16, entityData: []main.entity.EntityNetworkData) void {
	mutex.lock();
	defer mutex.unlock();
	timeDifference.addDataPoint(time);

	for (entityData) |data| {
		const pos = [_]f64{
			data.pos[0],
			data.pos[1],
			data.pos[2],
			@floatCast(data.rot[0]),
			@floatCast(data.rot[1]),
			@floatCast(data.rot[2]),
		};
		const vel = [_]f64{
			data.vel[0],
			data.vel[1],
			data.vel[2],
			0,
			0,
			0,
		};
		if (getEntity(data.id)) |ent| {
			ent.updatePosition(&pos, &vel, time);
		}
	}
}
