#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/_common.sh"

VERSION=$(extract_version)
ARCH="amd64"
BUNDLE="ui/build/linux/x64/release/bundle"
DESKTOP_SOURCE="ui/linux/com.enegalan.ui.desktop"
ICON_NAME="com.enegalan.ui"
LINUX_BUILD_DIR="$BUILD_DIR/linux"

require_directory "$BUNDLE" "run 'make release-linux' first"
require_command dpkg-deb
require_command rpmbuild
require_command wget
require_command sha256sum

mkdir -p "$DIST_DIR" "$LINUX_BUILD_DIR"

DESKTOP_DEB_RPM="$LINUX_BUILD_DIR/$APP_NAME.desktop"
DESKTOP_APPIMAGE="$LINUX_BUILD_DIR/$APP_NAME-appimage.desktop"

cp "$DESKTOP_SOURCE" "$DESKTOP_DEB_RPM"
sed -i "s|Exec=@EXECUTABLE@|Exec=/opt/$APP_NAME/ui|" "$DESKTOP_DEB_RPM"

cp "$DESKTOP_SOURCE" "$DESKTOP_APPIMAGE"
sed -i "s|Exec=@EXECUTABLE@|Exec=$APP_NAME|" "$DESKTOP_APPIMAGE"
sed -i "s|Icon=$ICON_NAME|Icon=$APP_NAME|" "$DESKTOP_APPIMAGE"

