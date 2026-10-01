const std = @import("std");
const Atomic = std.atomic.Value;

const main = @import("main");
const Block = main.blocks.Block;
const chunk = main.chunk;
const particles = main.particles;
const items = main.items;
const ZonElement = main.ZonElement;
const game = main.game;
const settings = main.settings;
const renderer = main.renderer;
const utils = main.utils;
const vec = main.vec;
const Vec3d = vec.Vec3d;
const Vec3f = vec.Vec3f;
const Vec3i = vec.Vec3i;
const NeverFailingAllocator = main.heap.NeverFailingAllocator;
const BlockUpdate = renderer.mesh_storage.BlockUpdate;

const network = main.network;
const Connection = network.Connection;

var clientReceiveList: [256]?*const fn (*Connection, *utils.BinaryReader) anyerror!void = @splat(null);
var serverReceiveList: [256]?*const fn (*Connection, *utils.BinaryReader) anyerror!void = @splat(null);
pub var bytesReceived: [256]Atomic(usize) = @splat(.init(0));
pub var bytesSent: [256]Atomic(usize) = @splat(.init(0));

pub fn init() void { // MARK: init()
	inline for (@typeInfo(@This()).@"struct".decls) |decl| {
		const Protocol = @field(@This(), decl.name);
		if (@TypeOf(Protocol) == type and @hasDecl(Protocol, "id")) {
			const id = Protocol.id;
			if (clientReceiveList[id] == null and serverReceiveList[id] == null) {
				if (@hasDecl(Protocol, "clientReceive")) {
					clientReceiveList[id] = Protocol.clientReceive;
				}
				if (@hasDecl(Protocol, "serverReceive")) {
					serverReceiveList[id] = Protocol.serverReceive;
				}
			} else {
				std.log.err("Duplicate list id {}.", .{id});
			}
		}
	}
}

pub fn onReceive(conn: *Connection, protocolIndex: u8, data: []const u8) !void { // MARK: onReceive()
	if (conn.handShakeState.raw != .complete and protocolIndex != handShake.id) return error.HandshakeIncomplete;
	const protocolReceive = blk: {
		if (conn.isServerSide()) break :blk serverReceiveList[protocolIndex] orelse return error.Invalid;
		break :blk clientReceiveList[protocolIndex] orelse return error.Invalid;
	};

	var reader = utils.BinaryReader.init(data);
	protocolReceive(conn, &reader) catch |err| {
		std.log.debug("Got error while executing protocol {} with data {any}", .{protocolIndex, data});
		return err;
	};

	_ = bytesReceived[protocolIndex].fetchAdd(data.len, .monotonic);
}

pub const reload = struct { // MARK: reload
	pub const id: u8 = 0;

	pub fn informClientOfRestart(conn: *Connection) void {
		var writer = utils.BinaryWriter.init(main.stackAllocator);
		defer writer.deinit();

		writer.writeInt(u32, conn.restartCounter);
		writer.writeEnum(main.server.User.State, conn.user.?.state);

		conn.send(.secure, id, writer.data.items);
		conn.send(.lossy, id, writer.data.items);
		conn.send(.slow, id, writer.data.items);
	}
	pub fn informServerOfRestart(conn: *Connection) void {
		var writer = utils.BinaryWriter.init(main.stackAllocator);
		defer writer.deinit();

		writer.writeInt(u32, conn.restartCounter);
		conn.send(.secure, id, writer.data.items);
		conn.send(.lossy, id, writer.data.items);
		conn.send(.slow, id, writer.data.items);
	}
};

