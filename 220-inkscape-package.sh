#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# This file is part of the build pipeline for Inkscape on macOS.
#
# ### 220-inkscape-package.sh ###
# Create Inkscape application bundle.

### load settings and functions ################################################

SELF_DIR=$(F=$0; while [ ! -z $(readlink $F) ] && F=$(readlink $F); cd $(dirname $F); F=$(basename $F); [ -L $F ]; do :; done; echo $(pwd -P))
for script in $SELF_DIR/0??-*.sh; do source $script; done

include_file error_.sh
error_trace_enable

### create application bundle ##################################################

mkdir -p $ARTIFACT_DIR

( # use subshell to fence temporary variables

  BUILD_DIR=$SRC_DIR/gtk-mac-bundler.build
  mkdir -p $BUILD_DIR

  cp $SELF_DIR/inkscape.bundle $BUILD_DIR
  cp $SELF_DIR/inkscape.plist $BUILD_DIR

  export ARTIFACT_DIR   # referenced in inkscape.bundle
  cd $BUILD_DIR
  jhbuild run gtk-mac-bundler inkscape.bundle
)

# Rename to get from lowercase to capitalized "i". This works only on
# case-insensitive filesystems (default on macOS).

mv $APP_DIR $APP_DIR.tmp
mv $APP_DIR.tmp $APP_DIR

# patch library link paths for lib2geom
lib_change_path \
  @executable_path/../Resources/lib/lib2geom.1.0.0.dylib \
  $APP_LIB_DIR/inkscape/libinkscape_base.dylib \
  $APP_EXE_DIR/inkscape

# patch library link path for libinkscape_base
lib_change_path \
  @executable_path/../Resources/lib/inkscape/libinkscape_base.dylib \
  $APP_EXE_DIR/inkscape

lib_change_siblings $APP_LIB_DIR

# update Inkscape version information
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString '$(get_inkscape_version) ($(get_repo_version $INK_DIR))'" $APP_PLIST
/usr/libexec/PlistBuddy -c "Set CFBundleVersion '$(get_inkscape_version) ($(get_repo_version $INK_DIR))'" $APP_PLIST

# update minimum system version according to deployment target
/usr/libexec/PlistBuddy -c "Set LSMinimumSystemVersion '$MACOSX_DEPLOYMENT_TARGET'" $APP_PLIST

### generate application icon ##################################################

# svg to png

(
  export DYLD_FALLBACK_LIBRARY_PATH=$LIB_DIR
  jhbuild run cairosvg -f png -s 8 -o $SRC_DIR/inkscape.png $INK_DIR/share/branding/inkscape.svg
)

# png to icns

cd $SRC_DIR   # png2icns.sh outputs to current directory
png2icns.sh inkscape.png
mv inkscape.icns $APP_RES_DIR

### bundle Python.framework ####################################################

# This section deals with bundling Python.framework into the application.

mkdir $APP_FRA_DIR
install_source file://$SRC_DIR/$(basename $URL_PYTHON) $APP_FRA_DIR --exclude="Versions/$PY3_MAJOR.$PY3_MINOR/lib/python$PY3_MAJOR.$PY3_MINOR/test/"'*'

# link it to $APP_BIN_DIR so it'll be in $PATH for the app
ln -sf ../../Frameworks/Python.framework/Versions/Current/bin/python$PY3_MAJOR $APP_BIN_DIR

# create '.pth' file inside Framework to include our site-packages directory
echo "./../../../../../../../Resources/lib/python$PY3_MAJOR.$PY3_MINOR/site-packages" > $APP_FRA_DIR/Python.framework/Versions/Current/lib/python$PY3_MAJOR.$PY3_MINOR/site-packages/inkscape.pth

### install Python package: lxml ###############################################

pip_install $PYTHON_LXML

### install Python package: NumPy ##############################################

pip_install $PYTHON_NUMPY

### install Python package: PyGObject ##########################################

pip_install $PYTHON_PYGOBJECT

# patch '_gi'
lib_change_paths \
  @loader_path/../../.. \
  $APP_LIB_DIR \
  $APP_LIB_DIR/python$PY3_MAJOR.$PY3_MINOR/site-packages/gi/_gi.cpython-$PY3_MAJOR${PY3_MINOR}-darwin.so

# patch '_gi_cairo'
lib_change_paths \
  @loader_path/../../.. \
  $APP_LIB_DIR \
  $APP_LIB_DIR/python$PY3_MAJOR.$PY3_MINOR/site-packages/gi/_gi_cairo.cpython-$PY3_MAJOR${PY3_MINOR}-darwin.so

### install Python package: Pycairo ############################################

# This package got pulled in by PyGObject.

# patch '_cairo'
lib_change_paths \
  @loader_path/../../.. \
  $APP_LIB_DIR \
  $APP_LIB_DIR/python$PY3_MAJOR.$PY3_MINOR/site-packages/cairo/_cairo.cpython-$PY3_MAJOR${PY3_MINOR}-darwin.so

### install Python package: pySerial ###########################################

pip_install $PYTHON_PYSERIAL

### install Python package: Scour ##############################################

pip_install $PYTHON_SCOUR

### precompile all Python packages #############################################

$APP_FRA_DIR/Python.framework/Versions/Current/bin/python$PY3_MAJOR -m compileall -f $APP_DIR || true

### fontconfig #################################################################

# Mimic the behavior of having all files under 'share' and linking the
# active ones to 'etc'.
cd $APP_ETC_DIR/fonts/conf.d

for file in ./*.conf; do
  ln -sf ../../../share/fontconfig/conf.avail/$(basename $file)
done

# Our customized version loses all the non-macOS paths and sets a cache
# directory below '$HOME/Library/Application Support/Inkscape'.
cp $SELF_DIR/fonts.conf $APP_ETC_DIR/fonts

### Ghostscript ################################################################

# patch gs
lib_change_paths \
  @executable_path/../lib \
  $APP_LIB_DIR \
  $APP_BIN_DIR/gs

### create GObject introspection repository ####################################

mkdir $APP_LIB_DIR/girepository-1.0

# remove fully qualified paths from libraries in *.gir files
for gir in $WRK_DIR/share/gir-1.0/*.gir; do
  sed "s/$(escape_sed $LIB_DIR/)//g" $gir > $SRC_DIR/$(basename $gir)
done

# compile *.gir into *.typelib files
for gir in $SRC_DIR/*.gir; do
  jhbuild run g-ir-compiler -o $APP_LIB_DIR/girepository-1.0/$(basename -s .gir $gir).typelib $gir
done
