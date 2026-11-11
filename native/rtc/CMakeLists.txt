if(WIN32)
  if(NOT MSVC)
    message(FATAL_ERROR "The Windows WebRTC DLL requires Windows x64 and MSVC (Release, static CRT).")
  endif()
  set(WEBRTC_ROOT "${PROJECT_SOURCE_DIR}/.deps/webrtc/windows/webrtc" CACHE PATH "Verified WebRTC package")
  if(NOT EXISTS "${WEBRTC_ROOT}/lib/webrtc.lib")
    message(FATAL_ERROR "Run python tools/fetch_webrtc.py windows first.")
  endif()
  add_library(micdrop_rtc SHARED engine.cc audio_device.cc windows_certificate_verifier.cc)
  target_compile_features(micdrop_rtc PRIVATE cxx_std_20)
  target_compile_definitions(micdrop_rtc PRIVATE MICDROP_RTC_EXPORTS WEBRTC_WIN NOMINMAX WIN32_LEAN_AND_MEAN _WIN32_WINNT=0x0A00 CERT_CHAIN_PARA_HAS_EXTRA_FIELDS)
  target_include_directories(micdrop_rtc SYSTEM PRIVATE "${WEBRTC_ROOT}/include" "${WEBRTC_ROOT}/include/third_party/abseil-cpp")
  target_compile_options(micdrop_rtc PRIVATE /W4 /EHsc /bigobj)
  set(MICDROP_RTC_LIBRARIES micdrop_windows_audio "${WEBRTC_ROOT}/lib/webrtc.lib"
    winmm ws2_32 crypt32 secur32 iphlpapi strmiids dmoguids msdmo wmcodecdspuuid shcore dwmapi d3d11 dxgi ole32 uuid)
  target_link_libraries(micdrop_rtc PRIVATE ${MICDROP_RTC_LIBRARIES})
