//! Guest window smoke: the userland counterpart of tools/darwin_window_smoke.zig.
//!
//! The host tool drives AppKit (NSApplication/NSWindow/NSImageView), which on
//! macOS bottoms out in SkyLight's CGS* RPCs to WindowServer.  Here we call
//! that same CGS layer directly — our own reimplementation in
//! src/skylight/{skylight,compositor}.zig — which composites onto the
//! IOFramebuffer aperture the kernel publishes (see src/userland/fb_smoke.zig
//! for the raw-framebuffer version of the same present path).
//!
//! Two windows are created so the run also exercises z-order, alpha blending
//! and hit testing, then the triangle from the host smoke is rasterized via
//! Prism (EGL / VK ICD) into the front window's backing store.

const std = @import("std");
const prism = @import("prism");

const CGError = i32;
const CGSConnectionID = u32;
const CGSWindowID = u32;
const CGSRegionRef = ?*anyopaque;

const CGPoint = extern struct { x: f64 = 0, y: f64 = 0 };
const CGSize = extern struct { width: f64 = 0, height: f64 = 0 };
const CGRect = extern struct { origin: CGPoint = .{}, size: CGSize = .{} };

const kCGSBackingBuffered: i32 = 2;
const kCGSWindowLevelFloating: i32 = 3;

extern fn write(fd: c_int, buf: [*]const u8, len: usize) isize;
extern fn usleep(usec: c_uint) c_int;

extern fn CGSNewConnection(callback: ?*const anyopaque, connection: *CGSConnectionID) CGError;
extern fn CGSReleaseConnection(connection: CGSConnectionID) CGError;
extern fn CGSNewRegionWithRect(rect: *const CGRect, region: *CGSRegionRef) CGError;
extern fn CGSReleaseRegion(region: CGSRegionRef) CGError;
extern fn CGSNewWindow(connection: CGSConnectionID, window_type: i32, x: f32, y: f32, region: CGSRegionRef, window: *CGSWindowID) CGError;
extern fn CGSReleaseWindow(connection: CGSConnectionID, window: CGSWindowID) CGError;
extern fn CGSSetWindowTitle(connection: CGSConnectionID, window: CGSWindowID, title: [*:0]const u8) CGError;
extern fn CGSSetWindowLevel(connection: CGSConnectionID, window: CGSWindowID, level: i32) CGError;
extern fn CGSSetWindowAlpha(connection: CGSConnectionID, window: CGSWindowID, alpha: f32) CGError;
extern fn CGSOrderWindow(connection: CGSConnectionID, window: CGSWindowID, mode: i32, relative_to: CGSWindowID) CGError;
extern fn CGSLockWindowBits(connection: CGSConnectionID, window: CGSWindowID, bounds_out: ?*CGRect, token_out: ?*i32, base_out: *[2]?[*]u8, rowBytes_out: *[2]i32) CGError;
extern fn CGSUnlockWindowBits(connection: CGSConnectionID, window: CGSWindowID, damage_region: CGSRegionRef) CGError;
extern fn CGSFlushWindow(connection: CGSConnectionID, window: CGSWindowID, region: CGSRegionRef) CGError;
extern fn CGSFlushConnection(connection: CGSConnectionID) CGError;
extern fn CGSGetDisplayBounds(display: u32, rect: *CGRect) CGError;
extern fn CGSGetCurrentCursorLocation(cid: CGSConnectionID, out: *CGPoint) CGError;
extern fn CGSHideCursor(cid: CGSConnectionID) CGError;
extern fn CGSShowCursor(cid: CGSConnectionID) CGError;
extern fn CGSWarpCursorPosition(cid: CGSConnectionID, x: f64, y: f64) CGError;
extern fn CGSFindWindowByGeometry(
    cid: CGSConnectionID,
    zero1: i32,
    zero2: i32,
    zero3: i32,
    screen_point: *const CGPoint,
    local_point_out: ?*CGPoint,
    window_out: *CGSWindowID,
    connection_out: ?*CGSConnectionID,
) CGError;

