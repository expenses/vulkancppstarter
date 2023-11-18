#include "pipelines.h"

const auto RGBA_MASK = vk::ColorComponentFlagBits::eR
    | vk::ColorComponentFlagBits::eG | vk::ColorComponentFlagBits::eB
    | vk::ColorComponentFlagBits::eA;

const auto FILL_RASTERIZATION = vk::PipelineRasterizationStateCreateInfo {
    .polygonMode = vk::PolygonMode::eFill,
    .cullMode = vk::CullModeFlagBits::eNone,
    .lineWidth = 1.0f};

const auto NO_MULTISAMPLING = vk::PipelineMultisampleStateCreateInfo {
    .rasterizationSamples = vk::SampleCountFlagBits::e1,
    .sampleShadingEnable = false,
    .minSampleShading = 1.0f,
    .alphaToCoverageEnable = false,
    .alphaToOneEnable = false,
};

const std::array<vk::DynamicState, 2> DEFAULT_DYNAMIC_STATES = {
    vk::DynamicState::eViewport,
    vk::DynamicState::eScissor,
};

const auto DEFAULT_DYNAMIC_STATE_INFO = vk::PipelineDynamicStateCreateInfo {
    .dynamicStateCount = DEFAULT_DYNAMIC_STATES.size(),
    .pDynamicStates = DEFAULT_DYNAMIC_STATES.data()};

const auto DEFAULT_VIEWPORT_STATE = vk::PipelineViewportStateCreateInfo {
    .viewportCount = 1,
    .scissorCount = 1,
};

const auto TRIANGLE_LIST_INPUT_ASSEMBLY =
    vk::PipelineInputAssemblyStateCreateInfo {
        .topology = vk::PrimitiveTopology::eTriangleList};

const vk::PipelineVertexInputStateCreateInfo EMPTY_VERTEX_INPUT = {};

const auto SINGLE_REPLACE_BLEND_ATTACHMENT =
    std::array {vk::PipelineColorBlendAttachmentState {
        .blendEnable = false,
        .colorWriteMask = RGBA_MASK}};

const auto EMPTY_BLEND_STATE = vk::PipelineColorBlendStateCreateInfo {};

const auto SINGLE_REPLACE_BLEND_STATE = vk::PipelineColorBlendStateCreateInfo {
    .logicOpEnable = false,
    .attachmentCount = SINGLE_REPLACE_BLEND_ATTACHMENT.size(),
    .pAttachments = SINGLE_REPLACE_BLEND_ATTACHMENT.data()};

const auto DEPTH_WRITE_GREATER = vk::PipelineDepthStencilStateCreateInfo {
    .depthTestEnable = true,
    .depthWriteEnable = true,
    .depthCompareOp = vk::CompareOp::eGreater,
};

const auto DEPTH_TEST_EQUAL = vk::PipelineDepthStencilStateCreateInfo {
    .depthTestEnable = true,
    .depthWriteEnable = false,
    .depthCompareOp = vk::CompareOp::eEqual,
};

std::vector<uint8_t> read_file_to_bytes(const char* filepath) {
    std::ifstream file_stream(filepath, std::ios::binary);

    if (!file_stream) {
        dbg(filepath);
        abort();
    }

    std::vector<uint8_t> contents(
        (std::istreambuf_iterator<char>(file_stream)),
        {}
    );

    assert(!contents.empty());

    return contents;
}

vk::raii::ShaderModule
create_shader_from_file(const vk::raii::Device& device, const char* filepath) {
    auto bytes = read_file_to_bytes(filepath);

    auto shader = device.createShaderModule(vk::ShaderModuleCreateInfo {
        .codeSize = bytes.size(),
        .pCode = (uint32_t*)bytes.data(),
    });

    return shader;
}

