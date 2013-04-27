.PHONY: all clean install build
all: build doc

NAME=xenblock
J=4

# To build the frontend/backend drivers we need either
# 1. the xenctrl library (userspace)
# 2. to be targetting xen via Mirage (kernelspace)
# If we have neither of these then we only build the
# generic protocol handling code.

USERSPACE ?= $(shell if ocamlfind query xenctrl >/dev/null 2>&1; then echo --enable-userspace; fi)
ifeq ($(MIRAGE_OS),xen)
KERNELSPACE ?= --enable-kernelspace
endif

export OCAMLRUNPARAM=b

setup.bin: setup.ml
	@ocamlopt.opt -o $@ $< || ocamlopt -o $@ $< || ocamlc -o $@ $<
	@rm -f setup.cmx setup.cmi setup.o setup.cmo

setup.data: setup.bin
	@./setup.bin -configure $(USERSPACE) $(KERNELSPACE)

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

clean:
	@ocamlbuild -clean
	@rm -f setup.data setup.log setup.bin
