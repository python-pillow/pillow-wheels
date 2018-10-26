# Define custom utilities
# Test for OSX with [ -n "$IS_OSX" ]

ARCHIVE_SDIR=pillow-depends-master

# Package versions for fresh source builds
FREETYPE_VERSION=2.9.1
LIBPNG_VERSION=1.6.35
ZLIB_VERSION=1.2.11
JPEG_VERSION=9c
OPENJPEG_VERSION=2.1
XZ_VERSION=5.2.4
TIFF_VERSION=4.0.9
LCMS2_VERSION=2.9
GIFLIB_VERSION=5.1.4
LIBWEBP_VERSION=1.0.0

function pre_build {
    # Any stuff that you need to do before you start building the wheels
    # Runs in the root directory of this repository.
    curl -fsSL -o pillow-depends-master.zip https://github.com/python-pillow/pillow-depends/archive/master.zip
    untar pillow-depends-master.zip
    if [ -n "$IS_OSX" ]; then
        # Update to latest zlib for OSX build
        build_new_zlib
    fi
    build_jpeg
    build_tiff
    build_libpng
    build_openjpeg
    if [ -n "$IS_OSX" ]; then
        # Fix openjpeg library install id
        # https://code.google.com/p/openjpeg/issues/detail?id=367
        install_name_tool -id $BUILD_PREFIX/lib/libopenjp2.7.dylib $BUILD_PREFIX/lib/libopenjp2.2.1.0.dylib
    fi
    build_lcms2
    if [ -n "$IS_OSX" ]; then
        # Custom libwebp build to allow building on OS X 10.10 and 10.11
        build_giflib
        build_simple libwebp $LIBWEBP_VERSION \
            https://storage.googleapis.com/downloads.webmproject.org/releases/webp tar.gz \
            --enable-libwebpmux --enable-libwebpdemux --disable-sse4.1
        
        # Custom freetype build
        build_simple freetype $FREETYPE_VERSION https://download.savannah.gnu.org/releases/freetype tar.gz --with-harfbuzz=no
    else
        build_libwebp
        build_freetype
    fi
}

function run_tests_in_repo {
    # Run Pillow tests from within source repo
    pytest
}

EXP_CODECS="jpg jpg_2000 libtiff zlib"
EXP_MODULES="freetype2 littlecms2 pil tkinter webp"

function run_tests {
    # Runs tests on installed distribution from an empty directory
    (cd ../Pillow && run_tests_in_repo)
    # Show supported codecs and modules
    local codecs=$(python -c 'from PIL.features import *; print(" ".join(sorted(get_supported_codecs())))')
    # Test against expected codecs and modules
    local ret=0
    if [ "$codecs" != "$EXP_CODECS" ]; then
        echo "Codecs should be: '$EXP_CODECS'; but are '$codecs'"
        ret=1
    fi
    local modules=$(python -c 'from PIL.features import *; print(" ".join(sorted(get_supported_modules())))')
    if [ "$modules" != "$EXP_MODULES" ]; then
        echo "Modules should be: '$EXP_MODULES'; but are '$modules'"
        ret=1
    fi
    return $ret
}
