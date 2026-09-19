cmake_minimum_required(VERSION 3.25)

project(PersistentSpatialDesktop
    VERSION 0.1.0
    DESCRIPTION "Persistent Spatial Desktop shell"
    LANGUAGES CXX
)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

include(CTest)

option(PSD_BUILD_HYPRLAND_PLUGIN "Build the experimental Hyprland compositor plugin" OFF)

find_package(Qt6 6.10 REQUIRED COMPONENTS Core Gui Network Qml Quick)
find_package(LayerShellQt REQUIRED)
qt_standard_project_setup(REQUIRES 6.10)

add_library(psd-core STATIC
    src/core/DesignTokens.cpp
    src/core/DesignTokens.h
    src/core/SpatialState.cpp
    src/core/SpatialState.h
    src/core/SpatialLayout.cpp
    src/core/SpatialLayout.h
    src/core/SpatialMotionController.cpp
    src/core/SpatialMotionController.h
    src/compositor/CompositorBridge.cpp
    src/compositor/CompositorBridge.h
    src/compositor/HyprlandIpcBridge.cpp
    src/compositor/HyprlandIpcBridge.h
    src/compositor/HyprlandProtocol.cpp
    src/compositor/HyprlandProtocol.h
)

target_include_directories(psd-core
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/src
)

target_link_libraries(psd-core
    PUBLIC
        Qt6::Core
        Qt6::Network
)

qt_add_executable(psd-shell
    src/main.cpp
)

target_link_libraries(psd-shell
    PRIVATE
        psd-core
        Qt6::Core
        Qt6::Gui
        Qt6::Qml
        Qt6::Quick
        LayerShellQt::Interface
)

qt_add_resources(psd-shell "psd_shell_resources"
    PREFIX "/"
    FILES
        qml/Main.qml
        qml/SpatialRoot.qml
        qml/Surfaces/SurfaceBase.qml
        qml/Surfaces/CenterSurface.qml
        qml/Surfaces/LeftSurface.qml
        qml/Surfaces/RightSurface.qml
        qml/Surfaces/TopSurface.qml
        qml/Surfaces/DashSurface.qml
        spec/design-tokens.json
)

install(TARGETS psd-shell
    RUNTIME DESTINATION bin
)

if(PSD_BUILD_HYPRLAND_PLUGIN)
    add_subdirectory(src/compositor/hyprland-plugin)
endif()

if(BUILD_TESTING)
    find_package(Qt6 6.10 REQUIRED COMPONENTS Test)
    add_subdirectory(tests)
endif()
