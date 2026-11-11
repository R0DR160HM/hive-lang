cmake_minimum_required(VERSION 3.19)

# On Linux this is built against libc++ and nothing else, so that is what the compiler is tried with too: a
# machine can have clang and no libstdc++ it can find, and CMake would call that compiler broken.
if(CMAKE_HOST_UNIX AND NOT CMAKE_HOST_APPLE AND NOT CMAKE_TOOLCHAIN_FILE)
    set(CMAKE_CXX_FLAGS_INIT "-stdlib=libc++")
endif()

project(hive-scene CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded")

set(FILAMENT "" CACHE PATH "the Filament SDK this is built against")
set(MATC "${FILAMENT}/bin/matc" CACHE FILEPATH "the matc that compiles the materials")
set(THIRD "" CACHE PATH "where miniaudio.h and stb_vorbis.c are")

if(EMSCRIPTEN)
    set(FAMILY mobile)
    set(APIS -a opengl)
else()
    set(FAMILY desktop)
    set(APIS -a opengl -a vulkan)
endif()

set(BAKED ${CMAKE_CURRENT_BINARY_DIR}/baked)
file(MAKE_DIRECTORY ${BAKED})
set(NAMES)
set(PACKAGES)
function(material name source)
    set(out ${BAKED}/${name}.filamat)
    add_custom_command(OUTPUT ${out}
        COMMAND ${MATC} ${APIS} -p ${FAMILY} ${ARGN} -o ${out} ${CMAKE_CURRENT_SOURCE_DIR}/materials/${source}.mat
        DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/materials/${source}.mat
        VERBATIM)
    set(NAMES ${NAMES} ${name} PARENT_SCOPE)
    set(PACKAGES ${PACKAGES} ${out} PARENT_SCOPE)
endfunction()

material(solid_opaque solid -TKIND=opaque -TBLENDING=opaque -TDEPTHWRITE=true -TDOUBLESIDED=false)
material(solid_pierced solid -TKIND=pierced -TBLENDING=masked -TDEPTHWRITE=true -TDOUBLESIDED=true)
material(solid_soft solid -TKIND=soft -TBLENDING=transparent -TDEPTHWRITE=false -TDOUBLESIDED=true)
material(figure figure)
material(sprite sprite)
material(line line)
material(sheet sheet)

string(REPLACE ";" "," LISTED "${NAMES}")
add_custom_command(OUTPUT ${BAKED}/baked.cpp ${BAKED}/baked.h
    COMMAND ${CMAKE_COMMAND} -DDIR=${BAKED} -DNAMES=${LISTED} -DOUT_CPP=${BAKED}/baked.cpp -DOUT_H=${BAKED}/baked.h
        -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/bake.cmake
    DEPENDS ${PACKAGES} ${CMAKE_CURRENT_SOURCE_DIR}/cmake/bake.cmake
    VERBATIM)

set(CORE
    src/canvas.cpp
    src/model.cpp
    src/shapes.cpp
    src/surfaces.cpp
    src/world.cpp
    ${BAKED}/baked.cpp)

set(LIBS filament backend bluegl bluevk filabridge filaflat utils geometry smol-v ibl abseil zstd)

if(EMSCRIPTEN)
    add_executable(hive-scene ${CORE} src/web.cpp)
else()
    add_executable(hive-scene ${CORE} src/native.cpp src/sound.cpp)
endif()
target_include_directories(hive-scene PRIVATE ${FILAMENT}/include ${BAKED} src ${THIRD})

if(WIN32)
    target_link_directories(hive-scene PRIVATE ${FILAMENT}/lib/x86_64/mt)
    target_link_libraries(hive-scene PRIVATE ${LIBS} gdi32 user32 opengl32 shlwapi)
    target_compile_definitions(hive-scene PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN _CRT_SECURE_NO_WARNINGS)
    target_compile_options(hive-scene PRIVATE /EHsc /W3 /wd4244 /wd4267 /wd4305)
    target_link_options(hive-scene PRIVATE /SUBSYSTEM:CONSOLE)
elseif(EMSCRIPTEN)
    target_compile_options(hive-scene PRIVATE -fno-rtti -fno-exceptions)
    target_link_directories(hive-scene PRIVATE ${FILAMENT}/lib)
    target_link_libraries(hive-scene PRIVATE filament backend filabridge filaflat utils geometry smol-v ibl abseil zstd)
    target_link_options(hive-scene PRIVATE -fno-rtti -sALLOW_MEMORY_GROWTH=1 -sMODULARIZE=1 -sEXPORT_ES6=1
        -sENVIRONMENT=web -sUSE_WEBGL2=1 -sFULL_ES3 -sMIN_WEBGL_VERSION=2 -sMAX_WEBGL_VERSION=2
        -sEXPORTED_FUNCTIONS=_malloc,_free -sEXPORTED_RUNTIME_METHODS=HEAPU8,HEAP32,UTF8ToString,stringToNewUTF8)
else()
    target_compile_options(hive-scene PRIVATE -stdlib=libc++ -fno-rtti)
    target_link_directories(hive-scene PRIVATE ${FILAMENT}/lib/${CMAKE_SYSTEM_PROCESSOR})
    target_link_libraries(hive-scene PRIVATE ${LIBS} webgpu_dawn pthread dl)
    target_link_options(hive-scene PRIVATE -stdlib=libc++ -static-libstdc++ -Wl,--gc-sections -s)
endif()
