## Quick start

**1. Start the API** (port `8080`):

```bash
cd backend
go run .
```

**2. Start the UI** (in another terminal):

```bash
cd ui
flutter pub get
flutter run
```

Pick a device when prompted (`chrome`, `macos`, etc.). The UI calls the API on startup and shows the response.
