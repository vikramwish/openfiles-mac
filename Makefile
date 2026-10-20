.PHONY: build run test test-cloud release
build:
	./scripts/build-app.sh
run:
	./scripts/run.sh
test:
	./scripts/test.sh
test-cloud:
	swift run --build-system native OpenFilesCloudChecks
release:
	./scripts/build-app.sh release
