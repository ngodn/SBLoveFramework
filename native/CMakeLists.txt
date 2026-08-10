cmake_minimum_required(VERSION 3.20)
project(SBLoveNative CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# UE4SS loads this as Mods/SBLoveNative/dlls/main.dll, so the name is fixed.
add_library(main SHARED src/main.cpp)

target_link_libraries(main PRIVATE kernel32 user32 psapi)

# Static CRT. A DLL dropped into someone's game folder cannot assume the MSVC
# redistributable is present, and diagnosing "the mod silently did not load"
# from a missing vcruntime DLL is exactly the kind of invisible failure this
# project keeps getting bitten by.
target_compile_options(main PRIVATE /W4 /EHsc)

set_target_properties(main PROPERTIES
    PREFIX ""
    OUTPUT_NAME "main"
    SUFFIX ".dll")