elseif(APPLE OR UNIX)
  if(APPLE)
    set(_micdrop_webrtc_platform "macos")
  else()
    set(_micdrop_webrtc_platform "linux")
  endif()
  set(WEBRTC_DEPS_DIR "${PROJECT_SOURCE_DIR}/.deps/webrtc/${_micdrop_webrtc_platform}" CACHE PATH "Verified WebRTC and Clang/libc++ bundle")
  set(WEBRTC_ROOT "${WEBRTC_DEPS_DIR}/webrtc" CACHE PATH "Verified WebRTC package")
  if(NOT EXISTS "${WEBRTC_ROOT}/lib/libwebrtc.a" OR NOT EXISTS "${WEBRTC_DEPS_DIR}/libcxx/include/__config_site")
    message(FATAL_ERROR "Run python3 tools/fetch_webrtc.py ${_micdrop_webrtc_platform} first.")
  endif()
  if(NOT CMAKE_CXX_COMPILER_ID STREQUAL "Clang" OR CMAKE_CXX_COMPILER_VERSION VERSION_LESS "21.0")
    message(FATAL_ERROR "WebRTC libc++ requires Clang 21+ (expected ${WEBRTC_DEPS_DIR}/clang/bin/clang++).")
  endif()

  set(MICDROP_WEBRTC_INCLUDES
    "${WEBRTC_ROOT}/include"
    "${WEBRTC_ROOT}/include/third_party/abseil-cpp"
    "${WEBRTC_ROOT}/include/third_party/boringssl/src/include"
  )
  set(MICDROP_WEBRTC_CXXFLAGS
    -nostdinc++
    "SHELL:-isystem \"${WEBRTC_DEPS_DIR}/libcxx/include\""
    -Wall
    -Wextra
  )
  if(APPLE)
    set(MICDROP_WEBRTC_DEFINES
      WEBRTC_POSIX
      WEBRTC_MAC
      _LIBCPP_ABI_NAMESPACE=Cr
      _LIBCPP_ABI_VERSION=2
      _LIBCPP_DISABLE_AVAILABILITY
      _LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS
      _LIBCXXABI_DISABLE_VISIBILITY_ANNOTATIONS
      _LIBCPP_ENABLE_NODISCARD
      _LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE
    )
    set(MICDROP_RTC_LIBRARIES
      micdrop_windows_audio
      "${WEBRTC_ROOT}/lib/libwebrtc.a"
      "-framework AppKit"
      "-framework AVFoundation"
      "-framework AudioToolbox"
      "-framework ApplicationServices"
      "-framework CoreAudio"
      "-framework CoreFoundation"
      "-framework CoreGraphics"
      "-framework CoreMedia"
      "-framework CoreVideo"
      "-framework Foundation"
      "-framework IOKit"
      "-framework IOSurface"
      "-framework Metal"
      "-framework MetalKit"
      "-framework Network"
      "-framework QuartzCore"
      "-framework ScreenCaptureKit"
      "-framework Security"
      "-framework SystemConfiguration"
      "-framework VideoToolbox"
    )
  else()
    find_package(Threads REQUIRED)
    set(MICDROP_WEBRTC_DEFINES
      WEBRTC_POSIX
      WEBRTC_LINUX
      _LIBCPP_ABI_NAMESPACE=Cr
      _LIBCPP_ABI_VERSION=2
      _LIBCPP_DISABLE_AVAILABILITY
      _LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE
    )
    set(MICDROP_RTC_LIBRARIES
      micdrop_windows_audio
      "${WEBRTC_ROOT}/lib/libwebrtc.a"
      Threads::Threads
      dl
      rt
      m
    )
  endif()

  add_library(micdrop_rtc SHARED engine.cc audio_device.cc posix_certificate_verifier.cc)
  target_compile_features(micdrop_rtc PRIVATE cxx_std_20)
  target_compile_definitions(micdrop_rtc PRIVATE MICDROP_RTC_EXPORTS ${MICDROP_WEBRTC_DEFINES})
  target_include_directories(micdrop_rtc SYSTEM PRIVATE ${MICDROP_WEBRTC_INCLUDES})
  target_compile_options(micdrop_rtc PRIVATE ${MICDROP_WEBRTC_CXXFLAGS})
  target_link_libraries(micdrop_rtc PRIVATE ${MICDROP_RTC_LIBRARIES})
  set_target_properties(micdrop_rtc PROPERTIES
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
  )
  if(APPLE)
    set_target_properties(micdrop_rtc PROPERTIES
      MACOSX_RPATH ON
      INSTALL_NAME_DIR "@rpath"
    )
    target_link_options(micdrop_rtc PRIVATE "-Wl,-dead_strip")
  else()
    target_link_options(micdrop_rtc PRIVATE "-Wl,--exclude-libs,ALL" "-Wl,--gc-sections" "-Wl,-z,defs")
  endif()
else()
  message(FATAL_ERROR "Unsupported host OS for micdrop_rtc.")
endif()