pub const handShake = struct { // MARK: handShake
	pub const id: u8 = 1;
	var assetsLoadedCondition: main.utils.Condition = .{};
	var hasFinishedLoadingAssets: bool = false;
	var handshakeZon: ZonElement = undefined;

	// --- ASHFRAME CUSTOM (UX-5a: asset pack cache) ---
	// The packed asset tree is identical for every join until the files
	// change, but packing re-walked + re-deflated all files per handshake.
	// Cache the deflated bytes keyed by a content hash. The full pack is
	// still SENT every join (vanilla-safe); only the repeated pack() work
	// is skipped. Guarded by a mutex: handshakes run on network threads.
	var assetPackCache: ?[]u8 = null;
	var assetPackHash: u64 = 0;
	var assetPackMutex: main.utils.Mutex = .{};

	/// Order-independent content hash of an asset dir: XOR of per-file
	/// path+content hashes, so walk order never matters.
	fn assetTreeHash(dir: main.files.Dir) !u64 {
		var h: u64 = 0;
		var walker = dir.walk(main.stackAllocator);
		defer walker.deinit();
		while (try walker.next(main.io)) |entry| {
			if (entry.kind != .file) continue;
			const relPath: []const u8 = entry.path;
			const fileData = try dir.read(main.stackAllocator, relPath);
			defer main.stackAllocator.free(fileData);
			h +%= std.hash.Wyhash.hash(0, relPath);
			h +%= std.hash.Wyhash.hash(0, fileData);
		}
		return h;
	}
	// --- ASHFRAME CUSTOM (UX-5a) ---

	pub fn clientReceive(conn: *Connection, reader: *utils.BinaryReader) !void {
		const newState = try reader.readEnum(Connection.HandShakeState);
		if (@intFromEnum(conn.handShakeState.load(.monotonic)) < @intFromEnum(newState)) {
			conn.handShakeState.store(newState, .monotonic);
			switch (newState) {
				.userData, .signatureResponse, .reload => return error.InvalidSide,
				.signatureRequest => {
					const signature1Len = try reader.readVarInt(usize);
					const signature1 = try reader.readSlice(signature1Len);
					const signature2Len = try reader.readVarInt(usize);
					const signature2 = try reader.readSlice(signature2Len);

					var writer: utils.BinaryWriter = .init(main.stackAllocator);
					defer writer.deinit();
					writer.writeEnum(Connection.HandShakeState, .signatureResponse);
					conn.handShakeState.store(.signatureResponse, .monotonic);

					network.authentication.KeyCollection.sign(&writer, std.meta.stringToEnum(network.authentication.KeyTypeEnum, signature1) orelse return error.Invalid, conn.secureChannel.verificationDataForClientSignature.items);
					if (signature2.len != 0) {
						network.authentication.KeyCollection.sign(&writer, std.meta.stringToEnum(network.authentication.KeyTypeEnum, signature2) orelse return error.Invalid, conn.secureChannel.verificationDataForClientSignature.items);
					}
					conn.send(.secure, id, writer.data.items);
				},
				.assets => {
					std.log.info("Received assets.", .{});
					main.files.cubyzDir().deleteTree("serverAssets") catch {}; // Delete old assets.
					var dir = try main.files.cubyzDir().openDir("serverAssets");
					defer dir.close();
					try utils.Compression.unpack(dir, reader.remaining);
				},
				.serverData => {
					handshakeZon = ZonElement.parseFromString(main.stackAllocator, null, reader.remaining);
					defer handshakeZon.deinit(main.stackAllocator);
					conn.handShakeState.store(.complete, .monotonic);
					conn.handShakeWaiting.broadcast(); // Notify the waiting client thread.
					conn.mutex.lock();
					while (!hasFinishedLoadingAssets) {
						assetsLoadedCondition.wait(&conn.mutex);
					}
					conn.mutex.unlock();
					hasFinishedLoadingAssets = false;
				},
				.start, .complete => {},
			}
		} else {
			// Ignore packages that refer to an unexpected state. Normally those might be packages that were resent by the other side.
		}
	}

	pub fn serverReceive(conn: *Connection, reader: *utils.BinaryReader) !void {
		const newState = try reader.readEnum(Connection.HandShakeState);
		if (@intFromEnum(conn.handShakeState.load(.monotonic)) < @intFromEnum(newState)) {
			conn.handShakeState.store(newState, .monotonic);
			stateSwitch: switch (newState) {
				.userData => {
					conn.secureChannel.finishedCollectingClientVerificationData = true;
					const zon = ZonElement.parseFromString(main.stackAllocator, null, reader.remaining);
					defer zon.deinit(main.stackAllocator);
					const name = zon.get([]const u8, "name") orelse "unnamed";
					if (!std.unicode.utf8ValidateSlice(name)) {
						std.log.err("Received player name with invalid UTF-8 characters.", .{});
						return error.Invalid;
					}
					if (name.len > 500 or main.graphics.TextBuffer.Parser.countVisibleCharacters(name) > 50) {
						std.log.err("Player has too long name with {}/{} characters.", .{main.graphics.TextBuffer.Parser.countVisibleCharacters(name), name.len});
						return error.Invalid;
					}
					// Reject control characters (newlines, tabs, ...) in names.
					for (name) |ch| {
						if (ch < 0x20 or ch == 0x7f) {
							std.log.err("Received player name with control characters.", .{});
							return error.Invalid;
						}
					}
					const version = zon.get([]const u8, "version") orelse "unknown";
					std.log.info("User {s} joined using version {s}", .{name, version});
					// --- ASHFRAME CUSTOM (UX-6: asset pack skip) ---
					// Custom clients announce their cached pack hash; vanilla
					// clients omit the field and always get the full pack.
					if (zon.get(i64, "ashframePackHash")) |h| {
						conn.user.?.ashframePackHash = @bitCast(h);
					}
					// --- ASHFRAME CUSTOM (UX-6) ---
					// --- ASHFRAME CUSTOM (capability handshake) ---
					// Argon announces its feature version; vanilla omits it.
					// Unknown fields are ignored by vanilla, so this is safe.
					if (zon.get(i64, "ashframeClientVersion")) |v| {
						if (v >= 0 and v <= std.math.maxInt(u16)) {
							conn.user.?.ashframeClientVersion = @intCast(v);
							std.log.info("User {s} is Argon v{d}", .{ name, v });
						}
					}
					// --- ASHFRAME CUSTOM (capability handshake) ---

					if (!try settings.version.isCompatibleClientVersion(version)) {
						std.log.warn("Version incompatible with server version {s}", .{settings.version.version});
						return error.IncompatibleVersion;
					}

					if (main.server.world.?.mode != .singleplayer) {
						const keys = zon.getChild("keys");
						try conn.user.?.identifyFromKeysAndName(name, keys, main.server.world.?.settings.whitelistEnabled.load(.monotonic));

						var writer: utils.BinaryWriter = .init(main.stackAllocator);
						defer writer.deinit();
						writer.writeEnum(Connection.HandShakeState, .signatureRequest);
						conn.handShakeState.store(.signatureRequest, .monotonic);
						writer.writeVarInt(usize, @tagName(conn.user.?.key).len);
						writer.writeSlice(@tagName(conn.user.?.key));
						if (conn.user.?.legacyKey) |legacyKey| {
							writer.writeVarInt(usize, @tagName(legacyKey).len);
							writer.writeSlice(@tagName(legacyKey));
						} else {
							writer.writeVarInt(usize, 0);
						}
						conn.send(.secure, id, writer.data.items);
					} else {
						try conn.user.?.identifyAsLocal(name);
						continue :stateSwitch .signatureResponse;
					}
				},
				.signatureResponse, .reload => {
					if (newState != .reload) {
						if (main.server.world.?.mode != .singleplayer) {
							try conn.user.?.verifySignatures(reader);
						}
						conn.user.?.state = .connectedVerified;
					} else {
						// check if player is attempting to reload without logging in (or in an otherwise unexpected state).
						if (conn.user.?.state != .awaitingReloadVerified) return error.KeysNotVerified;
					}
					// --- ASHFRAME CUSTOM (Ban check before spending bandwidth on assets) ---
					// Reject banned / disallowed names before packing and sending the
					// asset pack, so we don't transfer assets to someone who is about
					// to be kicked anyway.
					if (main.server.chatfilter.isBanned(conn.user.?.name, conn.user.?.newKeyString)) {
						std.log.info("[ashframe] banned player {s} tried to join; disconnected before sending assets", .{conn.user.?.name});
						conn.disconnect();
						return;
					}
					if (main.server.chatfilter.findBad(conn.user.?.name) != null) {
						std.log.info("[ashframe] player with a disallowed name tried to join; disconnected before sending assets", .{});
						conn.disconnect();
						return;
					}
					// --- ASHFRAME CUSTOM (Ban check) ---
					{
						const path = main.stackAllocator.print("saves/{s}/assets/", .{main.server.world.?.path});
						defer main.stackAllocator.free(path);
						var dir = try main.files.cubyzDir().openIterableDir(path);
						defer dir.close();
						// --- ASHFRAME CUSTOM (UX-5a: asset pack cache) ---
						// Hash the tree (cheap walk, no deflate); on hit, send
						// a copy of the cached pack. On miss, pack fresh into
						// a global-owned buffer and promote it to the cache.
						// conn.send copies synchronously, but we dupe anyway
						// so no lock is held across the send.
						const hash = try assetTreeHash(dir);
						assetPackMutex.lock();
						var owned: []u8 = undefined;
						var ownedIsDupe = false;
						if (assetPackCache) |cached| {
							if (assetPackHash == hash) {
								owned = main.globalAllocator.dupe(u8, cached);
								ownedIsDupe = true;
							}
						}
						if (!ownedIsDupe) {
							var packer = try std.Io.Writer.Allocating.initCapacity(main.globalAllocator.allocator, 16);
							errdefer packer.deinit();
							try utils.Compression.pack(dir, &packer.writer);
							const packedBytes = try packer.toOwnedSlice();
							if (assetPackCache) |old| main.globalAllocator.free(old);
							assetPackCache = packedBytes;
							assetPackHash = hash;
							owned = main.globalAllocator.dupe(u8, packedBytes);
							ownedIsDupe = true;
						}
						assetPackMutex.unlock();
						defer main.globalAllocator.free(owned);
						// --- ASHFRAME CUSTOM (UX-6b: asset pack skip) ---
						// Compare against the hash of the packed bytes actually
						// being sent (same function the client uses on what it
						// received). The tree hash above is only for the pack
						// cache lookup; it can never match a client value.
						// Vanilla clients never announce -> full pack, as ever.
						if (main.settings.launchConfig.ashframePackSkip) {
							if (conn.user.?.ashframePackHash) |announced| {
								const sentHash = std.hash.Wyhash.hash(0, owned);
								if (announced == sentHash) {
									std.log.info("[ashframe] pack skip for {s}: client cache matches, sending marker", .{conn.user.?.name});
									var marker = try std.Io.Writer.Allocating.initCapacity(main.stackAllocator.allocator, 16);
									defer marker.deinit();
									try marker.writer.writeByte(@intFromEnum(Connection.HandShakeState.assets));
									conn.send(.secure, id, marker.written());
									conn.handShakeState.store(.assets, .monotonic);
									main.server.connect(conn.user.?);
									return;
								} else {
									std.log.debug("[ashframe] pack hash mismatch for {s}: announced={d} current={d}, sending full pack", .{ conn.user.?.name, announced, sentHash });
								}
							}
						}
						// --- ASHFRAME CUSTOM (UX-6b) ---
						var writer = try std.Io.Writer.Allocating.initCapacity(main.stackAllocator.allocator, 16);
						defer writer.deinit();
						try writer.writer.writeByte(@intFromEnum(Connection.HandShakeState.assets));
						try writer.writer.writeAll(owned);
						conn.send(.secure, id, writer.written());
						// --- ASHFRAME CUSTOM (UX-5a) ---
					}
					conn.handShakeState.store(.assets, .monotonic);

					main.server.connect(conn.user.?);
				},
				.assets, .serverData, .signatureRequest => return error.InvalidSide,
				.start, .complete => {},
			}
		} else {
			// Ignore packages that refer to an unexpected state. Normally those might be packages that were resent by the other side.
		}
	}

	pub fn serverSide(conn: *Connection) void {
		conn.handShakeState.store(.start, .monotonic);
	}

	pub fn sendServerPlayerData(conn: *Connection) void {
		const zonObject = ZonElement.initObject(main.stackAllocator);
		defer zonObject.deinit(main.stackAllocator);
		zonObject.put("player", conn.user.?.player().save(main.stackAllocator, .playerHimself));
		zonObject.put("player_id", @intFromEnum(conn.user.?.id));
		zonObject.put("gamemode", @intFromEnum(conn.user.?.gamemode.raw));
		zonObject.put("blockPalette", main.server.world.?.blockPalette.storeToZon(main.stackAllocator));
		zonObject.put("itemPalette", main.server.world.?.itemPalette.storeToZon(main.stackAllocator));
		zonObject.put("toolPalette", main.server.world.?.proceduralItemPalette.storeToZon(main.stackAllocator));
		zonObject.put("biomePalette", main.server.world.?.biomePalette.storeToZon(main.stackAllocator));
		zonObject.put("entityModelPalette", main.server.world.?.entityModelPalette.storeToZon(main.stackAllocator));
		zonObject.put("entityComponentPalette", main.server.world.?.entityComponentPalette.storeToZon(main.stackAllocator));

		const outData = zonObject.toStringEfficient(main.stackAllocator, &[1]u8{@intFromEnum(Connection.HandShakeState.serverData)});
		defer main.stackAllocator.free(outData);
		conn.send(.secure, id, outData);
	}

	pub fn clientSide(conn: *Connection, name: []const u8) !ZonElement {
		switch (conn.handShakeState.load(.monotonic)) {
			.start => {
				const zonObject = ZonElement.initObject(main.stackAllocator);
				defer zonObject.deinit(main.stackAllocator);

				zonObject.putOwnedString("version", settings.version.version);
				zonObject.putOwnedString("name", name);
				if (main.network.authentication.KeyCollection.initialized) {
					zonObject.put("keys", main.network.authentication.KeyCollection.getPublicKeys(main.stackAllocator));
				}
				try conn.secureChannel.startTlsHandshake();
				conn.secureChannel.finishedCollectingClientVerificationData = true;

				const prefix: [1]u8 = .{@intFromEnum(Connection.HandShakeState.userData)};
				const data = zonObject.toStringEfficient(main.stackAllocator, &prefix);
				defer main.stackAllocator.free(data);

				conn.send(.secure, id, data);
			},
			.reload => {
				conn.send(.secure, id, &.{@intFromEnum(Connection.HandShakeState.reload)});
			},
			else => unreachable,
		}

		while (true) {
			conn.mutex.lock();
			defer conn.mutex.unlock();
			const expectedRestartCounter = conn.restartCounter;
			while (true) {
				try main.io.checkCancel();
				conn.handShakeWaiting.timedWait(&conn.mutex, .fromMilliseconds(16)) catch {
					main.heap.GarbageCollection.syncPoint();
					continue;
				};
				break;
			}
			if (conn.restartCounter != expectedRestartCounter) return error.RestartAgain;
			if (conn.connectionState.load(.monotonic) == .disconnected) return error.DisconnectedByServer;
			if (conn.connectionState.load(.monotonic) != .connected) continue;
			break;
		}

		return handshakeZon;
	}

	pub fn signalLoadedAssets() void {
		main.network.protocols.handShake.hasFinishedLoadingAssets = true;
		main.network.protocols.handShake.assetsLoadedCondition.signal();
	}
};

