qt_add_executable(psd-core-tests
    tst_core.cpp
)

target_link_libraries(psd-core-tests
    PRIVATE
        psd-core
        Qt6::Test
)

qt_add_resources(psd-core-tests "psd_test_spec"
    PREFIX "/"
    FILES
        ${PROJECT_SOURCE_DIR}/spec/design-tokens.json
)

add_test(NAME psd-core-tests COMMAND psd-core-tests)
