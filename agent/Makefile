VERSION ?= 0.3.5
LDFLAGS := -s -w -X main.version=$(VERSION)
OUT := dist
IOS_RES := ../ios/ServerMonitor/Resources/Agent

.PHONY: test build ios-resources clean
test:
	go vet ./... && go test -race -count=1 ./...

build:
	mkdir -p $(OUT)
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "$(LDFLAGS)" -o $(OUT)/srvmon-agent-linux-amd64 .
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags "$(LDFLAGS)" -o $(OUT)/srvmon-agent-linux-arm64 .
	cd $(OUT) && sha256sum srvmon-agent-linux-* > SHA256SUMS

# Copies binaries + install scripts into the iOS app bundle.
ios-resources: build
	mkdir -p $(IOS_RES)
	cp $(OUT)/srvmon-agent-linux-amd64 $(OUT)/srvmon-agent-linux-arm64 $(OUT)/SHA256SUMS scripts/install.sh scripts/uninstall.sh $(IOS_RES)/
	echo $(VERSION) > $(IOS_RES)/VERSION

clean:
	rm -rf $(OUT)
