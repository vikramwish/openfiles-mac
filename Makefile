.PHONY: build run test test-cloud release
build:
	./scripts/build-app.sh
run:
	./scripts/run.sh
test:
	swift run --build-system native OpenFilesChecks
	swift run --build-system native OpenFilesCloudChecks
test-cloud:
	swift run --build-system native OpenFilesCloudChecks
release:
	./scripts/build-app.sh release
