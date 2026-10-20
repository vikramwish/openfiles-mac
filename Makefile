.PHONY: build run test release
build:
	./scripts/build-app.sh
run:
	./scripts/run.sh
test:
	./scripts/test.sh
release:
	./scripts/build-app.sh release
