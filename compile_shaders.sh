dxc -HV 2021 -Wall -spirv -T lib_6_7 src/shaders/display_transform.hlsl -Fo compiled_shaders/display_transform.spv
dxc -HV 2021 -Wall -spirv -T lib_6_7 src/shaders/fullscreen_tri.hlsl    -Fo compiled_shaders/fullscreen_tri.spv
dxc -HV 2021 -Wall -spirv -T lib_6_7 src/shaders/render_geometry.hlsl   -Fo compiled_shaders/render_geometry.spv