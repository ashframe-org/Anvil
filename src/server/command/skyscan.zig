const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;
const shrines = main.server.shrines;

pub const description = "Debug: trace your column for sky-island ground.";
pub const usage = "/skyscan";

pub const Args = union(enum) {
	@"/skyscan": struct {},
};

pub fn execute(args: Args, source: Source) void {
	_ = args;
	if (!source.hasPermission("/ashframe/admin/skyscan")) {
		source.sendMessage("#e6312cYou do not have permission to use this developer command.", .{});
		return;
	}
	if (source != .user) {
		source.sendMessage("Command cannot be run without a user", .{});
		return;
	}
	const prof = source.user.player();
	const hx: i32 = @as(i32, @intFromFloat(prof.pos[0]));
	const hz: i32 = @as(i32, @intFromFloat(prof.pos[1]));
	source.sendMessage("#f2f2f2Sky scan for column #e6312c{d},{d}", .{ hx, hz });

	const world = main.server.world orelse return;
	// Biome ids at a coarse vertical spread.
	var y: i32 = 6000;
	while (y <= 23000) : (y += 1000) {
		const biome = world.getBiome(hx, hz, y);
		source.sendMessage("#9a9a9ay={d}: #cfcfcf{s}", .{ y, biome.id });
	}
	if (shrines.findIslandSurface(hx, hz)) |surface| {
		source.sendMessage("#00ff00Solid ground found at y={d}.", .{surface});
	} else {
		source.sendMessage("#e6312cNo solid ground in band 10800-13300.", .{});
	}
}
