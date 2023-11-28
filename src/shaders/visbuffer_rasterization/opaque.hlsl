#include "../common/geometry.hlsl"

struct Varyings {
    [[vk::location(0)]] float4 clip_pos : SV_Position;
    [[vk::location(1)]] uint32_t packed: ATTRIB0;
};

[shader("vertex")]
Varyings vertex(
    uint32_t global_vertex_index : SV_VertexID
) {
    uint32_t instance_index = global_vertex_index / MAX_MESHLET_VERTICES;
    uint32_t vertex_index = global_vertex_index % MAX_MESHLET_VERTICES;
    uint32_t triangle_index = vertex_index / 3;

    MeshletIndex meshlet_index = load_instance_meshlet(uniforms.instance_meshlets, instance_index);
    Instance instance = load_instance(meshlet_index.instance_index);
    MeshInfo mesh_info = load_mesh_info(instance.mesh_info_address);
    Meshlet meshlet = load_meshlet(mesh_info.meshlets, meshlet_index.meshlet_index);

    if (triangle_index >= meshlet.triangle_count) {
        Varyings varyings;
        varyings.clip_pos = 0;
        varyings.packed = 0;
        return varyings;
    }

    Varyings varyings;

    uint16_t micro_index = load_uint8_t(mesh_info.micro_indices + meshlet.triangle_offset + vertex_index);

    uint32_t index = load_index(mesh_info, meshlet.index_offset + micro_index);

    varyings.clip_pos =  calculate_view_pos_position(instance, mesh_info, index);
    varyings.packed = pack(triangle_index, instance_index);
    return varyings;
}

[shader("pixel")]
void pixel(
    Varyings input,
    [[vk::location(0)]] out uint32_t packed: SV_Target0
) {
    packed = input.packed;
}
