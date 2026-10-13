project(yabause-nx)

yab_port_start()

# C++17 for the Vulkan renderer headers (vulkan.hpp) and ImGui Vulkan backend
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=gnu++17")

# Platform-specific definitions matching build_yabause()
add_definitions(
    -D__SWITCH__
    -DSWITCH
    -DHAVE_LIBNX
    -DAARCH64
    -DNX
    -DNDEBUG
    -DHAVE_MUSASHI
    -DYAB_WANT_SCSP
    -DYAB_WANT_OPENGL
    -DYAB_WANT_SH2_CACHE
    -DYAB_ASYNC_RENDERING
    # the ImGui OpenGL backend's Switch path (Mesa's GL headers, no loader)
    -DIMGUI_IMPL_OPENGL_LOADER_CUSTOM
    # no fork/exec here for ImGui's "open in shell"
    -DIMGUI_DISABLE_DEFAULT_SHELL_FUNCTIONS
    -DHAVE_LIBCHDR
    -DRC_CLIENT_SUPPORTS_HASH=1
    -D_GNU_SOURCE
    -D_POSIX_C_SOURCE=200809L
)

# Additional optimization and platform flags
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -O3 -ffunction-sections -fdata-sections -mcpu=cortex-a57 -mtune=cortex-a57 -ffast-math -flto -ftree-vectorize -fomit-frame-pointer")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -O3 -ffunction-sections -fdata-sections -mcpu=cortex-a57 -mtune=cortex-a57 -ffast-math -flto -ftree-vectorize -fomit-frame-pointer")

add_definitions(
    -DHAVE_FLOORF=1
    -DHAVE_NEON=1
    -D__ARM_NEON__
)

set(PORT_INCLUDE_DIRS 
    "../"
    "${CMAKE_CURRENT_BINARY_DIR}/../"
    "${DEVKITPRO}/libnx/include"
    "${DEVKITPRO}/portlibs/switch/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/../vulkan/Include"
    "${CMAKE_CURRENT_SOURCE_DIR}/../gllibs/include"
    "${GLM_INCLUDE_DIRS}"
    "${CMAKE_CURRENT_SOURCE_DIR}/tico/deps/imgui"
    "${CMAKE_CURRENT_SOURCE_DIR}/tico/deps/imgui/backends"
    "${CMAKE_CURRENT_SOURCE_DIR}/tico"
    "${CMAKE_CURRENT_SOURCE_DIR}/tico/deps"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../rcheevos/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../rcheevos/src"
)

# Both renderers in one NRO, picked at launch:
#   OpenGL -- devkitPro's Mesa 20.1 (EGL/GLES through nvc0) and libdrm_nouveau
#   Vulkan -- mesa-switch NVK, the loaderless libvulkan.a from the
#             switch-dev-legacy-vulkan image (its Mesa internals are renamed
#             so they do not clash with the legacy OpenGL's)
set(PORT_LIBRARIES
    vulkan
    ${SHADERC_LIBRARIES}
    EGL
    GLESv2
    glapi
    drm_nouveau
    expat
    zstd
    z
    nx 
    m 
    SDL2
    SDL2_mixer
    mpg123
    modplug
    opusfile
    opus
    vorbisidec
    ogg
)

set(yabause_nx_SOURCES
    # tico frontend: entry point, quick menu, RetroAchievements, game list
    tico/TicoMain.cpp
    tico/YabaMenu.cpp
    tico/YabaRA.cpp
    tico/TicoLsfg.cpp
    tico/YabaSanshiroConfig.cpp
    tico/tico_entry.cpp
    tico/tico_library.cpp
    tico/UsbStorage.cpp
    # the overlay shared by the tico cores (ImGui on OpenGL or Vulkan)
    tico/overlay/imgui_overlay.cpp
    tico/overlay/overlay_ui.cpp
    tico/overlay/ra_alerts.cpp
    tico/overlay/tico_config.cpp
    tico/overlay/translation_manager.cpp
    # ImGui core
    tico/deps/imgui/imgui.cpp
    tico/deps/imgui/imgui_draw.cpp
    tico/deps/imgui/imgui_tables.cpp
    tico/deps/imgui/imgui_widgets.cpp
    # ImGui backends
    tico/deps/imgui/backends/imgui_impl_vulkan.cpp
    tico/deps/imgui/backends/imgui_impl_opengl3.cpp
    # RetroAchievements (rcheevos)
    # RetroAchievements (rcheevos)
    ../../../rcheevos/src/rc_client.c
    ../../../rcheevos/src/rc_client_external.c
    ../../../rcheevos/src/rc_client_raintegration.c
    ../../../rcheevos/src/rc_compat.c
    ../../../rcheevos/src/rc_util.c
    ../../../rcheevos/src/rc_version.c
    ../../../rcheevos/src/rapi/rc_api_common.c
    ../../../rcheevos/src/rapi/rc_api_editor.c
    ../../../rcheevos/src/rapi/rc_api_info.c
    ../../../rcheevos/src/rapi/rc_api_runtime.c
    ../../../rcheevos/src/rapi/rc_api_user.c
    ../../../rcheevos/src/rcheevos/alloc.c
    ../../../rcheevos/src/rcheevos/condition.c
    ../../../rcheevos/src/rcheevos/condset.c
    ../../../rcheevos/src/rcheevos/consoleinfo.c
    ../../../rcheevos/src/rcheevos/format.c
    ../../../rcheevos/src/rcheevos/lboard.c
    ../../../rcheevos/src/rcheevos/memref.c
    ../../../rcheevos/src/rcheevos/operand.c
    ../../../rcheevos/src/rcheevos/rc_validate.c
    ../../../rcheevos/src/rcheevos/richpresence.c
    ../../../rcheevos/src/rcheevos/runtime.c
    ../../../rcheevos/src/rcheevos/runtime_progress.c
    ../../../rcheevos/src/rcheevos/trigger.c
    ../../../rcheevos/src/rcheevos/value.c
    ../../../rcheevos/src/rhash/aes.c
    ../../../rcheevos/src/rhash/cdreader.c
    ../../../rcheevos/src/rhash/hash.c
    ../../../rcheevos/src/rhash/hash_disc.c
    ../../../rcheevos/src/rhash/hash_encrypted.c
    ../../../rcheevos/src/rhash/hash_rom.c
    ../../../rcheevos/src/rhash/hash_zip.c
    ../../../rcheevos/src/rhash/md5.c
)

