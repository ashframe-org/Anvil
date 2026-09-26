const std = @import("std");

const main = @import("main");
const Blueprint = main.blueprint.Blueprint;
const Mask = main.blueprint.Mask;
const Pattern = main.blueprint.Pattern;
const NeverFailingAllocator = main.heap.NeverFailingAllocator;
const ListManaged = main.ListManaged;
const User = main.server.User;
pub const commandList = @import("command/_list.zig");
const ashutil = @import("command/ashutil.zig");

pub const Source = union(enum) {
	user: *User,
	server: void,

	pub fn sendMessage(self: Source, comptime fmt: []const u8, args: anytype) void {
		switch (self) {
			.user => |user| user.sendMessage(fmt, args),
			.server => main.log.server(fmt, args),
		}
	}

	pub fn hasPermission(self: Source, permissionPath: []const u8) bool {
		return switch (self) {
			.user => |user| main.entity.components.@"cubyz:permissions".server.hasPermission(user.id, permissionPath),
			.server => true,
		};
	}
};

pub const Command = struct {
	exec: *const fn (args: []const u8, source: Source) void,
	name: []const u8,
	description: []const u8,
	usage: []const u8,
	permissionPath: []const u8,
};

pub var commands: std.StringHashMap(Command) = undefined;

fn formatUsageBlock(allocator: main.heap.NeverFailingAllocator, usage: []const u8) []const u8 {
	var result: main.ListManaged(u8) = .init(allocator);
	var lines = std.mem.splitScalar(u8, usage, '\n');
	var first = true;
	while (lines.next()) |line| {
		if (!first) result.append('\n');
		first = false;
		result.appendSlice("#b8221e  \xe2\x86\x92 #cfcfcf");
		result.appendSlice(line);
	}
	return result.toOwnedSlice();
}

fn initExecutionFn(comptime name: []const u8) *const fn (args: []const u8, source: Source) void {
	const ArgPaser = main.argparse.Parser(@field(commandList, name).Args, .{.commandName = name});
	return struct {
		fn exec(msg: []const u8, source: Source) void {
			const arena: main.heap.NeverFailingAllocator = .createArena(main.stackAllocator);
			defer main.stackAllocator.destroyArena(arena);
			var errorMessage: main.ListManaged(u8) = .init(arena);
			const result = ArgPaser.parse(arena, msg, &errorMessage) catch {
				const usageBlock = formatUsageBlock(arena, @field(commandList, name).usage);
				source.sendMessage("#e6312cIncorrect use of #cfcfcf/{s}#e6312c: #b0b0b0{s}\n#e6312cHere are the following options:\n{s}", .{name, errorMessage.items, usageBlock});
				return;
			};
			@field(commandList, name).execute(result, source);
		}
	}.exec;
}

pub fn init() void {
	commands = .init(main.globalAllocator.allocator);
	inline for (@typeInfo(commandList).@"struct".decls) |decl| {
		commands.put(decl.name, .{
			.name = decl.name,
			.description = @field(commandList, decl.name).description,
			.usage = @field(commandList, decl.name).usage,
			.exec = initExecutionFn(decl.name),
			.permissionPath = "/command/" ++ decl.name,
		}) catch unreachable;
		std.log.debug("Registered command: '/{s}'", .{decl.name});
	}
}

pub fn deinit() void {
	commands.deinit();
}