fn log(msg: []const u8) void {
    _ = write(1, msg.ptr, msg.len);
}

fn printInt(v: i64) void {
    if (v == 0) {
        log("0");
        return;
    }
    var buf: [20]u8 = undefined;
    var i: usize = buf.len;
    var n: u64 = if (v < 0) @intCast(-v) else @intCast(v);
    while (n > 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
    }
    if (v < 0) {
        i -= 1;
        buf[i] = '-';
    }
    log(buf[i..]);
}

const Backing = struct {
    base: [*]u8,
    stride: u32,
    width: u32,
    height: u32,

    fn put(self: Backing, x: u32, y: u32, b: u8, g: u8, r: u8) void {
        const p = self.base + y * self.stride + x * 4;
        p[0] = b;
        p[1] = g;
        p[2] = r;
        p[3] = 0xff;
    }
};

fn fill(dst: Backing, b: u8, g: u8, r: u8) void {
    var y: u32 = 0;
    while (y < dst.height) : (y += 1) {
        var x: u32 = 0;
        while (x < dst.width) : (x += 1) dst.put(x, y, b, g, r);
    }
}

fn flipRows(pixels: []u8, width: usize, height: usize, stride: usize) void {
    _ = width;
    var scratch: [4096 * 4]u8 = undefined;
    const row_bytes = @min(stride, scratch.len);
    for (0..height / 2) |top| {
        const bottom = height - 1 - top;
        const a = pixels[top * stride ..][0..row_bytes];
        const b = pixels[bottom * stride ..][0..row_bytes];
        @memcpy(scratch[0..row_bytes], a);
        @memcpy(a, b);
        @memcpy(b, scratch[0..row_bytes]);
    }
}

const Vtx = extern struct { x: f32, y: f32, r: f32, g: f32, b: f32 };

/// Same triangle as tools/darwin_window_smoke.zig, in NDC.
const tri = [3]Vtx{
    .{ .x = -0.8, .y = -0.75, .r = 1, .g = 0, .b = 0 },
    .{ .x = 0.8, .y = -0.75, .r = 0, .g = 1, .b = 0 },
    .{ .x = 0.0, .y = 0.8, .r = 0, .g = 0, .b = 1 },
};

const vs_src =
    \\attribute vec2 aPos;
    \\attribute vec3 aColor;
    \\varying vec3 vColor;
    \\void main() { gl_Position = vec4(aPos, 0.0, 1.0); vColor = aColor; }
;
const fs_src =
    \\precision mediump float;
    \\varying vec3 vColor;
    \\void main() { gl_FragColor = vec4(vColor, 1.0); }
;

const PixelSurface = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    stride: u32,

    fn currentBuffer(ptr: *anyopaque) prism.hal.Error!prism.platform.Buffer {
        const self: *PixelSurface = @ptrCast(@alignCast(ptr));
        return .{
            .bytes = self.pixels,
            .width = self.width,
            .height = self.height,
            .stride = self.stride,
            .format = .bgra8_unorm,
        };
    }

    fn commit(ptr: *anyopaque) prism.hal.Error!void {
        _ = ptr;
    }

    fn processEvents(ptr: *anyopaque) prism.hal.Error!prism.platform.WindowEvent {
        _ = ptr;
        return .none;
    }

    fn size(ptr: *anyopaque) [2]u32 {
        const self: *PixelSurface = @ptrCast(@alignCast(ptr));
        return .{ self.width, self.height };
    }

    fn deinit(ptr: *anyopaque) void {
        _ = ptr;
    }

    const vtable = prism.platform.Surface.VTable{
        .currentBuffer = &currentBuffer,
        .commit = &commit,
        .processEvents = &processEvents,
        .size = &size,
        .deinit = &deinit,
    };
};

