//! Host-Metal integration tests for metallibs produced by metalc.

#![cfg(test)]

#[cfg(target_os = "macos")]
mod macos_tests {
    use air_bitcode::{add_one_module, emit_metallib};
    use std::io::Write;
    use std::process::Command;

    #[test]
    fn add_one_runs_on_host_metal() {
        let dir = std::env::temp_dir().join("metalc-host-test");
        std::fs::create_dir_all(&dir).unwrap();
        let metallib = emit_metallib(&add_one_module(), &dir).expect("emit metallib");
        let lib_path = dir.join("add_one.metallib");
        std::fs::write(&lib_path, &metallib).unwrap();

        let swift = dir.join("run.swift");
        let mut f = std::fs::File::create(&swift).unwrap();
        write!(
            f,
            r#"
import Metal
import Foundation
import Dispatch

let path = CommandLine.arguments[1]
let nsData = NSData(contentsOfFile: path)!
let dd = DispatchData(bytes: UnsafeRawBufferPointer(start: nsData.bytes, count: nsData.length))
guard let device = MTLCreateSystemDefaultDevice() else {{ fatalError("no device") }}
let lib = try device.makeLibrary(data: dd)
let fn = lib.makeFunction(name: "add_one")!
let pso = try device.makeComputePipelineState(function: fn)
let n = 64
let inBuf = device.makeBuffer(length: n*4, options: .storageModeShared)!
let outBuf = device.makeBuffer(length: n*4, options: .storageModeShared)!
let inPtr = inBuf.contents().bindMemory(to: Float.self, capacity: n)
for i in 0..<n {{ inPtr[i] = Float(i) }}
let q = device.makeCommandQueue()!
let cb = q.makeCommandBuffer()!
let enc = cb.makeComputeCommandEncoder()!
enc.setComputePipelineState(pso)
enc.setBuffer(inBuf, offset: 0, index: 0)
enc.setBuffer(outBuf, offset: 0, index: 1)
let tpg = min(n, pso.maxTotalThreadsPerThreadgroup)
enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1))
enc.endEncoding()
cb.commit()
cb.waitUntilCompleted()
let outPtr = outBuf.contents().bindMemory(to: Float.self, capacity: n)
for i in 0..<n {{
  if abs(outPtr[i] - (Float(i)+1)) > 1e-5 {{
    fputs("FAIL \(i) \(outPtr[i])\n", stderr)
    exit(1)
  }}
}}
print("PASS")
"#
        )
        .unwrap();

        let out = Command::new("swift")
            .arg(&swift)
            .arg(&lib_path)
            .output()
            .expect("swift");
        let stdout = String::from_utf8_lossy(&out.stdout);
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(
            out.status.success() && stdout.contains("PASS"),
            "status={} stdout={} stderr={}",
            out.status,
            stdout,
            stderr
        );
    }
}
