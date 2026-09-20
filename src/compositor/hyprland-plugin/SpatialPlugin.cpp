#define WLR_USE_UNSTABLE

#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/SharedDefs.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/devices/IPointer.hpp>
#include <hyprland/src/managers/EventManager.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/render/Renderer.hpp>

#include <algorithm>
#include <any>
#include <cstdint>
#include <cmath>
#include <format>
#include <numeric>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

struct PresentationWindowTransform
{
    PHLWINDOWREF window;
    bool pinned = false;
    Vector2D observedBefore;
    Vector2D appliedOffset;
};

struct MonitorTransformState
{
    PHLWORKSPACEREF workspace;
    Vector2D offset;
    uint64_t workspaceGeneration = 0;
    std::vector<PresentationWindowTransform> presentationWindows;
};

HANDLE g_handle = nullptr;
SP<SHyprCtlCommand> g_capabilitiesCommand;
SP<SHyprCtlCommand> g_stateCommand;
SP<HOOK_CALLBACK_FN> g_swipeBeginCallback;
SP<HOOK_CALLBACK_FN> g_swipeUpdateCallback;
SP<HOOK_CALLBACK_FN> g_swipeEndCallback;
std::vector<PHLWORKSPACEREF> g_touchedWorkspaces;
std::unordered_map<std::string, MonitorTransformState> g_monitorTransforms;

bool g_gestureEventsEnabled = false;
bool g_spatialGestureActive = false;
std::string g_spatialGestureMonitor;
uint64_t g_nextWorkspaceGeneration = 1;
uint64_t g_workspaceSwitchResetCount = 0;

std::string jsonEscape(const std::string &value)
{
    std::string result;
    result.reserve(value.size());

    for (const unsigned char ch : value) {
        switch (ch) {
        case '"':
            result += R"(\")";
            break;
        case '\\':
            result += R"(\\)";
            break;
        case '\b':
            result += R"(\b)";
            break;
        case '\f':
            result += R"(\f)";
            break;
        case '\n':
            result += R"(\n)";
            break;
        case '\r':
            result += R"(\r)";
            break;
        case '\t':
            result += R"(\t)";
            break;
        default:
            if (ch < 0x20)
                result += std::format(R"(\u{:04x})", ch);
            else
                result += static_cast<char>(ch);
            break;
        }
    }

    return result;
}

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

void applyOffset(const PHLWORKSPACE &workspace, const Vector2D &offset)
{
    if (!workspace || !workspace->m_renderOffset)
        return;

    rememberWorkspace(workspace);
    workspace->m_renderOffset->setValueAndWarp(offset);

    const auto monitor = workspace->m_monitor.lock();
    if (monitor)
        g_pHyprRenderer->damageMonitor(monitor);
}

bool presentationWindowBelongsToTransform(
    const PHLWINDOW &window,
    const PHLMONITOR &monitor,
    const PHLWORKSPACE &workspace)
{
    if (!window || !window->m_isMapped || window->isHidden() || !window->m_isFloating)
        return false;

    if (window->m_monitor.lock() != monitor)
        return false;

    if (window->m_pinned)
        return true;

    return window->m_workspace == workspace;
}

void clearPresentationWindows(MonitorTransformState &state)
{
    for (PresentationWindowTransform &tracked : state.presentationWindows) {
        const auto window = tracked.window.lock();
        if (window)
            window->m_floatingOffset = Vector2D{};
    }

    state.presentationWindows.clear();
}

void applyPresentationWindows(
    MonitorTransformState &state,
    const PHLMONITOR &monitor,
    const PHLWORKSPACE &workspace,
    const Vector2D &offset)
{
    // CWorkspace::m_renderOffset already translates every non-pinned window
    // in Hyprland 0.53.x. Its workspace-animation callback additionally writes
    // CWindow::m_floatingOffset for floating-window clipping near monitor
    // boundaries. PSD requires rigid translation, so that correction is
    // neutralized for non-pinned floating windows after setValueAndWarp()
    // synchronously ran Hyprland's callback.
    //
    // Pinned windows are deliberately excluded from m_renderOffset by
    // Hyprland's renderer. For them, m_floatingOffset is the narrow render-time
    // compensation needed to keep pinned content attached to CENTER.
    for (PresentationWindowTransform &tracked : state.presentationWindows) {
        const auto window = tracked.window.lock();
        if (window && !presentationWindowBelongsToTransform(window, monitor, workspace))
            window->m_floatingOffset = Vector2D{};
    }

    std::vector<PresentationWindowTransform> next;
    next.reserve(state.presentationWindows.size() + 4);

    for (const auto &window : g_pCompositor->m_windows) {
        if (!presentationWindowBelongsToTransform(window, monitor, workspace))
            continue;

        const Vector2D observedBefore = window->m_floatingOffset;
        const Vector2D appliedOffset = window->m_pinned ? offset : Vector2D{};

        window->m_floatingOffset = appliedOffset;
        next.push_back({
            .window = window,
            .pinned = window->m_pinned,
            .observedBefore = observedBefore,
            .appliedOffset = appliedOffset,
        });
    }

    state.presentationWindows = std::move(next);

    if (monitor)
        g_pHyprRenderer->damageMonitor(monitor);
}