fn attrFormat(n: u8) prism.hal.Format {
    return switch (n) {
        2 => .r32g32_float,
        3 => .r32g32b32_float,
        else => .r32g32b32a32_float,
    };
}

fn attrOffset(name: []const u8) u32 {
    return if (std.mem.eql(u8, name, "aPos")) 0 else 8;
}

fn renderPrismTriangle(gpa: std.mem.Allocator, pixels: []u8, width: u32, height: u32, stride: u32) !void {
    log("[prism] compiling vs\n");
    var cvs = try prism.glsl.compileForStageWithLayout(gpa, vs_src, .vertex);
    defer cvs.deinit(gpa);
    log("[prism] compiling fs\n");
    const fs_spirv = try prism.glsl.compileForStage(gpa, fs_src, .fragment);
    defer gpa.free(fs_spirv);

    log("[prism] creating device\n");
    const device = try prism.drivers.software.driver.createDevice(gpa);
    defer device.deinit();

    log("[prism] creating vbuf\n");
    const vbuf = try device.createResource(.{ .buffer = .{ .size = @sizeOf(@TypeOf(tri)), .usage = .{ .vertex = true } } });
    defer device.destroyResource(vbuf);
    @memcpy(try device.mapResource(vbuf), std.mem.asBytes(&tri));

    log("[prism] creating shaders\n");
    const vs = try device.createShaderModule(.{ .stage = .vertex, .code = cvs.spirv });
    defer device.destroyShaderModule(vs);
    const fs = try device.createShaderModule(.{ .stage = .fragment, .code = fs_spirv });
    defer device.destroyShaderModule(fs);

    var attrs: [4]prism.hal.VertexAttribute = undefined;
    for (cvs.attributes, 0..) |a, i| {
        attrs[i] = .{ .location = a.location, .format = attrFormat(a.components), .offset = attrOffset(a.name) };
    }

    log("[prism] creating pipeline\n");
    const pipeline = try device.createPipeline(.{
        .vertex = vs,
        .fragment = fs,
        .vertex_layout = .{ .stride = @sizeOf(Vtx), .attributes = attrs[0..cvs.attributes.len] },
        .color_format = .bgra8_unorm,
    });
    defer device.destroyPipeline(pipeline);

    log("[prism] creating ctx\n");
    const ctx = try device.createContext();
    defer ctx.deinit();

    log("[prism] creating target\n");
    const target = try device.createResource(.{ .image = .{
        .width = width,
        .height = height,
        .format = .bgra8_unorm,
        .usage = .{ .render_target = true },
    } });
    defer device.destroyResource(target);

    log("[prism] rendering\n");
    const cb = try ctx.beginCommands();
    defer cb.deinit();
    try cb.setRenderTarget(target);
    try cb.clear(.{ .r = 0.04, .g = 0.04, .b = 0.06, .a = 1 });
    try cb.bindPipeline(pipeline);
    try cb.bindVertexBuffer(vbuf);
    try cb.draw(3, 0);
    try ctx.submit(cb);

    log("[prism] presenting\n");
    var pixel_surface = PixelSurface{
        .pixels = pixels,
        .width = width,
        .height = height,
        .stride = stride,
    };
    var plat_surface = prism.platform.Surface{ .ptr = &pixel_surface, .vtable = &PixelSurface.vtable };
    const hal_surface = try device.createSurface(@ptrCast(&plat_surface));
    defer device.destroySurface(hal_surface);
    try ctx.present(hal_surface, target);
    log("[prism] done\n");
}

