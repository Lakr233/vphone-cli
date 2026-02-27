#!/bin/bash

# If you like this script and my work on libimobiledevice, please
# consider becoming a patron at https://patreon.com/nikias - Thanks <3

REV=1.0.20

if test "`echo -e Test`" != "Test" 2>&1; then
  echo Please run this with zsh or bash.
  exit 1
fi

if test -x "`which tput`"; then
  ncolors=`tput colors`
  if test -n "$ncolors" && test $ncolors -ge 8; then
    BOLD="$(tput bold)"
    UNDERLINE="$(tput smul)"
    STANDOUT="$(tput smso)"
    NORMAL="$(tput sgr0)"
    BLACK="$(tput setaf 0)"
    RED="$(tput setaf 1)"
    GREEN="$(tput setaf 2)"
    YELLOW="$(tput setaf 3)"
    BLUE="$(tput setaf 4)"
    MAGENTA="$(tput setaf 5)"
    CYAN="$(tput setaf 6)"
    WHITE="$(tput setaf 7)"
  fi
fi

echo -e "${BOLD}**** libimobiledevice stack build script for macOS, revision $REV ****${NORMAL}"

INSTALL_STUFF=1

while getopts hyn flag
do
  case "${flag}" in
    h)
      echo "
This script will build the ${BOLD}libimobiledevice${NORMAL} stack for macOS consisting of
${YELLOW}libplist${NORMAL}, ${YELLOW}libusbmuxd${NORMAL}, ${YELLOW}libimobiledevice${NORMAL}, ${YELLOW}libimobiledevice-glue${NORMAL}, ${YELLOW}libirecovery${NORMAL},
${YELLOW}libtatsu${NORMAL}, ${YELLOW}idevicerestore${NORMAL}, ${YELLOW}libideviceactivation${NORMAL}, ${YELLOW}ideviceinstaller${NORMAL},
and ${YELLOW}ifuse${NORMAL} (requires macFUSE) with the least amount of external dependencies.
Besides command line tools and the compiler for the build process (and
optionally macFUSE) currently the only external dependency is libzip which
will be statically linked.

Everything needed for the build process will be automatically downloaded,
built, and installed. The built libraries and tools will be installed in
the default prefix /usr/local. This can be changed by setting the PREFIX
environment variable. This script will run sudo if the install prefix is
not writeable for the current user, so it might ask for your password.

NOTE: It is *not* recommended to run this script as root. Instead you should
set the DESTDIR environment variable to specify a writeable install location.

Available options:
  -h   Print this help text.
  -y   Assume yes for steps that require user confirmation.
  -n   Do not ask for confirmation and do not attempt to install third party
       software (like macFUSE) during the process. This will still allow
       installation of required tools within the source tree.
"
      exit 0
      ;;
    y)
      DONTASK=1
      ;;
    n)
      unset DONTASK
      unset INSTALL_STUFF
      ;;
  esac
done

echo -e "Run $0 -h for help."

if test $UID -eq 0; then
  if test -z $RUN_AS_ROOT; then
    echo -e "${RED}WARNING: It is *NOT* recommended to run this script as root. See -h for help.${NORMAL}"
    echo -e "If you still want to run it as root, set environment variable RUN_AS_ROOT=1"
    exit 1
  else
    echo -e "${RED}WARNING: Running as root (enforced via env RUN_AS_ROOT)${NORMAL}"
  fi
fi

TESTCOMMANDS="xcrun clang"
for TESTCMD in ${TESTCOMMANDS}; do
  if ! test -x "`which $TESTCMD`"; then
    echo -e "${RED}FATAL: Xcode with command line tools is required. Please install and run again.${NORMAL}"
    exit 1
  fi
done

if test -z "$CFLAGS"; then
  SDKDIR=`xcrun --sdk macosx --show-sdk-path 2>/dev/null`
  TESTARCHS="arm64 x86_64"
  USEARCHS=
  for ARCH in $TESTARCHS; do
    if echo "int main(int argc, char **argv) { return 0; }" |clang -arch $ARCH -o /dev/null -isysroot $SDKDIR -x c - 2>/dev/null; then
      USEARCHS="$USEARCHS -arch $ARCH"
    fi
  done
  export CFLAGS="$USEARCHS -isysroot $SDKDIR"
else
  echo -e "${YELLOW}NOTE: Using externally defined CFLAGS. If that's not what you want, run: unset CFLAGS${NORMAL}"
  if test -z "$SDKDIR"; then
    SDKDIR=`xcrun --sdk macosx --show-sdk-path 2>/dev/null`
    echo -e "${YELLOW}NOTE: SDKDIR is not defined, using ${WHITE}$SDKDIR${NORMAL}"
  fi
fi

if test -z "$PREFIX"; then
  PREFIX="/usr/local"
else
  echo -e "${YELLOW}NOTE: Using externally defined PREFIX. If that's not what you want, run: unset PREFIX${NORMAL}"
