#include "common/bindings.hlsl"
#include "common/debug.hlsl"
#include "common/loading.hlsl"
#include "common/vbuffer.hlsl"
#include "common/geometry.hlsl"

static const float4x4 bias_matrix = float4x4(
    0.5, 0.0, 0.0, 0.5,
    0.0, 0.5, 0.0, 0.5,
    0.0, 0.0, 1.0, 0.0,
    0.0, 0.0, 0.0, 1.0
);

struct Material {
    float3 albedo;
    float metallic;
    float roughness;
};

[shader("compute")]
[numthreads(8, 8, 1)]
void render_geometry(
    uint3 global_id: SV_DispatchThreadID
) {
    uint64_t start_time = 0;

    if (uniforms.debug == UNIFORMS_DEBUG_SHADER_CLOCK) {
        start_time = vk::ReadClock(vk::SubgroupScope);
    }

    if (global_id.x >= uniforms.window_size.x || global_id.y >= uniforms.window_size.y) {
        return;
    }

    uint32_t packed = visibility_buffer[global_id.xy];
    uint32_t instance_index = packed & ((1 << 16) - 1);
    uint32_t triangle_index = packed >> 16;

    Instance instance = load_instance(instance_index);
    MeshInfo mesh_info = load_mesh_info(instance.mesh_info_address);

    uint3 indices = uint3(
        load_index(mesh_info, triangle_index * 3),
        load_index(mesh_info, triangle_index * 3 + 1),
        load_index(mesh_info, triangle_index * 3 + 2)
    );

    float2 ndc = float2(global_id.xy) / float2(uniforms.window_size) * 2.0 - 1.0;

    float3 pos_a = calculate_world_pos(instance, mesh_info, indices.x);
    float3 pos_b = calculate_world_pos(instance, mesh_info, indices.y);
    float3 pos_c = calculate_world_pos(instance, mesh_info, indices.z);

    BarycentricDeriv bary = CalcFullBary(
        mul(uniforms.combined_perspective_view, float4(pos_a, 1.0)),
        mul(uniforms.combined_perspective_view, float4(pos_b, 1.0)),
        mul(uniforms.combined_perspective_view, float4(pos_c, 1.0)),
        ndc,
        uniforms.window_size
    );

    // Reconstruct the world position from ndc (without reinterpolating)
    // See https://github.com/ConfettiFX/The-Forge/tree/master/Examples_3/Visibility_Buffer/Documentation.
    // 'Reconstruct the Z value at this screen point performing only the necessary matrix * vector multiplication
    // operations that involve computing Z'
    float z = bary.interpW * uniforms.combined_perspective_view[2][2] + uniforms.combined_perspective_view[2][3];
    float3 world_pos = mul(uniforms.inv_perspective_view, float4(ndc * bary.interpW, z, bary.interpW)).xyz;

    InterpolatedVector<float2> uv = interpolate(
        bary,
        float2(load_value<uint16_t2>(mesh_info.uvs, indices.x)) * mesh_info.texture_scale + mesh_info.texture_offset,
        float2(load_value<uint16_t2>(mesh_info.uvs, indices.y)) * mesh_info.texture_scale + mesh_info.texture_offset,
        float2(load_value<uint16_t2>(mesh_info.uvs, indices.z)) * mesh_info.texture_scale + mesh_info.texture_offset
    );

    float3 view_vector = world_pos - uniforms.camera_pos;

    // Load 3 x i8 with a padding byte.
    float3 normal = interpolate(
        bary,
        normalize(float3(unpack_s8s16(load_value<int8_t4_packed>(mesh_info.normals, indices.x)).xyz)),
        normalize(float3(unpack_s8s16(load_value<int8_t4_packed>(mesh_info.normals, indices.y)).xyz)),
        normalize(float3(unpack_s8s16(load_value<int8_t4_packed>(mesh_info.normals, indices.z)).xyz))
    ).value;
    normal = normalize(mul(instance.normal_transform, normal));

    if (mesh_info.flags & MESH_INFO_FLAGS_ALPHA_CLIP) {
        // Calculate whether the triangle is back facing using the (unnormalized) geometric normal.
        // I tried getting this with the code from
        // https://registry.khronos.org/vulkan/specs/1.3-khr-extensions/html/chap22.html#tessellation-vertex-winding-order
        // but I had problems with large triangles that go over the edges of the screen.
        float3 geometric_normal = cross(pos_b - pos_a, pos_c - pos_a);
        bool is_back_facing = dot(geometric_normal, view_vector) > 0;

        // For leaves etc, we shouldn't treat them as totally opaque by just flipping
        // the normals like this. But it's fine for now.

        if (is_back_facing) {
            normal = -normal;
        }
    }

    uint32_t cascade_index;
    float4 shadow_coord = float4(0,0,0,0);
    for (cascade_index = 0; cascade_index < 4; cascade_index++) {
        // Get the coordinate in shadow view space.
        shadow_coord = mul(misc_storage[0].shadow_matrices[cascade_index], float4(world_pos, 1.0));
        // If it's inside the cascade view space (which is NDC so -1 to 1) then stop as
        // this is the highest quality cascade for the fragment.
        if (abs(shadow_coord.x) < 1.0 && abs(shadow_coord.y) < 1.0) {
            break;
        }
    }

    // Use the tiniest shadow bias for alpha clipped meshes as they're double sided..
    float shadow_bias = (mesh_info.flags & MESH_INFO_FLAGS_ALPHA_CLIP) ? 0.000001 : 0.0;

    float4 shadow_view_coord = mul(bias_matrix, shadow_coord);
    shadow_view_coord /= shadow_view_coord.w;
    float shadow_sum = 0.0;
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            float2 offset = float2(x, y) / 1024.0;
            shadow_sum += shadowmap.SampleCmpLevelZero(
                shadowmap_comparison_sampler,
                float3(shadow_view_coord.xy + offset, cascade_index),
                shadow_view_coord.z - shadow_bias
            );
        }
    }
    shadow_sum /= 9.0;

    if (shadow_view_coord.z > 1) {
        shadow_sum = 1.0;
    }

    Material material;

    float n_dot_l = max(dot(uniforms.sun_dir, normal), 0.0);
    material.albedo = textures[NonUniformResourceIndex(mesh_info.albedo_texture_index)].SampleGrad(repeat_sampler, uv.value, uv.dx, uv.dy).rgb;
    float2 metallic_roughness = textures[NonUniformResourceIndex(mesh_info.metallic_roughness_texture_index)].SampleGrad(repeat_sampler, uv.value, uv.dx, uv.dy).yx;
    material.roughness = metallic_roughness.x;
    material.metallic = metallic_roughness.y;

    float ambient = 0.05;

    float3 lighting = max(n_dot_l * shadow_sum * uniforms.sun_intensity, ambient);

    float3 diffuse = material.albedo * lighting;

    rw_scene_referred_framebuffer[global_id.xy] = float4(diffuse, 1.0);

    if (uniforms.debug == UNIFORMS_DEBUG_CASCADES) {
        float3 debug_col = DEBUG_COLOURS[cascade_index];
        rw_scene_referred_framebuffer[global_id.xy] = float4(material.albedo * debug_col, 1.0);
    } else if (uniforms.debug == UNIFORMS_DEBUG_TRIANGLE_INDEX) {
        rw_scene_referred_framebuffer[global_id.xy] = float4(DEBUG_COLOURS[triangle_index % 10], 1.0);
    } else if (uniforms.debug == UNIFORMS_DEBUG_INSTANCE_INDEX) {
        rw_scene_referred_framebuffer[global_id.xy] = float4(DEBUG_COLOURS[instance_index % 10], 1.0);
    } else if (uniforms.debug == UNIFORMS_DEBUG_SHADER_CLOCK) {
        uint64_t end_time = vk::ReadClock(vk::SubgroupScope);

        float heatmapScale = 65000.0f;
        float deltaTimeScaled =  clamp(float(timediff(start_time, end_time)) / heatmapScale, 0.0f, 1.0f );

        rw_scene_referred_framebuffer[global_id.xy] = float4(temperature(deltaTimeScaled), 1.0);
    }
}