/// Render the triangle using Prism Vulkan ICD.
fn renderPrismVkTriangle(gpa: std.mem.Allocator, pixels: []u8, width: u32, height: u32, stride: u32) !void {
    var pixel_surface = PixelSurface{
        .pixels = pixels,
        .width = width,
        .height = height,
        .stride = stride,
    };
    var plat_surface = prism.platform.Surface{ .ptr = &pixel_surface, .vtable = &PixelSurface.vtable };

    const icd = prism.vk.icd;
    const vk = prism.vk.vk;

    var inst: vk.VkInstance = null;
    const app_info = std.mem.zeroInit(vk.VkApplicationInfo, .{
        .sType = .VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "window-smoke",
        .applicationVersion = 1,
        .pEngineName = "prism",
        .engineVersion = 1,
        .apiVersion = vk.VK_API_VERSION_1_0,
    });
    const inst_ci = std.mem.zeroInit(vk.VkInstanceCreateInfo, .{
        .sType = .VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app_info,
    });
    if (icd.createInstance(&inst_ci, null, &inst) != .VK_SUCCESS) return error.VkInstanceFailed;
    defer icd.destroyInstance(inst, null);

    var phys_count: u32 = 0;
    if (icd.enumeratePhysicalDevices(inst, &phys_count, null) != .VK_SUCCESS or phys_count == 0) return error.VkPhysDevFailed;
    var phys_devs: [4]vk.VkPhysicalDevice = undefined;
    phys_count = @min(phys_count, phys_devs.len);
    if (icd.enumeratePhysicalDevices(inst, &phys_count, &phys_devs) != .VK_SUCCESS) return error.VkPhysDevFailed;
    const phys_dev = phys_devs[0];

    const queue_priority = [_]f32{1.0};
    const queue_ci = std.mem.zeroInit(vk.VkDeviceQueueCreateInfo, .{
        .sType = .VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = 0,
        .queueCount = 1,
        .pQueuePriorities = &queue_priority,
    });
    const queue_cis = [_]vk.VkDeviceQueueCreateInfo{queue_ci};
    const dev_ci = std.mem.zeroInit(vk.VkDeviceCreateInfo, .{
        .sType = .VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue_cis,
    });
    var device: vk.VkDevice = null;
    if (icd.createDevice(phys_dev, &dev_ci, null, &device) != .VK_SUCCESS) return error.VkDeviceFailed;
    defer icd.destroyDevice(device, null);

    var queue: vk.VkQueue = null;
    icd.getDeviceQueue(device, 0, 0, &queue);

    const wsci = std.mem.zeroInit(vk.VkWaylandSurfaceCreateInfoKHR, .{
        .sType = .VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR,
        .surface = @as(?*anyopaque, @ptrCast(&plat_surface)),
    });
    var surface: vk.VkSurfaceKHR = 0;
    if (icd.createWaylandSurfaceKHR(inst, &wsci, null, &surface) != .VK_SUCCESS) return error.VkSurfaceFailed;
    defer icd.destroySurfaceKHR(inst, surface, null);

    const swapchain_ci = std.mem.zeroInit(vk.VkSwapchainCreateInfoKHR, .{
        .sType = .VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = surface,
        .minImageCount = 1,
        .imageFormat = vk.VK_FORMAT_R8G8B8A8_UNORM,
        .imageColorSpace = vk.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR,
        .imageExtent = .{ .width = width, .height = height },
        .imageArrayLayers = 1,
        .imageUsage = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .imageSharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        .preTransform = vk.VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR,
        .compositeAlpha = vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode = vk.VK_PRESENT_MODE_FIFO_KHR,
    });
    var swapchain: vk.VkSwapchainKHR = 0;
    if (icd.createSwapchainKHR(device, &swapchain_ci, null, &swapchain) != .VK_SUCCESS) return error.VkSwapchainFailed;
    defer icd.destroySwapchainKHR(device, swapchain, null);

    var cvs = try prism.glsl.compileForStageWithLayout(gpa, vs_src, .vertex);
    defer cvs.deinit(gpa);
    const fs_spirv = try prism.glsl.compileForStage(gpa, fs_src, .fragment);
    defer gpa.free(fs_spirv);

    const vs_ci = std.mem.zeroInit(vk.VkShaderModuleCreateInfo, .{
        .sType = .VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = cvs.spirv.len,
        .pCode = @as(?[*]const u32, @ptrCast(@alignCast(cvs.spirv.ptr))),
    });
    var vs_mod: vk.VkShaderModule = 0;
    if (icd.createShaderModule(device, &vs_ci, null, &vs_mod) != .VK_SUCCESS) return error.VkShaderModuleFailed;
    defer icd.destroyShaderModule(device, vs_mod, null);

    const fs_ci = std.mem.zeroInit(vk.VkShaderModuleCreateInfo, .{
        .sType = .VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = fs_spirv.len,
        .pCode = @as(?[*]const u32, @ptrCast(@alignCast(fs_spirv.ptr))),
    });
    var fs_mod: vk.VkShaderModule = 0;
    if (icd.createShaderModule(device, &fs_ci, null, &fs_mod) != .VK_SUCCESS) return error.VkShaderModuleFailed;
    defer icd.destroyShaderModule(device, fs_mod, null);

    const stages = [_]vk.VkPipelineShaderStageCreateInfo{
        std.mem.zeroInit(vk.VkPipelineShaderStageCreateInfo, .{ .sType = .VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = vk.VK_SHADER_STAGE_VERTEX_BIT, .module = vs_mod, .pName = "main" }),
        std.mem.zeroInit(vk.VkPipelineShaderStageCreateInfo, .{ .sType = .VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = vk.VK_SHADER_STAGE_FRAGMENT_BIT, .module = fs_mod, .pName = "main" }),
    };

    const binding_desc = vk.VkVertexInputBindingDescription{
        .binding = 0,
        .stride = @sizeOf(Vtx),
        .inputRate = 0,
    };
    const binding_descs = [_]vk.VkVertexInputBindingDescription{binding_desc};
    const attrib_descs = [_]vk.VkVertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = vk.VK_FORMAT_R32G32_SFLOAT, .offset = 0 },
        .{ .location = 1, .binding = 0, .format = vk.VK_FORMAT_R32G32B32_SFLOAT, .offset = 8 },
    };
    const vi_ci = std.mem.zeroInit(vk.VkPipelineVertexInputStateCreateInfo, .{
        .sType = .VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .vertexBindingDescriptionCount = 1,
        .pVertexBindingDescriptions = &binding_descs,
        .vertexAttributeDescriptionCount = 2,
        .pVertexAttributeDescriptions = &attrib_descs,
    });
    const ia_ci = std.mem.zeroInit(vk.VkPipelineInputAssemblyStateCreateInfo, .{
        .sType = .VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
    });
    const vp = vk.VkViewport{ .x = 0, .y = 0, .width = @floatFromInt(width), .height = @floatFromInt(height), .minDepth = 0, .maxDepth = 1 };
    const vps = [_]vk.VkViewport{vp};
    const sc = vk.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = width, .height = height } };
    const scissors = [_]vk.VkRect2D{sc};
    const vp_ci = std.mem.zeroInit(vk.VkPipelineViewportStateCreateInfo, .{
        .sType = .VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1,
        .pViewports = &vps,
        .scissorCount = 1,
        .pScissors = &scissors,
    });
    const rs_ci = std.mem.zeroInit(vk.VkPipelineRasterizationStateCreateInfo, .{
        .sType = .VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .cullMode = 0,
        .frontFace = 0,
    });
    const ms_ci = std.mem.zeroInit(vk.VkPipelineMultisampleStateCreateInfo, .{
        .sType = .VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .rasterizationSamples = 1,
    });
    const cb_att = std.mem.zeroInit(vk.VkPipelineColorBlendAttachmentState, .{
        .colorWriteMask = 0xf,
    });
    const cb_atts = [_]vk.VkPipelineColorBlendAttachmentState{cb_att};
    const cb_ci = std.mem.zeroInit(vk.VkPipelineColorBlendStateCreateInfo, .{
        .sType = .VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .attachmentCount = 1,
        .pAttachments = &cb_atts,
    });

    const pipe_layout_ci = std.mem.zeroInit(vk.VkPipelineLayoutCreateInfo, .{
        .sType = .VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
    });
    var pipe_layout: vk.VkPipelineLayout = 0;
    if (icd.createPipelineLayout(device, &pipe_layout_ci, null, &pipe_layout) != .VK_SUCCESS) return error.VkPipelineLayoutFailed;
    defer icd.destroyPipelineLayout(device, pipe_layout, null);

    const pipe_ci = std.mem.zeroInit(vk.VkGraphicsPipelineCreateInfo, .{
        .sType = .VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .stageCount = 2,
        .pStages = &stages,
        .pVertexInputState = &vi_ci,
        .pInputAssemblyState = &ia_ci,
        .pViewportState = &vp_ci,
        .pRasterizationState = &rs_ci,
        .pMultisampleState = &ms_ci,
        .pColorBlendState = &cb_ci,
        .layout = pipe_layout,
    });
    const pipe_cis = [_]vk.VkGraphicsPipelineCreateInfo{pipe_ci};
    var pipeline: vk.VkPipeline = 0;
    var pipelines = [_]vk.VkPipeline{pipeline};
    if (icd.createGraphicsPipelines(device, 0, 1, &pipe_cis, null, &pipelines) != .VK_SUCCESS) return error.VkPipelineFailed;
    pipeline = pipelines[0];
    defer icd.destroyPipeline(device, pipeline, null);

    const buf_ci = std.mem.zeroInit(vk.VkBufferCreateInfo, .{
        .sType = .VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = @sizeOf(@TypeOf(tri)),
        .usage = vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
    });
    var vbuf: vk.VkBuffer = 0;
    if (icd.createBuffer(device, &buf_ci, null, &vbuf) != .VK_SUCCESS) return error.VkBufferFailed;
    defer icd.destroyBuffer(device, vbuf, null);

    var mem_reqs: vk.VkMemoryRequirements = undefined;
    icd.getBufferMemoryRequirements(device, vbuf, &mem_reqs);
    const alloc_info = std.mem.zeroInit(vk.VkMemoryAllocateInfo, .{
        .sType = .VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = mem_reqs.size,
        .memoryTypeIndex = 0,
    });
    var vbuf_mem: vk.VkDeviceMemory = 0;
    if (icd.allocateMemory(device, &alloc_info, null, &vbuf_mem) != .VK_SUCCESS) return error.VkAllocMemFailed;
    defer icd.freeMemory(device, vbuf_mem, null);

    if (icd.bindBufferMemory(device, vbuf, vbuf_mem, 0) != .VK_SUCCESS) return error.VkBindBufferFailed;
    var mapped_ptr: ?*anyopaque = null;
    if (icd.mapMemory(device, vbuf_mem, 0, @sizeOf(@TypeOf(tri)), 0, &mapped_ptr) != .VK_SUCCESS) return error.VkMapMemFailed;
    @memcpy(@as([*]u8, @ptrCast(mapped_ptr.?))[0..@sizeOf(@TypeOf(tri))], std.mem.asBytes(&tri));
    icd.unmapMemory(device, vbuf_mem);

    const cp_ci = std.mem.zeroInit(vk.VkCommandPoolCreateInfo, .{
        .sType = .VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .queueFamilyIndex = 0,
    });
    var cmd_pool: vk.VkCommandPool = 0;
    if (icd.createCommandPool(device, &cp_ci, null, &cmd_pool) != .VK_SUCCESS) return error.VkCmdPoolFailed;
    defer icd.destroyCommandPool(device, cmd_pool, null);

    const cb_alloc_info = std.mem.zeroInit(vk.VkCommandBufferAllocateInfo, .{
        .sType = .VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = cmd_pool,
        .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    });
    var cmd_buf: vk.VkCommandBuffer = null;
    var cmd_bufs = [_]vk.VkCommandBuffer{cmd_buf};
    if (icd.allocateCommandBuffers(device, &cb_alloc_info, &cmd_bufs) != .VK_SUCCESS) return error.VkAllocCmdBufFailed;
    cmd_buf = cmd_bufs[0];

    const begin_info = std.mem.zeroInit(vk.VkCommandBufferBeginInfo, .{
        .sType = .VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
    });
    if (icd.beginCommandBuffer(cmd_buf, &begin_info) != .VK_SUCCESS) return error.VkBeginCmdBufFailed;

    icd.cmdBindPipeline(cmd_buf, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
    const bufs = [_]vk.VkBuffer{vbuf};
    const offsets = [_]vk.VkDeviceSize{0};
    icd.cmdBindVertexBuffers(cmd_buf, 0, 1, &bufs, &offsets);
    icd.cmdDraw(cmd_buf, 3, 1, 0, 0);
    if (icd.endCommandBuffer(cmd_buf) != .VK_SUCCESS) return error.VkEndCmdBufFailed;

    var img_idx: u32 = 0;
    if (icd.acquireNextImageKHR(device, swapchain, ~@as(u64, 0), 0, 0, &img_idx) != .VK_SUCCESS) return error.VkAcquireFailed;

    const cmd_buf_ptrs = [_]vk.VkCommandBuffer{cmd_buf};
    const submit_info = std.mem.zeroInit(vk.VkSubmitInfo, .{
        .sType = .VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &cmd_buf_ptrs,
    });
    const submit_infos = [_]vk.VkSubmitInfo{submit_info};
    if (icd.queueSubmit(queue, 1, &submit_infos, 0) != .VK_SUCCESS) return error.VkQueueSubmitFailed;

    const swapchains = [_]vk.VkSwapchainKHR{swapchain};
    const img_indices = [_]u32{img_idx};
    const present_info = std.mem.zeroInit(vk.VkPresentInfoKHR, .{
        .sType = .VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .swapchainCount = 1,
        .pSwapchains = &swapchains,
        .pImageIndices = &img_indices,
    });
    if (icd.queuePresentKHR(queue, &present_info) != .VK_SUCCESS) return error.VkPresentFailed;
}

