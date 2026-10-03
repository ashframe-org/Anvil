const std = @import("std");
const builtin = @import("builtin");

const main = @import("main");
const ZonElement = main.ZonElement;
const Window = @import("graphics/Window.zig");

pub const version = @import("utils/version.zig");

pub const defaultPort: u16 = 47649;
pub const connectionTimeout = 60_000_000;

pub const entityLookback: i16 = 100;

pub const highestSupportedLod: u3 = 5;

pub var lastVersionString: []const u8 = "";

pub var simulationDistance: u16 = 4;

pub var cpuThreads: ?u64 = null;

pub var anisotropicFiltering: u8 = 4.0;

pub var fpsCap: ?u32 = null;

pub var fov: f32 = 70;

pub var mouseSensitivity: f32 = 1;
pub var controllerSensitivity: f32 = 1;

pub var invertMouseY: bool = false;

pub var renderDistance: u16 = 12;

pub var highestLod: u3 = highestSupportedLod;

pub var resolutionScale: f32 = 1;

pub var bloom: bool = true;

pub var vsync: bool = true;

pub var playerName: []const u8 = "";

pub var showPlayerIndexWithName: bool = false;

pub var streamerMode: bool = false;

pub var lastUsedIPAddress: []const u8 = "";

pub var storedAccount: main.network.authentication.PasswordEncodedAccountCode = .empty;

pub var guiScale: ?f32 = null;

pub var musicVolume: f32 = 1;

pub var leavesQuality: u16 = 2;

pub var @"lod0.5Distance": f32 = 200;

pub var blockContrast: f32 = 0;

pub var nightBrightness: f32 = 0.5;

pub var storageTime: std.Io.Duration = .fromSeconds(5);

pub var updateRepeatSpeed: std.Io.Duration = .fromMilliseconds(200);

pub var updateRepeatDelay: std.Io.Duration = .fromMilliseconds(500);

pub var controllerAxisDeadzone: f32 = 0.2;

const settingsFile = if (builtin.mode == .Debug) "debug_settings.zig.zon" else "settings.zig.zon";

pub fn init() void {
	const zon: ZonElement = main.files.cubyzDir().readToZon(main.stackAllocator, settingsFile) catch |err| blk: {
		if (err != error.FileNotFound) {
			std.log.err("Could not read settings file: {s}", .{@errorName(err)});
		}
		break :blk .null;
	};
	defer zon.deinit(main.stackAllocator);

	inline for (@typeInfo(@This()).@"struct".decls) |decl| runtimeContinueInsideOfComptimeBlock: {
		const is_const = @typeInfo(@TypeOf(&@field(@This(), decl.name))).pointer.is_const; // Sadly there is no direct way to check if a declaration is const.
		if (!is_const) {
			comptime var DeclType = @TypeOf(@field(@This(), decl.name));
			if (@typeInfo(DeclType) == .optional) {
				DeclType = @typeInfo(DeclType).optional.child;
			}
			if (@typeInfo(DeclType) == .@"struct") {
				if (DeclType == std.Io.Duration) {
					const defaultMilli = @as(f64, @floatFromInt(@field(@This(), decl.name).toNanoseconds()))/1.0e6;
					@field(@This(), decl.name) = .fromNanoseconds(@trunc((zon.get(f64, decl.name) orelse defaultMilli)*1.0e6));
					continue;
				}
				@field(@This(), decl.name) = DeclType.fromZon(main.globalAllocator, zon.getChild(decl.name)) catch |err| {
					std.log.err("Got error while loading setting {s}: {s}", .{decl.name, @errorName(err)});
					break :runtimeContinueInsideOfComptimeBlock;
				};
				continue;
			}
			@field(@This(), decl.name) = zon.get(DeclType, decl.name) orelse @field(@This(), decl.name);
			if (@typeInfo(DeclType) == .pointer) {
				if (@typeInfo(DeclType).pointer.size == .slice) {
					@field(@This(), decl.name) = main.globalAllocator.dupe(@typeInfo(DeclType).pointer.child, @field(@This(), decl.name));
				} else {
					@compileError("Not implemented yet.");
				}
			}
		}
	}

	if (resolutionScale != 1 and resolutionScale != 0.5 and resolutionScale != 0.25) resolutionScale = 1;

	// keyboard settings:
	const keyboard = zon.getChild("keyboard");
	for (&main.KeyBoard.keys) |*key| {
		const keyZon = keyboard.getChild(key.name);
		key.key = keyZon.get(c_int, "key") orelse key.key;
		key.mouseButton = keyZon.get(c_int, "mouseButton") orelse key.mouseButton;
		key.scancode = keyZon.get(c_int, "scancode") orelse key.scancode;
		if (key.isToggling != .never) {
			key.isToggling = std.meta.stringToEnum(Window.Key.IsToggling, keyZon.get([]const u8, "isToggling") orelse "") orelse key.isToggling;
		}
	}
}

