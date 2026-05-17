#include <obs-module.h>

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE("obs-mac-game-auto-capture", "en-US")

MODULE_EXPORT const char *obs_module_description(void)
{
    return "Auto-detects and captures macOS games via ScreenCaptureKit";
}

MODULE_EXPORT const char *obs_module_name(void)
{
    return "Mac Game Auto Capture";
}

extern struct obs_source_info game_auto_source_info;

bool obs_module_load(void)
{
    obs_register_source(&game_auto_source_info);
    blog(LOG_INFO, "[mac-game-auto-capture] loaded v0.1.0");
    return true;
}

void obs_module_unload(void)
{
    blog(LOG_INFO, "[mac-game-auto-capture] unloaded");
}