fn backingOf(cid: CGSConnectionID, wid: CGSWindowID, width: u32, height: u32) ?Backing {
    var bounds: CGRect = .{};
    var base: [2]?[*]u8 = .{ null, null };
    var row_bytes: [2]i32 = .{ 0, 0 };
    if (CGSLockWindowBits(cid, wid, &bounds, null, &base, &row_bytes) != 0) return null;
    if (row_bytes[0] <= 0) return null;
    return .{ .base = base[0] orelse return null, .stride = @intCast(row_bytes[0]), .width = width, .height = height };
}

fn makeWindow(cid: CGSConnectionID, x: f32, y: f32, width: u32, height: u32, title: ?[*:0]const u8) ?CGSWindowID {
    var region: CGSRegionRef = null;
    const rect = CGRect{ .size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) } };
    if (CGSNewRegionWithRect(&rect, &region) != 0) return null;
    defer _ = CGSReleaseRegion(region);

    var wid: CGSWindowID = 0;
    if (CGSNewWindow(cid, kCGSBackingBuffered, x, y, region, &wid) != 0) return null;
    if (title) |t| _ = CGSSetWindowTitle(cid, wid, t);
    _ = CGSOrderWindow(cid, wid, 1, 0);
    return wid;
}

pub fn main() u8 {
    var cid: CGSConnectionID = 0;
    if (CGSNewConnection(null, &cid) != 0 or cid == 0) {
        log("CGSNewConnection failed\n");
        return 10;
    }
    defer _ = CGSReleaseConnection(cid);

    var screen: CGRect = .{};
    if (CGSGetDisplayBounds(1, &screen) != 0 or screen.size.width == 0) {
        log("CGSGetDisplayBounds failed (no IOFramebuffer?)\n");
        return 11;
    }

    // Background window: a flat panel, half transparent, normal level.
    const bg_w: u32 = 240;
    const bg_h: u32 = 160;
    const bg = makeWindow(cid, 60, 90, bg_w, bg_h, "background") orelse {
        log("CGSNewWindow(background) failed\n");
        return 20;
    };
    _ = CGSSetWindowAlpha(cid, bg, 0.6);
    if (backingOf(cid, bg, bg_w, bg_h)) |b| {
        fill(b, 0xc0, 0x60, 0x20);
        _ = CGSUnlockWindowBits(cid, bg, null);
    } else {
        log("CGSLockWindowBits(background) failed\n");
        return 21;
    }

    // Foreground window: floating level, carries the triangle.
    const fg_w: u32 = 320;
    const fg_h: u32 = 200;
    const fg = makeWindow(cid, 160, 150, fg_w, fg_h, "Prism triangle") orelse {
        log("CGSNewWindow(triangle) failed\n");
        return 22;
    };
    _ = CGSSetWindowLevel(cid, fg, kCGSWindowLevelFloating);
    const fb = backingOf(cid, fg, fg_w, fg_h) orelse {
        log("CGSLockWindowBits(triangle) failed\n");
        return 23;
    };
    log("[window_smoke] testing page_allocator...\n");
    const test_alloc = std.heap.page_allocator.alloc(u8, 1024) catch |err| {
        log("[window_smoke] page_allocator test alloc failed: ");
        log(@errorName(err));
        log("\n");
        return 23;
    };
    log("[window_smoke] page_allocator test alloc succeeded\n");
    std.heap.page_allocator.free(test_alloc);
    log("[window_smoke] page_allocator test free succeeded\n");

    const pixels = fb.base[0 .. @as(usize, fb.stride) * fb.height];
    renderPrismTriangle(std.heap.page_allocator, pixels, fg_w, fg_h, fb.stride) catch |err| {
        log("Prism HAL render failed: ");
        log(@errorName(err));
        log(" (");
        printInt(@intFromError(err));
        log(")\n");
        return 24;
    };
    flipRows(pixels, fg_w, fg_h, fb.stride);
    _ = CGSUnlockWindowBits(cid, fg, null);

    // Verify cursor APIs
    var cur_loc: CGPoint = .{};
    if (CGSGetCurrentCursorLocation(cid, &cur_loc) != 0) {
        log("CGSGetCurrentCursorLocation failed\n");
        return 28;
    }
    _ = CGSHideCursor(cid);
    _ = CGSShowCursor(cid);
    _ = CGSWarpCursorPosition(cid, 200.0, 200.0);

    // The floating window must win the hit test where the two overlap.
    var hit: CGSWindowID = 0;
    const pt = CGPoint{ .x = 200, .y = 200 };
    var local_pt: CGPoint = .{};
    var hit_cid: CGSConnectionID = 0;
    if (CGSFindWindowByGeometry(cid, 0, 0, 0, &pt, &local_pt, &hit, &hit_cid) != 0 or hit != fg) {
        log("CGSFindWindowByGeometry picked the wrong window\n");
        return 30;
    }

    if (CGSFlushWindow(cid, fg, null) != 0) {
        log("CGSFlushWindow failed\n");
        return 31;
    }

    log("SkyLight window composite passed — entering interactive cursor loop\n");
    var last_x: f64 = -1;
    var last_y: f64 = -1;
    var loop_count: usize = 0;
    while (true) {
        _ = CGSFlushConnection(cid);
        var cur: CGPoint = .{};
        if (CGSGetCurrentCursorLocation(cid, &cur) == 0) {
            if (cur.x != last_x or cur.y != last_y) {
                last_x = cur.x;
                last_y = cur.y;
            }
        }
        loop_count += 1;
        _ = usleep(2000);
    }
    return 0;
}
