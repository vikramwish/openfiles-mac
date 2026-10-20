.PHONY: build run test test-cloud test-window-sizing release
build:
	./scripts/build-app.sh
run:
	./scripts/run.sh
test:
	./scripts/test.sh
test-cloud:
	swift run --build-system native OpenFilesCloudChecks
test-window-sizing:
	./scripts/test-window-sizing.sh
release:
	./scripts/build-app.sh release
