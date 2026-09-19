find_package(PkgConfig REQUIRED)
pkg_check_modules(HYPRLAND REQUIRED IMPORTED_TARGET hyprland)

add_library(psd-hyprland-plugin MODULE
    SpatialPlugin.cpp
)

target_compile_features(psd-hyprland-plugin PRIVATE cxx_std_23)

target_link_libraries(psd-hyprland-plugin
    PRIVATE
        PkgConfig::HYPRLAND
)

if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
    target_compile_options(psd-hyprland-plugin PRIVATE -fno-gnu-unique)
endif()

set_target_properties(psd-hyprland-plugin PROPERTIES
    PREFIX ""
    OUTPUT_NAME "psd-hyprland-plugin"
)
