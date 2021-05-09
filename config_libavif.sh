set -e

PILLOW_WHEELS_DIR=$(abspath $(dirname "$CONFIG_PATH"))

LIBAVIF_VERSION=0.9.0
CARGO_C_VERSION=0.8.0
AOM_VERSION=2.0.2
DAV1D_VERSION=0.8.2
SVT_AV1_VERSION=0.8.6
RAV1E_VERSION=0.4.0

function install_nasm {
    if [ -e nasm-stamp ]; then return; fi

    echo "::group::Build nasm"
    if [ -n "$IS_MACOS" ]; then
        brew install nasm
    else
        build_simple nasm 2.15.05 https://www.nasm.us/pub/nasm/releasebuilds/2.15.05/
    fi
    echo "::endgroup::"

    touch nasm-stamp
}

function install_meson {
    if [ -e meson-stamp ]; then return; fi

    echo "::group::Install meson"
    $PYTHON_EXE -m pip install meson
    echo "::endgroup::"

    touch meson-stamp
}

function install_ninja {
    if [ -e ninja-stamp ]; then return; fi

    echo "::group::Install ninja"
    $PYTHON_EXE -m pip install ninja
    local ninja_exe=$(dirname $PYTHON_EXE)/ninja
    ln -s $ninja_exe /usr/local/bin/ninja-build
    echo "::endgroup::"

    touch ninja-stamp
}

function install_rust {
    if [ -e rust-stamp ]; then return; fi

    echo "::group::Install rust"
    if [ -n "$IS_MACOS" ]; then
        brew install rust
    else
        if [[ "$MB_ML_VER" == "1" ]]; then
            # Download and use old rustup-init that's compatible with glibc on el5
            curl -sLO https://static.rust-lang.org/rustup/archive/1.22.1/$PLAT-unknown-linux-gnu/rustup-init
            chmod u+x rustup-init
            ./rustup-init --default-toolchain nightly-2020-07-18 -y
        else
            curl https://sh.rustup.rs -sSf | /bin/sh -s -- -y
        fi
    fi
    if [ -e $HOME/.cargo/env ]; then
        source $HOME/.cargo/env
    fi
    echo "::endgroup::"

    touch rust-stamp
}

function install_more_modern_cmake {
    # install_modern_cmake installs cmake 2.8, but some libavif dependencies
    # require a higher version
    if [ -e cmake-more-modern ]; then return; fi

    echo "::group::Install cmake"
    if [ -n "$IS_MACOS" ]; then
        brew install cmake
    else
        $PYTHON_EXE -m pip install cmake
    fi
    echo "::endgroup::"

    touch cmake-more-modern
}

function install_cargo_c {
    install_rust

    if which cargo-cbuild 1>/dev/null 2>/dev/null; then return; fi

    echo "::group::Install cargo-c"
    if [ -n "$IS_MACOS" ]; then
        brew install cargo-c
    else
        mkdir -p $HOME/.cargo/bin
        (cd $HOME/.cargo/bin \
            && fetch_unpack \
                https://github.com/lu-zero/cargo-c/releases/download/v$CARGO_C_VERSION/cargo-c-linux.tar.gz \
                cargo-c-$CARGO_C_VERSION-linux.tar.gz)
    fi
    echo "::endgroup::"
}