pub const chunkRequest = struct { // MARK: chunkRequest
	pub const id: u8 = 2;
	/// Upper bound on the render distance a client may claim, so a hostile value
	/// can't keep huge numbers of chunks scheduled.
	const maxClientRenderDistance: u16 = 64;

	pub fn serverReceive(conn: *Connection, reader: *utils.BinaryReader) !void {
		const user = conn.user.?;
		main.server.metrics.noteChunkRequest();
		// Chunk/lightmap streaming must never be dropped: this packet also carries
		// `clientUpdatePos`/`renderDistance`, which `ChunkTask.isStillNeeded` uses to
		// decide what to keep. Dropping it froze the server's view of the player and
		// stalled chunk loading permanently (the client never retries a request).
		// Out-of-range requests are already pruned by `isStillNeeded`, and the
		// client's render distance is clamped to `maxClientRenderDistance`.
		const basePosition = try reader.readVec(Vec3i);
		user.clientUpdatePos = basePosition;
		user.renderDistance = @min(try reader.readInt(u16), maxClientRenderDistance);
		// --- ASHFRAME CUSTOM (Dynamic render distance) ---
		// Recompute the speed-based effective render distance for this packet, then
		// serve requests inside it and hold back (never drop) requests outside it.
		user.refreshDynamicRenderDistance();
		const effectiveRenderDistance = user.dynamicRenderDistance.load(.monotonic);
		// Only hold requests back when the player is actually view-capped.
		const viewCapped = effectiveRenderDistance < user.renderDistance;
		// --- ASHFRAME CUSTOM (Dynamic render distance) ---
		while (reader.remaining.len >= 4) {
			const x: i32 = try reader.readInt(i8);
			const y: i32 = try reader.readInt(i8);
			const z: i32 = try reader.readInt(i8);
			const voxelSizeShift: u5 = try reader.readInt(u5);
			if (voxelSizeShift > main.settings.highestSupportedLod) return error.Invalid;
			const positionMask = ~((@as(i32, 1) << voxelSizeShift + chunk.chunkShift) - 1);
			const request = chunk.ChunkPosition{
				.wx = (x << voxelSizeShift + chunk.chunkShift) +% (basePosition[0] & positionMask),
				.wy = (y << voxelSizeShift + chunk.chunkShift) +% (basePosition[1] & positionMask),
				.wz = (z << voxelSizeShift + chunk.chunkShift) +% (basePosition[2] & positionMask),
				.voxelSize = @as(u31, 1) << voxelSizeShift,
			};
			// --- ASHFRAME CUSTOM (Dynamic render distance) ---
			// +1 chunk of slack: chunks sitting right on the boundary must not be
			// held back (the defer/promote/discard radii would disagree otherwise
			// and leave holes at the edge of the view).
			const minDistance = @as(f64, @floatFromInt(request.getMinDistanceSquared(basePosition)));
			const effectiveRadius = @as(f64, @floatFromInt(effectiveRenderDistance + 1))*@as(f64, @floatFromInt(chunk.chunkSize))*@as(f64, @floatFromInt(request.voxelSize));
			if (!viewCapped or minDistance <= effectiveRadius*effectiveRadius) {
				main.server.world.?.queueChunk(request, conn.user.?);
			} else {
				// Held back; `User.processDeferredChunks` re-queues it once the
				// player slows down (the client never retries a request itself).
				user.deferChunk(request);
			}
			// --- ASHFRAME CUSTOM (Dynamic render distance) ---
		}
	}
	pub fn sendRequest(conn: *Connection, requests: []chunk.ChunkPosition, basePosition: Vec3i, renderDistance: u16) void {
		if (requests.len == 0) return;
		var writer = utils.BinaryWriter.initCapacity(main.stackAllocator, 14 + 4*requests.len);
		defer writer.deinit();
		writer.writeVec(Vec3i, basePosition);
		writer.writeInt(u16, renderDistance);
		for (requests) |req| {
			const voxelSizeShift: u5 = std.math.log2_int(u31, req.voxelSize);
			const positionMask = ~((@as(i32, 1) << voxelSizeShift + chunk.chunkShift) - 1);
			writer.writeInt(i8, @intCast((req.wx -% (basePosition[0] & positionMask)) >> voxelSizeShift + chunk.chunkShift));
			writer.writeInt(i8, @intCast((req.wy -% (basePosition[1] & positionMask)) >> voxelSizeShift + chunk.chunkShift));
			writer.writeInt(i8, @intCast((req.wz -% (basePosition[2] & positionMask)) >> voxelSizeShift + chunk.chunkShift));
			writer.writeInt(u5, voxelSizeShift);
		}
		conn.send(.secure, id, writer.data.items); // TODO: Can this use the slow channel?
	}
};

