#define WLR_USE_UNSTABLE

#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/render/Renderer.hpp>

#include <algorithm>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

HANDLE g_handle = nullptr;
std::vector<PHLWORKSPACEREF> g_touchedWorkspaces;

void rememberWorkspace(const PHLWORKSPACE &workspace)
{
    const bool alreadyTracked = std::ranges::any_of(
        g_touchedWorkspaces,
        [&workspace](const PHLWORKSPACEREF &weak) {
            return weak.lock() == workspace;
        });

    if (!alreadyTracked)
        g_touchedWorkspaces.emplace_back(workspace);
}

void applyOffset(const PHLWORKSPACE &workspace, const PHLMONITOR &monitor, const Vector2D &offset)
{
    rememberWorkspace(workspace);
    workspace->m_renderOffset->setValueAndWarp(offset);
    g_pHyprRenderer->damageMonitor(monitor);
}

SDispatchResult activeWorkspaceForExperiment(PHLMONITOR &monitor, PHLWORKSPACE &workspace)
{
    monitor = Desktop::focusState()->monitor();
    if (!monitor)
        return {.success = false, .error = "PSD: no focused monitor"};

    workspace = monitor->m_activeWorkspace;
    if (!workspace)
        return {.success = false, .error = "PSD: focused monitor has no active workspace"};

    if (workspace->m_isSpecialWorkspace)
        return {.success = false, .error = "PSD: special workspaces are excluded from the offset experiment"};

    if (workspace->m_hasFullscreenWindow)
        return {.success = false, .error = "PSD: refusing render offset while the workspace contains fullscreen content"};

    return {};
}

SDispatchResult setOffset(std::string arguments)
{
    std::replace(arguments.begin(), arguments.end(), ',', ' ');

    std::istringstream stream(arguments);
    double x = 0.0;
    double y = 0.0;
    std::string trailing;

    if (!(stream >> x >> y) || (stream >> trailing))
        return {.success = false, .error = "PSD: expected exactly two numbers: <x> <y>"};

    PHLMONITOR monitor;
    PHLWORKSPACE workspace;
    if (const auto result = activeWorkspaceForExperiment(monitor, workspace); !result.success)
        return result;

    applyOffset(workspace, monitor, Vector2D{x, y});
    return {};
}

SDispatchResult resetOffset(std::string)
{
    PHLMONITOR monitor;
    PHLWORKSPACE workspace;
    if (const auto result = activeWorkspaceForExperiment(monitor, workspace); !result.success)
        return result;

    applyOffset(workspace, monitor, Vector2D{});
    return {};
}

void resetTouchedWorkspaces()
{
    for (const PHLWORKSPACEREF &weak : g_touchedWorkspaces) {
        const auto workspace = weak.lock();
        if (!workspace || !workspace->m_renderOffset)
            continue;

        workspace->m_renderOffset->setValueAndWarp(Vector2D{});

        const auto monitor = workspace->m_monitor.lock();
        if (monitor)
            g_pHyprRenderer->damageMonitor(monitor);
    }

    g_touchedWorkspaces.clear();
}

} // namespace

APICALL EXPORT std::string PLUGIN_API_VERSION()
{
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle)
{
    g_handle = handle;

    const std::string serverHash = __hyprland_api_get_hash();
    const std::string clientHash = __hyprland_api_get_client_hash();
    if (serverHash != clientHash)
        throw std::runtime_error("PSD Hyprland plugin ABI mismatch");

    bool success = true;
    success = success && HyprlandAPI::addDispatcherV2(
        g_handle, "plugin:psd:offset", setOffset);
    success = success && HyprlandAPI::addDispatcherV2(
        g_handle, "plugin:psd:reset", resetOffset);

    if (!success)
        throw std::runtime_error("PSD failed to register experimental Hyprland dispatchers");

    return {
        "psd-hyprland-plugin",
        "Persistent Spatial Desktop compositor integration experiment",
        "SupraLINUX",
        "0.1.0",
    };
}

APICALL EXPORT void PLUGIN_EXIT()
{
    resetTouchedWorkspaces();

    if (g_handle) {
        HyprlandAPI::removeDispatcher(g_handle, "plugin:psd:offset");
        HyprlandAPI::removeDispatcher(g_handle, "plugin:psd:reset");
    }

    g_handle = nullptr;
}
