#include <metal_stdlib>
using namespace metal;

kernel void add_one(device const float* in [[buffer(0)]],
                    device float* out [[buffer(1)]],
                    uint tid [[thread_position_in_grid]]) {
  out[tid] = in[tid] + 1.0f;
}