pub const chunkTransmission = struct { // MARK: chunkTransmission
	pub const id: u8 = 3;

	pub const MeshGenerationTask = struct {
		pos: chunk.ChunkPosition,
		data: []const u8,

		pub const vtable = utils.ThreadPool.VTable{
			.getPriority = main.meta.castFunctionSelfToAnyopaque(getPriority),
			.isStillNeeded = main.meta.castFunctionSelfToAnyopaque(isStillNeeded),
			.run = main.meta.castFunctionSelfToAnyopaque(run),
			.clean = main.meta.castFunctionSelfToAnyopaque(clean),
			.taskType = .meshgenAndLighting,
		};

		pub fn getPriority(self: *MeshGenerationTask) f32 {
			return self.pos.getPriority(game.Player.getPosBlocking()); // TODO: This is called in loop, find a way to do this without calling the mutex every time.
		}

		pub fn isStillNeeded(self: *MeshGenerationTask) bool {
			if (main.game.world == null or main.game.world.?.paused) return false;
			const distanceSqr = self.pos.getMinDistanceSquared(@trunc(game.Player.getPosBlocking())); // TODO: This is called in loop, find a way to do this without calling the mutex every time.
			var maxRenderDistance = settings.renderDistance*chunk.chunkSize*self.pos.voxelSize;
			maxRenderDistance += 2*self.pos.voxelSize*chunk.chunkSize;
			return distanceSqr < maxRenderDistance*maxRenderDistance;
		}

		pub fn run(self: *MeshGenerationTask) void {
			defer self.clean();
			const pos = self.pos;
			const mesh = main.renderer.chunk_meshing.ChunkMesh.init(pos, self.data) catch |err| {
				std.log.err("Could not load chunk mesh from server: {s} Disconnecting.", .{@errorName(err)});
				main.game.world.?.conn.disconnect();
				return;
			};
			mesh.generateLightingData() catch mesh.deferredDeinit();
		}

		pub fn clean(self: *MeshGenerationTask) void {
			main.globalAllocator.free(self.data);
			main.globalAllocator.destroy(self);
		}
	};
	pub fn clientReceive(_: *Connection, reader: *utils.BinaryReader) !void {
		const task = main.globalAllocator.create(MeshGenerationTask);
		errdefer main.globalAllocator.destroy(task);
		task.* = .{
			.pos = .{
				.wx = try reader.readInt(i32),
				.wy = try reader.readInt(i32),
				.wz = try reader.readInt(i32),
				.voxelSize = try reader.readInt(u31),
			},
			.data = main.globalAllocator.dupe(u8, reader.remaining),
		};
		main.threadPool.addTask(task, &MeshGenerationTask.vtable);
	}
	fn sendChunkOverTheNetwork(conn: *Connection, ch: *chunk.ServerChunk) void {
		main.server.metrics.noteChunkSent();
		// --- ASHFRAME CUSTOM (UX-2a: compress outside the chunk lock) ---
		// Extract everything that reads chunk state under the lock (palette,
		// voxels, hiding/smoothing, block entities), then release it BEFORE
		// the ~0.6-1.2 ms deflate. Same bytes as storeChunk, just split.
		const CC = main.server.storage.ChunkCompression;
		ch.mutex.lock();
		var extraction: CC.BlockDataExtraction = undefined;
		const voxels = main.stackAllocator.alloc(u8, chunk.chunkVolume*@sizeOf(u32));
		defer main.stackAllocator.free(voxels);
		CC.extractBlockData(&ch.super, ch.super.pos.voxelSize != 1, main.settings.launchConfig.antiXray, voxels, &extraction);
		var entWriter = utils.BinaryWriter.init(main.stackAllocator);
		defer entWriter.deinit();
		CC.compressBlockEntityData(&ch.super, .toClient, &entWriter);
		const chunkWx = ch.super.pos.wx;
		const chunkWy = ch.super.pos.wy;
		const chunkWz = ch.super.pos.wz;
		const chunkVoxelSize = ch.super.pos.voxelSize;
		ch.mutex.unlock();
		// --- ASHFRAME CUSTOM (NET-001: compress-time observability) ---
		const compressT0 = main.timestamp();
		var blockWriter = utils.BinaryWriter.init(main.stackAllocator);
		defer blockWriter.deinit();
		CC.writeExtractedBlockData(main.stackAllocator, &extraction, voxels[0..extraction.voxelBytes], &blockWriter);
		const compressNs = compressT0.durationTo(main.timestamp()).toNanoseconds();
		main.server.metrics.noteChunkCompressUs(@intCast(@max(0, @divTrunc(compressNs, 1000))));
		// --- ASHFRAME CUSTOM (NET-001) ---
		const chunkData = blockWriter.data.items;
		var writer = utils.BinaryWriter.initCapacity(main.stackAllocator, chunkData.len + entWriter.data.items.len + 16);
		defer writer.deinit();
		writer.writeInt(i32, chunkWx);
		writer.writeInt(i32, chunkWy);
		writer.writeInt(i32, chunkWz);
		writer.writeInt(u31, chunkVoxelSize);
		writer.writeSlice(chunkData);
		writer.writeSlice(entWriter.data.items);
		// --- ASHFRAME CUSTOM (UX-2a) ---
		// --- ASHFRAME CUSTOM (UX-1: chunks on the slow channel) ---
		// Chunk bursts (up to ~3.4 MB queued, 7.6 MB/s) used to ride `.secure`
		// and head-of-line-block gameplay acks (position, block edits,
		// teleports). `.slow` has its own window/pacing; the client handles
		// it natively and protocol dispatch is by id, not channel, so this
		// is vanilla-safe. Answers the TODO above: yes.
		conn.send(.slow, id, writer.data.items);
		// --- ASHFRAME CUSTOM (UX-1) ---
	}
	pub fn sendChunk(conn: *Connection, ch: *chunk.ServerChunk) void {
		sendChunkOverTheNetwork(conn, ch);
	}
};

pub const playerPosition = struct { // MARK: playerPosition
	pub const id: u8 = 4;

	pub fn serverReceive(conn: *Connection, reader: *utils.BinaryReader) !void {
		main.server.metrics.notePositionUpdate();
		try conn.user.?.receiveData(reader);
	}
	var lastPositionSent: u16 = 0;
	pub fn send(conn: *Connection, playerPos: Vec3d, playerVel: Vec3d, time: u16) void {
		if (time -% lastPositionSent < 50) {
			return; // Only send at most once every 50 ms.
		}
		lastPositionSent = time;
		var writer = utils.BinaryWriter.initCapacity(main.stackAllocator, 62);
		defer writer.deinit();
		writer.writeInt(u64, @bitCast(playerPos[0]));
		writer.writeInt(u64, @bitCast(playerPos[1]));
		writer.writeInt(u64, @bitCast(playerPos[2]));
		writer.writeInt(u64, @bitCast(playerVel[0]));
		writer.writeInt(u64, @bitCast(playerVel[1]));
		writer.writeInt(u64, @bitCast(playerVel[2]));
		writer.writeInt(u32, @bitCast(game.camera.rotation[0]));
		writer.writeInt(u32, @bitCast(game.camera.rotation[1]));
		writer.writeInt(u32, @bitCast(game.camera.rotation[2]));
		writer.writeInt(u16, time);
		conn.send(.lossy, id, writer.data.items);
	}
};

