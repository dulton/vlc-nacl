#!/bin/sh

SRC_DIR=$(dirname `readlink -f $0`)
BUILD_DIR=$(readlink -f `pwd`)

if [ "${SRC_DIR}" = "${BUILD_DIR}" ]; then
    BUILD_DIR=${BUILD_DIR}/build
fi

#############
# FUNCTIONS #
#############

msg() {
    echo "compile.sh: $*"
}

step_msg() {
    msg
    msg "$1"
    msg
}

copy_if_changed() {
    if cmp -s $1 $2
    then
        msg "leaving $2 unchanged"
    else
        cp -f $1 $2
        chmod u-w $2 # make copied artifact read-only
    fi
}

move_if_changed() {
    if cmp -s $1 $2
    then
        msg "leaving $2 unchanged"
    else
        mv -f $1 $2
        chmod u-w $2 # make moved artifact read-only
    fi
}

make_dir() {
    if [ ! -d $1 ]
    then
        mkdir -p $1
    fi
}

showvar() {
    local T
    eval T=\$$1
    printf "compile.sh: %-26s := %s %s\n" $1 "$T" "$2"
}

putvar() {
    local T
    eval T=\$$1
    printf "compile.sh: %-26s := %s %s\n" $1 "$T" "$2"
    printf "export %s=%s\n" $1 "$T" >> ${BUILD_DIR}/config.tmp
}

putstrvar() {
    local T
    eval T=\$$1
    printf "compile.sh: %-26s := %s %s\n" $1 "$T" "$2"
    printf "export %s=\"%s\"\n" $1 "$T" >> ${BUILD_DIR}/config.tmp
}

checkfail()
{
    if [ ! $? -eq 0 ];then
        msg "$1"
        exit 1
    fi
}

showvar SRC_DIR
showvar BUILD_DIR

#############
# ARGUMENTS #
#############

DISABLE_MANAGE_SUBMODULES=0
ARCH="le32"
RELEASE=0
GDB_FILE=""

# load the config file:
if [ -f ${BUILD_DIR}/config.sh ]; then
    . ${BUILD_DIR}/config.sh
fi

while [ $# -gt 0 ]; do
    case $1 in
        help|--help)
            echo "Use --arch to set the ARCH: `le32` (default), `x86_64`, `i686`, or `arm`."
            echo "Use --release to build in release mode"
            echo 'Use --pepper-root to override $NACL_SDK_ROOT.'
            echo 'Use --webports-root to override $WEBPORTS_ROOT.'
            exit 1
            ;;
        a|-a|--arch)
            ARCH=$2
            shift
            ;;
        --pepper-root)
            NACL_SDK_ROOT=$2
            export NACL_SDK_ROOT=$NACL_SDK_ROOT
            shift
            ;;
        --webports-root)
            WEBPORTS_ROOT=$2
            export WEBPORTS_ROOT=$WEBPORTS_ROOT
            shift
            ;;
        release|--release)
            RELEASE=1
            ;;
        --gdb)
            GDB_FILE="$2"
            shift
            ;;
        --disable-manage-submodules)
            DISABLE_MANAGE_SUBMODULES=1
            ;;
    esac
    shift
done

if [ -z "$NACL_SDK_ROOT" ]; then
    echo "Please provide --pepper-root or set the NACL_SDK_ROOT environment variable to its path."
    exit 1
fi
if [ -z "$WEBPORTS_ROOT" ]; then
    echo "Please provide --webports-root set the WEBPORTS_ROOT environment variable to its path."
    exit 1
fi

if which remake 2&>1 > /dev/null;
then
    MAKE=remake
else
    MAKE=make
fi

putstrvar NACL_SDK_ROOT
putstrvar WEBPORTS_ROOT
putvar DISABLE_MANAGE_SUBMODULES
putvar ARCH
putvar RELEASE
putvar MAKE

# CONFIGURE DONE

make_dir ${BUILD_DIR}
move_if_changed ${BUILD_DIR}/config.tmp ${BUILD_DIR}/config.sh
rm -f ${BUILD_DIR}/config.tmp

step_msg "configure done"

