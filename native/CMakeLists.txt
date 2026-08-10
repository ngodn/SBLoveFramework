cmake_minimum_required(VERSION 3.20)
project(SBLoveNative CXX C)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# MinHook, vendored. Inline hooking is the entire reason the native half
# exists: UE4SS's Lua RegisterHook costs 1-3 fps in this game because it
# switches on global ProcessInternal interception, while an inline hook patches
# one function and costs nothing elsewhere.
add_library(minhook STATIC
    deps/minhook/src/buffer.c
    deps/minhook/src/hook.c
    deps/minhook/src/trampoline.c
    deps/minhook/src/hde/hde64.c)
target_include_directories(minhook PUBLIC deps/minhook/include)

# MinHook is C from before clang was this strict; its own warnings are not ours
# to fix and would drown the ones that are.
target_compile_options(minhook PRIVATE /W0)

# UE4SS loads this as Mods/SBLoveNative/dlls/main.dll, so the name is fixed.
add_library(main SHARED
    src/main.cpp
    src/hooks.cpp)

target_link_libraries(main PRIVATE minhook kernel32 user32 psapi)

# Static CRT. A DLL dropped into someone's game folder cannot assume the MSVC
# redistributable is present, and diagnosing "the mod silently did not load"
# from a missing vcruntime DLL is exactly the kind of invisible failure this
# project keeps getting bitten by.
target_compile_options(main PRIVATE /W4 /EHsc)

set_target_properties(main PROPERTIES
    PREFIX ""
    OUTPUT_NAME "main"
    SUFFIX ".dll")