MonitorTransformState &trackWorkspaceForMonitor(
    const std::string &monitorName, const PHLWORKSPACE &workspace)
{
    auto [it, inserted] = g_monitorTransforms.try_emplace(monitorName);
    MonitorTransformState &state = it->second;
    const auto previousWorkspace = state.workspace.lock();

    if (inserted || previousWorkspace != workspace) {
        if (previousWorkspace) {
            applyOffset(previousWorkspace, Vector2D{});
            clearPresentationWindows(state);
            ++g_workspaceSwitchResetCount;
        }

        for (auto other = g_monitorTransforms.begin(); other != g_monitorTransforms.end();) {
            if (other->first != monitorName && other->second.workspace.lock() == workspace)
                other = g_monitorTransforms.erase(other);
            else
                ++other;
        }

        state.workspace = workspace;
        state.workspaceGeneration = g_nextWorkspaceGeneration++;
        if (g_nextWorkspaceGeneration == 0)
            g_nextWorkspaceGeneration = 1;
    }

    return state;
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

    if (!std::isfinite(x) || !std::isfinite(y))
        return {.success = false, .error = "PSD: offset coordinates must be finite"};

    PHLMONITOR monitor;
    PHLWORKSPACE workspace;
    if (const auto result = workspaceForMonitor(monitorName, monitor, workspace); !result.success)
        return result;

    if (workspace->m_hasFullscreenWindow)
        return {.success = false, .error = "PSD: refusing non-zero render offset while the workspace contains fullscreen content"};

    MonitorTransformState &state = trackWorkspaceForMonitor(monitorName, workspace);
    state.offset = Vector2D{x, y};
    applyOffset(workspace, state.offset);
    applyPresentationWindows(state, monitor, workspace, state.offset);
    return {};
}

SDispatchResult resetOffset(std::string arguments)
{
    std::istringstream stream(arguments);
    std::string monitorName;
    std::string trailing;

    if (!(stream >> monitorName) || (stream >> trailing))
        return {.success = false, .error = "PSD: expected <monitor>"};

    const auto tracked = g_monitorTransforms.find(monitorName);
    if (tracked == g_monitorTransforms.end())
        return {};

    MonitorTransformState &state = tracked->second;
    const auto workspace = state.workspace.lock();

    if (workspace)
        applyOffset(workspace, Vector2D{});

    clearPresentationWindows(state);
    g_monitorTransforms.erase(tracked);

    return {};
}

void postGestureEvent(const std::string &name, const std::string &payload)
{
    if (g_pEventManager)
        g_pEventManager->postEvent({.event = name, .data = payload});
}

void finishSpatialGesture(bool cancelled, uint32_t timeMs)
{
    if (!g_spatialGestureActive)
        return;

    postGestureEvent(
        "psdgestureend",
        std::format("{},{},{}", g_spatialGestureMonitor, cancelled ? 1 : 0, timeMs));

    g_spatialGestureActive = false;
    g_spatialGestureMonitor.clear();
}

SDispatchResult setGestureEvents(std::string arguments)
{
    std::istringstream stream(arguments);
    int enabled = -1;
    std::string trailing;

    if (!(stream >> enabled) || (stream >> trailing) || (enabled != 0 && enabled != 1))
        return {.success = false, .error = "PSD: expected 0 or 1"};

    const bool wantEnabled = enabled == 1;
    if (g_gestureEventsEnabled == wantEnabled)
        return {};

    if (!wantEnabled)
        finishSpatialGesture(true, 0);

    g_gestureEventsEnabled = wantEnabled;
    return {};
}

void onSwipeBegin(void *, SCallbackInfo &info, std::any parameter)
{
    if (!g_gestureEventsEnabled || info.cancelled)
        return;

    const auto event = std::any_cast<IPointer::SSwipeBeginEvent>(parameter);
    if (event.fingers != 4)
        return;

    const PHLMONITOR monitor = Desktop::focusState()->monitor();
    if (!monitor || !monitor->m_activeWorkspace)
        return;

    const PHLWORKSPACE workspace = monitor->m_activeWorkspace;
    if (workspace->m_isSpecialWorkspace || workspace->m_hasFullscreenWindow)
        return;

    if (g_spatialGestureActive)
        finishSpatialGesture(true, event.timeMs);

    g_spatialGestureActive = true;
    g_spatialGestureMonitor = monitor->m_name;
    info.cancelled = true;

    postGestureEvent(
        "psdgesturebegin",
        std::format("{},{}", g_spatialGestureMonitor, event.timeMs));
}