###########################
# VLC CONFIGURE ARGUMENTS #
###########################

VLC_CONFIGURE_ARGS="--disable-shared --enable-static --disable-vlc --disable-a52 --enable-gles2 --disable-xcb --disable-xvideo --disable-libgcrypt --disable-lua --disable-vlm --disable-sout --disable-addonmanagermodules --disable-httpd --disable-alsa --disable-pulse --disable-svg --disable-svgdec --disable-ncurses --disable-shout --disable-gnutls --disable-screen --disable-dbus --disable-udev --disable-upnp --disable-goom --disable-projectm --disable-mtp --disable-vsxu -disable-qt --disable-skins2 --disable-vdpau --disable-vda --without-contrib --disable-aribsub --disable-optimizations --disable-avcodec --disable-swscale"

########################
# VLC MODULE BLACKLIST #
########################

VLC_MODULE_BLACKLIST="
    addons.*
    stats
    access_(bd|shm|imem)
    oldrc
    real
    hotkeys
    gestures
    sap
    dynamicoverlay
    rss
    ball
    audiobargraph_[av]
    clone
    mosaic
    osdmenu
    puzzle
    mediadirs
    t140
    ripple
    motion
    sharpen
    grain
    posterize
    mirror
    wall
    scene
    blendbench
    psychedelic
    alphamask
    netsync
    audioscrobbler
    motiondetect
    motionblur
    export
    smf
    podcast
    bluescreen
    erase
    stream_filter_record
    speex_resampler
    remoteosd
    magnify
    gradient
    dtstofloat32
    logger
    visual
    fb
    aout_file
    yuv
    .dummy
"

#########
# FLAGS #
#########

TARGET_TRIPLE="${ARCH}-unknown-nacl"

OS=`$NACL_SDK_ROOT/tools/getos.py`
# We always use the PNaCl/Clang toolchain (which can also target NaCl).
SYSROOT=$NACL_SDK_ROOT/toolchain/${OS}_pnacl/

case $ARCH in
    le32)
        CONFIG_ARGS="-t pnacl"
        PNACL=1

        BC_SYSROOT=$SYSROOT/le32-nacl
        ;;
    x86_64|i686|arm)
        CONFIG_ARGS="-t clang-newlib -a ${ARCH}"
        BC_SYSROOT=$SYSROOT/${ARCH}_bc-nacl
        ;;
    *)
        echo "Unknown ARCH: '${ARCH}'. Die, die, die!"
        exit 1
    ;;
esac

WEBPORTS_SYSROOT=$SYSROOT/$ARCH-nacl

export PATH=${SYSROOT}/bin:$PATH

# Make in //
if [ -z "$MAKEFLAGS" ]; then
    UNAMES=$(uname -s)
    MAKEFLAGS=
    if which nproc >/dev/null; then
        MAKEFLAGS=-j`nproc`
    elif [ "$UNAMES" == "Darwin" ] && which sysctl >/dev/null; then
        MAKEFLAGS=-j`sysctl -n machdep.cpu.thread_count`
    fi
fi

##########
# CFLAGS #
##########
if [ "$NO_OPTIM" = "1" ];
then
     CFLAGS="-g -O0"
else
     CFLAGS="-g -O2"
fi

CFLAGS="${CFLAGS} -fstrict-aliasing -funsafe-math-optimizations"

if [ "$PNACL" = "1" ]; then
    # matroska uses exceptions:
    CFLAGS="${CFLAGS} --pnacl-exceptions=sjlj"

    CFLAGS="${CFLAGS} -ffp-contract=off"
fi

CFLAGS="${CFLAGS} $(${NACL_SDK_ROOT}/tools/nacl_config.py ${CONFIG_ARGS} --cflags)"
CFLAGS="${CFLAGS} -I${WEBPORTS_SYSROOT}/usr/include -I${WEBPORTS_SYSROOT}/usr/include/glibc-compat"

case $ARCH in
    le32)
        CFLAGS="${CFLAGS}"
        ;;
    x86_64|i686|arm)

        ;;
esac