DescriptorSetLayouts
create_descriptor_set_layouts(const vk::raii::Device& device) {
    auto everything_bindings = std::array {
        // Geometry buffer
        vk::DescriptorSetLayoutBinding {
            .binding = 0,
            .descriptorType = vk::DescriptorType::eStorageBuffer,
            .descriptorCount = 1,
            .stageFlags = vk::ShaderStageFlagBits::eVertex,
        },
        // Uniforms
        vk::DescriptorSetLayoutBinding {
            .binding = 1,
            .descriptorType = vk::DescriptorType::eUniformBuffer,
            .descriptorCount = 1,
            .stageFlags = vk::ShaderStageFlagBits::eVertex,
        },
        // hdr framebuffer
        vk::DescriptorSetLayoutBinding {
            .binding = 2,
            .descriptorType = vk::DescriptorType::eSampledImage,
            .descriptorCount = 1,
            .stageFlags = vk::ShaderStageFlagBits::eFragment,
        },
        // sampler
        vk::DescriptorSetLayoutBinding {
            .binding = 3,
            .descriptorType = vk::DescriptorType::eSampler,
            .descriptorCount = 1,
            .stageFlags = vk::ShaderStageFlagBits::eFragment,
        },
        // display transform LUT
        vk::DescriptorSetLayoutBinding {
            .binding = 4,
            .descriptorType = vk::DescriptorType::eSampledImage,
            .descriptorCount = 1,
            .stageFlags = vk::ShaderStageFlagBits::eFragment,
        },
        vk::DescriptorSetLayoutBinding {
            .binding = 5,
            .descriptorType = vk::DescriptorType::eSampler,
            .descriptorCount = 1,
            .stageFlags = vk::ShaderStageFlagBits::eFragment,
        },
        // Bindless images
        vk::DescriptorSetLayoutBinding {
            .binding = 6,
            .descriptorType = vk::DescriptorType::eSampledImage,
            .descriptorCount = 1,
            .stageFlags = vk::ShaderStageFlagBits::eFragment,
            .descriptorCount = 512,
        },
    };

    std::array<vk::DescriptorBindingFlags, 7> flags;
    // Set the images as being partially bound, so not all slots have to be used.
    flags[6] = vk::DescriptorBindingFlagBits::ePartiallyBound;

    assert(flags.size() == everything_bindings.size());

    auto flags_create_info = vk::DescriptorSetLayoutBindingFlagsCreateInfo {
        .bindingCount = flags.size(),
        .pBindingFlags = flags.data()};

    return DescriptorSetLayouts {
        .everything = device.createDescriptorSetLayout({
            .pNext = &flags_create_info,
            .bindingCount = everything_bindings.size(),
            .pBindings = everything_bindings.data(),
        }),
    };
}