void onSwipeUpdate(void *, SCallbackInfo &info, std::any parameter)
{
    if (!g_gestureEventsEnabled || !g_spatialGestureActive)
        return;

    const auto event = std::any_cast<IPointer::SSwipeUpdateEvent>(parameter);
    info.cancelled = true;

    if (event.fingers != 4) {
        finishSpatialGesture(true, event.timeMs);
        return;
    }

    postGestureEvent(
        "psdgestureupdate",
        std::format(
            "{},{:.6f},{:.6f},{}",
            g_spatialGestureMonitor,
            event.delta.x,
            event.delta.y,
            event.timeMs));
}

void onSwipeEnd(void *, SCallbackInfo &info, std::any parameter)
{
    if (!g_gestureEventsEnabled || !g_spatialGestureActive)
        return;

    const auto event = std::any_cast<IPointer::SSwipeEndEvent>(parameter);
    info.cancelled = true;
    finishSpatialGesture(event.cancelled, event.timeMs);
}

std::string capabilitiesResponse(eHyprCtlOutputFormat format, std::string)
{
    if (format == FORMAT_JSON) {
        return R"json({"protocolVersion":3,"pluginVersion":"0.1.3","spatialRenderOffsetExperimental":true,"monitorTargeting":true,"fourFingerGestureEventsExperimental":true,"gestureEventsDefaultEnabled":false,"diagnosticStateQueryExperimental":true,"lifecycleEventsExperimental":true,"rigidFloatingNormalizationExperimental":true,"pinnedPresentationOffsetExperimental":true})json";
    }

    return "protocolVersion=3 pluginVersion=0.1.3 spatialRenderOffsetExperimental=true monitorTargeting=true fourFingerGestureEventsExperimental=true gestureEventsDefaultEnabled=false diagnosticStateQueryExperimental=true lifecycleEventsExperimental=true rigidFloatingNormalizationExperimental=true pinnedPresentationOffsetExperimental=true";
}

std::string stateResponse(eHyprCtlOutputFormat format, std::string)
{
    if (format != FORMAT_JSON) {
        return std::format(
            "trackedTransforms={} touchedWorkspaces={} trackedPresentationWindows={} workspaceSwitchResetCount={} gestureEventsEnabled={} gestureActive={}",
            g_monitorTransforms.size(),
            g_touchedWorkspaces.size(),
            std::accumulate(
                g_monitorTransforms.begin(),
                g_monitorTransforms.end(),
                size_t{0},
                [](size_t count, const auto &entry) {
                    return count + entry.second.presentationWindows.size();
                }),
            g_workspaceSwitchResetCount,
            g_gestureEventsEnabled ? "true" : "false",
            g_spatialGestureActive ? "true" : "false");
    }

    std::string transforms;
    bool first = true;

    for (const auto &[monitorName, state] : g_monitorTransforms) {
        if (!first)
            transforms += ',';
        first = false;

        const auto workspace = state.workspace.lock();
        const Vector2D actual =
            workspace && workspace->m_renderOffset
            ? workspace->m_renderOffset->value()
            : Vector2D{};
        const Vector2D goal =
            workspace && workspace->m_renderOffset
            ? workspace->m_renderOffset->goal()
            : Vector2D{};
        const bool animated =
            workspace && workspace->m_renderOffset
            ? workspace->m_renderOffset->isBeingAnimated()
            : false;

        transforms += std::format(
            R"json({{"monitor":"{}","workspace":"{}","workspaceGeneration":{},"requestedX":{:.6f},"requestedY":{:.6f},"actualX":{:.6f},"actualY":{:.6f},"goalX":{:.6f},"goalY":{:.6f},"animated":{}}})json",
            jsonEscape(monitorName),
            workspace ? jsonEscape(workspace->m_name) : std::string{},
            state.workspaceGeneration,
            state.offset.x,
            state.offset.y,
            actual.x,
            actual.y,
            goal.x,
            goal.y,
            animated ? "true" : "false");
    }

    std::string presentationOffsets;
    first = true;

    for (const auto &[monitorName, state] : g_monitorTransforms) {
        for (const PresentationWindowTransform &tracked : state.presentationWindows) {
            const auto window = tracked.window.lock();
            if (!window)
                continue;

            if (!first)
                presentationOffsets += ',';
            first = false;

            presentationOffsets += std::format(
                R"json({{"monitor":"{}","pinned":{},"strategy":"{}","observedBeforeX":{:.6f},"observedBeforeY":{:.6f},"appliedX":{:.6f},"appliedY":{:.6f},"currentX":{:.6f},"currentY":{:.6f}}})json",
                jsonEscape(monitorName),
                tracked.pinned ? "true" : "false",
                tracked.pinned ? "pinned-compensation" : "workspace-only",
                tracked.observedBefore.x,
                tracked.observedBefore.y,
                tracked.appliedOffset.x,
                tracked.appliedOffset.y,
                window->m_floatingOffset.x,
                window->m_floatingOffset.y);
        }
    }

    return std::format(
        R"json({{"trackedTransforms":[{}],"touchedWorkspaceCount":{},"trackedPresentationWindowCount":{},"presentationOffsets":[{}],"workspaceSwitchResetCount":{},"gestureEventsEnabled":{},"gestureActive":{}}})json",
        transforms,
        g_touchedWorkspaces.size(),
        std::accumulate(
            g_monitorTransforms.begin(),
            g_monitorTransforms.end(),
            size_t{0},
            [](size_t count, const auto &entry) {
                return count + entry.second.presentationWindows.size();
            }),
        presentationOffsets,
        g_workspaceSwitchResetCount,
        g_gestureEventsEnabled ? "true" : "false",
        g_spatialGestureActive ? "true" : "false");
}