pub fn execute(msg: []const u8, source: Source) void {
	// --- ASHFRAME CUSTOM (Anticheat: command rate limit) ---
	if (source == .user) {
		const user = source.user;
		if (!user.rateCommand.allow(main.server.anticheat.nowMilliseconds())) {
			main.server.anticheat.note(user, .rate, "command");
			return;
		}
	}
	// --- ASHFRAME CUSTOM (Anticheat) ---
	const end = std.mem.indexOfScalar(u8, msg, ' ') orelse msg.len;
	const command = msg[0..end];
	if (commands.get(command)) |cmd| {
		if (!source.hasPermission(cmd.permissionPath)) {
			source.sendMessage("#e6312cNo permission to use Command \"{s}\"", .{command});
			return;
		}
		cmd.exec(msg[@min(end + 1, msg.len)..], source);
	} else {
		if (ashutil.suggestCommand(command, source)) |suggestion| {
			source.sendMessage("#e6312cUnrecognized command \"{s}\". Did you mean #cfcfcf/{s}#e6312c?", .{command, suggestion});
		} else {
			source.sendMessage("#e6312cUnrecognized Command \"{s}\"", .{command});
		}
	}
}

pub const Coordinate = union(enum) {
	relative: f64, // Relative coordinates are indicated by leading `~`.
	absolute: f64,

	pub fn parse(_: NeverFailingAllocator, name: []const u8, arg: []const u8, errorMessage: *ListManaged(u8)) error{ParseError}!Coordinate {
		const isRelative = arg[0] == '~';
		const numberSlice = if (isRelative) arg[1..] else arg;
		if (isRelative and numberSlice.len == 0) return .{.relative = 0};
		if (isRelative) {
			return .{.relative = std.fmt.parseFloat(f64, numberSlice) catch {
				errorMessage.print("Expected number for <{s}>, found \"{s}\"", .{name, numberSlice});
				return error.ParseError;
			}};
		}
		return .{.absolute = std.fmt.parseFloat(f64, numberSlice) catch {
			errorMessage.print("Expected number or \"~\" for <{s}>, found \"{s}\"", .{name, arg});
			return error.ParseError;
		}};
	}
};

pub const Rotation = union(enum) {
	relative: f32, // Relative rotations are indicated by leading `~`.
	absolute: f32,

	pub fn parse(_: NeverFailingAllocator, name: []const u8, arg: []const u8, errorMessage: *ListManaged(u8)) error{ParseError}!Rotation {
		const isRelative = arg[0] == '~';
		const numberSlice = if (isRelative) arg[1..] else arg;
		if (isRelative and numberSlice.len == 0) return .{.relative = 0};
		if (isRelative) {
			return .{.relative = std.math.degreesToRadians(std.fmt.parseFloat(f32, numberSlice) catch {
				errorMessage.print("Expected number for <{s}>, found \"{s}\"", .{name, numberSlice});
				return error.ParseError;
			})};
		}
		return .{.absolute = std.math.degreesToRadians(std.fmt.parseFloat(f32, numberSlice) catch {
			errorMessage.print("Expected number or \"~\" for <{s}>, found \"{s}\"", .{name, arg});
			return error.ParseError;
		})};
	}
};

pub fn resolveCoordinates(x: Coordinate, y: Coordinate, z: Coordinate, source: Source) error{InvalidArg}!main.vec.Vec3d {
	if (source != .user and (x == .relative or y == .relative or z == .relative)) {
		source.sendMessage("Command was run without a user; unable to interpret relative coordinates.", .{});
		return error.InvalidArg;
	}
	const fx = if (x == .relative) source.user.player().pos[0] + x.relative else x.absolute;
	const fy = if (y == .relative) source.user.player().pos[1] + y.relative else y.absolute;
	const fz = if (z == .relative) source.user.player().pos[2] + z.relative else z.absolute;
	// `parseFloat` accepts nan/inf; reject rather than silently clamping to a
	// boundary. Bounds match the anticheat's own limits (horizontal 1e9,
	// vertical 1e5) so command coordinates can never exceed what a client may.
	if (!std.math.isFinite(fx) or !std.math.isFinite(fy) or !std.math.isFinite(fz)) {
		if (source == .user) source.sendMessage("Invalid coordinates.", .{});
		return error.InvalidArg;
	}
	return .{
		// TODO: Remove clamp after #310 is implemented
		std.math.clamp(fx, -main.server.anticheat.maxHorizontal, main.server.anticheat.maxHorizontal),
		std.math.clamp(fy, -main.server.anticheat.maxHorizontal, main.server.anticheat.maxHorizontal),
		std.math.clamp(fz, -main.server.anticheat.maxVertical, main.server.anticheat.maxVertical),
	};
}

