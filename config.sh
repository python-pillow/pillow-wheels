# Define custom utilities
# Test for macOS with [ -n "$IS_MACOS" ]

ARCHIVE_SDIR=pillow-depends-main

# Package versions for fresh source builds
FREETYPE_VERSION=2.13.0
HARFBUZZ_VERSION=7.1.0
LIBPNG_VERSION=1.6.39
JPEGTURBO_VERSION=2.1.5.1
OPENJPEG_VERSION=2.5.0
XZ_VERSION=5.4.2
TIFF_VERSION=4.5.0
LCMS2_VERSION=2.15
if [[ -n "$IS_MACOS" ]]; then
    GIFLIB_VERSION=5.1.4
else
    GIFLIB_VERSION=5.2.1
fi
if [[ -n "$IS_MACOS" ]] || [[ "$MB_ML_VER" != 2014 ]]; then
    ZLIB_VERSION=1.2.13
else
    ZLIB_VERSION=1.2.8
fi
LIBWEBP_VERSION=1.3.0
BZIP2_VERSION=1.0.8
LIBXCB_VERSION=1.15
BROTLI_VERSION=1.0.9

if [[ -n "$IS_MACOS" ]] && [[ "$PLAT" == "x86_64" ]]; then
    function build_openjpeg {
        local out_dir=$(fetch_unpack https://github.com/uclouvain/openjpeg/archive/v${OPENJPEG_VERSION}.tar.gz)
        (cd $out_dir \
            && cmake -DCMAKE_INSTALL_PREFIX=$BUILD_PREFIX -DCMAKE_INSTALL_NAME_DIR=$BUILD_PREFIX/lib . \
            && make install)
        touch openjpeg-stamp
    }
fi

function build_brotli {
    local cmake=$(get_modern_cmake)
    local out_dir=$(fetch_unpack https://github.com/google/brotli/archive/v$BROTLI_VERSION.tar.gz)
    (cd $out_dir \
        && $cmake -DCMAKE_INSTALL_PREFIX=$BUILD_PREFIX -DCMAKE_INSTALL_NAME_DIR=$BUILD_PREFIX/lib . \
        && make install)
    if [[ "$MB_ML_LIBC" == "manylinux" ]] && [[ "$PLAT" == "x86_64" ]]; then
        cp /usr/local/lib64/libbrotli* /usr/local/lib
        cp /usr/local/lib64/pkgconfig/libbrotli* /usr/local/lib/pkgconfig
    fi
}

function pre_build {
    # Any stuff that you need to do before you start building the wheels
    # Runs in the root directory of this repository.
    if [ ! -d pillow-depends-main ]; then
        curl -fsSL -o pillow-depends-main.zip https://github.com/python-pillow/pillow-depends/archive/main.zip
        untar pillow-depends-main.zip
    fi

    build_xz
    if [ -z "$IS_ALPINE" ] && [ -z "$IS_MACOS" ]; then
        yum remove -y zlib-devel
    fi
    build_new_zlib

    if [ -n "$IS_MACOS" ]; then
        ORIGINAL_BUILD_PREFIX=$BUILD_PREFIX
        ORIGINAL_PKG_CONFIG_PATH=$PKG_CONFIG_PATH
        BUILD_PREFIX=`dirname $(dirname $(which python))`
        PKG_CONFIG_PATH="$BUILD_PREFIX/lib/pkgconfig"
    fi
    build_simple xcb-proto 1.15.2 https://xcb.freedesktop.org/dist
    if [ -n "$IS_MACOS" ]; then
        build_simple xorgproto 2022.2 https://www.x.org/pub/individual/proto
        build_simple libXau 1.0.11 https://www.x.org/pub/individual/lib
        build_simple libpthread-stubs 0.4 https://xcb.freedesktop.org/dist
        cp venv/share/pkgconfig/xcb-proto.pc venv/lib/pkgconfig/xcb-proto.pc
    else
        sed s/\${pc_sysrootdir\}// /usr/local/share/pkgconfig/xcb-proto.pc > /usr/local/lib/pkgconfig/xcb-proto.pc
    fi
    build_simple libxcb $LIBXCB_VERSION https://xcb.freedesktop.org/dist
    if [ -n "$IS_MACOS" ]; then
        BUILD_PREFIX=$ORIGINAL_BUILD_PREFIX
        PKG_CONFIG_PATH=$ORIGINAL_PKG_CONFIG_PATH
    fi

    build_libjpeg_turbo
    if [[ -n "$IS_MACOS" ]]; then
        rm /usr/local/lib/libjpeg.dylib || true
    fi
    build_tiff
    if [[ -n "$IS_MACOS" ]]; then
        rm /usr/local/lib/libpng* || true
    fi
    build_libpng
    build_lcms2
    build_openjpeg

    ORIGINAL_CFLAGS=$CFLAGS
    CFLAGS="$CFLAGS -O3 -DNDEBUG"
    build_libwebp
    CFLAGS=$ORIGINAL_CFLAGS

    build_brotli

    if [ -n "$IS_MACOS" ]; then
        # Custom freetype build
        build_simple freetype $FREETYPE_VERSION https://download.savannah.gnu.org/releases/freetype tar.gz --with-harfbuzz=no
    else
        build_freetype
    fi

    if [ -z "$IS_MACOS" ]; then
        export FREETYPE_LIBS=-lfreetype
        export FREETYPE_CFLAGS=-I/usr/local/include/freetype2/
    fi
    build_simple harfbuzz $HARFBUZZ_VERSION https://github.com/harfbuzz/harfbuzz/releases/download/$HARFBUZZ_VERSION tar.xz --with-freetype=yes --with-glib=no
    if [ -z "$IS_MACOS" ]; then
        export FREETYPE_LIBS=''
        export FREETYPE_CFLAGS=''
    fi

    # Append licenses
    for filename in dependency_licenses/*; do
      echo -e "\n\n----\n\n$(basename $filename | cut -f 1 -d '.')\n" | cat >> Pillow/LICENSE
      cat $filename >> Pillow/LICENSE
    done
}

function pip_wheel_cmd {
    local abs_wheelhouse=$1
    if [ -z "$IS_MACOS" ]; then
        CFLAGS="$CFLAGS --std=c99"  # for Raqm
    fi
    pip wheel $(pip_opts) \
        --global-option build_ext --global-option --enable-raqm \
        --global-option --vendor-raqm --global-option --vendor-fribidi \
        -w $abs_wheelhouse --no-deps .
}

function run_tests_in_repo {
    # Run Pillow tests from within source repo
    python3 selftest.py
    pytest
}

EXP_CODECS="jpg jpg_2000 libtiff zlib"
EXP_MODULES="freetype2 littlecms2 pil tkinter webp"
EXP_FEATURES="fribidi harfbuzz libjpeg_turbo raqm transp_webp webp_anim webp_mux xcb"

function run_tests {
    if [[ "$PLAT" == "universal2" ]]; then
        # libpng needs to be rebuilt on x86_64 to fix ImageMagick
        build_libpng
    fi
    if [ -n "$IS_MACOS" ]; then
        brew install fribidi
    elif [ -n "$IS_ALPINE" ]; then
        apk add curl fribidi
    else
        apt-get update
        apt-get install -y curl libfribidi0 unzip
    fi
    if [[ $(uname -m) == "i686" ]]; then
        if [[ "$MB_PYTHON_VERSION" != 3.11 ]]; then
            python3 -m pip install numpy==1.21
        fi
    elif [ -z "$IS_ALPINE" ]; then
        python3 -m pip install numpy
    fi

    curl -fsSL -o pillow-test-images.zip https://github.com/python-pillow/test-images/archive/main.zip
    untar pillow-test-images.zip
    mv test-images-main/* ../Pillow/Tests/images

    # Runs tests on installed distribution from an empty directory
    (cd ../Pillow && run_tests_in_repo)
    # Test against expected codecs, modules and features
    local ret=0
    local codecs=$(python3 -c 'from PIL.features import *; print(" ".join(sorted(get_supported_codecs())))')
    if [ "$codecs" != "$EXP_CODECS" ]; then
        echo "Codecs should be: '$EXP_CODECS'; but are '$codecs'"
        ret=1
    fi
    local modules=$(python3 -c 'from PIL.features import *; print(" ".join(sorted(get_supported_modules())))')
    if [ "$modules" != "$EXP_MODULES" ]; then
        echo "Modules should be: '$EXP_MODULES'; but are '$modules'"
        ret=1
    fi
    local features=$(python3 -c 'from PIL.features import *; print(" ".join(sorted(get_supported_features())))')
    if [ "$features" != "$EXP_FEATURES" ]; then
        echo "Features should be: '$EXP_FEATURES'; but are '$features'"
        ret=1
    fi
    return $ret
}