pub const entityPosition = struct { // MARK: entityPosition
	pub const id: u8 = 6;
	const Type = enum(u8) {
		noVelocityEntity = 0,
		f16VelocityEntity = 1,
		f32VelocityEntity = 2,
		noVelocityItem = 3,
		f16VelocityItem = 4,
		f32VelocityItem = 5,
	};
	pub fn clientReceive(conn: *Connection, reader: *utils.BinaryReader) !void {
		if (conn.manager.world) |world| {
			const time = try reader.readInt(i16);
			const playerPos = try reader.readVec(Vec3d);
			var entityData: main.ListManaged(main.entity.EntityNetworkData) = .init(main.stackAllocator);
			defer entityData.deinit();
			var itemData: main.ListManaged(main.itemdrop.ItemDropNetworkData) = .init(main.stackAllocator);
			defer itemData.deinit();
			while (reader.remaining.len != 0) {
				const typ = try reader.readEnum(Type);
				switch (typ) {
					.noVelocityEntity, .f16VelocityEntity, .f32VelocityEntity => {
						entityData.append(.{
							.vel = switch (typ) {
								.noVelocityEntity => @splat(0),
								.f16VelocityEntity => @floatCast(try reader.readVec(@Vector(3, f16))),
								.f32VelocityEntity => @floatCast(try reader.readVec(@Vector(3, f32))),
								else => unreachable,
							},
							.id = try reader.readEnum(main.entity.Entity),
							.pos = playerPos + try reader.readVec(Vec3f),
							.rot = try reader.readVec(Vec3f),
						});
					},
					.noVelocityItem, .f16VelocityItem, .f32VelocityItem => {
						itemData.append(.{
							.vel = switch (typ) {
								.noVelocityItem => @splat(0),
								.f16VelocityItem => @floatCast(try reader.readVec(@Vector(3, f16))),
								.f32VelocityItem => @floatCast(try reader.readVec(Vec3f)),
								else => unreachable,
							},
							.index = try reader.readInt(u16),
							.pos = playerPos + try reader.readVec(Vec3f),
						});
					},
				}
			}
			main.client.entity_manager.serverUpdate(time, entityData.items);
			world.itemDrops.readPosition(time, itemData.items);
		}
	}
	pub fn send(conn: *Connection, playerPos: Vec3d, entityData: []const main.entity.EntityNetworkData, itemData: []const main.itemdrop.ItemDropNetworkData) void {
		var writer = utils.BinaryWriter.init(main.stackAllocator);
		defer writer.deinit();

		writer.writeInt(i16, @truncate(main.timestamp().toMilliseconds()));
		writer.writeVec(Vec3d, playerPos);
		for (entityData) |data| {
			const velocityMagnitudeSqr = vec.lengthSquare(data.vel);
			if (velocityMagnitudeSqr < 1e-6*1e-6) {
				writer.writeEnum(Type, .noVelocityEntity);
			} else if (velocityMagnitudeSqr > 1000*1000) {
				writer.writeEnum(Type, .f32VelocityEntity);
				writer.writeVec(Vec3f, @floatCast(data.vel));
			} else {
				writer.writeEnum(Type, .f16VelocityEntity);
				writer.writeVec(@Vector(3, f16), @floatCast(data.vel));
			}
			writer.writeEnum(main.entity.Entity, data.id);
			writer.writeVec(Vec3f, @floatCast(data.pos - playerPos));
			writer.writeVec(Vec3f, data.rot);
		}
		for (itemData) |data| {
			const velocityMagnitudeSqr = vec.lengthSquare(data.vel);
			if (velocityMagnitudeSqr < 1e-6*1e-6) {
				writer.writeEnum(Type, .noVelocityItem);
			} else if (velocityMagnitudeSqr > 1000*1000) {
				writer.writeEnum(Type, .f32VelocityItem);
				writer.writeVec(Vec3f, @floatCast(data.vel));
			} else {
				writer.writeEnum(Type, .f16VelocityItem);
				writer.writeVec(@Vector(3, f16), @floatCast(data.vel));
			}
			writer.writeInt(u16, data.index);
			writer.writeVec(Vec3f, @floatCast(data.pos - playerPos));
		}
		conn.send(.lossy, id, writer.data.items);
	}
};

pub const blockUpdate = struct { // MARK: blockUpdate
	pub const id: u8 = 7;

	pub fn clientReceive(_: *Connection, reader: *utils.BinaryReader) !void {
		while (reader.remaining.len != 0) {
			renderer.mesh_storage.updateBlock(.{
				.pos = try reader.readVec(Vec3i),
				.newBlock = Block.fromInt(try reader.readInt(u32)),
				.blockEntityData = try reader.readSlice(try reader.readInt(usize)),
			});
		}
	}
	pub fn send(conn: *Connection, updates: []const BlockUpdate) void {
		var writer = utils.BinaryWriter.initCapacity(main.stackAllocator, 16);
		defer writer.deinit();

		for (updates) |update| {
			writer.writeVec(Vec3i, update.pos);
			writer.writeInt(u32, update.newBlock.toInt());
			writer.writeInt(usize, update.blockEntityData.len);
			writer.writeSlice(update.blockEntityData);
		}
		conn.send(.secure, id, writer.data.items);
	}
};

pub const entity = struct { // MARK: entity
	pub const id: u8 = 8;

	pub fn clientReceive(conn: *Connection, reader: *utils.BinaryReader) !void {
		const zonArray = ZonElement.parseFromString(main.stackAllocator, null, reader.remaining);
		defer zonArray.deinit(main.stackAllocator);
		var i: u32 = 0;
		while (i < zonArray.array.items.len) : (i += 1) {
			const elem = zonArray.array.items[i];
			switch (elem) {
				.int => {
					main.client.entity_manager.removeEntity(@enumFromInt(elem.as(u32) orelse return error.Invalid));
				},
				.object => {
					try main.client.entity_manager.addEntity(elem);
				},
				.null => {
					i += 1;
					break;
				},
				else => {
					std.log.err("Unrecognized zon parameters for protocol {}: {s}", .{id, reader.remaining});
				},
			}
		}
		while (i < zonArray.array.items.len) : (i += 1) {
			const elem: ZonElement = zonArray.array.items[i];
			if (elem == .int) {
				conn.manager.world.?.itemDrops.remove(elem.as(u16) orelse return error.Invalid);
			} else if (!elem.getChild("array").isNull()) {
				conn.manager.world.?.itemDrops.loadFrom(elem);
			} else {
				conn.manager.world.?.itemDrops.addFromZon(elem);
			}
		}
	}
	pub fn send(conn: *Connection, msg: []const u8) void {
		conn.send(.secure, id, msg);
	}
};