void resetTouchedWorkspaces()
{
    for (const PHLWORKSPACEREF &weak : g_touchedWorkspaces) {
        const auto workspace = weak.lock();
        if (workspace)
            applyOffset(workspace, Vector2D{});
    }

    for (auto &[monitorName, state] : g_monitorTransforms) {
        (void)monitorName;
        clearPresentationWindows(state);
    }

    g_monitorTransforms.clear();
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
    success = success && HyprlandAPI::addDispatcherV2(
        g_handle, "plugin:psd:gesture-events", setGestureEvents);

    g_capabilitiesCommand = HyprlandAPI::registerHyprCtlCommand(
        g_handle,
        SHyprCtlCommand{
            .name = "psd-plugin",
            .exact = true,
            .fn = capabilitiesResponse,
        });

    g_stateCommand = HyprlandAPI::registerHyprCtlCommand(
        g_handle,
        SHyprCtlCommand{
            .name = "psd-plugin-state",
            .exact = true,
            .fn = stateResponse,
        });

    g_swipeBeginCallback = HyprlandAPI::registerCallbackDynamic(
        g_handle, "swipeBegin", onSwipeBegin);
    g_swipeUpdateCallback = HyprlandAPI::registerCallbackDynamic(
        g_handle, "swipeUpdate", onSwipeUpdate);
    g_swipeEndCallback = HyprlandAPI::registerCallbackDynamic(
        g_handle, "swipeEnd", onSwipeEnd);

    success = success
        && static_cast<bool>(g_capabilitiesCommand)
        && static_cast<bool>(g_stateCommand)
        && static_cast<bool>(g_swipeBeginCallback)
        && static_cast<bool>(g_swipeUpdateCallback)
        && static_cast<bool>(g_swipeEndCallback);

    if (!success)
        throw std::runtime_error("PSD failed to register experimental Hyprland integration");

    postGestureEvent("psdpluginready", "3");

    return {
        "psd-hyprland-plugin",
        "Persistent Spatial Desktop compositor integration experiment",
        "SupraLINUX",
        "0.1.3",
    };
}

APICALL EXPORT void PLUGIN_EXIT()
{
    g_gestureEventsEnabled = false;
    finishSpatialGesture(true, 0);
    postGestureEvent("psdpluginunloading", "3");
    resetTouchedWorkspaces();

    g_swipeBeginCallback.reset();
    g_swipeUpdateCallback.reset();
    g_swipeEndCallback.reset();

    if (g_handle) {
        if (g_capabilitiesCommand)
            HyprlandAPI::unregisterHyprCtlCommand(g_handle, g_capabilitiesCommand);
        if (g_stateCommand)
            HyprlandAPI::unregisterHyprCtlCommand(g_handle, g_stateCommand);
        HyprlandAPI::removeDispatcher(g_handle, "plugin:psd:offset");
        HyprlandAPI::removeDispatcher(g_handle, "plugin:psd:reset");
        HyprlandAPI::removeDispatcher(g_handle, "plugin:psd:gesture-events");
    }

    g_capabilitiesCommand.reset();
    g_stateCommand.reset();
    g_handle = nullptr;
}
