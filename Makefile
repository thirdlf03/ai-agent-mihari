.PHONY: help setup fmt lint build run test clean app-build app-run

help:
	@echo "make setup         - bridge/ の Python 依存を同期する(初回セットアップ)"
	@echo "make build         - Mihari.app をビルドして ad-hoc 署名する"
	@echo "make run           - Mihari.app をビルドして起動する"
	@echo "make test          - desktop/ のテストを実行する"
	@echo "make fmt           - Swift / Python のコードを整形する"
	@echo "make lint          - Swift / Python のフォーマットと lint を検査する"
	@echo "make clean         - ビルド成果物を削除する"
	@echo ""
	@echo "make app-build     - (参照用) 旧 app/ をビルドする"
	@echo "make app-run       - (参照用) 旧 app/ を起動する"

setup:
	cd bridge && uv sync

build:
	cd desktop && ./build.sh

run:
	cd desktop && ./run.sh

test:
	cd desktop && swift test

fmt:
	cd desktop && swift format --in-place --recursive Sources Tests
	cd app && swift format --in-place --recursive Sources
	cd bridge && uv run ruff format . && uv run ruff check --fix .

lint:
	cd desktop && swift format lint --strict --recursive Sources Tests
	cd app && swift format lint --strict --recursive Sources
	cd bridge && uv run ruff check . && uv run ruff format --check .

clean:
	rm -rf desktop/.build desktop/Mihari.app app/.build

app-build:
	cd app && swift build

app-run:
	cd app && swift run
