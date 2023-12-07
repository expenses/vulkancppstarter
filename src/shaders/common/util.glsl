
uint32_t load_index(MeshInfo mesh_info, uint32_t vertex_id) {
    if (bool(mesh_info.flags & MESH_INFO_FLAGS_32_BIT_INDICES)) {
        return Index32Buffer(mesh_info.indices).indices[vertex_id];
    } else {
        return Index16Buffer(mesh_info.indices).indices[vertex_id];
    }
}

float3
calculate_world_pos(Instance instance, MeshInfo mesh_info, uint32_t index) {
    float3 position =
        QuantizedPositionBuffer(mesh_info.positions).positions[index];
    return (instance.transform * float4(position, 1.0)).xyz;
}

void reset_draw_calls() {
    DrawCallBuffer draw_call_buf = DrawCallBuffer(get_uniforms().draw_calls);
    draw_call_buf.num_opaque = uint32_t4(0);
    draw_call_buf.num_alpha_clip = uint32_t4(0);
}

uint32_t pack(uint32_t triangle_index, uint32_t instance_index) {
    return triangle_index << 24 | instance_index;
}

// Super easy.
float convert_infinite_reverze_z_depth(float depth) {
    return NEAR_PLANE / depth;
}

uint32_t total_num_meshlets() {
    return uint32_t(
        NumMeshletsPrefixSumResultBuffer(get_uniforms().num_meshlets_prefix_sum)
            .counter
    );
}

uint32_t total_unculled_instances() {
    return uint32_t(
        NumMeshletsPrefixSumResultBuffer(get_uniforms().num_meshlets_prefix_sum)
            .counter
        >> 32
    );
}

// See https://en.cppreference.com/w/cpp/algorithm/upper_bound.
NumMeshletsPrefixSumResult binary_search_upper_bound(uint32_t target) {
    NumMeshletsPrefixSumResultBuffer values =
        NumMeshletsPrefixSumResultBuffer(get_uniforms().num_meshlets_prefix_sum
        );
    uint32_t count = uint32_t(values.counter >> 32);
    uint32_t first = 0;

    while (count > 0) {
        uint32_t step = (count / 2);
        uint32_t current = first + step;
        bool greater = target >= values.values[current].meshlets_offset;
        first = select(greater, current + 1, first);
        count = select(greater, count - (step + 1), step);
    }

    return values.values[first];
}

uint32_t dispatch_size(uint32_t width, uint32_t workgroup_size) {
    return ((width - 1) / workgroup_size) + 1;
}

MeshletReference get_meshlet_reference(uint32_t global_meshlet_index) {
    NumMeshletsPrefixSumResult result =
        binary_search_upper_bound(global_meshlet_index);
    Instance instance = InstanceBuffer(get_uniforms().instances)
                            .instances[result.instance_index];
    MeshInfo mesh_info = MeshInfoBuffer(instance.mesh_info_address).mesh_info;

    uint32_t local_meshlet_index = global_meshlet_index
        - (result.meshlets_offset - mesh_info.num_meshlets);

    MeshletReference reference;
    reference.instance_index = result.instance_index;
    reference.meshlet_index = uint16_t(local_meshlet_index);
    return reference;
}
