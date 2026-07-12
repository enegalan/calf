.PHONY: help format format-backend format-ui format-check format-check-backend \
        format-check-ui ui-macos clean dev dev-backend dev-ui-macos verify-docker-cli \
        release-macos ui-linux ui-windows dev-ui-linux dev-ui-windows release-linux \
        release-windows release package-macos package-windows package-linux package \
        homebrew-cask

help:
	@echo "Calf — common commands"
	@echo ""
	@echo "  make dev-backend        API daemon on :8765 (terminal 1)"

	@echo "  make dev-ui-macos       Flutter app on macOS (terminal 2)"
	@echo "  make dev-ui-linux       Flutter app on Linux (terminal 2)"
	@echo "  make dev-ui-windows     Flutter app on Windows (terminal 2)"

	@echo ""
	@echo "  make ui-macos           build macOS app"
	@echo "  make ui-linux           build Linux app"
	@echo "  make ui-windows         build Windows app"

	@echo ""
	@echo "  make release-macos      build Go daemon + macOS app"
	@echo "  make release-linux      build Go daemon + Linux app"
	@echo "  make release-windows    build Go daemon + Windows app"
	@echo "  make release            build for all platforms (macOS + Linux + Windows)"
	@echo ""
	@echo "  make package-macos      create macOS .dmg and .pkg installers"
	@echo "  make package-linux      create Linux .deb, .rpm, and AppImage installers"
	@echo "  make package-windows    create Windows .exe installer"
	@echo ""
	@echo "  make format             format Go + Dart sources"
	@echo "  make format-backend     gofmt backend/"
	@echo "  make format-ui          dart format ui/"
	@echo "  make format-check       verify Go + Dart formatting (CI)"
	@echo ""
	@echo "  make clean              remove build artifacts"
	@echo "  make verify-docker-cli  smoke-test docker CLI against Calf"
	@echo ""
	@echo "Full guide: DEVELOPMENT.md"

format: format-backend format-ui

format-backend:
	cd backend && gofmt -w .

format-ui:
	cd ui && dart format .

format-check: format-check-backend format-check-ui

format-check-backend:
	@test -z "$$(cd backend && gofmt -l .)" || (echo "Run 'make format-backend' to fix:"; cd backend && gofmt -l .; exit 1)

format-check-ui:
	cd ui && dart format --output=none --set-exit-if-changed .

ui-macos:
	cd ui && flutter build macos

ui-linux:
	cd ui && flutter build linux

ui-windows:
	cd ui && flutter build windows

release: release-macos release-linux release-windows

release-macos:
	cd backend && CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -o calf-daemon-amd64 ./cmd/calf
	cd backend && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -o calf-daemon-arm64 ./cmd/calf
	lipo -create -output backend/calf-daemon backend/calf-daemon-amd64 backend/calf-daemon-arm64
	rm backend/calf-daemon-amd64 backend/calf-daemon-arm64
	cd ui && flutter build macos
	cp backend/calf-daemon ui/build/macos/Build/Products/Release/Calf.app/Contents/MacOS/calf-daemon
	rm backend/calf-daemon
	codesign --force --sign - --identifier com.enegalan.calf.daemon ui/build/macos/Build/Products/Release/Calf.app/Contents/MacOS/calf-daemon
	codesign --force --sign - --entitlements ui/macos/Runner/Release.entitlements ui/build/macos/Build/Products/Release/Calf.app
	codesign --verify --deep --strict ui/build/macos/Build/Products/Release/Calf.app

release-linux: ui-linux
	cd backend && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o calf-daemon ./cmd/calf
	cp backend/calf-daemon ui/build/linux/x64/release/bundle/calf-daemon
	rm backend/calf-daemon

release-windows: ui-windows
	cd backend && CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -o calf-daemon.exe ./cmd/calf
	cp backend/calf-daemon.exe ui/build/windows/x64/runner/Release/calf-daemon.exe
	rm backend/calf-daemon.exe


package: package-macos package-windows package-linux

package-macos: release-macos
	./scripts/package-macos.sh

homebrew-cask:
	./scripts/update-homebrew.sh

package-windows: release-windows
	pwsh -ExecutionPolicy Bypass -File scripts/package-windows.ps1

package-linux: release-linux
	./scripts/package-linux.sh

clean:
	cd ui && flutter clean

dev-backend:
	cd backend && CGO_ENABLED=0 go run ./cmd/calf

dev-ui-macos:
	cd ui && flutter run -d macos --dart-define=CALF_EXTERNAL_DAEMON=true

dev-ui-linux:
	cd ui && flutter run -d linux

dev-ui-windows:
	cd ui && flutter run -d windows

verify-docker-cli:
	./scripts/verify-docker-cli.sh

dev: help
