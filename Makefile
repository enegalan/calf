.PHONY: backend ui build clean

backend:
	cd backend && go build -o ../bin/calf ./cmd/calf

ui:
	cd ui && flutter build macos

build: backend ui

clean:
	rm -rf bin
	cd ui && flutter clean
