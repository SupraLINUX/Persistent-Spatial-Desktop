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