EXTRA_CFLAGS="-std=gnu11 -lc++ -lpthread"
EXTRA_CXXFLAGS="-std=gnu++11"

#################
# Setup LDFLAGS #
#################

case $ARCH in
    le32)
        EXTRA_LDFLAGS="-L$NACL_SDK_ROOT/lib/pnacl/Release"
        ;;
esac

# Release or not?
if [ "$RELEASE" = 1 ]; then
    OPTS=""
    EXTRA_CFLAGS="${EXTRA_CFLAGS} -DNDEBUG "
else
    OPTS="--enable-debug"
fi


showvar CFLAGS
showvar EXTRA_CFLAGS
showvar CXXFLAGS
showvar EXTRA_CXXFLAGS
showvar LDFLAGS

# Have to be in the top of src directory for this
if [ -z $DISABLE_MANAGE_SUBMODULES ]
then
    cd ${SRC_DIR}

    msg "git: submodule sync"
    git submodule sync

    msg "git: submodule init"
    git submodule init

    msg "git: submodule update"
    git submodule update
    checkfail "git failed"

    msg "git: submodule foreach sync"
    git submodule foreach --recursive 'if test -e .gitmodules; then git submodule sync; fi'
    checkfail "git failed"

    msg "git: submodule foreach update"
    git submodule update --recursive
    checkfail "git failed"

    # NB: this is just for the sake of getting the submodule SHA1 values
    # and status written into the build log.
    msg "git: submodule status"
    git submodule status --recursive

    msg "git: submodule clobber"
    git submodule foreach --recursive git clean -dxf
    checkfail "git failed"
    git submodule foreach --recursive git checkout .
    checkfail "git failed"

    cd ${BUILD_DIR}
fi


###########################
# Build buildsystem tools #
###########################

step_msg "Building webports (this may take awhile)"
cd $WEBPORTS_ROOT
./bin/webports ${CONFIG_FLAGS} install libtheora libvorbis zlib ffmpeg libogg flac libpng x264 lame freetype fontconfig libxml2 libarchive mpg123 libmodplug faad2 libebml libmatroska
checkfail "build && install prerequisites"


#############
# BOOTSTRAP #
#############

VLC_SRC_DIR=$SRC_DIR/vlc
VLC_BUILD_DIR=${BUILD_DIR}/vlc-${TARGET_TRIPLE}
make_dir $VLC_BUILD_DIR

if [ ! -f $VLC_SRC_DIR/configure ]; then
    step_msg "Bootstraping"
    cd $VLC_SRC_DIR
    ./bootstrap
    checkfail "vlc: bootstrap failed"
fi

# GLES 2 pc file:
cp ${SRC_DIR}/extras/glesv2.pc ${WEBPORTS_SYSROOT}/usr/lib/pkgconfig

#################
# CONFIGURE VLC #
#################

cd ${BUILD_DIR}/vlc-${TARGET_TRIPLE}

if [ ! -e ./config.h ]; then
    step_msg "Configuring VLC..."

    CPPFLAGS="$CPPFLAGS" \
            CFLAGS="$CFLAGS ${EXTRA_CFLAGS}" \
            CXXFLAGS="$CFLAGS ${EXTRA_CXXFLAGS}" \
            LDFLAGS="$LDFLAGS" \
            CC="$($NACL_SDK_ROOT/tools/nacl_config.py ${CONFIG_ARGS} --tool cc)" \
            CXX="$($NACL_SDK_ROOT/tools/nacl_config.py ${CONFIG_ARGS} --tool c++)" \
            NM="$($NACL_SDK_ROOT/tools/nacl_config.py ${CONFIG_ARGS} --tool nm)" \
            STRIP="$($NACL_SDK_ROOT/tools/nacl_config.py ${CONFIG_ARGS} --tool strip)" \
            RANLIB="$($NACL_SDK_ROOT/tools/nacl_config.py ${CONFIG_ARGS} --tool ranlib)" \
            AR="$($NACL_SDK_ROOT/tools/nacl_config.py ${CONFIG_ARGS} --tool ar)" \
            PKG_CONFIG_LIBDIR="${WEBPORTS_SYSROOT}/usr/lib/pkgconfig" \
            sh $VLC_SRC_DIR/configure --host=$TARGET_TRIPLE --target=$TARGET_TRIPLE \
            ${EXTRA_PARAMS} ${VLC_CONFIGURE_ARGS} ${OPTS}
    checkfail "vlc: configure failed"
