SHELL := /bin/bash
.DEFAULT_GOAL := all

.PHONY: all app dmg test clean distclean

all: dmg

app:
	@bash scripts/build-app.sh

dmg: app
	@bash scripts/make-dmg.sh

test:
	@go test ./...
	@swift test --package-path macos --disable-sandbox

clean:
	@rm -rf build/DitKit.app build/dmg-staging
	@rm -f build/ditkitd build/DitKit-*.dmg build/DitKit.dmg build/DitKit-rw.dmg
	@rm -f build/background-*.png build/background-*.tiff
	@echo "已清理 build/ 内产物与中间文件（保留 build/py 与 macos/.build 缓存）"

distclean: clean
	@rm -rf macos/.build macos/build build/py
	@echo "已清理全部构建缓存，下次构建会重新编译"
