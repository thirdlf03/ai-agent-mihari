.PHONY: help setup fmt lint lint-swift lint-python build run clean

help:
	@echo "make setup  - bridge/ の Python 依存を同期する(初回セットアップ)"
	@echo "make fmt    - Swift / Python のコードを整形する"
	@echo "make lint   - Swift / Python のフォーマットと lint を検査する"
	@echo "             (lint-swift / lint-python で片側だけ実行できる)"
	@echo "make build  - macOS アプリをビルドする"
	@echo "make run    - macOS アプリを起動する"
	@echo "make clean  - ビルド成果物を削除する"

setup:
	cd bridge && uv sync

fmt:
	cd app && swift format --in-place --recursive Sources
	cd bridge && uv run ruff format . && uv run ruff check --fix .

lint: lint-swift lint-python

lint-swift:
	cd app && swift format lint --strict --recursive Sources

lint-python:
	cd bridge && uv run ruff check . && uv run ruff format --check .

build:
	cd app && swift build

run:
	cd app && swift run

clean:
	rm -rf app/.build