pub const genericUpdate = struct { // MARK: genericUpdate
	pub const id: u8 = 9;

	const UpdateType = enum(u8) {
		gamemode = 0,
		teleport = 1,
		worldEditPos = 2,
		time = 3,
		biome = 4,
		particles = 5,
		clear = 6,
	};

	const WorldEditPosition = enum(u2) {
		selectedPos1 = 0,
		selectedPos2 = 1,
		clear = 2,
	};

	const ClearType = enum(u1) {
		chat = 0,
	};

	pub fn clientReceive(conn: *Connection, reader: *utils.BinaryReader) !void {
		switch (try reader.readEnum(UpdateType)) {
			.gamemode => {
				main.sync.setGamemode(null, try reader.readEnum(main.game.Gamemode));
			},
			.teleport => {
				game.Player.setPosBlocking(try reader.readVec(Vec3d));
			},
			.worldEditPos => {
				const typ = try reader.readEnum(WorldEditPosition);
				const pos: ?Vec3i = switch (typ) {
					.selectedPos1, .selectedPos2 => try reader.readVec(Vec3i),
					.clear => null,
				};
				switch (typ) {
					.selectedPos1 => game.Player.selectionPosition1 = pos,
					.selectedPos2 => game.Player.selectionPosition2 = pos,
					.clear => {
						game.Player.selectionPosition1 = null;
						game.Player.selectionPosition2 = null;
					},
				}
			},
			.time => {
				const world = conn.manager.world.?;
				const expectedTime = try reader.readInt(i64);

				var curTime = world.gameTime.load(.monotonic);
				if (@abs(curTime -% expectedTime) >= 10) {
					world.gameTime.store(expectedTime, .monotonic);
				} else if (curTime < expectedTime) { // world.gameTime++
					while (world.gameTime.cmpxchgWeak(curTime, curTime +% 1, .monotonic, .monotonic)) |actualTime| {
						curTime = actualTime;
					}
				} else { // world.gameTime--
					while (world.gameTime.cmpxchgWeak(curTime, curTime -% 1, .monotonic, .monotonic)) |actualTime| {
						curTime = actualTime;
					}
				}
			},
			.biome => {
				const world = conn.manager.world.?;
				const biomeId = try reader.readInt(u32);

				const newBiome = main.server.terrain.biomes.getByIndex(biomeId) orelse return error.MissingBiome;
				const oldBiome = world.playerBiome.swap(newBiome, .monotonic);
				if (oldBiome != newBiome) {
					main.audio.setMusic(newBiome.preferredMusic);
				}
			},
			.particles => {
				const particleIdLen = try reader.readVarInt(u16);
				const particleId = try reader.readSlice(particleIdLen);
				const pos = try reader.readVec(Vec3d);
				const collides = try reader.readBool();
				const count = try reader.readVarInt(u32);
				const spawnZonLen = try reader.readVarInt(usize);
				const spawnZon = try reader.readSlice(spawnZonLen);

				var emitter: particles.Emitter = undefined;
				if (spawnZonLen != 0) {
					const zon = ZonElement.parseFromString(main.stackAllocator, null, spawnZon);
					defer zon.deinit(main.stackAllocator);
					emitter = .initFromZon(particleId, collides, zon);
				} else {
					const emitterProperties = particles.EmitterProperties{
						.speed = .init(1, 1.5),
						.lifeTime = .init(0.75, 1),
						.randomizeRotation = true,
					};
					emitter = .init(particleId, collides, .{.point = .{}}, emitterProperties, .spread);
				}

				particles.ParticleSystem.addParticlesFromNetwork(emitter, pos, count);
			},
			.clear => {
				const typ = try reader.readEnum(ClearType);
				switch (typ) {
					.chat => main.gui.windowlist.chat.clearChat(),
				}
			},
		}
	}

	pub fn serverReceive(conn: *Connection, reader: *utils.BinaryReader) !void {
		switch (try reader.readEnum(UpdateType)) {
			.gamemode, .teleport, .time, .biome, .particles, .clear => return error.InvalidSide,
			.worldEditPos => {
				const typ = try reader.readEnum(WorldEditPosition);
				const pos: ?Vec3i = switch (typ) {
					.selectedPos1, .selectedPos2 => try reader.readVec(Vec3i),
					.clear => null,
				};
				switch (typ) {
					.selectedPos1 => conn.user.?.worldEditData.selectionPosition1 = pos.?,
					.selectedPos2 => conn.user.?.worldEditData.selectionPosition2 = pos.?,
					.clear => {
						conn.user.?.worldEditData.selectionPosition1 = null;
						conn.user.?.worldEditData.selectionPosition2 = null;
					},
				}
			},
		}
	}

	pub fn sendGamemode(conn: *Connection, gamemode: main.game.Gamemode) void {
		conn.send(.secure, id, &.{@intFromEnum(UpdateType.gamemode), @intFromEnum(gamemode)});
	}

	pub fn sendTPCoordinates(conn: *Connection, pos: Vec3d) void {
		// --- ASHFRAME CUSTOM (Teleport view ramp): every teleport goes through
		// here, so this is the one place we need to hook. ---
		if (conn.user) |user| user.beginTeleportViewRamp();
		// --- ASHFRAME CUSTOM (Teleport view ramp) ---
		var writer = utils.BinaryWriter.initCapacity(main.stackAllocator, 25);
		defer writer.deinit();

		writer.writeEnum(UpdateType, .teleport);
		writer.writeVec(Vec3d, pos);

		conn.send(.secure, id, writer.data.items);
	}

	pub fn sendWorldEditPos(conn: *Connection, posType: WorldEditPosition, maybePos: ?Vec3i) void {
		var writer = utils.BinaryWriter.initCapacity(main.stackAllocator, 25);
		defer writer.deinit();

		writer.writeEnum(UpdateType, .worldEditPos);
		writer.writeEnum(WorldEditPosition, posType);
		if (maybePos) |pos| {
			writer.writeVec(Vec3i, pos);
		}

		conn.send(.secure, id, writer.data.items);
	}

	pub fn sendBiome(conn: *Connection, biomeIndex: u32) void {
		var writer = utils.BinaryWriter.initCapacity(main.stackAllocator, 13);
		defer writer.deinit();

		writer.writeEnum(UpdateType, .biome);
		writer.writeInt(u32, biomeIndex);

		conn.send(.secure, id, writer.data.items);
	}

	pub fn sendParticles(conn: *Connection, particleId: []const u8, pos: Vec3d, collides: bool, count: u32, spawnZon: []const u8) void {
		// Bisect toggle: mute all custom particle sends (all callers are ours).
		if (!main.settings.launchConfig.customParticles) return;
		const bufferSize = particleId.len*8 + 32;
		var writer = utils.BinaryWriter.initCapacity(main.stackAllocator, bufferSize);
		defer writer.deinit();

		writer.writeEnum(UpdateType, .particles);
		writer.writeVarInt(u16, @intCast(particleId.len));
		writer.writeSlice(particleId);
		writer.writeVec(Vec3d, pos);
		writer.writeBool(collides);
		writer.writeVarInt(u32, count);
		writer.writeVarInt(usize, spawnZon.len);
		writer.writeSlice(spawnZon);

		conn.send(.secure, id, writer.data.items);
	}

	pub fn sendTime(conn: *Connection, world: *const main.server.ServerWorld) void {
		var writer = utils.BinaryWriter.initCapacity(main.stackAllocator, 13);
		defer writer.deinit();

		writer.writeEnum(UpdateType, .time);
		writer.writeInt(i64, world.gameTime);

		conn.send(.secure, id, writer.data.items);
	}

	pub fn sendClear(conn: *Connection, cleartype: ClearType) void {
		conn.send(.lossy, id, &.{@intFromEnum(UpdateType.clear), @intFromEnum(cleartype)}); // TODO change channel afer #1879
	}
};

pub const chat = struct { // MARK: chat
	pub const id: u8 = 10;

	pub fn clientReceive(_: *Connection, reader: *utils.BinaryReader) !void {
		const msg = reader.remaining;
		if (!std.unicode.utf8ValidateSlice(msg)) {
			std.log.err("Received chat message with invalid UTF-8 characters.", .{});
			return error.Invalid;
		}
		main.gui.windowlist.chat.addMessage(msg);
	}
	pub fn serverReceive(conn: *Connection, reader: *utils.BinaryReader) !void {
		const msg = reader.remaining;
		if (!std.unicode.utf8ValidateSlice(msg)) {
			std.log.err("Received chat message with invalid UTF-8 characters.", .{});
			return error.Invalid;
		}
		const user = conn.user.?;
		if (msg.len > 10000 or main.graphics.TextBuffer.Parser.countVisibleCharacters(msg) > 1000) {
			std.log.err("Received too long chat message with {}/{} characters.", .{main.graphics.TextBuffer.Parser.countVisibleCharacters(msg), msg.len});
			return error.Invalid;
		}
		if (!user.rateChat.allow(main.server.anticheat.nowMilliseconds())) {
			main.server.anticheat.note(user, .rate, "chat");
			return;
		}
		main.server.messageFrom(msg, user);
	}

	pub fn send(conn: *Connection, msg: []const u8) void {
		conn.send(.lossy, id, msg);
	}
};