function build_aom {
    if [ -e aom-stamp ]; then return; fi

    if [ ! -n "$IS_MACOS" ]; then
        install_more_modern_cmake
        install_nasm
    fi

    echo "::group::Build aom"

    if [ -n "$IS_MACOS" ]; then
        brew install aom
    else
        (rm_mkdir aom-$AOM_VERSION \
            && cd aom-$AOM_VERSION \
            && fetch_unpack \
                https://storage.googleapis.com/aom-releases/libaom-$AOM_VERSION.tar.gz)

        if [[ "$MB_ML_VER" == "1" ]]; then
            (cd aom-$AOM_VERSION \
                && patch -p1 < $PILLOW_WHEELS_DIR/patches/aom-2.0.2-manylinux1.patch)
        fi
        mkdir aom-$AOM_VERSION/build/linux
        (cd aom-$AOM_VERSION/build/linux \
            && cmake \
                -DCMAKE_C_FLAGS=-fPIC \
                -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_INSTALL_PREFIX="${BUILD_PREFIX}" \
                -DCMAKE_INSTALL_LIBDIR=lib \
                -DBUILD_SHARED_LIBS=0 \
                -DENABLE_DOCS=0 \
                -DENABLE_EXAMPLES=0 \
                -DENABLE_TESTDATA=0 \
                -DENABLE_TESTS=0 \
                -DENABLE_TOOLS=0 \
                ../.. \
            && make install)
    fi
    echo "::endgroup::"

    touch aom-stamp
}

function build_dav1d {
    if [ -e dav1d-stamp ]; then return; fi

    install_meson
    install_ninja
    install_nasm

    echo "::group::Build dav1d"
    fetch_unpack "https://code.videolan.org/videolan/dav1d/-/archive/$DAV1D_VERSION/dav1d-$DAV1D_VERSION.tar.gz"
    (cd dav1d-$DAV1D_VERSION \
        && meson . build \
              "--prefix=${BUILD_PREFIX}" \
              --default-library=static \
              --buildtype=release \
        && ninja -vC build install)
    echo "::endgroup::"

    touch dav1d-stamp
}

function build_svt_av1 {
    if [ -e svt-av1-stamp ]; then return; fi

    echo "::group::Build SVT-AV1"

    install_nasm
    install_more_modern_cmake

    fetch_unpack \
        "https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v$SVT_AV1_VERSION/SVT-AV1-v$SVT_AV1_VERSION.tar.gz"

    (cd SVT-AV1-v$SVT_AV1_VERSION/Build/linux \
        && cmake \
            ../.. \
            -DCMAKE_INSTALL_PREFIX="${BUILD_PREFIX}" \
            -DBUILD_SHARED_LIBS=OFF \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_LIBDIR=lib \
        && make install \
        && cp SvtAv1Enc.pc $BUILD_PREFIX/lib/pkgconfig)

    echo "::endgroup::"

    touch svt-av1-stamp
}

function build_rav1e {
    if [ -e rav1e-stamp ]; then return; fi

    install_cargo_c
    install_nasm

    echo "::group::Build rav1e"

    CARGO_VENDOR_TGZ=$ARCHIVE_SDIR/rav1e-vendor-$RAV1E_VERSION.tar.gz
    if [ -e $CARGO_VENDOR_TGZ ]; then
        mkdir -p "$HOME/.cargo"
        tar -C $ARCHIVE_SDIR -zxf $CARGO_VENDOR_TGZ
        VENDOR_DIR=$(pwd -P)/$ARCHIVE_SDIR/vendor
        cat > ~/.cargo/config <<EOF
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "$VENDOR_DIR"
EOF
    fi

    fetch_unpack \
        "https://github.com/xiph/rav1e/archive/v$RAV1E_VERSION.tar.gz" \
        "rav1e-$RAV1E_VERSION.tar.gz"

    # Strip rust version check
    perl -p0i -e 's/(?<=fn rustc_version_check\(\) {).*?(?=\n}\n)//ms' \
        rav1e-$RAV1E_VERSION/build.rs

    (cd rav1e-$RAV1E_VERSION \
        && cargo cinstall --release --library-type=staticlib "--prefix=$BUILD_PREFIX")

    if [ ! -n "$IS_MACOS" ]; then
        sed -i 's/-lgcc_s/-lgcc_eh/g' "${BUILD_PREFIX}/lib/pkgconfig/rav1e.pc"
    fi

    echo "::endgroup::"

    touch rav1e-stamp
}

function build_libavif {
    if [ -e libavif-stamp ]; then return; fi

    echo "::endgroup::"

    LIBAVIF_CMAKE_FLAGS=()

    build_aom
    LIBAVIF_CMAKE_FLAGS+=(-DAVIF_CODEC_AOM=ON)

    build_dav1d
    LIBAVIF_CMAKE_FLAGS+=(-DAVIF_CODEC_DAV1D=ON)

    if [ "$PLAT" != "i686" ]; then
        if [ -n "$IS_MACOS" ]; then
            build_svt_av1
            LIBAVIF_CMAKE_FLAGS+=(-DAVIF_CODEC_SVT=ON)
        elif [[ "$MB_ML_VER" != "1" ]]; then
            LDFLAGS=-lrt build_svt_av1
            LIBAVIF_CMAKE_FLAGS+=(-DCMAKE_EXE_LINKER_FLAGS=-lrt)
            LIBAVIF_CMAKE_FLAGS+=(-DAVIF_CODEC_SVT=ON)
        fi
    fi

    if [[ "$PLAT" != "i686" ]]; then
        build_rav1e
        LIBAVIF_CMAKE_FLAGS+=(-DAVIF_CODEC_RAV1E=ON)
    fi

    if [ -n "$IS_MACOS" ]; then
        # Prevent cmake from using @rpath in install id, so that delocate can
        # find and bundle the libavif dylib
        LIBAVIF_CMAKE_FLAGS+=(\
            "-DCMAKE_INSTALL_NAME_DIR=$BUILD_PREFIX/lib" \
            -DCMAKE_MACOSX_RPATH=OFF)
    fi

    echo "::group::Build libavif"

    fetch_unpack \
        "https://github.com/AOMediaCodec/libavif/archive/v$LIBAVIF_VERSION.tar.gz" \
        "libavif-$LIBAVIF_VERSION.tar.gz"

    mkdir -p libavif-$LIBAVIF_VERSION/build

    (cd libavif-$LIBAVIF_VERSION/build \
        && cmake .. \
            -DCMAKE_INSTALL_PREFIX=$BUILD_PREFIX \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_LIBDIR=lib \
            "${LIBAVIF_CMAKE_FLAGS[@]}" \
        && make install)

    echo "::endgroup::"

    touch libavif-stamp
}