if(MICDROP_BUILD_TESTS)
  if(WIN32)
    add_executable(rtc_certificate_test certificate_test.cc windows_certificate_verifier.cc)
    target_compile_features(rtc_certificate_test PRIVATE cxx_std_20)
    target_compile_definitions(rtc_certificate_test PRIVATE WEBRTC_WIN NOMINMAX WIN32_LEAN_AND_MEAN _WIN32_WINNT=0x0A00 CERT_CHAIN_PARA_HAS_EXTRA_FIELDS)
    target_include_directories(rtc_certificate_test SYSTEM PRIVATE "${WEBRTC_ROOT}/include" "${WEBRTC_ROOT}/include/third_party/abseil-cpp")
    target_link_libraries(rtc_certificate_test PRIVATE ${MICDROP_RTC_LIBRARIES})

    add_executable(rtc_media_transport_test media_transport_test.cc)
    target_compile_features(rtc_media_transport_test PRIVATE cxx_std_20)
    target_compile_definitions(rtc_media_transport_test PRIVATE WEBRTC_WIN NOMINMAX WIN32_LEAN_AND_MEAN _WIN32_WINNT=0x0A00)
    target_include_directories(rtc_media_transport_test SYSTEM PRIVATE "${WEBRTC_ROOT}/include" "${WEBRTC_ROOT}/include/third_party/abseil-cpp")
    target_link_libraries(rtc_media_transport_test PRIVATE ${MICDROP_RTC_LIBRARIES})
  else()
    add_executable(rtc_certificate_test certificate_test.cc posix_certificate_verifier.cc)
    target_compile_features(rtc_certificate_test PRIVATE cxx_std_20)
    target_compile_definitions(rtc_certificate_test PRIVATE ${MICDROP_WEBRTC_DEFINES})
    target_include_directories(rtc_certificate_test SYSTEM PRIVATE ${MICDROP_WEBRTC_INCLUDES})
    target_compile_options(rtc_certificate_test PRIVATE ${MICDROP_WEBRTC_CXXFLAGS})
    target_link_libraries(rtc_certificate_test PRIVATE ${MICDROP_RTC_LIBRARIES})

    add_executable(rtc_media_transport_test media_transport_test.cc)
    target_compile_features(rtc_media_transport_test PRIVATE cxx_std_20)
    target_compile_definitions(rtc_media_transport_test PRIVATE ${MICDROP_WEBRTC_DEFINES})
    target_include_directories(rtc_media_transport_test SYSTEM PRIVATE ${MICDROP_WEBRTC_INCLUDES})
    target_compile_options(rtc_media_transport_test PRIVATE ${MICDROP_WEBRTC_CXXFLAGS})
    target_link_libraries(rtc_media_transport_test PRIVATE ${MICDROP_RTC_LIBRARIES})
  endif()
  add_test(NAME rtc_certificate COMMAND rtc_certificate_test)
  set_tests_properties(rtc_certificate PROPERTIES TIMEOUT 30)
  add_test(NAME rtc_media_transport COMMAND rtc_media_transport_test)

  add_executable(rtc_route_test route_test.cc)
  target_link_libraries(rtc_route_test PRIVATE micdrop_rtc)
  target_compile_features(rtc_route_test PRIVATE cxx_std_20)
  add_test(NAME rtc_route COMMAND rtc_route_test)
  set_tests_properties(rtc_route PROPERTIES TIMEOUT 90)
  add_test(NAME rtc_continuous COMMAND rtc_route_test continuous)
  set_tests_properties(rtc_continuous PROPERTIES TIMEOUT 90)

  add_executable(rtc_trickle_test trickle_test.cc)
  target_link_libraries(rtc_trickle_test PRIVATE micdrop_rtc)
  target_compile_features(rtc_trickle_test PRIVATE cxx_std_20)
  add_test(NAME rtc_trickle COMMAND rtc_trickle_test)
  set_tests_properties(rtc_trickle PROPERTIES TIMEOUT 45)

  add_executable(rtc_loopback_test loopback_test.cc)
  target_link_libraries(rtc_loopback_test PRIVATE micdrop_rtc)
  target_compile_features(rtc_loopback_test PRIVATE cxx_std_20)
  add_test(NAME rtc_loopback COMMAND rtc_loopback_test)
  set_tests_properties(rtc_loopback PROPERTIES TIMEOUT 90)

  add_executable(rtc_gathering_test gathering_test.cc)
  if(WIN32)
    target_link_libraries(rtc_gathering_test PRIVATE micdrop_rtc ws2_32)
  else()
    target_link_libraries(rtc_gathering_test PRIVATE micdrop_rtc)
  endif()
  target_compile_features(rtc_gathering_test PRIVATE cxx_std_20)
  add_test(NAME rtc_gathering COMMAND rtc_gathering_test)
  set_tests_properties(rtc_gathering PROPERTIES TIMEOUT 90)
endif()