pub fn deinit() void {
	save();
	inline for (@typeInfo(@This()).@"struct".decls) |decl| {
		const is_const = @typeInfo(@TypeOf(&@field(@This(), decl.name))).pointer.is_const; // Sadly there is no direct way to check if a declaration is const.
		if (!is_const) {
			const DeclType = @TypeOf(@field(@This(), decl.name));
			if (@typeInfo(DeclType) == .@"struct") {
				if (DeclType == std.Io.Duration) continue;
				@field(@This(), decl.name).deinit(main.globalAllocator);
				continue;
			}
			if (@typeInfo(DeclType) == .pointer) {
				if (@typeInfo(DeclType).pointer.size == .slice) {
					main.globalAllocator.free(@field(@This(), decl.name));
				} else {
					@compileError("Not implemented yet.");
				}
			}
		}
	}
}

pub fn save() void {
	var zonObject = ZonElement.initObject(main.stackAllocator);
	defer zonObject.deinit(main.stackAllocator);

	inline for (@typeInfo(@This()).@"struct".decls) |decl| {
		if (comptime std.mem.eql(u8, decl.name, "lastVersionString")) {
			zonObject.put(decl.name, version.version);
			continue;
		}
		const is_const = @typeInfo(@TypeOf(&@field(@This(), decl.name))).pointer.is_const; // Sadly there is no direct way to check if a declaration is const.
		if (!is_const) {
			const DeclType = @TypeOf(@field(@This(), decl.name));
			if (@typeInfo(DeclType) == .@"struct") {
				if (DeclType == std.Io.Duration) {
					zonObject.put(decl.name, @as(f64, @floatFromInt(@field(@This(), decl.name).toNanoseconds()))/1.0e6);
					continue;
				}
				zonObject.put(decl.name, @field(@This(), decl.name).toZon(main.stackAllocator));
				continue;
			}
			if (DeclType == []const u8) {
				zonObject.putOwnedString(decl.name, @field(@This(), decl.name));
			} else {
				zonObject.put(decl.name, @field(@This(), decl.name));
			}
		}
	}

	// keyboard settings:
	const keyboard = ZonElement.initObject(main.stackAllocator);
	for (&main.KeyBoard.keys) |key| {
		const keyZon = ZonElement.initObject(main.stackAllocator);
		keyZon.put("key", key.key);
		keyZon.put("mouseButton", key.mouseButton);
		keyZon.put("scancode", key.scancode);
		if (key.isToggling != .never) {
			keyZon.put("isToggling", @tagName(key.isToggling));
		}
		keyboard.put(key.name, keyZon);
	}
	zonObject.put("keyboard", keyboard);

	// Merge with the old settings file to preserve unknown settings.
	var oldZonObject: ZonElement = main.files.cubyzDir().readToZon(main.stackAllocator, settingsFile) catch |err| blk: {
		if (err != error.FileNotFound) {
			std.log.err("Could not read settings file: {s}", .{@errorName(err)});
		}
		break :blk .null;
	};
	defer oldZonObject.deinit(main.stackAllocator);

	if (oldZonObject == .object) {
		zonObject.join(.preferLeft, oldZonObject);
	}

	main.files.cubyzDir().writeZon(settingsFile, zonObject) catch |err| {
		std.log.err("Couldn't write settings to file: {s}", .{@errorName(err)});
	};
}

