# expect: compiled
# mode: engine-build
# A pass that owns a wgpu Buffer and records into a FrameRenderPass (a linear type) inside a comptime for over the
# pack; each pass contributes WGSL through a trait constant, concatenated by the pipeline.
from wgpu import Instance, WGPUBufferUsage
from wgpu.buffer import Buffer
from wgpu.device import Device
from wgpu.render_pass import FrameRenderPass


trait RenderPass(Movable, Deinitable):
    comptime WGSL: StaticString

    def prepare(mut self, device: Device) raises: ...

    def record(self, mut rpass: FrameRenderPass): ...


struct Clear(RenderPass):
    comptime WGSL: StaticString = "fn clear_tint() -> vec3<f32> { return vec3<f32>(1.0); }"
    var buf: Buffer
    var frames: Int

    def __init__(out self, device: Device) raises:
        self.buf = device.create_buffer(UInt64(64), WGPUBufferUsage.UNIFORM | WGPUBufferUsage.COPY_DST, label="probe")
        self.frames = 0

    def prepare(mut self, device: Device) raises:
        self.frames += 1

    def record(self, mut rpass: FrameRenderPass):
        pass


struct Pipeline[*Ps: RenderPass](Movable):
    var passes: Tuple[*Self.Ps]

    def __init__(out self, var passes: Tuple[*Self.Ps]):
        self.passes = passes^

    @staticmethod
    def wgsl() -> String:
        var s = String()
        comptime for i in range(len(Self.Ps)):
            s += Self.Ps[i].WGSL
            s += "\n"
        return s^

    def prepare(mut self, device: Device) raises:
        comptime for i in range(len(Self.Ps)):
            self.passes[i].prepare(device)

    def record(self, mut rpass: FrameRenderPass):
        comptime for i in range(len(Self.Ps)):
            self.passes[i].record(rpass)


def main() raises:
    var device = Instance().request_adapter().request_device()
    var p = Pipeline[Clear, Clear]((Clear(device), Clear(device)))
    p.prepare(device)
    print("ok", Pipeline[Clear, Clear].wgsl().byte_length() > 0)