include_directories(
    ${YABAUSE_INCLUDE_DIR} 
    ${PORT_INCLUDE_DIRS} 
    ${Boost_INCLUDE_DIR} 
    "nanogui-sdl/include" 
    "nanogui-sdl/ext/eigen"
)

link_directories(
    ${DEVKITPRO}/devkitA64/lib/
    ${DEVKITPRO}/libnx/lib/
    ${DEVKITPRO}/portlibs/switch/lib/
    ${LIBCHDR_LIB_DIR}
) 

add_executable(yabause-nx ${yabause_nx_SOURCES})

# Frame generation (LSFG): tico/deps/LSFG-VK, as tico-flycast builds it. It
# reads Lossless Scaling's shaders from the player's own Lossless.dll at run
# time, and reaches Vulkan through the vkGetInstanceProcAddr it is given.
set(TICO_LSFG ${CMAKE_CURRENT_SOURCE_DIR}/tico/deps/LSFG-VK)
file(GLOB TICO_LSFG_SOURCES
    ${TICO_LSFG}/bridge/lsfg_bridge.cpp
    ${TICO_LSFG}/lsfg-vk-common/src/helpers/*.cpp
    ${TICO_LSFG}/lsfg-vk-common/src/vulkan/*.cpp
    ${TICO_LSFG}/lsfg-vk-backend/src/*.cpp
    ${TICO_LSFG}/lsfg-vk-backend/src/extraction/*.cpp
    ${TICO_LSFG}/lsfg-vk-backend/src/helpers/*.cpp
    ${TICO_LSFG}/lsfg-vk-backend/src/shaderchains/*.cpp)
add_library(tico_lsfg STATIC ${TICO_LSFG_SOURCES})
target_include_directories(tico_lsfg PUBLIC ${TICO_LSFG}/bridge)
target_include_directories(tico_lsfg PRIVATE
    ${TICO_LSFG}/lsfg-vk-common/include ${TICO_LSFG}/lsfg-vk-backend/include
    ${TICO_LSFG}/lsfg-vk-backend/src)
# after the project's -std=gnu++17
target_compile_options(tico_lsfg PRIVATE -std=gnu++20 -fexceptions -frtti)
# LSFG-VK's C++ wrappers live in namespace vk, as Vulkan-Hpp's types do in
# the renderer: two vk::CommandBuffer classes with LTO merge their code (the
# renderer's command buffer vectors ran LSFG's destructor and crashed). The
# bridge's C ABI is all the rest of the program sees.
target_compile_definitions(tico_lsfg PRIVATE USE_VULKAN=1 VK_NO_PROTOTYPES=1 vk=tico_lsfg_vk)
# USB drives (libusbhsfs with usbntfs), and libsodium to open the session tico seals
target_link_libraries(yabause-nx tico_lsfg yabause ${YABAUSE_LIBRARIES} ${PORT_LIBRARIES} ${LIBCHDR_LIBRARIES} curl usbhsfs usbntfs sodium)

# glm is fetched as an ExternalProject by the parent vulkan block — make sure
# it exists before nx sources (which include VIDVulkan.h → glm) compile.
if (YAB_WANT_VULKAN)
    add_dependencies(yabause-nx glm)
endif()

# Linker flags matching build_yabause() architecture and specs
set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -specs=${DEVKITPRO}/libnx/switch.specs -g -Wl,-Map,memory.map -Wl,--gc-sections")

# Copy translation, assets, and font files to romfs
file(COPY "${CMAKE_CURRENT_SOURCE_DIR}/tico/lang" DESTINATION "${CMAKE_CURRENT_SOURCE_DIR}/romfs")
file(COPY "${CMAKE_CURRENT_SOURCE_DIR}/tico/assets" DESTINATION "${CMAKE_CURRENT_SOURCE_DIR}/romfs")
file(COPY "${CMAKE_CURRENT_SOURCE_DIR}/tico/fonts" DESTINATION "${CMAKE_CURRENT_SOURCE_DIR}/romfs")
# the overlay builds its settings screen from the module's definition
file(COPY "${CMAKE_CURRENT_SOURCE_DIR}/tico/module/settings.json" DESTINATION "${CMAKE_CURRENT_SOURCE_DIR}/romfs/module")

# POST_BUILD generation is handled by the wrapper script `build_yabasanshiro3_nro.sh`
install(TARGETS yabause-nx DESTINATION "bin")
install(FILES "README.md" DESTINATION ".")