pub fn resolveRotation(yaw: Rotation, pitch: Rotation, source: Source) error{InvalidArg}!main.vec.Vec3f {
	if (source != .user and (yaw == .relative or pitch == .relative)) {
		source.sendMessage("Command was run without a user; unable to interpret relative rotation.", .{});
		return error.InvalidArg;
	}
	const bound = std.math.pi/2.0 - 0.001;
	const yawValue = if (yaw == .relative) source.user.player().rot[0] + yaw.relative else yaw.absolute;
	const pitchValue = if (pitch == .relative) source.user.player().rot[2] + pitch.relative else pitch.absolute;
	if (!std.math.isFinite(yawValue) or !std.math.isFinite(pitchValue)) {
		if (source == .user) source.sendMessage("Invalid rotation.", .{});
		return error.InvalidArg;
	}
	return .{
		std.math.clamp(yawValue, -bound, bound),
		0,
		// Pitch was previously unclamped, so nan/absurd pitch could be sent to
		// the client; clamp it like yaw.
		std.math.clamp(pitchValue, -bound, bound),
	};
}

pub const Target = struct {
	user: *User,

	pub fn fromPlayerIndex(arg: ?PlayerIndex, source: Source) !Target {
		if (arg == null and source != .user) {
			source.sendMessage("#e6312cCommand was run without a user; unable to infer the player index", .{});
			return error.InvalidArg;
		}
		const playerIndex = arg orelse return .{
			.user = source.user,
		};
		return .{
			.user = main.server.getUserByIndex(playerIndex.index) orelse {
				source.sendMessage("#e6312cPlayer with index {d} not found or not online", .{playerIndex.index});
				return error.InvalidArg;
			},
		};
	}
};

/// Largest selection volume allowed for WorldEdit operations, so a hostile or
/// accidental huge selection can't overflow or exhaust memory.
pub const maxSelectionVolume: u64 = 1 << 18; // 262144 blocks (64^3)

/// Get current selection from user data. This function will output appropriate error to chat upon failure.
pub fn getCurrentSelection(source: *User) !Blueprint.Selection {
	const pos1 = source.worldEditData.selectionPosition1 orelse {
		source.sendMessage("#e6312cPosition 1 isn't set", .{});
		return error.SelectionPartiallyUnset;
	};
	const pos2 = source.worldEditData.selectionPosition2 orelse {
		source.sendMessage("#e6312cPosition 2 isn't set", .{});
		return error.SelectionPartiallyUnset;
	};
	const selection = Blueprint.Selection.initFromInclusive(pos1, pos2);
	const volume = selection.volume() orelse {
		source.sendMessage("#e6312cSelection is too large.", .{});
		return error.SelectionTooLarge;
	};
	if (volume > maxSelectionVolume) {
		source.sendMessage("#e6312cSelection is too large ({d} blocks, max {d}).", .{ volume, maxSelectionVolume });
		return error.SelectionTooLarge;
	}
	return selection;
}

pub const PlayerIndex = struct {
	index: usize,

	pub fn parse(_: NeverFailingAllocator, name: []const u8, arg: []const u8, errorMessage: *ListManaged(u8)) error{ParseError}!PlayerIndex {
		if (!std.ascii.startsWithIgnoreCase(arg, "@")) {
			errorMessage.print("Expected to start with @ for <{s}>, found \"{s}\"", .{name, arg});
			return error.ParseError;
		}
		return .{.index = std.fmt.parseInt(usize, arg[1..], 10) catch {
			errorMessage.print("Expected and integer after @ for <{s}>, found \"{s}\"", .{name, arg[1..]});
			return error.ParseError;
		}};
	}
};

pub const RestOfLine = main.argparse.RestOfLine;