fi

############
# BUILDING #
############

step_msg "Building"
$MAKE $MAKEFLAGS V=1
checkfail "vlc: make failed"

cd $SRC_DIR

msg "TODO: get VLC proper to build for NaCl, then fix the rest of this script."
exit 1


##################
# libVLC modules #
##################

REDEFINED_VLC_MODULES_DIR=$SRC_DIR/.modules/${VLC_BUILD_DIR}
rm -rf ${REDEFINED_VLC_MODULES_DIR}
mkdir -p ${REDEFINED_VLC_MODULES_DIR}

echo "Generating static module list"
blacklist_regexp=
for i in ${VLC_MODULE_BLACKLIST}
do
    if [ -z "${blacklist_regexp}" ]
    then
        blacklist_regexp="${i}"
    else
        blacklist_regexp="${blacklist_regexp}|${i}"
    fi
done

find_modules()
{
    echo "`find $1 -name 'lib*plugin.a' | grep -vE "lib(${blacklist_regexp})_plugin.a" | tr '\n' ' '`"
}

get_symbol()
{
    echo "$1" | grep vlc_entry_$2|cut -d" " -f 3
}

VLC_MODULES=$(find_modules vlc/$VLC_BUILD_DIR/modules)
DEFINITION="";
BUILTINS="const void *vlc_static_modules[] = {\n";
for file in $VLC_MODULES; do
    outfile=${REDEFINED_VLC_MODULES_DIR}/`basename $file`
    name=`echo $file | sed 's/.*\.libs\/lib//' | sed 's/_plugin\.a//'`;
    symbols=$("${CROSS_COMPILE}nm" -g $file)

    # assure that all modules have differents symbol names
    entry=$(get_symbol "$symbols" _)
    copyright=$(get_symbol "$symbols" copyright)
    license=$(get_symbol "$symbols" license)
    cat <<EOF > ${REDEFINED_VLC_MODULES_DIR}/syms
AccessOpen AccessOpen__$name
AccessClose AccessClose__$name
StreamOpen StreamOpen__$name
StreamClose StreamClose__$name
DemuxOpen DemuxOpen__$name
DemuxClose DemuxClose__$name
OpenFilter OpenFilter__$name
CloseFilter CloseFilter__$name
Open Open__$name
Close Close__$name
$entry vlc_entry__$name
$copyright vlc_entry_copyright__$name
$license vlc_entry_license__$name
EOF
    ${CROSS_COMPILE}objcopy --redefine-syms ${REDEFINED_VLC_MODULES_DIR}/syms $file $outfile
    checkfail "objcopy failed"

    DEFINITION=$DEFINITION"int vlc_entry__$name (int (*)(void *, void *, int, ...), void *);\n";
    BUILTINS="$BUILTINS vlc_entry__$name,\n";
done;
BUILTINS="$BUILTINS NULL\n};\n"; \
printf "/* Autogenerated from the list of modules */\n$DEFINITION\n$BUILTINS\n" > libvlc/jni/libvlcjni-modules.h
rm ${REDEFINED_VLC_MODULES_DIR}/syms

# Generating the .ver file like libvlc.so upstream
VER_FILE="vlc/$VLC_BUILD_DIR/lib/.libs/libvlc.ver"
echo "{ global:" > $VER_FILE
cat vlc/lib/libvlc.sym libvlc/libvlcjni.sym | sed -e "s/\(.*\)/\1;/" >> $VER_FILE
echo "__gmp_binvert_limb_table;" >> $VER_FILE # FIXME
echo "local: *; };" >> $VER_FILE

###############################
# NDK-Build for libvlcjni.so  #
###############################