pub const launchConfig = struct {
	pub var cubyzDir: []const u8 = "";
	pub var autoEnterWorld: []const u8 = "";
	pub var headlessServer: bool = false;
	/// Account public key of the server owner (e.g. "ed25519:..."). Matching
	/// accounts get full permissions ("/") on every join — the only way to
	/// bootstrap an admin on a dedicated server, where group membership
	/// otherwise needs an existing admin. Empty = disabled.
	pub var serverOwnerKey: []const u8 = "";
	pub var preferredAuthenticationAlgorithm: main.network.authentication.KeyTypeEnum = .ed25519;
	/// Writes `saves/<world>/ashframe_metrics.json` a few times a second for the
	/// external monitor (`tools/ashframe_monitor.py`).
	pub var ashframeMetrics: bool = true;
	/// Speed/load/teleport-driven render distance. Off (default) = stock
	/// streaming, which is the known-good behaviour. Turn on to experiment.
	pub var dynamicRenderDistance: bool = false;
	/// Hides ores that have no exposed face in the chunk data sent to clients, so
	/// x-ray mods can't see them. Revealed as they become exposed by mining.
	/// OFF by default: the hide/reveal round-trip caused visible ore
	/// appear/disappear flicker on chunk re-send, and there is little cheating
	/// to defend against.
	pub var antiXray: bool = false;
	// --- ASHFRAME CUSTOM (Bisect toggles) ---
	// Kill-switches for crash bisection. All default true (= current
	// behaviour). Flip one to false, rebuild, restart, and retest the crash
	// scenario; the first stable toggle names the system.
	/// Decorated `[Title]\nName` nametags. Off = plain validated usernames.
	pub var titlesInNametag: bool = true;
	/// Custom particle sends (claim outlines, teleport poofs).
	pub var customParticles: bool = true;
	/// Non-`cubyz:` structures in worldgen (addon SBBs). New chunks only.
	pub var customStructures: bool = true;
	/// Server-authoritative inventory payments (charges/refunds/shop payouts).
	/// Off = refused with a message, economy frozen.
	pub var serverAuthoritativeCharges: bool = true;
	// --- ASHFRAME CUSTOM (UX-6: asset pack skip) ---
	/// Skip re-sending the asset pack when the joining client announces a
	/// matching cached pack hash. Kill-switch: false restores always-send.
	/// Vanilla clients never announce, so they always get the full pack.
	pub var ashframePackSkip: bool = true;
	// --- ASHFRAME CUSTOM (UX-6) ---
	// --- ASHFRAME CUSTOM (MTU probing, upstream PR #3633 port) ---
	/// RFC 8899 path-MTU discovery. Probes go only to Argon peers with
	/// `ashframeClientVersion >= mtuProbeVersion`; vanilla/old clients never
	/// see the probe channel. Kill-switch: false disables all probing.
	pub var mtuProbing: bool = true;
	// --- ASHFRAME CUSTOM (MTU probing) ---
	// --- ASHFRAME CUSTOM (Hunger) ---
	/// Hunger uses the vanilla energy bar (energy == calories). Drains over
	/// time, food (`/eat`) restores it, and starving drains health to 1 HP.
	/// Purely server-side: the vanilla client already renders the energy bar.
	/// Disabled for now pending balance work; re-enable when ready.
	pub var hungerSystem: bool = false;
	// --- ASHFRAME CUSTOM (Hunger) ---
	// --- ASHFRAME CUSTOM (Bisect toggles) ---

	pub var vulkanTestingMode: bool = false;

	pub fn init() void {
		const zon: ZonElement = main.files.cwd().readToZon(main.stackAllocator, "launchConfig.zon") catch |err| blk: {
			std.log.err("Could not read launchConfig.zon: {s}", .{@errorName(err)});
			break :blk .null;
		};
		defer zon.deinit(main.stackAllocator);

		cubyzDir = main.globalArena.dupe(u8, zon.get([]const u8, "cubyzDir") orelse cubyzDir);
		headlessServer = zon.get(bool, "headlessServer") orelse headlessServer;
		serverOwnerKey = main.globalArena.dupe(u8, zon.get([]const u8, "serverOwnerKey") orelse serverOwnerKey);
		autoEnterWorld = main.globalArena.dupe(u8, zon.get([]const u8, "autoEnterWorld") orelse autoEnterWorld);
		preferredAuthenticationAlgorithm = zon.get(main.network.authentication.KeyTypeEnum, "preferredAuthenticationAlgorithm") orelse preferredAuthenticationAlgorithm;
		vulkanTestingMode = zon.get(bool, "vulkanTestingMode") orelse false;
		ashframeMetrics = zon.get(bool, "ashframeMetrics") orelse ashframeMetrics;
		dynamicRenderDistance = zon.get(bool, "dynamicRenderDistance") orelse dynamicRenderDistance;
		antiXray = zon.get(bool, "antiXray") orelse antiXray;
		titlesInNametag = zon.get(bool, "titlesInNametag") orelse titlesInNametag;
		customParticles = zon.get(bool, "customParticles") orelse customParticles;
		customStructures = zon.get(bool, "customStructures") orelse customStructures;
		serverAuthoritativeCharges = zon.get(bool, "serverAuthoritativeCharges") orelse serverAuthoritativeCharges;
		// --- ASHFRAME CUSTOM (UX-6: asset pack skip) ---
		ashframePackSkip = zon.get(bool, "ashframePackSkip") orelse ashframePackSkip;
		mtuProbing = zon.get(bool, "mtuProbing") orelse mtuProbing;
		// --- ASHFRAME CUSTOM (UX-6) ---
		hungerSystem = zon.get(bool, "hungerSystem") orelse hungerSystem;
		// --- ASHFRAME CUSTOM (UX-3: tunable worker count) ---
		// `cpuThreads` existed but was never loaded, so the pool was always
		// `nproc-1`. Expose it so the server can oversubscribe for blocking
		// (disk/mutex) waits during chunk bursts. Null = auto.
		cpuThreads = zon.get(u64, "cpuThreads") orelse cpuThreads;
		// --- ASHFRAME CUSTOM (UX-3) ---
	}
};

pub const environment = struct {
	pub var SDL_GAMECONTROLLERCONFIG: ?[]const u8 = null;

	pub var env: std.process.Environ = undefined;

	pub fn init(_env: std.process.Environ) void {
		env = _env;
		SDL_GAMECONTROLLERCONFIG = env.getAlloc(main.globalArena.allocator, "SDL_GAMECONTROLLERCONFIG") catch null;
	}
};
