#include <metal_stdlib>
using namespace metal;
kernel void probe(device uint *out [[buffer(0)]], uint i [[thread_position_in_grid]]) {
    out[i] = 42;
}
