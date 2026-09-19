#define WLR_USE_UNSTABLE

#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/SharedDefs.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/render/Renderer.hpp>

#include <algorithm>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

HANDLE g_handle = nullptr;
SP<SHyprCtlCommand> g_capabilitiesCommand;
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

SDispatchResult workspaceForMonitor(
    const std::string &monitorName, PHLMONITOR &monitor, PHLWORKSPACE &workspace)
{
    monitor = g_pCompositor->getMonitorFromName(monitorName);
    if (!monitor)
        return {.success = false, .error = "PSD: unknown monitor " + monitorName};

    workspace = monitor->m_activeWorkspace;
    if (!workspace)
        return {.success = false, .error = "PSD: monitor has no active workspace"};

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
    std::string monitorName;
    double x = 0.0;
    double y = 0.0;
    std::string trailing;

    if (!(stream >> monitorName >> x >> y) || (stream >> trailing))
        return {.success = false, .error = "PSD: expected <monitor> <x> <y>"};

    PHLMONITOR monitor;
    PHLWORKSPACE workspace;
    if (const auto result = workspaceForMonitor(monitorName, monitor, workspace); !result.success)
        return result;

    applyOffset(workspace, monitor, Vector2D{x, y});
    return {};
}

SDispatchResult resetOffset(std::string arguments)
{
    std::istringstream stream(arguments);
    std::string monitorName;
    std::string trailing;

    if (!(stream >> monitorName) || (stream >> trailing))
        return {.success = false, .error = "PSD: expected <monitor>"};

    PHLMONITOR monitor;
    PHLWORKSPACE workspace;
    if (const auto result = workspaceForMonitor(monitorName, monitor, workspace); !result.success)
        return result;

    applyOffset(workspace, monitor, Vector2D{});
    return {};
}

std::string capabilitiesResponse(eHyprCtlOutputFormat format, std::string)
{
    if (format == FORMAT_JSON) {
        return R"json({"protocolVersion":2,"pluginVersion":"0.1.0","spatialRenderOffsetExperimental":true,"monitorTargeting":true})json";
    }

    return "protocolVersion=2 pluginVersion=0.1.0 spatialRenderOffsetExperimental=true monitorTargeting=true";
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

    g_capabilitiesCommand = HyprlandAPI::registerHyprCtlCommand(
        g_handle,
        SHyprCtlCommand{
            .name = "psd-plugin",
            .exact = true,
            .fn = capabilitiesResponse,
        });
    success = success && static_cast<bool>(g_capabilitiesCommand);

    if (!success)
        throw std::runtime_error("PSD failed to register experimental Hyprland integration");

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
        if (g_capabilitiesCommand)
            HyprlandAPI::unregisterHyprCtlCommand(g_handle, g_capabilitiesCommand);
        HyprlandAPI::removeDispatcher(g_handle, "plugin:psd:offset");
        HyprlandAPI::removeDispatcher(g_handle, "plugin:psd:reset");
    }

    g_handle = nullptr;
}
