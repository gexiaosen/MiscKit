APP_NAME := MiscKit
# 构建产物放在 iCloud 同步目录之外：~/Documents 下的 file provider 会给产物贴
# xattr（FinderInfo / fpfs），codesign 会拒绝签名。原因详见 Scripts/make-app.sh 顶部。
SCRATCH ?= $(HOME)/.cache/misckit-build
APP := $(SCRATCH)/product/$(APP_NAME).app
CONFIG ?= debug
SWIFT_FLAGS := --arch arm64 --scratch-path $(SCRATCH)

.PHONY: all app run test scan build clean hotkey-log install

all: app

build:
	swift build -c $(CONFIG) $(SWIFT_FLAGS)

app:
	./Scripts/make-app.sh $(CONFIG)

run: app
	open $(APP)

# 装进 /Applications 后把旧实例正常退出、拉起新的（失败不会留半旧半新）
install:
	./Scripts/install.sh

test:
	swift test $(SWIFT_FLAGS)

scan:
	./Scripts/scan-secrets.sh --selftest && ./Scripts/scan-secrets.sh

clean:
	rm -rf $(SCRATCH) .build

# 观察唤起延迟与面板状态（summon→visible 基准沿用 ≤100ms）
hotkey-log:
	log stream --predicate 'subsystem == "app.misckit.launcher"' --level info