Pipelines Pipelines::compile_pipelines(
    const vk::raii::Device& device,
    vk::Format swapchain_format
) {
    auto descriptor_set_layouts = create_descriptor_set_layouts(device);

    auto descriptor_set_layout_array =
        std::array {*descriptor_set_layouts.everything};

    auto pipeline_layout =
        device.createPipelineLayout(vk::PipelineLayoutCreateInfo {
            .setLayoutCount = descriptor_set_layout_array.size(),
            .pSetLayouts = descriptor_set_layout_array.data(),
            .pushConstantRangeCount = 0,
            .pPushConstantRanges = nullptr,
        });

    auto render_geometry =
        create_shader_from_file(device, "compiled_shaders/render_geometry.spv");

    auto fullscreen_tri =
        create_shader_from_file(device, "compiled_shaders/fullscreen_tri.spv");

    auto display_transform = create_shader_from_file(
        device,
        "compiled_shaders/display_transform.spv"
    );

    auto blit_stages = std::array {
        vk::PipelineShaderStageCreateInfo {
            .stage = vk::ShaderStageFlagBits::eVertex,
            .module = *fullscreen_tri,
            .pName = "VSMain",
        },
        vk::PipelineShaderStageCreateInfo {
            .stage = vk::ShaderStageFlagBits::eFragment,
            .module = *display_transform,
            .pName = "PSMain"}};

    auto render_geometry_stages = std::array {
        vk::PipelineShaderStageCreateInfo {
            .stage = vk::ShaderStageFlagBits::eVertex,
            .module = *render_geometry,
            .pName = "VSMain",
        },
        vk::PipelineShaderStageCreateInfo {
            .stage = vk::ShaderStageFlagBits::eFragment,
            .module = *render_geometry,
            .pName = "PSMain"}};

    auto depth_pre_pass_stage = std::array {vk::PipelineShaderStageCreateInfo {
        .stage = vk::ShaderStageFlagBits::eVertex,
        .module = *render_geometry,
        .pName = "depth_only",
    }};

    auto swapchain_format_rendering_info = vk::PipelineRenderingCreateInfoKHR {
        .colorAttachmentCount = 1,
        .pColorAttachmentFormats = &swapchain_format};

    auto rgba16f = vk::Format::eR16G16B16A16Sfloat;

    auto rgba16f_format_rendering_info = vk::PipelineRenderingCreateInfoKHR {
        .colorAttachmentCount = 1,
        .pColorAttachmentFormats = &rgba16f,
        .depthAttachmentFormat = vk::Format::eD32Sfloat};

    auto depth_only_rendering_info = vk::PipelineRenderingCreateInfoKHR {
        .depthAttachmentFormat = vk::Format::eD32Sfloat};

    auto pipeline_infos =
        std::array {// display_transform
                    vk::GraphicsPipelineCreateInfo {
                        .pNext = &swapchain_format_rendering_info,
                        .stageCount = blit_stages.size(),
                        .pStages = blit_stages.data(),
                        .pVertexInputState = &EMPTY_VERTEX_INPUT,
                        .pInputAssemblyState = &TRIANGLE_LIST_INPUT_ASSEMBLY,
                        .pViewportState = &DEFAULT_VIEWPORT_STATE,
                        .pRasterizationState = &FILL_RASTERIZATION,
                        .pMultisampleState = &NO_MULTISAMPLING,
                        .pColorBlendState = &SINGLE_REPLACE_BLEND_STATE,
                        .pDynamicState = &DEFAULT_DYNAMIC_STATE_INFO,
                        .layout = *pipeline_layout,
                    },
                    // render_geometry
                    vk::GraphicsPipelineCreateInfo {
                        .pNext = &rgba16f_format_rendering_info,
                        .stageCount = render_geometry_stages.size(),
                        .pStages = render_geometry_stages.data(),
                        .pVertexInputState = &EMPTY_VERTEX_INPUT,
                        .pInputAssemblyState = &TRIANGLE_LIST_INPUT_ASSEMBLY,
                        .pViewportState = &DEFAULT_VIEWPORT_STATE,
                        .pRasterizationState = &FILL_RASTERIZATION,
                        .pMultisampleState = &NO_MULTISAMPLING,
                        .pDepthStencilState = &DEPTH_TEST_EQUAL,
                        .pColorBlendState = &SINGLE_REPLACE_BLEND_STATE,
                        .pDynamicState = &DEFAULT_DYNAMIC_STATE_INFO,
                        .layout = *pipeline_layout,
                    },
                    // geometry depth pre pass
                    vk::GraphicsPipelineCreateInfo {
                        .pNext = &depth_only_rendering_info,
                        .stageCount = depth_pre_pass_stage.size(),
                        .pStages = depth_pre_pass_stage.data(),
                        .pVertexInputState = &EMPTY_VERTEX_INPUT,
                        .pInputAssemblyState = &TRIANGLE_LIST_INPUT_ASSEMBLY,
                        .pViewportState = &DEFAULT_VIEWPORT_STATE,
                        .pRasterizationState = &FILL_RASTERIZATION,
                        .pMultisampleState = &NO_MULTISAMPLING,
                        .pDepthStencilState = &DEPTH_WRITE_GREATER,
                        .pColorBlendState = &EMPTY_BLEND_STATE,
                        .pDynamicState = &DEFAULT_DYNAMIC_STATE_INFO,
                        .layout = *pipeline_layout,
                    }};

    auto pipelines = device.createGraphicsPipelines(nullptr, pipeline_infos);

    return Pipelines {
        .display_transform = std::move(pipelines[0]),
        .render_geometry = std::move(pipelines[1]),
        .geometry_depth_prepass = std::move(pipelines[2]),
        .pipeline_layout = std::move(pipeline_layout),
        .dsl = std::move(descriptor_set_layouts),
    };
}