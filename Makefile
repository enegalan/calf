.PHONY: help ui build clean dev dev-backend dev-ui

help:
	@echo "Calf — common commands"
	@echo ""
	@echo "  make dev-backend   API daemon on :8765 (terminal 1)"
	@echo "  make dev-ui        Flutter app on macOS (terminal 2)"
	@echo ""
	@echo "  make ui            build macOS app"
	@echo "  make build         build macOS app"
	@echo "  make clean         remove build artifacts"
	@echo ""
	@echo "Full guide: DEVELOPMENT.md"

ui:
	cd ui && flutter build macos

build: ui

clean:
	cd ui && flutter clean

dev-backend:
	cd backend && CGO_ENABLED=0 go run ./cmd/calf

dev-ui:
	cd ui && flutter run -d macos

dev: help