pub const lightMapRequest = struct { // MARK: lightMapRequest
	pub const id: u8 = 11;

	pub fn serverReceive(conn: *Connection, reader: *utils.BinaryReader) !void {
		const user = conn.user orelse return;
		while (reader.remaining.len >= 9) {
			const wx = try reader.readInt(i32);
			const wy = try reader.readInt(i32);
			const voxelSizeShift = try reader.readInt(u5);
			if (voxelSizeShift > main.settings.highestSupportedLod) return error.Invalid;
			const request = main.server.terrain.SurfaceMap.MapFragmentPosition{
				.wx = wx,
				.wy = wy,
				.voxelSize = @as(u31, 1) << voxelSizeShift,
				.voxelSizeShift = voxelSizeShift,
			};
			main.server.world.?.queueLightMap(request, user);
		}
	}
	pub fn sendRequest(conn: *Connection, requests: []main.server.terrain.SurfaceMap.MapFragmentPosition) void {
		if (requests.len == 0) return;
		var writer = utils.BinaryWriter.initCapacity(main.stackAllocator, 9*requests.len);
		defer writer.deinit();
		for (requests) |req| {
			writer.writeInt(i32, req.wx);
			writer.writeInt(i32, req.wy);
			writer.writeInt(u8, req.voxelSizeShift);
		}
		conn.send(.secure, id, writer.data.items); // TODO: Can this use the slow channel?
	}
};

pub const lightMapTransmission = struct { // MARK: lightMapTransmission
	pub const id: u8 = 12;

	const LightMapTask = struct {
		wx: i32,
		wy: i32,
		voxelSizeShift: u5,
		data: []const u8,

		const vtable = utils.ThreadPool.VTable{
			.getPriority = main.meta.castFunctionSelfToAnyopaque(getPriority),
			.isStillNeeded = main.meta.castFunctionSelfToAnyopaque(isStillNeeded),
			.run = main.meta.castFunctionSelfToAnyopaque(run),
			.clean = main.meta.castFunctionSelfToAnyopaque(clean),
			.taskType = .misc,
		};

		pub fn getPriority(_: *LightMapTask) f32 {
			return std.math.floatMax(f32);
		}

		pub fn isStillNeeded(_: *LightMapTask) bool {
			if (main.game.world == null or main.game.world.?.paused) return false;
			return true;
		}

		pub fn run(self: *LightMapTask) void {
			defer self.clean();

			const pos = main.server.terrain.SurfaceMap.MapFragmentPosition{
				.wx = self.wx,
				.wy = self.wy,
				.voxelSize = @as(u31, 1) << self.voxelSizeShift,
				.voxelSizeShift = self.voxelSizeShift,
			};
			const _inflatedData = main.stackAllocator.alloc(u8, main.server.terrain.LightMap.LightMapFragment.mapSize*main.server.terrain.LightMap.LightMapFragment.mapSize*2);
			defer main.stackAllocator.free(_inflatedData);
			const _inflatedLen = utils.Compression.inflateTo(_inflatedData, self.data) catch |err| {
				std.log.err("Got error {s} while decompressing lightmap data at position {} with data {any}", .{@errorName(err), pos, self.data});
				main.game.world.?.conn.disconnect();
				return;
			};
			if (_inflatedLen != main.server.terrain.LightMap.LightMapFragment.mapSize*main.server.terrain.LightMap.LightMapFragment.mapSize*2) {
				std.log.err("Transmission of light map has invalid size: {}. Input data: {any}, After inflate: {any}", .{_inflatedLen, self.data, _inflatedData[0.._inflatedLen]});
				main.game.world.?.conn.disconnect();
				return;
			}
			var ligthMapReader = utils.BinaryReader.init(_inflatedData);
			const map = main.globalAllocator.create(main.server.terrain.LightMap.LightMapFragment);
			map.init(pos.wx, pos.wy, pos.voxelSize);
			for (&map.startHeight) |*val| {
				val.* = ligthMapReader.readInt(i16) catch |err| {
					std.log.err("Got error {s} while reading decompressed lightmap data at position {} with data {any}", .{@errorName(err), pos, _inflatedData});
					main.game.world.?.conn.disconnect();
					return;
				};
			}
			renderer.mesh_storage.updateLightMap(map);
		}

		pub fn clean(self: *LightMapTask) void {
			main.globalAllocator.free(self.data);
			main.globalAllocator.destroy(self);
		}
	};

	pub fn clientReceive(_: *Connection, reader: *utils.BinaryReader) !void {
		const task = main.globalAllocator.create(LightMapTask);
		errdefer main.globalAllocator.destroy(task);
		task.* = .{
			.wx = try reader.readInt(i32),
			.wy = try reader.readInt(i32),
			.voxelSizeShift = try reader.readInt(u5),
			.data = main.globalAllocator.dupe(u8, reader.remaining),
		};
		main.threadPool.addTask(task, &LightMapTask.vtable);
	}
	pub fn sendLightMap(conn: *Connection, map: *main.server.terrain.LightMap.LightMapFragment) void {
		var ligthMapWriter = utils.BinaryWriter.initCapacity(main.stackAllocator, @sizeOf(@TypeOf(map.startHeight)));
		defer ligthMapWriter.deinit();
		for (&map.startHeight) |val| {
			ligthMapWriter.writeInt(i16, val);
		}
		const compressedData = utils.Compression.deflate(main.stackAllocator, ligthMapWriter.data.items, .default);
		defer main.stackAllocator.free(compressedData);
		var writer = utils.BinaryWriter.initCapacity(main.stackAllocator, 9 + compressedData.len);
		defer writer.deinit();
		writer.writeInt(i32, map.pos.wx);
		writer.writeInt(i32, map.pos.wy);
		writer.writeInt(u8, map.pos.voxelSizeShift);
		writer.writeSlice(compressedData);
		// --- ASHFRAME CUSTOM (UX-1c: lightmaps on the slow channel) ---
		// Same rationale as UX-1 for chunks: lightmap bursts rode `.secure`
		// and head-of-line-blocked gameplay acks. `.slow` is a stock channel
		// and dispatch is by protocol id, so vanilla clients handle it
		// natively and the UX-1b 900 KB backpressure (channel-wide) covers it.
		conn.send(.slow, id, writer.data.items);
		// --- ASHFRAME CUSTOM (UX-1c) ---
	}
};

pub const inventory = struct { // MARK: inventory
	pub const id: u8 = 13;

	pub fn clientReceive(_: *Connection, reader: *utils.BinaryReader) !void {
		const typ = try reader.readInt(u8);
		if (typ == 0xff) { // Confirmation
			main.sync.client.receiveSyncOperation(.init(.confirmation, reader.remaining));
		} else if (typ == 0xfe) { // Failure
			main.sync.client.receiveSyncOperation(.init(.failure, &.{}));
		} else {
			main.sync.client.receiveSyncOperation(.init(.sync, reader.remaining));
		}
	}
	pub fn serverReceive(conn: *Connection, reader: *utils.BinaryReader) !void {
		const user = conn.user.?;
		if (reader.remaining.len == 0) return error.Invalid;
		if (reader.remaining[0] == 0xff) return error.Invalid;
		// --- ASHFRAME CUSTOM (Split rate gates) ---
		// Damage reports and inventory/crafting traffic must never be starved
		// by rate limiting: a dry bucket silently discards damage
		// (invincibility) or leaves the client's optimistic inventory change
		// hanging with no reply (stuck items, uncraftable recipes). Both
		// bypass rate limiting entirely (the queue cap in receiveCommand
		// already bounds floods); block place/break keeps its own generous
		// bucket as the remaining flood guard.
		const payloadTag = reader.remaining[0];
		const isBlockEdit = payloadTag == @intFromEnum(main.sync.Command.PayloadType.updateBlock);
		if (isBlockEdit) {
			if (!user.rateBlock.allow(main.server.anticheat.nowMilliseconds())) {
				// Review-only: bursts from fast building are legitimate.
				main.server.anticheat.suspect(user, .rate, "block");
				return;
			}
		}
		// --- ASHFRAME CUSTOM (Split rate gates) ---
		main.sync.server.receiveCommand(user, reader);
	}
	pub fn sendCommand(conn: *Connection, payloadType: main.sync.Command.PayloadType, _data: []const u8) void {
		std.debug.assert(conn.user == null);
		var writer = utils.BinaryWriter.initCapacity(main.stackAllocator, _data.len + 1);
		defer writer.deinit();
		writer.writeEnum(main.sync.Command.PayloadType, payloadType);
		std.debug.assert(writer.data.items[0] != 0xff);
		writer.writeSlice(_data);
		conn.send(.secure, id, writer.data.items);
	}
	pub fn sendConfirmation(conn: *Connection, _data: []const u8) void {
		std.debug.assert(conn.isServerSide());
		var writer = utils.BinaryWriter.initCapacity(main.stackAllocator, _data.len + 1);
		defer writer.deinit();
		writer.writeInt(u8, 0xff);
		writer.writeSlice(_data);
		conn.send(.secure, id, writer.data.items);
	}
	pub fn sendFailure(conn: *Connection) void {
		std.debug.assert(conn.isServerSide());
		conn.send(.secure, id, &.{0xfe});
	}
	pub fn sendSyncOperation(conn: *Connection, _data: []const u8) void {
		std.debug.assert(conn.isServerSide());
		var writer = utils.BinaryWriter.initCapacity(main.stackAllocator, _data.len + 1);
		defer writer.deinit();
		writer.writeInt(u8, 0);
		writer.writeSlice(_data);
		conn.send(.secure, id, writer.data.items);
	}
};