fi
echo -e "${BOLD}PREFIX:${NORMAL} ${GREEN}$PREFIX${NORMAL}"
INSTALL_DIR=$PREFIX
if test -n "$DESTDIR"; then
  case "$DESTDIR" in
    /*) export DESTDIR="$DESTDIR" ;;
    *)  export DESTDIR="`pwd`/$DESTDIR" ;;
  esac
  mkdir -p "$DESTDIR"
  echo -e "${BOLD}DESTDIR:${NORMAL} ${GREEN}$DESTDIR${NORMAL}"
  INSTALL_DIR=$DESTDIR
fi

if ! test -w "$INSTALL_DIR"; then
  echo -e "${YELLOW}NOTE: During the process you will be asked for your password, this is to allow installation of the built libraries and tools via ${MAGENTA}sudo${YELLOW}.${NORMAL}"
fi

###########################################################
VERS=`sw_vers -productVersion`
VMAJ=`echo $VERS |cut -d "." -f 1`
VMIN=`echo $VERS |cut -d "." -f 2`

############# DEPENDENCY URLS AND FILE DATA ###############
# autoconf
AUTOCONF_URL=https://ftpmirror.gnu.org/gnu/autoconf/autoconf-2.69.tar.gz
AUTOCONF_HASH=562471cbcb0dd0fa42a76665acf0dbb68479b78a

# automake
AUTOMAKE_URL=https://ftpmirror.gnu.org/gnu/automake/automake-1.16.3.tar.gz
AUTOMAKE_HASH=b36e3877d961c1344351cc97b35b683a4dfadc0c

# libtool
LIBTOOL_URL=https://ftpmirror.gnu.org/gnu/libtool/libtool-2.4.6.tar.gz
LIBTOOL_HASH=25b6931265230a06f0fc2146df64c04e5ae6ec33

# cmake
if [ $VMAJ -le 10 ] && [ $VMIN -lt 13 ]; then
  if [ $VMIN -lt 10 ]; then
    # < macOS 10.10
    CMAKE_URL=https://github.com/Kitware/CMake/releases/download/v3.18.6/cmake-3.18.6-Darwin-x86_64.tar.gz
    CMAKE_HASH=fe09f28c2bfe26a7b7daf0ff9444175f410bae36
  else
    # >= macOS 10.10
    CMAKE_URL=https://github.com/Kitware/CMake/releases/download/v3.20.1/cmake-3.20.1-macos10.10-universal.tar.gz
    CMAKE_HASH=668e554a7fa7ad57eaf73d374774afd7fd25f98f
  fi
else
  # >= macOS 10.13
  CMAKE_URL=https://github.com/Kitware/CMake/releases/download/v3.20.1/cmake-3.20.1-macos-universal.tar.gz
  CMAKE_HASH=43cc6b91ca2ec711f3a1a3eafb970f9389e795e2
fi

# libzip
LIBZIP_URL=https://github.com/nih-at/libzip/releases/download/v1.11.4/libzip-1.11.4.tar.gz
LIBZIP_VERSION=1.11.4
LIBZIP_HASH=70b24dde7aa7690a83940d301b965b514ce5eb3b

# macFUSE
if [ $VMAJ -le 10 ] && [ $VMIN -lt 12 ]; then
  # <= macOS 10.11
  MFUSE_URL=https://github.com/osxfuse/osxfuse/releases/download/macfuse-4.0.5/macfuse-4.0.5.dmg
  MFUSE_HASH=2056c833aa8996d03748687bc938ba9805cc77a5
elif [ $VMAJ -le 12 ]; then
  # macOS >= 10.12
  MFUSE_URL=https://github.com/osxfuse/osxfuse/releases/download/macfuse-4.5.0/macfuse-4.5.0.dmg
  MFUSE_HASH=8d24a497a40d3f3e70cf68f5203517e647789615
else
  # macOS >= 12.x
  MFUSE_URL=https://github.com/macfuse/macfuse/releases/download/macfuse-5.0.6/macfuse-5.0.6.dmg
  MFUSE_HASH=2424c85e2145046f70ef64d127f46605d81ef012
fi

############# CHECK REQUIRED COMMANDS #####################
if test -x "`which shasum`"; then
  SHA1SUM="`which shasum`"
  SHA256SUM="$SHA1SUM -a 256"
elif test -x "`which sha1sum`"; then
  SHA1SUM="`which sha1sum`"
fi
if test -z "$SHA1SUM"; then
  echo -e "${RED}FATAL: no shasum or sha1sum found.${NORMAL}"
  exit 1
fi
if test -z "$SHA256SUM"; then
  if test -x "`which sha256sum`"; then
    SHA256SUM="`which sha256sum`"
  fi
fi
if test -z "$SHA256SUM"; then
  echo -e "${RED}FATAL: no sha256sum found.${NORMAL}"
  exit 1
fi
TESTCOMMANDS="strings dirname cut grep find curl tar gunzip git make sudo"
for TESTCMD in ${TESTCOMMANDS}; do
  if ! test -x "`which $TESTCMD`"; then
    echo -e "${RED}FATAL: Required command '$TESTCMD' is not available.${NORMAL}"
    exit 1
  fi
done

CURL="`which curl`"
if test -x "/usr/bin/curl" && test "$CURL" != "/usr/bin/curl"; then
  CURL=/usr/bin/curl
fi

if test -f "/usr/local/include/openssl/opensslv.h"; then
  echo -e "${RED}ERROR: You have OpenSSL headers installed in /usr/local/include/openssl
and compiling libimobiledevice will fail.${NORMAL}
You can either uninstall the OpenSSL package or just temporarily rename it
like this:
${YELLOW}sudo mv /usr/local/include/openssl /usr/local/include/openssl.bak${NORMAL}
and once this script completes, just rename it back:
${YELLOW}sudo mv /usr/local/include/openssl.bak /usr/local/include/openssl${NORMAL}

Aborting.
"
  exit 1
fi

echo "Checking for externally installed packages..."

BREW_OR_PORTS_INSTALL=
if test -x "`which brew`"; then
  BREW_OR_PORTS_INSTALL="brew install"
elif test -x "`which port`"; then
  BREW_OR_PORTS_INSTALL="sudo port install"
fi

CHECKPKGS="idevicerestore ideviceinstaller libimobiledevice libusbmuxd libplist libimobiledevice-glue libirecovery libideviceactivation ifuse"
for PKG in $CHECKPKGS; do
  PKG_INSTALLED=
  if test -x "`which brew`"; then
    if brew list $PKG >/dev/null 2>/dev/null; then
      PKG_INSTALLED="brew"
      PKG_UNINSTALL_CMD="brew uninstall"
    fi
  fi
  if test -x "`which port`"; then
    if test -n "`port installed $PKG 2>/dev/null |grep active`"; then
      PKG_INSTALLED="macports"
      PKG_UNINSTALL_CMD="sudo port uninstall"
    fi
  fi
  if test -n "$PKG_INSTALLED"; then
    echo -e "${RED}WARNING: ${YELLOW}$PKG${RED} is already installed through ${PKG_INSTALLED}!${NORMAL}
Unless you know exactly what you are doing it is recommended to uninstall the
package first by running: ${YELLOW}${PKG_UNINSTALL_CMD} $PKG${NORMAL}"
    echo
    echo -e "Choose one of these options:"
    echo -e "  [a] Abort now and do nothing"
    echo -e "  [r] Run the uninstall command, then continue"
    echo -e "  [c] Continue without doing anything"
    read -r -p "${BOLD}Your choice? [A/r/c]${NORMAL} " response
    case "$response" in
      [rR])
        echo -e "Running ${YELLOW}$PKG_UNINSTALL_CMD $PKG${NORMAL}..."
        $PKG_UNINSTALL_CMD $PKG 2>/dev/null || exit 1
        ;;
      [cC])
        ;;
      ""|*)
        echo "Aborting."
        exit 0
        ;;
    esac
  fi
done

if test -z "$INSTALL_STUFF"; then
  unset BREW_OR_PORTS_INSTALL
fi

BASEDIR=`pwd`
DEPSDIR="$BASEDIR/deps"
mkdir -p "$DEPSDIR"
cd "$DEPSDIR"
rm -f "*.log"

if ! test -x "`which pkg-config`"; then
  if ! test -x "$DEPSDIR/bin/pkg-config"; then
    # fake pkg-config
    echo -e "#!/bin/sh\nexit 0\n" > "$DEPSDIR/bin/pkg-config"
    chmod 755 "$DEPSDIR/bin/pkg-config"
  fi
fi

export PATH="$PATH:$DEPSDIR/bin"

function error_out {
  echo -e "${RED}ERROR: ${STEP} failed for ${COMP}, check ${YELLOW}${LOGF}${RED} for details.${NORMAL}"
  exit 1
}

echo -e "${CYAN}######## INSTALLING REQUIRED TOOLS AND DEPENDENCIES ########${NORMAL}"

#################### autoconf ####################
if ! test -x "`which autoconf`"; then
  echo -e "${BOLD}*** Installing autoconf (in-tree)${NORMAL}"
  if test -z "$BREW_OR_PORTS_INSTALL"; then
    AUTOCONF_TGZ=`basename $AUTOCONF_URL`
    HASH=`$SHA1SUM "$AUTOCONF_TGZ" 2>/dev/null |cut -d " " -f 1`
    if test -z "$HASH" || test "$HASH" != "$AUTOCONF_HASH"; then
      echo "-- downloading autoconf"
      $CURL -LfsS -o $AUTOCONF_TGZ $AUTOCONF_URL || exit 1
      HASH=`$SHA1SUM "$AUTOCONF_TGZ" 2>/dev/null |cut -d " " -f 1`
      if test -z "$HASH" || test "$HASH" != "$AUTOCONF_HASH"; then
        echo -e "${RED}FATAL: hash mismatch for $AUTOCONF_TGZ${NORMAL}"
        exit 1
      fi
    fi
    tar xzf $AUTOCONF_TGZ
    cd `basename $AUTOCONF_TGZ .tar.gz`
    COMP=autoconf
    echo "-- configuring autoconf"
    STEP=configure
    LOGF=${DEPSDIR}/autoconf-configure.log
    ./configure --prefix="$DEPSDIR" > $LOGF 2>&1 || error_out
    echo "-- building autoconf"
    STEP=build
    LOGF=${DEPSDIR}/autoconf-make.log
    make clean > /dev/null
    make > $LOGF 2>&1 || error_out
    echo "-- installing autoconf (in-tree)"
    STEP=install
    LOGF=${DEPSDIR}/autoconf-make_install.log
    make install > $LOGF 2>&1 || error_out
    cd $DEPSDIR
  else
    $BREW_OR_PORTS_INSTALL autoconf || exit 1
  fi
  echo -e "${BOLD}* autoconf: ${GREEN}done${NORMAL}"
else
  echo -e "${BOLD}* autoconf: ${GREEN}found${NORMAL}"
fi

#################### automake ####################
if ! test -x "`which automake`"; then
  echo -e "${BOLD}*** Installing automake (in-tree)${NORMAL}"
  if test -z "$BREW_OR_PORTS_INSTALL"; then
    AUTOMAKE_TGZ=`basename $AUTOMAKE_URL`
    HASH=`$SHA1SUM "$AUTOMAKE_TGZ" 2>/dev/null |cut -d " " -f 1`
    if test -z "$HASH" || test "$HASH" != "$AUTOMAKE_HASH"; then
      echo "-- Downloading automake"
      $CURL -LfsS -o $AUTOMAKE_TGZ $AUTOMAKE_URL || exit 1
      HASH=`$SHA1SUM "$AUTOMAKE_TGZ" 2>/dev/null |cut -d " " -f 1`
      if test -z "$HASH" || test "$HASH" != "$AUTOMAKE_HASH"; then
        echo -e "${RED}FATAL: hash mismatch for $AUTOMAKE_TGZ${NORMAL}"
        exit 1
      fi
    fi
    tar xzf $AUTOMAKE_TGZ
    cd `basename $AUTOMAKE_TGZ .tar.gz`
    COMP=automake
    echo "-- Configuring automake"
    STEP=configure
    LOGF=${DEPSDIR}/automake-configure.log
    ./configure --prefix="$DEPSDIR" > $LOGF 2>&1 || error_out
    echo "-- Building automake"
    STEP=build
    LOGF=${DEPSDIR}/automake-make.log
    make clean > /dev/null
    make > $LOGF 2>&1 || error_out
    echo "-- Installing automake (in-tree)"
    STEP=install
    LOGF=${DEPSDIR}/automake-make_install.log
    make install > $LOGF 2>&1 || error_out
    cd $DEPSDIR
  else
    $BREW_OR_PORTS_INSTALL automake || exit 1
  fi
  echo -e "${BOLD}* automake: ${GREEN}done${NORMAL}"
else
  echo -e "${BOLD}* automake: ${GREEN}found${NORMAL}"
fi

#################### libtool ####################
if ! test -x "`which libtool`" || ! test -x "`which libtoolize`" -o -x "`which glibtoolize`"; then
  echo -e "${BOLD}*** Installing libtool (in-tree)${NORMAL}"
  if test -z "$BREW_OR_PORTS_INSTALL"; then
    LIBTOOL_TGZ=`basename $LIBTOOL_URL`
    HASH=`$SHA1SUM "$LIBTOOL_TGZ" 2>/dev/null |cut -d " " -f 1`
    if test -z "$HASH" || test "$HASH" != "$LIBTOOL_HASH"; then
      echo "-- Downloading libtool"
      $CURL -LfsS -o $LIBTOOL_TGZ $LIBTOOL_URL || exit 1
      HASH=`$SHA1SUM "$LIBTOOL_TGZ" 2>/dev/null |cut -d " " -f 1`
      if test -z "$HASH" || test "$HASH" != "$LIBTOOL_HASH"; then
        echo -e "${RED}FATAL: hash mismatch for $LIBTOOL_TGZ${NORMAL}"
        exit 1
      fi
    fi
    tar xzf $LIBTOOL_TGZ
    cd `basename $LIBTOOL_TGZ .tar.gz`
    COMP=libtool
    echo "-- Configuring libtool"
    STEP=configure
    LOGF=${DEPSDIR}/libtool-configure.log
    ./configure --prefix="$DEPSDIR" > $LOGF 2>&1 || error_out
    echo "-- Building libtool"
    make clean > /dev/null
    STEP=make
    LOGF=${DEPSDIR}/libtool-make.log
    make > $LOGF 2>&1 || error_out
    echo "-- Installing libtool (in-tree)"
    STEP=install
    LOGF=${DEPSDIR}/libtool-make_install.log
    make install > $LOGF 2>&1 || error_out
    cd $DEPSDIR
  else
    $BREW_OR_PORTS_INSTALL libtool || exit 1
  fi
  echo -e "${BOLD}* libtool: ${GREEN}done${NORMAL}"
else
  echo -e "${BOLD}* libtool: ${GREEN}found${NORMAL}"
fi

TESTCOMMANDS="autoconf automake libtool" # pkg-config"
for TESTCMD in ${TESTCOMMANDS}; do
  if ! test -x "`which $TESTCMD`"; then
    echo -e "${RED}FATAL: required ${BOLD}$TESTCMD${RED} not found. Please install manually.${NORMAL}"
    err_cmd="$err_cmd $TESTCMD"
  fi
done
if test -n "$err_cmd"; then
  exit 1
fi

INSTALL_SUDO=
POSTINSTALL=
if test -z $DESTDIR; then
  if ! test -w $PREFIX; then
    INSTALL_SUDO="sudo"
  fi
fi

ACLOCALDIR=$(dirname `automake --print-libdir`)/aclocal
if ! test -f ${ACLOCALDIR}/pkg.m4; then
  $CURL -LfsS -o "$DEPSDIR/pkg.m4" https://raw.githubusercontent.com/pkgconf/pkgconf/master/pkg.m4 || exit 1
  if test -w ${ACLOCALDIR}; then
    cp "$DEPSDIR/pkg.m4" "${ACLOCALDIR}/pkg.m4"
  else
    $INSTALL_SUDO cp "$DEPSDIR/pkg.m4" "${ACLOCALDIR}/pkg.m4"
  fi
  rm -f "$DEPSDIR/pkg.m4"
fi

############## CMAKE for building libzip ####################
if ! test -x "`which cmake`"; then
  echo -e "${BOLD}*** Installing cmake (in-tree)${NORMAL}"
  CMAKE_TGZ=`basename $CMAKE_URL`
  HASH=`$SHA1SUM "$CMAKE_TGZ" 2>/dev/null |cut -d " " -f 1`
  if test -z "$HASH" || test "$HASH" != "$CMAKE_HASH"; then
    echo "-- Downloading cmake"
    $CURL -LfsS -o "$CMAKE_TGZ" "$CMAKE_URL" || exit 1
  fi
  CMAKE_PATH="$DEPSDIR/`basename $CMAKE_TGZ .tar.gz`/CMake.app/Contents/bin"
  CMAKE_BIN="$CMAKE_PATH/cmake"
  if ! test -x "$CMAKE_BIN"; then
    echo "-- Extracting cmake (in tree)"
    tar xzf "$CMAKE_TGZ"
  fi
  echo "-- Updating \$PATH"
  export PATH="$PATH:$CMAKE_PATH"
  if ! test -x "`which cmake`"; then
    echo -e "${RED}FATAL: cmake not found in \$PATH after trying to install it locally?!${NORMAL}"
    exit 1
  fi
  echo -e "${BOLD}* cmake: ${GREEN}done${NORMAL}"
else
  echo -e "${BOLD}* cmake: ${GREEN}found${NORMAL}"
fi

############ lzma headers for libzip #############
if ! test -f "$DEPSDIR/xz-5.0.5/src/liblzma/api/lzma.h"; then
  echo -e "${BOLD}*** Installing lzma headers (in-tree)${NORMAL}"
  XZ_URL=https://sourceforge.net/projects/lzmautils/files/xz-5.0.5.tar.gz/download
  XZ_HASH=26fec2c1e409f736e77a85e4ab314dc74987def0
  XZ_TGZ="xz-5.0.5.tar.gz"
  HASH=`$SHA1SUM "$XZ_TGZ" 2>/dev/null |cut -d " " -f 1`
  if test -z "$HASH" || test "$HASH" != "$XZ_HASH"; then
    echo "-- Downloading xz"
    $CURL -LfsS -o "$XZ_TGZ" "$XZ_URL" || exit 1
  fi
  echo "-- Extracting xz"
  tar xzf "$XZ_TGZ"
  LZMA_INCLUDES="$DEPSDIR/xz-5.0.5/src/liblzma/api"
  if ! test -f "$LZMA_INCLUDES/lzma.h"; then
    echo -e "${RED}FATAL: lzma.h not found${NORMAL}"
    exit 1
  fi
  echo -e "${BOLD}* lzma headers: ${GREEN}done${NORMAL}"
else
  LZMA_INCLUDES="$DEPSDIR/xz-5.0.5/src/liblzma/api"
  echo -e "${BOLD}* lzma headers: ${GREEN}found${NORMAL}"
fi

############ libzip ###################
LIBZIP_FILENAME=`basename $LIBZIP_URL`
LIBZIP_DIR=`basename $LIBZIP_FILENAME .tar.gz`
if ! test -f $DEPSDIR/$LIBZIP_DIR/build/lib/libzip.a; then
  echo -e "${BOLD}*** Installing libzip (static, in-tree)${NORMAL}"
  HASH=`$SHA1SUM "LIBZIP_FILENAME" 2>/dev/null |cut -d " " -f 1`
  if test -z "$HASH" || test "$HASH" != "$LIBZIP_HASH"; then
    echo "-- Downloading libzip"
    $CURL -LfsS -o "$LIBZIP_FILENAME" "$LIBZIP_URL" || exit 1
  fi
  echo "-- Extracting libzip"
  tar xzf "$LIBZIP_FILENAME"
  if test -z "$SDKDIR"; then
    SDKDIR=`xcrun --sdk macosx --show-sdk-path 2>/dev/null`
  fi
  cd "$LIBZIP_DIR"
  rm -rf build
  mkdir build
  cd build
  COMP=libzip
  echo "-- Configuring libzip (cmake)"
  STEP=configure
  LOGF=${DEPSDIR}/libzip-cmake.log
  cmake -DCMAKE_OSX_SYSROOT="${SDKDIR}" -DBUILD_SHARED_LIBS=OFF -DBUILD_DOC=OFF -DBUILD_EXAMPLES=OFF -DBUILD_OSSFUZZ=OFF -DBUILD_REGRESS=OFF -DBUILD_TOOLS=OFF -DENABLE_GNUTLS=OFF -DENABLE_MBEDTLS=OFF -DENABLE_OPENSSL=OFF -DENABLE_ZSTD=OFF -DCMAKE_POLICY_DEFAULT_CMP0063=NEW -DCMAKE_LIBRARY_PATH="$SDKDIR/usr/lib" -DLIBLZMA_INCLUDE_DIR="$LZMA_INCLUDES" .. > $LOGF 2>&1 || error_out
  echo "-- Bulding libzip"
  STEP=build
  LOGF=${DEPSDIR}/libzip-make.log
  make clean > /dev/null
  make > $LOGF 2>&1 || error_out
  cd "$DEPSDIR"
  echo -e "${BOLD}* libzip: ${GREEN}done${NORMAL}"
else
  echo -e "${BOLD}* libzip: ${GREEN}found${NORMAL}"
fi
LIBZIP_CFLAGS="-I$DEPSDIR/$LIBZIP_DIR/lib -I$DEPSDIR/$LIBZIP_DIR/build"
LIBZIP_LIBS="$DEPSDIR/$LIBZIP_DIR/build/lib/libzip.a -Xlinker $SDKDIR/usr/lib/libbz2.tbd -Xlinker $SDKDIR/usr/lib/liblzma.tbd -lz"

############ LibreSSL ##############
if ! test -f "$LIBCRYPTO" || ! test -f "$LIBSSL"; then
  mkdir -p lib
  if ! test -f "lib/libssl.35.tbd"; then
    $CURL -o "lib/libssl.35.tbd" -LfsS \
        https://gist.github.com/nikias/94c99fd145a75a5104415e5117b0cafa/raw/5209dfbff5a871a14272afe4794e76eb4cf6f062/libssl.35.tbd || exit 1
  fi
  if ! test -f "lib/libcrypto.35.tbd"; then
    $CURL -o "lib/libcrypto.35.tbd" -LfsS \
        https://gist.github.com/nikias/94c99fd145a75a5104415e5117b0cafa/raw/5209dfbff5a871a14272afe4794e76eb4cf6f062/libcrypto.35.tbd || exit 1
  fi
  LIBSSL=$DEPSDIR/lib/libssl.35.tbd
  LIBCRYPTO=$DEPSDIR/lib/libcrypto.35.tbd
  LIBRESSL_VER=2.2.7
fi

if ! test -f "$LIBCRYPTO"; then
  echo -e "${RED}ERROR: Could not find $LIBCRYPTO. Cannot continue.${NORMAL}"
  exit 1
else
  echo -e "${BOLD}* LibreSSL `basename $LIBSSL`: ${GREEN}found${NORMAL}"
fi

if ! test -f "$LIBSSL"; then
  echo -e "${RED}ERROR: Could not find $LIBSSL. Cannot continue.${NORMAL}"
  exit 1
else
  echo -e "${BOLD}* LibreSSL `basename $LIBCRYPTO`: ${GREEN}found${NORMAL}"
fi

if test -z "$LIBRESSL_VER"; then
  if LIBRESSL_VER_TMP=`strings "$LIBCRYPTO" |grep "^LibreSSL .\..\.."`; then
    LIBRESSL_VER=`echo $LIBRESSL_VER_TMP |cut -d " " -f 2`
  fi
fi
echo "  ${YELLOW}LibreSSL version requirment: $LIBRESSL_VER${NORMAL}"
if ! test -f "$DEPSDIR/libressl-$LIBRESSL_VER/include/openssl/opensslv.h"; then
  echo -e "${BOLD}*** Installing LibreSSL headers (in-tree)${NORMAL}"
  rm -rf libressl-$LIBRESSL_VER
  FILENAME="libressl-$LIBRESSL_VER.tar.gz"
  $CURL -LfsS -o "libressl.sha256.txt" "https://ftp.openbsd.org/pub/OpenBSD/LibreSSL/SHA256" || exit 1
  CHKSUM=`cat "libressl.sha256.txt" |grep "($FILENAME)" |cut -d " " -f 4`
  rm -f "libressl.sha256.txt"
  if test -z "$CHKSUM"; then
    echo -e "${RED}ERROR: Failed to get checksum from server for $FILENAME${NORMAL}"
    exit 1
  fi
  if test -f "$FILENAME"; then
    CALCSUM=`$SHA256SUM "$FILENAME" |cut -d " " -f 1`
  fi
  if test -z "$CALCSUM" -o "$CALCSUM" != "$CHKSUM"; then
    echo "-- Downloading $FILENAME${NORMAL}"
    $CURL -LfsS -o "$FILENAME" "https://ftp.openbsd.org/pub/OpenBSD/LibreSSL/$FILENAME" || exit 1
    CALCSUM=`$SHA256SUM "$FILENAME" |cut -d " " -f 1`
    if test "$CALCSUM" != "$CHKSUM"; then
      echo -e "${RED}ERROR: Failed to verify $FILENAME (checksum mismatch).${NORMAL}"
      exit 1
    fi
  else
    echo "-- Using cached $FILENAME"
  fi
  echo "-- Extracting $FILENAME"
  tar xzf "$FILENAME" || exit 1
  echo -e "${BOLD}* LibreSSL headers: ${GREEN}done${NORMAL}"
else
  echo -e "${BOLD}* LibreSSL headers: ${GREEN}found${NORMAL}"
fi
cd "$BASEDIR"

############ macFUSE ##############
HAVE_MACFUSE=no
if ! test -f "/usr/local/lib/libfuse.dylib" || ! test -f "/usr/local/include/fuse/fuse.h"; then
  INSTALL_MACFUSE=no
  if test -n "$DONTASK" && test -n "$INSTALL_STUFF"; then
    INSTALL_MACFUSE=yes
  elif test -z "$INSTALL_STUFF"; then
    INSTALL_MACFUSE=no
  else
    echo -e "${BOLD}The OPTIONAL package ifuse requires macFUSE in order to work."
    if [ $VMAJ -ge 11 ] && [ $VMAJ -lt 12 ]; then
      echo -e "${YELLOW}NOTE: Your Mac's startup security needs to be set to ${MAGENTA}reduced security${YELLOW} in recovery mode, and also the kernel extension cache has to be regenerated for macFUSE to work. Without perfoming these steps after the installation of macFUSE, ifuse will not be able to run.${NORMAL}"
    elif [ $VMAJ -ge 12 ]; then
      echo -e "${YELLOW}NOTE: For macFUSE to work, you need to allow the macFUSE system extension in Settings -> Privacy & Security -> Security. Note that changes will require a system restart.${NORMAL}"
    fi
    echo
    read -r -p "${BOLD}Install macFUSE? If unsure, select 'N'. [y/N]${NORMAL} " response
    case "$response" in
      [yY][eE][sS]|[yY])
        INSTALL_MACFUSE=yes
        ;;
      *)
        INSTALL_MACFUSE=no
        ;;
    esac
  fi
  if test "$INSTALL_MACFUSE" == "yes"; then
    echo -e "${BOLD}*** Installing macFUSE${NORMAL}"
    MFUSE_DMG=$DEPSDIR/`basename $MFUSE_URL`
    HASH=`$SHA1SUM "$MFUSE_DMG" 2>/dev/null |cut -d " " -f 1`
    if test -z "$HASH" || test "$HASH" != "$MFUSE_HASH"; then
      echo "-- Downloading macFUSE"
      $CURL -LfsS -o "$MFUSE_DMG" "$MFUSE_URL" || exit 1
    fi
    hdiutil attach "$MFUSE_DMG" -quiet || exit 1
    MOUNTP="/Volumes/macFUSE"
    INSTPKG="$MOUNTP/Install macFUSE.pkg"
    echo "-- Installing macFUSE (runs with sudo, enter your password when asked for it)"
    sudo /usr/sbin/installer -pkg "$INSTPKG" -target /
    INSTRES=$?
    hdiutil detach "$MOUNTP" -quiet
    if test $INSTRES != 0; then exit 1; fi
    echo -e "${BOLD}* macFUSE: ${GREEN}done${NORMAL}"
    HAVE_MACFUSE=yes
  else
    echo "Skipping installation of macFUSE."
  fi
else
  echo -e "${BOLD}* macFUSE: ${GREEN}found${NORMAL}"
  HAVE_MACFUSE=yes
fi

#############################################################################
COMPONENTS="
  libplist:master \
  libimobiledevice-glue:master \
  libusbmuxd:master \
  libimobiledevice:master  \
  libirecovery:master \
  libtatsu:master \
  idevicerestore:master \
  libideviceactivation:master \
  ideviceinstaller:master \
"
# error helper function
function error_exit {
  echo "$1"
  exit 1
}

CURDIR=${BASEDIR}

if test "$HAVE_MACFUSE" == "yes"; then
  COMPONENTS="$COMPONENTS ifuse:master"
fi
if test -z "$NO_CLONE"; then
echo
echo -e "${CYAN}######## UPDATING SOURCES ########${NORMAL}"
echo
for I in $COMPONENTS; do
  COMP=`echo $I |cut -d ":" -f 1`;
  CVER=`echo $I |cut -d ":" -f 2`;
  if test -d "$COMP/.git" && ! test -f "$COMP/.git/shallow"; then
    cd $COMP
    if test -z "`git branch |grep '$CVER'`"; then
      git checkout $CVER --quiet || error_exit "Failed to check out $CVER"
    fi
    if test "$CVER" != "master"; then
      echo "Updating $COMP (release $CVER)";
    else
      echo "Updating $COMP";
    fi
    git reset --hard --quiet
    git pull --quiet || error_exit "Failed to pull from git $COMP"
    cd "$CURDIR"
  else
    rm -rf $COMP
    if test "$CVER" != "master"; then
      echo "Cloning $COMP (release $CVER)";
      if test "$COMP" == "libirecovery"; then
        git clone -b $CVER https://github.com/wh1te4ever/libirecovery 2>/dev/null || error_exit "Failed to clone $COMP"
      else
        git clone -b $CVER https://github.com/libimobiledevice/$COMP 2>/dev/null || error_exit "Failed to clone $COMP"
      fi
    else
      echo "Cloning $COMP (master)";
      if test "$COMP" == "libirecovery"; then
        git clone https://github.com/wh1te4ever/libirecovery 2>/dev/null || error_exit "Failed to clone $COMP"
      else
        git clone https://github.com/libimobiledevice/$COMP 2>/dev/null || error_exit "Failed to clone $COMP"
      fi
    fi
  fi
done
fi

#############################################################################
echo
echo -e "${CYAN}######## STARTING BUILD ########${NORMAL}"
echo
#############################################################################



export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"

LIBCURL_VERSION=`/usr/bin/curl-config --version |cut -d " " -f 2`
LIBXML2_VERSION=`/usr/bin/xml2-config --version |cut -d " " -f 2`
READLINE_VERSION=`grep RT_READLINE_VERSION "${SDKDIR}/usr/include/readline/readline.h" |awk '{ print $NF }'`
READLINE_CFLAGS="-I${SDKDIR}/usr/include"
READLINE_LIBS="${SDKDIR}/usr/lib/libreadline.tbd"

#############################################################################
COMP=libplist
echo -e "${BOLD}#### Building libplist ####${NORMAL}"
cd libplist
echo -e "[*] Configuring..."
STEP=configure
LOGF=$CURDIR/${COMP}_${STEP}.log
./autogen.sh --prefix="$PREFIX" --without-cython > "$LOGF" 2>&1 || error_out
echo -e "[*] Building..."
STEP=build
LOGF=$CURDIR/${COMP}_${STEP}.log
make clean > /dev/null 2>&1
make V=1 > "$LOGF" 2>&1 || error_out
echo -e "[*] Installing..."
STEP=install
LOGF=$CURDIR/${COMP}_${STEP}.log
$INSTALL_SUDO make install > "$LOGF" 2>&1 || error_out
LIBPLIST_CFLAGS="-I$PREFIX/include"
LIBPLIST_LIBS="-L$PREFIX/lib -lplist-2.0"
LIBPLIST_VERSION=`cat src/libplist-2.0.pc |grep Version: |cut -d " " -f 2`
cd "$CURDIR"

#############################################################################
COMP=libimobiledevice-glue
echo -e "${BOLD}#### Building libimobiledevice-glue ####${NORMAL}"
cd libimobiledevice-glue
echo -e "[*] Configuring..."
STEP=configure
LOGF=$CURDIR/${COMP}_${STEP}.log
./autogen.sh --prefix="$PREFIX" libplist_CFLAGS="$LIBPLIST_CFLAGS" libplist_LIBS="$LIBPLIST_LIBS" libplist_VERSION="$LIBPLIST_VERSION" > "$LOGF" 2>&1 || error_out
echo -e "[*] Building..."
STEP=build
LOGF=$CURDIR/${COMP}_${STEP}.log
make clean > /dev/null 2>&1
make V=1 > "$LOGF" 2>&1 || error_out
echo -e "[*] Installing..."
STEP=install
LOGF=$CURDIR/${COMP}_${STEP}.log
$INSTALL_SUDO make install > "$LOGF" 2>&1 || error_out
LIMD_GLUE_CFLAGS="-I$PREFIX/include"
LIMD_GLUE_LIBS="-L$PREFIX/lib -limobiledevice-glue-1.0"
LIMD_GLUE_VERSION=`cat src/libimobiledevice-glue-1.0.pc |grep Version: |cut -d " " -f 2`
cd "$CURDIR"

#############################################################################
COMP=libtatsu
echo -e "${BOLD}#### Building libtatsu ####${NORMAL}"
cd libtatsu
echo -e "[*] Configuring..."
STEP=configure
LOGF=$CURDIR/${COMP}_${STEP}.log
./autogen.sh --prefix="$PREFIX" \
  libplist_CFLAGS="$LIBPLIST_CFLAGS" libplist_LIBS="$LIBPLIST_LIBS" libplist_VERSION="$LIBPLIST_VERSION" \
  libcurl_CFLAGS="-I$SDKDIR/usr/include" libcurl_LIBS="-lcurl" libcurl_VERSION="$LIBCURL_VERSION" > "$LOGF" 2>&1 || error_out
echo -e "[*] Building..."
STEP=build
LOGF=$CURDIR/${COMP}_${STEP}.log
make clean > /dev/null 2>&1
make V=1 > "$LOGF" 2>&1 || error_out
echo -e "[*] Installing..."
STEP=install
LOGF=$CURDIR/${COMP}_${STEP}.log
$INSTALL_SUDO make install > "$LOGF" 2>&1 || error_out
LIBTATSU_CFLAGS="-I$PREFIX/include"
LIBTATSU_LIBS="-L$PREFIX/lib -ltatsu"
LIBTATSU_VERSION=`cat src/libtatsu-1.0.pc |grep Version: |cut -d " " -f 2`
cd "$CURDIR"

#############################################################################
COMP=libusbmuxd
echo -e "${BOLD}#### Building libusbmuxd ####${NORMAL}"
cd libusbmuxd
echo -e "[*] Configuring..."
STEP=configure
LOGF=$CURDIR/${COMP}_${STEP}.log
./autogen.sh --prefix="$PREFIX" libplist_CFLAGS="$LIBPLIST_CFLAGS" libplist_LIBS="$LIBPLIST_LIBS" libplist_VERSION="$LIBPLIST_VERSION" limd_glue_CFLAGS="$LIMD_GLUE_CFLAGS" limd_glue_LIBS="$LIMD_GLUE_LIBS" limd_glue_VERSION="$LIMD_GLUE_VERSION" > "$LOGF" 2>&1 || error_out
echo -e "[*] Building..."
STEP=build
LOGF=$CURDIR/${COMP}_${STEP}.log
make clean > /dev/null 2>&1
make V=1 > "$LOGF" 2>&1 || error_out
echo -e "[*] Installing..."
STEP=install
LOGF=$CURDIR/${COMP}_${STEP}.log
$INSTALL_SUDO make install > "$LOGF" 2>&1 || error_out
LIBUSBMUXD_CFLAGS="-I$PREFIX/include"
LIBUSBMUXD_LIBS="-L$PREFIX/lib -lusbmuxd-2.0"
LIBUSBMUXD_VERSION=`cat src/libusbmuxd-2.0.pc |grep Version: |cut -d " " -f 2`
cd "$CURDIR"

#############################################################################
COMP=libimobiledevice
echo -e "${BOLD}#### Building libimobiledevice ####${NORMAL}"
cd libimobiledevice
echo -e "[*] Configuring..."
STEP=configure
LOGF=$CURDIR/${COMP}_${STEP}.log
./autogen.sh --prefix="$PREFIX" --enable-debug --without-cython \
  openssl_CFLAGS="-I$DEPSDIR/libressl-$LIBRESSL_VER/include" openssl_LIBS="-Xlinker $LIBSSL -Xlinker $LIBCRYPTO" openssl_VERSION="$LIBRESSL_VER" \
  libplist_CFLAGS="$LIBPLIST_CFLAGS" libplist_LIBS="$LIBPLIST_LIBS" libplist_VERSION="$LIBPLIST_VERSION" \
  libusbmuxd_CFLAGS="$LIBUSBMUXD_CFLAGS" libusbmuxd_LIBS="$LIBUSBMUXD_LIBS" libusbmuxd_VERSION="$LIBUSBMUXD_VERSION" \
  limd_glue_CFLAGS="$LIMD_GLUE_CFLAGS" limd_glue_LIBS="$LIMD_GLUE_LIBS" limd_glue_VERSION="$LIMD_GLUE_VERSION" \
  libtatsu_CFLAGS="$LIBTATSU_CFLAGS" libtatsu_LIBS="$LIBTATSU_LIBS" libtatsu_VERSION="$LIBTATSU_VERSION" \
  readline_CFLAGS="$READLINE_CFLAGS" readline_LIBS="$READLINE_LIBS" readline_VERSION="$READLINE_VERSION" \
  > "$LOGF" 2>&1 || error_out
echo -e "[*] Building..."
STEP=build
LOGF=$CURDIR/${COMP}_${STEP}.log
make clean > /dev/null 2>&1
make V=1 > "$LOGF" 2>&1 || error_out
echo -e "[*] Installing..."
STEP=install
LOGF=$CURDIR/${COMP}_${STEP}.log
$INSTALL_SUDO make install > "$LOGF" 2>&1 || error_out
LIMD_CFLAGS="-I$PREFIX/include"
LIMD_LIBS="-L$PREFIX/lib -limobiledevice-1.0 -lplist-2.0"
LIMD_VERSION=`cat src/libimobiledevice-1.0.pc |grep Version: |cut -d " " -f 2`
cd "$CURDIR"

#############################################################################
COMP=libirecovery
echo -e "${BOLD}#### Building libirecovery ####${NORMAL}"
cd libirecovery
echo -e "[*] Configuring..."
STEP=configure
LOGF=$CURDIR/${COMP}_${STEP}.log
./autogen.sh --prefix="$PREFIX" limd_glue_CFLAGS="$LIMD_GLUE_CFLAGS" limd_glue_LIBS="$LIMD_GLUE_LIBS" limd_glue_VERSION="$LIMD_GLUE_VERSION" > "$LOGF" 2>&1 || error_out
echo -e "[*] Building..."
STEP=build
LOGF=$CURDIR/${COMP}_${STEP}.log
make clean > /dev/null 2>&1
make V=1 > "$LOGF" 2>&1 || error_out
echo -e "[*] Installing..."
STEP=install
LOGF=$CURDIR/${COMP}_${STEP}.log
$INSTALL_SUDO make install > "$LOGF" 2>&1 || error_out
IRECV_CFLAGS="-I$PREFIX/include"
IRECV_LIBS="-L$PREFIX/lib -lirecovery-1.0"
IRECV_VERSION=`cat src/libirecovery-1.0.pc |grep Version: |cut -d " " -f 2`
cd "$CURDIR"

#############################################################################
COMP=idevicerestore
echo -e "${BOLD}#### Building idevicerestore ####${NORMAL}"
cd idevicerestore
echo -e "[*] Configuring..."
STEP=configure
LOGF=$CURDIR/${COMP}_${STEP}.log
./autogen.sh --prefix="$PREFIX" \
  openssl_CFLAGS="-I$DEPSDIR/libressl-$LIBRESSL_VER/include" openssl_LIBS="-Xlinker $LIBSSL -Xlinker $LIBCRYPTO" openssl_VERSION="$LIBRESSL_VER" \
  libcurl_CFLAGS="-I$SDKDIR/usr/include" libcurl_LIBS="-lcurl" libcurl_VERSION="$LIBCURL_VERSION" \
  libzip_CFLAGS="$LIBZIP_CFLAGS" libzip_LIBS="$LIBZIP_LIBS" libzip_VERSION="$LIBZIP_VERSION" \
  zlib_CFLAGS="-I$SDKDIR/usr/include" zlib_LIBS="-lz" zlib_VERSION="1.2" \
  libimobiledevice_CFLAGS="$LIMD_CFLAGS" libimobiledevice_LIBS="$LIMD_LIBS" libimobiledevice_VERSION="$LIMD_VERSION" \
  libusbmuxd_CFLAGS="$LIBUSBMUXD_CFLAGS" libusbmuxd_LIBS="$LIBUSBMUXD_LIBS" libusbmuxd_VERSION="$LIBUSBMUXD_VERSION" \
  libirecovery_CFLAGS="$IRECV_CFLAGS" libirecovery_LIBS="$IRECV_LIBS" libirecovery_VERSION="$IRECV_VERSION" \
  libplist_CFLAGS="$LIBPLIST_CFLAGS" libplist_LIBS="$LIBPLIST_LIBS" libplist_VERSION="$LIBPLIST_VERSION" \
  limd_glue_CFLAGS="$LIMD_GLUE_CFLAGS" limd_glue_LIBS="$LIMD_GLUE_LIBS" limd_glue_VERSION="$LIMD_GLUE_VERSION" \
  libtatsu_CFLAGS="$LIBTATSU_CFLAGS" libtatsu_LIBS="$LIBTATSU_LIBS" libtatsu_VERSION="$LIBTATSU_VERSION" \
  > "$LOGF" 2>&1 || error_out
echo -e "[*] Building..."
STEP=build
LOGF=$CURDIR/${COMP}_${STEP}.log
make clean > /dev/null 2>&1
make V=1 > "$LOGF" 2>&1 || error_out
echo -e "[*] Installing..."
STEP=install
LOGF=$CURDIR/${COMP}_${STEP}.log
$INSTALL_SUDO make install > "$LOGF" 2>&1 || error_out
cd "$CURDIR"

#############################################################################
COMP=libideviceactivation
echo -e "${BOLD}#### Building libideviceactivation ####${NORMAL}"
cd libideviceactivation
echo -e "[*] Configuring..."
STEP=configure
LOGF=$CURDIR/${COMP}_${STEP}.log
./autogen.sh --prefix="$PREFIX" \
  libcurl_CFLAGS="-I$SDKDIR/usr/include" libcurl_LIBS="-lcurl" libcurl_VERSION="$LIBCURL_VERSION" \
  libxml2_CFLAGS="-I$SDKDIR/usr/include/libxml2" libxml2_LIBS="-lxml2" libxml2_VERSION="$LIBXML2_VERSION" \
  libimobiledevice_CFLAGS="$LIMD_CFLAGS" libimobiledevice_LIBS="$LIMD_LIBS" libimobiledevice_VERSION="$LIMD_VERSION" \
  libplist_CFLAGS="$LIBPLIST_CFLAGS" libplist_LIBS="$LIBPLIST_LIBS" libplist_VERSION="$LIBPLIST_VERSION" \
  > "$LOGF" 2>&1 || error_out
echo -e "[*] Building..."
STEP=build
LOGF=$CURDIR/${COMP}_${STEP}.log
make clean > /dev/null 2>&1
make V=1 > "$LOGF" 2>&1 || error_out
echo -e "[*] Installing..."
STEP=install
LOGF=$CURDIR/${COMP}_${STEP}.log
$INSTALL_SUDO make install > "$LOGF" 2>&1 || error_out
cd "$CURDIR"

#############################################################################
COMP=ideviceinstaller
echo -e "${BOLD}#### Building ideviceinstaller ####${NORMAL}"
cd ideviceinstaller
echo -e "[*] Configuring..."
STEP=configure
LOGF=$CURDIR/${COMP}_${STEP}.log
./autogen.sh --prefix="$PREFIX" \
  libzip_CFLAGS="$LIBZIP_CFLAGS" libzip_LIBS="$LIBZIP_LIBS" libzip_VERSION="$LIBZIP_VERSION" \
  libimobiledevice_CFLAGS="$LIMD_CFLAGS" libimobiledevice_LIBS="$LIMD_LIBS" libimobiledevice_VERSION="$LIMD_VERSION" \
  libplist_CFLAGS="$LIBPLIST_CFLAGS" libplist_LIBS="$LIBPLIST_LIBS" libplist_VERSION="$LIBPLIST_VERSION" \
  > "$LOGF" 2>&1 || error_out
echo -e "[*] Building..."
STEP=build
LOGF=$CURDIR/${COMP}_${STEP}.log
make clean > /dev/null 2>&1
make V=1 > "$LOGF" 2>&1 || error_out
echo -e "[*] Installing..."
STEP=install
LOGF=$CURDIR/${COMP}_${STEP}.log
$INSTALL_SUDO make install > "$LOGF" 2>&1 || error_out
cd "$CURDIR"

#############################################################################
if test "$HAVE_MACFUSE" == "yes"; then
  COMP=ifuse
  echo -e "${BOLD}#### Building ifuse ####${NORMAL}"
  cd ifuse
  echo -e "[*] Configuring..."
  STEP=configure
  LOGF=$CURDIR/${COMP}_${STEP}.log
  ./autogen.sh --prefix="$PREFIX" \
    libfuse_CFLAGS="-I/usr/local/include/fuse3 -D_FILE_OFFSET_BITS=64" libfuse_LIBS="-L/usr/local/lib -lfuse3 -pthread" \
    libimobiledevice_CFLAGS="$LIMD_CFLAGS" libimobiledevice_LIBS="$LIMD_LIBS" libimobiledevice_VERSION="$LIMD_VERSION" \
    libplist_CFLAGS="$LIBPLIST_CFLAGS" libplist_LIBS="$LIBPLIST_LIBS" libplist_VERSION="$LIBPLIST_VERSION" \
    > "$LOGF" 2>&1 || error_out
  echo -e "[*] Building..."
  STEP=build
  LOGF=$CURDIR/${COMP}_${STEP}.log
  make clean > /dev/null 2>&1
  make V=1 > "$LOGF" 2>&1 || error_out
  echo -e "[*] Installing..."
  STEP=install
  LOGF=$CURDIR/${COMP}_${STEP}.log
  $INSTALL_SUDO make install > "$LOGF" 2>&1 || error_out
  cd "$CURDIR"
fi

#############################################################################
echo
echo -e "${CYAN}######## BUILD COMPLETE ########${NORMAL}"
echo
echo -e "${BOLD}If you like this script and my work on libimobiledevice, please
consider becoming a patron at ${YELLOW}https://patreon.com/nikias${NORMAL}"
echo -e "${BOLD}or a GitHub sponsor: ${YELLOW}https://github.com/sponsors/nikias${NORMAL}"
echo -e "${BOLD}or send some love via PayPal: ${YELLOW}https://www.paypal.me/NikiasBassen${NORMAL}"
echo -e "${BOLD}Thanks ${RED}<3${NORMAL}"
echo
#############################################################################