/* -----------------------------------------------------
This source code is public domain ( CC0 )
The code is provided as-is without limitations, requirements and responsibilities.
Creators and contributors to this source code are provided as a token of appreciation
and no one associated with this source code can be held responsible for any possible
damages or losses of any kind.

Original file creator:  Niko Kauppi (Code maintenance)
Contributors:
----------------------------------------------------- */

#include "BUILD_OPTIONS.h"
#include "Platform.h"

#include "Window.h"
#include "Shared.h"
#include "Renderer.h"

#include <assert.h>
#include <iostream>

#include "VulkanTools.h"

#if defined(__SWITCH__)

void Window::_InitOSWindow()
{
}

void Window::_DeInitOSWindow()
{
}

void Window::_UpdateOSWindow()
{
}

void Window::_InitOSSurface()
{
  NWindow *win = (NWindow *)window;
  if (win == nullptr) {
    win = nwindowGetDefault();
  }

  VkViSurfaceCreateInfoNN info{};
  info.sType = VK_STRUCTURE_TYPE_VI_SURFACE_CREATE_INFO_NN;
  info.window = win;

  if (VK_SUCCESS != vkCreateViSurfaceNN(_renderer->GetVulkanInstance(), &info, nullptr, &_surface)) {
    assert(0 && "Switch could not create the window surface (vkCreateViSurfaceNN).");
    LOGE("_InitOSSurface FAIL: vkCreateViSurfaceNN");
    return;
  }

  LOGI("_InitOSSurface OK (VI_NN surface created)");
}

#endif // __SWITCH__