pub const KeyString = struct {
	key: []const u8,

	pub fn parse(_: NeverFailingAllocator, name: []const u8, arg: []const u8, errorMessage: *ListManaged(u8)) error{ParseError}!KeyString {
		const colonIndex = std.mem.indexOfScalar(u8, arg, ':') orelse {
			errorMessage.print("Expected a public key of the form \"<keyType>:<base64>\" for <{s}>, found \"{s}\"", .{name, arg});
			return error.ParseError;
		};
		const keyType = std.meta.stringToEnum(main.network.authentication.KeyTypeEnum, arg[0..colonIndex]) orelse {
			errorMessage.print("Unknown key type \"{s}\" for <{s}>", .{arg[0..colonIndex], name});
			return error.ParseError;
		};
		_ = main.network.authentication.PublicKey.initFromBase64(arg[colonIndex + 1 ..], keyType) catch {
			errorMessage.print("Invalid public key \"{s}\" for <{s}>", .{arg, name});
			return error.ParseError;
		};
		return .{.key = arg};
	}
};

pub const BiomeId = struct {
	biome: *const main.server.terrain.biomes.Biome,

	pub fn parse(_: NeverFailingAllocator, name: []const u8, args: []const u8, errorMessage: *ListManaged(u8)) error{ParseError}!@This() {
		return .{.biome = main.server.terrain.biomes.getByIdOptional(args) orelse {
			errorMessage.print("Couldn't find biome for <{s}> with id \"{s}\"", .{name, args});
			return error.ParseError;
		}};
	}
};

pub const BlockId = struct {
	block: main.blocks.Block,

	pub fn parse(_: NeverFailingAllocator, name: []const u8, args: []const u8, errorMessage: *ListManaged(u8)) error{ParseError}!@This() {
		const blockTyp = main.blocks.getBlockById(args) catch {
			errorMessage.print("Couldn't find block for <{s}> with id \"{s}\"", .{name, args});
			return error.ParseError;
		};
		return .{.block = .{.typ = blockTyp, .data = 0}};
	}
};

pub const EntityModel = struct {
	index: main.entityModel.EntityModelIndex,

	pub fn parse(_: NeverFailingAllocator, name: []const u8, args: []const u8, errorMessage: *ListManaged(u8)) error{ParseError}!EntityModel {
		if (main.entityModel.getById(args)) |entityModel| {
			return .{.index = entityModel};
		} else {
			errorMessage.print("Couldn't find EntityModel for <{s}> with id \"{s}\"", .{name, args});
			return error.ParseError;
		}
	}
};

pub const MaskExpression = struct {
	mask: Mask,

	pub fn parse(arena: NeverFailingAllocator, _: []const u8, args: []const u8, errorMessage: *ListManaged(u8)) error{ParseError}!MaskExpression {
		return .{.mask = Mask.initFromString(arena, args) catch |err| {
			errorMessage.print("Couldn't parse mask: {s}", .{@errorName(err)});
			return error.ParseError;
		}};
	}
};

pub const PatternExpression = struct {
	pattern: Pattern,

	pub fn parse(arena: NeverFailingAllocator, _: []const u8, args: []const u8, errorMessage: *ListManaged(u8)) error{ParseError}!PatternExpression {
		return .{.pattern = Pattern.initFromString(arena, args) catch |err| {
			errorMessage.print("Couldn't parse pattern: {s}", .{@errorName(err)});
			return error.ParseError;
		}};
	}
};

pub const PermissionPath = struct {
	path: []const u8,

	pub fn parse(_: NeverFailingAllocator, name: []const u8, arg: []const u8, errorMessage: *ListManaged(u8)) error{ParseError}!PermissionPath {
		if (arg[0] != '/') {
			errorMessage.print("Permission path for <{s}> doesn't begin with a \"/\", got: {s}", .{name, arg});
			return error.ParseError;
		}
		return .{.path = arg};
	}
};
