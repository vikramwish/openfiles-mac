.PHONY: build run test release
build:
	./scripts/build-app.sh
run:
	./scripts/run.sh
test:
	swift run --build-system native OpenFilesChecks
release:
	./scripts/build-app.sh release
