const std = @import("std");

const main = @import("main");
const command = main.server.command;
const Source = command.Source;
const waypoints = main.server.waypoints;

pub const description = "Show your waypoint pair status.";
pub const usage = "/waypoint";

pub const Args = union(enum) {
	@"/waypoint": struct {},
};

pub fn execute(args: Args, source: Source) void {
	_ = args;
	if (source != .user) {
		source.sendMessage("Command cannot be run without a user", .{});
		return;
	}
	const prof = source.user.player();
	if (waypoints.pairFor(source.user.playerIndex)) |pair| {
		source.sendMessage("#cfcfcfWaypoint A - {d} {d} {d}\n#cfcfcfWaypoint B - {d} {d} {d}\n#8a8a8aStand on either anchor to teleport.", .{ pair[0][0], pair[0][1], pair[0][2], pair[1][0], pair[1][1], pair[1][2] });
	} else if (prof.waypointPending) |pending| {
		source.sendMessage("#cfcfcfWaypoint A - {d} {d} {d}\n#8a8a8aWaypoint B - (not placed yet)\n#8a8a8aPlace another to link them.", .{ @as(i32, @intFromFloat(pending[0])), @as(i32, @intFromFloat(pending[1])), @as(i32, @intFromFloat(pending[2])) });
	} else {
		source.sendMessage("#8a8a8aNo waypoint pair. #cfcfcfPlace two waypoints to link them.", .{});
	}
}