pub const blockEntityUpdate = struct { // MARK: blockEntityUpdate
	pub const id: u8 = 14;

	pub fn serverReceive(conn: *Connection, reader: *utils.BinaryReader) !void {
		const pos = try reader.readVec(Vec3i);
		const blockType = try reader.readInt(u16);

		// --- ASHFRAME CUSTOM (Chat filter: sign text) ---
		const blockId = main.blocks.idOfType(blockType);
		if (blockId != null and std.mem.startsWith(u8, blockId.?, "cubyz:sign")) {
			// --- ASHFRAME CUSTOM (Sign shops: protect the offer text) ---
			if (conn.user) |user| {
				if (main.server.shops.rejectEdit(user, pos)) {
					user.sendMessage("#e6312cThis sign is part of a shop and can't be edited.", .{});
					sendServerDataUpdateToClients(pos);
					return;
				}
			}
			// --- ASHFRAME CUSTOM (Sign shops) ---
		// --- ASHFRAME CUSTOM (Anticheat: reach) ---
		if (conn.user) |user| {
			if (!main.server.anticheat.checkReach(user, .{pos[0], pos[1], pos[2]})) return;
		}
		// --- ASHFRAME CUSTOM (Anticheat) ---
		// NOTE: a claim check (canBuild) was tried here and REMOVED: this
		// handler runs on the network thread, and canBuild reaches
		// permissions.hasPermission, which asserts server-thread-only and
		// aborts the whole server on any sign edit. Sign text is therefore
		// NOT claim-gated (shop offer text is still protected above).
		if (main.server.chatfilter.findBad(reader.remaining) != null) {
				if (conn.user) |user| {
					// The ban is completed on the server thread.
					_ = main.server.chatfilter.strike(user);
				}
				return;
			}
		}
		// --- ASHFRAME CUSTOM (Chat filter) ---

		const simChunk = main.server.world.?.getSimulationChunkAndIncreaseRefCount(pos[0], pos[1], pos[2]) orelse return;
		defer simChunk.decreaseRefCount();
		const ch = simChunk.chunk.load(.monotonic) orelse return;
		ch.mutex.lock();
		defer ch.mutex.unlock();
		const block = ch.getBlock(pos[0] - ch.super.pos.wx, pos[1] - ch.super.pos.wy, pos[2] - ch.super.pos.wz);
		if (block.typ != blockType) return;
		const blockEntity = block.blockEntity() orelse return;
		try blockEntity.updateServerData(pos, &ch.super, .{.update = reader});
		ch.setChanged();

		sendServerDataUpdateToClientsInternal(pos, &ch.super, block, blockEntity);
	}

	pub fn sendClientDataUpdateToServer(conn: *Connection, pos: Vec3i) void {
		const mesh = main.renderer.mesh_storage.getMesh(.initFromWorldPos(pos, 1)) orelse return;
		mesh.mutex.lock();
		defer mesh.mutex.unlock();
		const localPos = mesh.chunk.getLocalBlockPos(pos);
		const block = mesh.chunk.data.getValue(localPos.toIndex());
		const blockEntity = block.blockEntity() orelse return;

		var writer = utils.BinaryWriter.init(main.stackAllocator);
		defer writer.deinit();
		writer.writeVec(Vec3i, pos);
		writer.writeInt(u16, block.typ);
		blockEntity.getClientToServerData(pos, mesh.chunk, &writer);

		conn.send(.secure, id, writer.data.items);
	}

	fn sendServerDataUpdateToClientsInternal(pos: Vec3i, ch: *chunk.Chunk, block: Block, blockEntity: *const main.block_entity.BlockEntityType) void {
		var writer = utils.BinaryWriter.init(main.stackAllocator);
		defer writer.deinit();
		blockEntity.getServerToClientData(pos, ch, &writer);

		const users = main.server.getUserList(main.stackAllocator);
		defer main.stackAllocator.free(users);

		for (users) |user| {
			// --- ASHFRAME CUSTOM (interest gating) ---
			if (!user.canSeeBlock(pos[0], pos[1], pos[2])) continue;
			blockUpdate.send(user.conn, &.{.{.pos = pos, .newBlock = block, .blockEntityData = writer.data.items}});
		}
	}

	pub fn sendServerDataUpdateToClients(pos: Vec3i) void {
		const simChunk = main.server.world.?.getSimulationChunkAndIncreaseRefCount(pos[0], pos[1], pos[2]) orelse return;
		defer simChunk.decreaseRefCount();
		const ch = simChunk.chunk.load(.monotonic) orelse return;
		ch.mutex.lock();
		defer ch.mutex.unlock();
		const block = ch.getBlock(pos[0] - ch.super.pos.wx, pos[1] - ch.super.pos.wy, pos[2] - ch.super.pos.wz);
		const blockEntity = block.blockEntity() orelse return;

		sendServerDataUpdateToClientsInternal(pos, &ch.super, block, blockEntity);
	}
};

pub const EntityComponentUpdate = struct { // MARK: EntityComponentUpdate
	pub const id: u8 = 15;

	const ActionType = enum(u8) {
		unload = 0,
		load = 1,
	};

	pub fn clientReceive(_: *Connection, reader: *utils.BinaryReader) !void {
		const entityId: main.entity.Entity = @enumFromInt(try reader.readVarInt(u32));
		const componentId = try reader.readVarInt(u32);
		const actionType: ActionType = try reader.readEnum(ActionType);

		if (actionType == .load) {
			const componentVersion = try reader.readVarInt(u32);
			try main.entity.loadComponent(.client, componentId, entityId, reader.remaining, componentVersion);
		} else if (actionType == .unload) {
			try main.entity.unloadComponent(.client, componentId, entityId);
		}
	}
	pub fn unload(conn: *Connection, entityId: main.entity.Entity, componentId: u32) void {
		var writer = utils.BinaryWriter.init(main.stackAllocator);
		defer writer.deinit();

		writer.writeVarInt(u32, @intFromEnum(entityId));
		writer.writeVarInt(u32, componentId);
		writer.writeEnum(ActionType, ActionType.unload);

		conn.send(.secure, id, writer.data.items);
	}
	pub fn load(conn: *Connection, entityId: main.entity.Entity, componentId: u32, version: u32, componentData: []const u8) void {
		var writer = utils.BinaryWriter.init(main.stackAllocator);
		defer writer.deinit();

		writer.writeVarInt(u32, @intFromEnum(entityId));
		writer.writeVarInt(u32, componentId);
		writer.writeEnum(ActionType, ActionType.load);
		// specific to `load`
		writer.writeVarInt(u32, version);
		writer.writeSlice(componentData);

		conn.send(.secure, id, writer.data.items);
	}
};
