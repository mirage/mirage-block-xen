.PHONY: all clean install build
all: build doc

NAME=xenblock
J=4

# Hack: userspace doesn't support Gntshr.get_n
BLKFRONT ?= $(shell if ocamlfind query xenctrl.lwt >/dev/null 2>&1; then echo --disable-blkfront; fi)

export OCAMLRUNPARAM=b

setup.bin: setup.ml
	@ocamlopt.opt -o $@ $< || ocamlopt -o $@ $< || ocamlc -o $@ $<
	@rm -f setup.cmx setup.cmi setup.o setup.cmo

setup.data: setup.bin
	@./setup.bin -configure $(BLKFRONT)

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
