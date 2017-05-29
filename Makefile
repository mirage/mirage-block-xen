
.PHONY: build clean test

build:
	jbuilder build @install --dev

test:
	jbuilder runtest --dev

install:
	jbuilder install

uninstall:
	jbuilder uninstall

xen-depends: Dockerfile build.sh
	docker build -t mirage-block-xen .

xen-build: xen-depends clean
	docker run -v $(shell pwd):/src mirage-block-xen /build.sh

clean:
	rm -rf _build
