qt_add_executable(psd-core-tests
    tst_core.cpp
)

target_link_libraries(psd-core-tests
    PRIVATE
        psd-core
        Qt6::Test
)

set(PSD_TEST_DESIGN_TOKENS "${PROJECT_SOURCE_DIR}/spec/design-tokens.json")
set_source_files_properties(
    "${PSD_TEST_DESIGN_TOKENS}"
    PROPERTIES QT_RESOURCE_ALIAS "spec/design-tokens.json"
)

qt_add_resources(psd-core-tests "psd_test_spec"
    PREFIX "/"
    FILES
        "${PSD_TEST_DESIGN_TOKENS}"
)

add_test(NAME psd-core-tests COMMAND psd-core-tests)


# Small deterministic Wayland client used only by compositor integration probes.
# It is not installed and is not part of the PSD runtime.
find_package(Qt6 6.10 REQUIRED COMPONENTS Gui Widgets)

qt_add_executable(psd-integration-client
    integration/psd-integration-client.cpp
)

target_link_libraries(psd-integration-client
    PRIVATE
        Qt6::Gui
        Qt6::Widgets
)


# Linux-only virtual touchpad used by the native Hyprland/QEMU integration
# probe. It talks directly to uinput and is never installed.
add_executable(psd-uinput-touchpad
    integration/psd-uinput-touchpad.cpp
)
