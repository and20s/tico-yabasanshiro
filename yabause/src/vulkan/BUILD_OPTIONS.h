/* -----------------------------------------------------
This source code is public domain ( CC0 )
The code is provided as-is without limitations, requirements and responsibilities.
Creators and contributors to this source code are provided as a token of appreciation
and no one associated with this source code can be held responsible for any possible
damages or losses of any kind.

Original file creator:  Niko Kauppi (Code maintenance)
Contributors:
----------------------------------------------------- */

#pragma once

// Vulkan validation layer + debug-utils/debug-report wiring. NDEBUG-
// gated so CMAKE_BUILD_TYPE=Release strips per-call validation and the
// layer-not-found exit(-1). libVkLayer_khronos_validation.so is also
// dropped from release/pro APKs by build.gradle's packagingOptions.
#ifdef NDEBUG
#define BUILD_ENABLE_VULKAN_DEBUG								0
#else
#define BUILD_ENABLE_VULKAN_DEBUG								1
#endif

// VkResult error logging. Cheap (only fires on real errors); always on.
#define BUILD_ENABLE_VULKAN_RUNTIME_DEBUG						1

// To use GLFW, make sure that it's available in the include directories
// along with library directories. You will also need to add
// GLFWs "glfw3.lib" file into the project, this task is up to you.
// GLFW version 3.2 or newer is required.
#if defined(ANDROID)
#else
#define BUILD_USE_GLFW											1
#endif
