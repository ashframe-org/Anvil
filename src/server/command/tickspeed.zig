const std = @import("std");

const main = @import("main");
const Source = main.server.command.Source;

pub const description = "Get or set the world's random tick speed.";
pub const usage =
	\\/tickspeed
	\\/tickspeed <rate>
;

pub const Args = union(enum) {
	@"/tickspeed <rate>": struct { rate: u32 },
	@"/tickspeed": struct {},
};

pub fn execute(args: Args, source: Source) void {
	switch (args) {
		.@"/tickspeed <rate>" => |tickSpeed| main.server.world.?.tickSpeed.store(@min(tickSpeed.rate, 1000), .monotonic),
		.@"/tickspeed" => {},
	}
	source.sendMessage("#ffff00{}", .{main.server.world.?.tickSpeed.load(.monotonic)});
}
