<picture>  
<source media="(prefers-color-scheme: dark)" srcset="https://i.imgur.com/8qsV6MH.png">  
<source media="(prefers-color-scheme: light)" srcset="https://i.imgur.com/4cpzGnB.png">  
<img src="https://i.imgur.com/8qsV6MH.png" width="200">  
</picture>  

*Part of the Tico ecosystem* — https://www.ticoverse.com

**YabaSanshiro** is a Sega Saturn emulator, known for its hardware-accelerated renderers and its speed on modest hardware.

This port is exclusive to Tico, adapted to work with its frontend and runtime, and provided as a standalone build for the Nintendo Switch. It focuses on integration, consistency, and predictable behavior within the Tico ecosystem.

----------

## Summary

This port focuses on making YabaSanshiro fit naturally within Tico, rather than behaving as a separate application.

It adds:

-   Custom overlay matching Tico design, including time, date, user avatar, and game title
-   A renderer choice: OpenGL (devkitPro's Mesa) or Vulkan (NVK), in one build
-   Explicit control over display (integer scaling and aspect ratios)
-   Built-in save and load state support, with pictures, that remembers the disc of multi-disc games
-   Cartridges, a choice between the real and emulated BIOS, and skipping the BIOS intro
-   Integrated RetroAchievements with custom alerts

----------

## Credits

This port is built on top of devMiyax's YabaSanshiro, itself based on Yabause.
All core emulation work belongs to the YabaSanshiro and Yabause teams and their contributors.

- **devMiyax** — https://github.com/devmiyax
- **YabaSanshiro website** — https://www.uoyabause.org
- **Yabause** — https://github.com/Yabause/yabause

----------

## A Note

A lot of work in this scene disappears over time — not because it lacked value, but because it was never shared.
If you are building something, consider releasing it. Even small contributions can help others move forward.
