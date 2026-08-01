//! Host-Metal integration tests for metallibs produced by metalc.
//!
//! On macOS, exercises the GPU via [`objc2_metal`] (no Swift subprocess).

#![cfg(test)]

#[cfg(target_os = "macos")]
mod macos_tests {
    use air_bitcode::{add_one_module, emit_metallib};
    use dialect_metal::build_scale_module;
    use dispatch2::DispatchData;
    use metal_lower::lower_module;
    use objc2_foundation::NSString;
    use objc2_metal::{
        MTLBuffer, MTLCommandBuffer, MTLCommandEncoder, MTLCommandQueue, MTLComputeCommandEncoder,
        MTLComputePipelineState, MTLCreateSystemDefaultDevice, MTLDevice, MTLLibrary,
        MTLResourceOptions, MTLSize,
    };
    use pliron::context::Context;

    // `MTLCreateSystemDefaultDevice` requires linking CoreGraphics.
    #[link(name = "CoreGraphics", kind = "framework")]
    unsafe extern "C" {}

    fn run_binary_kernel(metallib: &[u8], name: &str, expected: impl Fn(usize) -> f32) {
        let device = MTLCreateSystemDefaultDevice().expect("no Metal device");
        let data = DispatchData::from_bytes(metallib);
        let library = device
            .newLibraryWithData_error(&data)
            .unwrap_or_else(|e| panic!("newLibraryWithData: {e}"));
        let function = library
            .newFunctionWithName(&NSString::from_str(name))
            .unwrap_or_else(|| panic!("missing {name} function"));
        let pso = device
            .newComputePipelineStateWithFunction_error(&function)
            .unwrap_or_else(|e| panic!("compute PSO: {e}"));

        let n: usize = 64;
        let bytes = n * std::mem::size_of::<f32>();
        let in_buf = device
            .newBufferWithLength_options(bytes, MTLResourceOptions::StorageModeShared)
            .expect("in buffer");
        let out_buf = device
            .newBufferWithLength_options(bytes, MTLResourceOptions::StorageModeShared)
            .expect("out buffer");

        unsafe {
            let in_ptr = in_buf.contents().cast::<f32>();
            let slice = std::slice::from_raw_parts_mut(in_ptr.as_ptr(), n);
            for (i, v) in slice.iter_mut().enumerate() {
                *v = i as f32;
            }
        }

        let queue = device.newCommandQueue().expect("command queue");
        let cmd = queue.commandBuffer().expect("command buffer");
        let enc = cmd.computeCommandEncoder().expect("compute encoder");
        enc.setComputePipelineState(&pso);
        unsafe {
            enc.setBuffer_offset_atIndex(Some(&in_buf), 0, 0);
            enc.setBuffer_offset_atIndex(Some(&out_buf), 0, 1);
        }

        let tpg = n.min(pso.maxTotalThreadsPerThreadgroup());
        let grid = MTLSize {
            width: n,
            height: 1,
            depth: 1,
        };
        let group = MTLSize {
            width: tpg,
            height: 1,
            depth: 1,
        };
        enc.dispatchThreads_threadsPerThreadgroup(grid, group);
        enc.endEncoding();
        cmd.commit();
        cmd.waitUntilCompleted();

        unsafe {
            let out_ptr = out_buf.contents().cast::<f32>();
            let slice = std::slice::from_raw_parts(out_ptr.as_ptr(), n);
            for (i, &v) in slice.iter().enumerate() {
                let want = expected(i);
                assert!(
                    (v - want).abs() < 1e-5,
                    "mismatch at {i}: got {v}, expected {want}"
                );
            }
        }
    }

    #[test]
    fn add_one_runs_on_host_metal() {
        let dir = std::env::temp_dir().join("metalc-host-objc2");
        let metallib = emit_metallib(&add_one_module(), &dir).expect("emit metallib");
        run_binary_kernel(&metallib, "add_one", |i| i as f32 + 1.0);
    }

    #[test]
    fn scale_runs_on_host_metal() {
        let ctx = &mut Context::new();
        let module = build_scale_module(ctx).expect("build");
        let air = lower_module(ctx, module).expect("lower");
        let dir = std::env::temp_dir().join("metalc-host-scale");
        let metallib = emit_metallib(&air, &dir).expect("emit");
        run_binary_kernel(&metallib, "scale", |i| i as f32 * 2.0);
    }
}
