.PHONY: all clean install build
all: build doc

NAME=mirage-block-xen
IMAGE=$(NAME)
J=4

include config.mk
config.mk: configure
	./configure

configure: configure.ml
	ocamlfind ocamlopt -package "cmdliner,findlib" -linkpkg $< -o $@

export OCAMLRUNPARAM=b

setup.bin: setup.ml
	@ocamlopt.opt -o $@ $< || ocamlopt -o $@ $< || ocamlc -o $@ $<
	@rm -f setup.cmx setup.cmi setup.o setup.cmo

setup.data: setup.bin
	@./setup.bin -configure $(ENABLE_BLKFRONT) $(ENABLE_BLKBACK)

build: setup.data setup.bin
	@./setup.bin -build -j $(J)

doc: setup.data setup.bin
	@./setup.bin -doc -j $(J)

install: setup.bin
	@./setup.bin -install

uninstall:
	@ocamlfind remove $(NAME) || true

test: setup.bin build
	@./setup.bin -test

reinstall: setup.bin
	@ocamlfind remove $(NAME) || true
	@./setup.bin -reinstall

xen-depends: Dockerfile build.sh
	docker build -t $(IMAGE) .

xen-build: xen-depends clean
	docker run -v $(shell pwd):/src $(IMAGE) /build.sh

clean:
	@ocamlbuild -clean
	@rm -f setup.data setup.log setup.bin