install_bundle() {
    local dest=$1
    rm -rf "$dest"
    mkdir -p "$dest/opt/$APP_NAME"
    cp -a "$BUNDLE"/* "$dest/opt/$APP_NAME/"
}

install_desktop_and_icons() {
    local dest=$1
    local desktop=$2
    mkdir -p "$dest/usr/share/applications"
    mkdir -p "$dest/usr/share/icons/hicolor"
    cp "$desktop" "$dest/usr/share/applications/$APP_NAME.desktop"
    cp -r ui/linux/icons/hicolor/* "$dest/usr/share/icons/hicolor/"
}

install_executable_link() {
    local dest=$1
    mkdir -p "$dest/usr/bin"
    ln -sf "/opt/$APP_NAME/ui" "$dest/usr/bin/$APP_NAME"
}

build_deb() {
    local deb_dir="$LINUX_BUILD_DIR/deb/$APP_NAME"
    install_bundle "$deb_dir"
    install_desktop_and_icons "$deb_dir" "$DESKTOP_DEB_RPM"
    install_executable_link "$deb_dir"
    mkdir -p "$deb_dir/DEBIAN"

    cat > "$deb_dir/DEBIAN/control" <<EOF
Package: $APP_NAME
Version: $VERSION
Section: utils
Priority: optional
Architecture: $ARCH
Depends: libgtk-3-0, libblkid1, liblzma5
Maintainer: $MAINTAINER
Description: $APP_NAME_TITLE - lightweight container manager
 $APP_NAME_TITLE is a lightweight, open-source alternative to Docker Desktop.
EOF

    dpkg-deb --build "$deb_dir" "$DIST_DIR/${APP_NAME}_${VERSION}_${ARCH}.deb"
}

build_rpm() {
    local rpmbuild="$LINUX_BUILD_DIR/rpmbuild"
    rm -rf "$rpmbuild"
    mkdir -p "$rpmbuild/SPECS" "$rpmbuild/BUILD" "$rpmbuild/RPMS" \
        "$rpmbuild/SOURCES" "$rpmbuild/SRPMS"

    cat > "$rpmbuild/SPECS/$APP_NAME.spec" <<EOF
Name: $APP_NAME
Version: %{_version}
Release: 1
Summary: $APP_NAME_TITLE - lightweight container manager
License: MIT
BuildArch: x86_64

%description
$APP_NAME_TITLE is a lightweight, open-source alternative to Docker Desktop.

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}/opt/$APP_NAME
cp -a %{_bundle}/* %{buildroot}/opt/$APP_NAME/
mkdir -p %{buildroot}/usr/share/applications
cp %{_desktop} %{buildroot}/usr/share/applications/$APP_NAME.desktop
mkdir -p %{buildroot}/usr/share/icons/hicolor
cp -r %{_icons}/* %{buildroot}/usr/share/icons/hicolor/
mkdir -p %{buildroot}/usr/bin
ln -s /opt/$APP_NAME/ui %{buildroot}/usr/bin/$APP_NAME

%files
/opt/$APP_NAME
/usr/share/applications/$APP_NAME.desktop
/usr/share/icons/hicolor
/usr/bin/$APP_NAME
EOF

    rpmbuild -bb \
        --define "_topdir $rpmbuild" \
        --define "_version $VERSION" \
        --define "_bundle $(pwd)/$BUNDLE" \
        --define "_desktop $(pwd)/$DESKTOP_DEB_RPM" \
        --define "_icons $(pwd)/ui/linux/icons/hicolor" \
        "$rpmbuild/SPECS/$APP_NAME.spec"

    cp "$rpmbuild/RPMS/x86_64/${APP_NAME}-${VERSION}-1.x86_64.rpm" "$DIST_DIR/"
}

build_appimage() {
    local appdir="$LINUX_BUILD_DIR/appimage/$APP_NAME.AppDir"
    rm -rf "$appdir"
    mkdir -p "$appdir/opt/$APP_NAME"
    cp -a "$BUNDLE"/* "$appdir/opt/$APP_NAME/"

    cp "$DESKTOP_APPIMAGE" "$appdir/$APP_NAME.desktop"
    cp "ui/linux/icons/hicolor/512x512/apps/$ICON_NAME.png" "$appdir/$APP_NAME.png"

    cat > "$appdir/AppRun" <<EOF
#!/bin/bash
HERE=\$(dirname \$(readlink -f "\${0}"))
exec "\$HERE/opt/$APP_NAME/ui" "\$@"
EOF
    chmod +x "$appdir/AppRun"

    local appimagetool
    appimagetool=$(ensure_appimagetool)

    "$appimagetool" --appimage-extract-and-run "$appdir" "$DIST_DIR/${APP_NAME_TITLE}-${VERSION}-x86_64.AppImage"
}

ensure_appimagetool() {
    local version="13"
    local base_url="https://github.com/AppImage/AppImageKit/releases/download/${version}"
    local binary="appimagetool-x86_64.AppImage"
    local checksums="SHA256SUMS"
    local tmp_dir="$LINUX_BUILD_DIR/appimagetool-tmp"
    local final="$LINUX_BUILD_DIR/appimagetool"

    mkdir -p "$tmp_dir"

    wget -q "$base_url/$checksums" -O "$tmp_dir/$checksums"

    local expected
    expected=$(grep "^[^#]*$binary" "$tmp_dir/$checksums" | awk '{print $1}')
    if [[ -z "$expected" ]]; then
        echo "error: could not find checksum for $binary" >&2
        exit 1
    fi

    if [[ -f "$final" ]]; then
        local actual
        actual=$(sha256sum "$final" | awk '{print $1}')
        if [[ "$actual" == "$expected" ]]; then
            rm -rf "$tmp_dir"
            echo "$final"
            return
        fi
        rm -f "$final"
    fi

    wget -q "$base_url/$binary" -O "$tmp_dir/$binary"
    chmod +x "$tmp_dir/$binary"

    local actual
    actual=$(sha256sum "$tmp_dir/$binary" | awk '{print $1}')
    if [[ "$actual" != "$expected" ]]; then
        echo "error: checksum mismatch for appimagetool" >&2
        exit 1
    fi

    mv "$tmp_dir/$binary" "$final"
    rm -rf "$tmp_dir"
    echo "$final"
}

build_deb
build_rpm
build_appimage

echo "done: $(ls -1 "$DIST_DIR")"
