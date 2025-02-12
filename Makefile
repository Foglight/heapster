all: build

#Environment Prerequisite
#GOLANG_VERSION like 1.8, 1.12.7, etc.
#VERSION like v1.6.0-beta.1, etc.
#SUPPORTED_KUBE_VERSIONS like 1.9.3, etc.
#ARCH like amd64, etc.
#HEAPSTER_BUILD_DIR like /<some directory path>
#REPO_PREFIX like k8s.gcr.io, etc.
#DOCKERHUB_USER and DOCKERHUB_PWD should be defined previously.

FLAGS=
ALL_ARCHITECTURES=amd64 arm arm64 ppc64le s390x
ML_PLATFORMS=linux/amd64,linux/arm,linux/arm64,linux/ppc64le,linux/s390x
#GOLANG_VERSION?=1.8

ifndef TEMP_DIR
TEMP_DIR:=$(shell mktemp -d /tmp/heapster.XXXXXX)
endif

GIT_COMMIT:=$(shell git rev-parse --short HEAD)

TESTUSER=
ifdef REPO_DIR
DOCKER_IN_DOCKER=1
TESTUSER=jenkins
else
REPO_DIR:=$(shell pwd)
endif

# You can set this variable for testing and the built image will also be tagged with this name
OVERRIDE_IMAGE_NAME?=

# If this session isn't interactive, then we don't want to allocate a
# TTY, which would fail, but if it is interactive, we do want to attach
# so that the user can send e.g. ^C through.
INTERACTIVE := $(shell [ -t 0 ] && echo 1 || echo 0)
TTY=
ifeq ($(INTERACTIVE), 1)
	TTY=-t
endif

TEST_NAMESPACE=heapster-e2e-tests

HEAPSTER_LDFLAGS=-w -X k8s.io/heapster/version.HeapsterVersion=$(VERSION) -X k8s.io/heapster/version.GitCommit=$(GIT_COMMIT)

fmt:
	find . -type f -name "*.go" | grep -v "./vendor*" | xargs gofmt -s -w

build: clean fmt
	GOARCH=$(ARCH) CGO_ENABLED=0 go build -ldflags "$(HEAPSTER_LDFLAGS)" -o $(HEAPSTER_BUILD_DIR)/heapster k8s.io/heapster/metrics
	GOARCH=$(ARCH) CGO_ENABLED=0 go build -ldflags "$(HEAPSTER_LDFLAGS)" -o $(HEAPSTER_BUILD_DIR)/eventer k8s.io/heapster/events

sanitize:
	hooks/check_boilerplate.sh
	# hooks/check_gofmt.sh
	hooks/run_vet.sh

test-unit: clean sanitize build
ifeq ($(ARCH),amd64)
	GOARCH=$(ARCH) go test --test.short -race ./... $(FLAGS)
else
	GOARCH=$(ARCH) go test --test.short ./... $(FLAGS)
endif

test-unit-cov: clean sanitize build
	hooks/coverage.sh

test-integration: clean build
	go test -v --timeout=60m ./integration/... --vmodule=*=2 $(FLAGS) --namespace=$(TEST_NAMESPACE) --kube_versions=$(SUPPORTED_KUBE_VERSIONS) --test_user=$(TESTUSER) --logtostderr

container:
	# Run the build in a container in order to have reproducible builds
	# Also, fetch the latest ca certificates
	docker run --rm -i $(TTY) -v $(TEMP_DIR):/build -v $(REPO_DIR):/go/src/k8s.io/heapster -w /go/src/k8s.io/heapster golang:$(GOLANG_VERSION) /bin/bash -c "\
		cp /etc/ssl/certs/ca-certificates.crt /build \
		&& GOARCH=$(ARCH) CGO_ENABLED=0 go build -ldflags \"$(HEAPSTER_LDFLAGS)\" -o /build/heapster k8s.io/heapster/metrics \
		&& GOARCH=$(ARCH) CGO_ENABLED=0 go build -ldflags \"$(HEAPSTER_LDFLAGS)\" -o /build/eventer k8s.io/heapster/events"

build-image:
	cp $(REPO_DIR)/deploy/docker/Dockerfile $(HEAPSTER_BUILD_DIR)/Dockerfile
	docker build --pull -t $(REPO_PREFIX)/heapster-$(ARCH):$(VERSION) $(HEAPSTER_BUILD_DIR)
ifneq ($(OVERRIDE_IMAGE_NAME),)
	docker tag $(REPO_PREFIX)/heapster-$(ARCH):$(VERSION) $(OVERRIDE_IMAGE_NAME)
endif

ifndef DOCKER_IN_DOCKER
	rm -rf $(TEMP_DIR)
endif

do-push:
	docker push $(REPO_PREFIX)/heapster-$(ARCH):$(VERSION)
ifeq ($(ARCH),amd64)
# TODO: Remove this and push the manifest list as soon as it's working
	docker tag $(REPO_PREFIX)/heapster-$(ARCH):$(VERSION) $(REPO_PREFIX)/heapster:$(VERSION)
	docker push $(REPO_PREFIX)/heapster:$(VERSION)
endif

# Should depend on target: ./manifest-tool
push: docker-login $(addprefix sub-push-,$(ALL_ARCHITECTURES))
#	./manifest-tool push from-args --platforms $(ML_PLATFORMS) --template $(REPO_PREFIX)/heapster-ARCH:$(VERSION) --target $(REPO_PREFIX)/heapster:$(VERSION)

sub-push-%:
	$(MAKE) ARCH=$* REPO_PREFIX=$(REPO_PREFIX) VERSION=$(VERSION) container
	$(MAKE) ARCH=$* REPO_PREFIX=$(REPO_PREFIX) VERSION=$(VERSION) build-image
	$(MAKE) ARCH=$* REPO_PREFIX=$(REPO_PREFIX) VERSION=$(VERSION) do-push

influxdb:
	ARCH=$(ARCH) REPO_PREFIX=$(REPO_PREFIX) make -C influxdb build

grafana:
	ARCH=$(ARCH) REPO_PREFIX=$(REPO_PREFIX) make -C grafana build

push-influxdb:
	REPO_PREFIX=$(REPO_PREFIX) make -C influxdb push

push-grafana:
	REPO_PREFIX=$(REPO_PREFIX) make -C grafana push

#gcr-login:
#ifeq ($(findstring gcr.io,$(REPO_PREFIX)),gcr.io)
#	@echo "If you are pushing to a gcr.io registry, you have to be logged in via 'docker login'; 'gcloud docker push' can't push manifest lists yet."
#	@echo "This script is automatically logging you in now with 'gcloud docker -a'"
#	gcloud docker -a
#endif
docker-login:
	@echo "Docker login with user $(DOCKERHUB_USER) credential."
	@echo $(DOCKERHUB_PWD) | docker login --username=$(DOCKERHUB_USER) --password-stdin

# TODO(luxas): As soon as it's working to push fat manifests to gcr.io, reenable this code
#./manifest-tool:
#	curl -sSL https://github.com/luxas/manifest-tool/releases/download/v0.3.0/manifest-tool > manifest-tool
#	chmod +x manifest-tool

clean:
	rm -f heapster
	rm -f eventer

.PHONY: all build sanitize test-unit test-unit-cov test-integration container grafana influxdb clean