LIBVLC_LIBS="libvlcjni"
VLC_MODULES=$(find_modules ${REDEFINED_VLC_MODULES_DIR})
VLC_SRC_DIR="$SRC_DIR/vlc"
ANDROID_SYS_HEADERS="$SRC_DIR/android-headers"
VLC_CONTRIB="$VLC_SRC_DIR/contrib/$TARGET_TUPLE"

if [ "${CHROME_OS}" != "1" ];then
    if [ "${HAVE_64}" != 1 ];then
        # Can't link with 32bits symbols.
        # Not a problem since MediaCodec should work on 64bits devices (android-21)
        LIBIOMX_LIBS="libiomx.14 libiomx.13 libiomx.10"
        LIBANW_LIBS="libanw.10 libanw.13 libanw.14 libanw.18"
    fi
    # (after android Jelly Bean, we prefer to use MediaCodec instead of iomx)
    # LIBIOMX_LIBS="${LIBIOMX_LIBS} libiomx.19 libiomx.18"

    LIBANW_LIBS="$LIBANW_LIBS libanw.21"
fi

echo "Building NDK"

$ANDROID_NDK/ndk-build -C libvlc \
    VLC_SRC_DIR="$VLC_SRC_DIR" \
    ANDROID_SYS_HEADERS="$ANDROID_SYS_HEADERS" \
    VLC_BUILD_DIR="$VLC_SRC_DIR/$VLC_BUILD_DIR" \
    VLC_CONTRIB="$VLC_CONTRIB" \
    VLC_MODULES="$VLC_MODULES" \
    TARGET_CFLAGS="$EXTRA_CFLAGS" \
    EXTRA_LDFLAGS="$EXTRA_LDFLAGS -Wl,-soname -Wl,libvlc.so.5 -Wl,-version-script -Wl,$SRC_DIR/$VER_FILE" \
    LIBVLC_LIBS="$LIBVLC_LIBS" \
    LIBIOMX_LIBS="$LIBIOMX_LIBS" \
    LIBANW_LIBS="$LIBANW_LIBS" \
    APP_BUILD_SCRIPT=jni/Android.mk \
    APP_PLATFORM=${ANDROID_API} \
    APP_ABI=${ANDROID_ABI} \
    SYSROOT=${SYSROOT} \
    TARGET_TUPLE=$TARGET_TUPLE \
    HAVE_64=${HAVE_64} \
    NDK_PROJECT_PATH=jni \
    NDK_TOOLCHAIN_VERSION=${GCCVER} \
    NDK_DEBUG=${NDK_DEBUG}

checkfail "ndk-build failed"

if [ "${ANDROID_API}" = "android-9" ] && [ "${ANDROID_ABI}" = "armeabi-v7a" -o "${ANDROID_ABI}" = "armeabi" ] ; then
    $ANDROID_NDK/ndk-build -C libvlc \
        APP_BUILD_SCRIPT=libcompat/Android.mk \
        APP_PLATFORM=${ANDROID_API} \
        APP_ABI="armeabi" \
        NDK_PROJECT_PATH=libcompat \
        NDK_TOOLCHAIN_VERSION=${GCCVER} \
        NDK_DEBUG=${NDK_DEBUG}
    checkfail "ndk-build compat failed"
fi

DBG_LIB_DIR=libvlc/jni/obj/local/${ANDROID_ABI}
OUT_LIB_DIR=libvlc/jni/libs/${ANDROID_ABI}
VERSION=$(grep "android:versionName" vlc-android/AndroidManifest.xml|cut -d\" -f 2)
OUT_DBG_DIR=.dbg/${ANDROID_ABI}/$VERSION

echo "Dumping dbg symbols info ${OUT_DBG_DIR}"

mkdir -p $OUT_DBG_DIR
for lib in ${DBG_LIB_DIR}/*.so; do
    ${CROSS_COMPILE}objcopy --only-keep-debug "$lib" "$OUT_DBG_DIR/`basename $lib.dbg`"; \
done
for lib in ${OUT_LIB_DIR}/*.so; do
    ${CROSS_COMPILE}objcopy --add-gnu-debuglink="$OUT_DBG_DIR/`basename $lib.dbg`" "$lib" ; \
done
