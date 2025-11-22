#include <metal_stdlib>
using namespace metal;

// Kernel to average two textures (running average)
// new_frame: The incoming frame (aligned)
// accumulator: The current average
// weight: The weight of the new frame (e.g., 1.0 / (frame_count + 1))
kernel void average_stack_kernel(texture2d<float, access::read> new_frame [[texture(0)]],
                                 texture2d<float, access::read_write> accumulator [[texture(1)]],
                                 constant float &weight [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= accumulator.get_width() || gid.y >= accumulator.get_height()) {
        return;
    }
    
    float4 newColor = new_frame.read(gid);
    float4 oldColor = accumulator.read(gid);
    
    // Running average: old * (1 - w) + new * w
    float4 avgColor = mix(oldColor, newColor, weight);
    
    accumulator.write(avgColor, gid);
}

// Kernel for Light Trails (Max Blend)
// new_frame: The incoming frame
// accumulator: The accumulated max values
kernel void max_blend_kernel(texture2d<float, access::read> new_frame [[texture(0)]],
                             texture2d<float, access::read_write> accumulator [[texture(1)]],
                             uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= accumulator.get_width() || gid.y >= accumulator.get_height()) {
        return;
    }
    
    float4 newColor = new_frame.read(gid);
    float4 oldColor = accumulator.read(gid);
    
    float4 maxColor = max(newColor, oldColor);
    
    accumulator.write(maxColor, gid);
}
