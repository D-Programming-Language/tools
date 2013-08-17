DMD ?= dmd
CC ?= gcc
PREFIX ?= /usr/local/bin

WITH_DOC ?= no
DOC ?= ../dlang.org/web

OS:=
uname_S:=$(shell uname -s)
ifeq (Darwin,$(uname_S))
	OS:=osx
endif
ifeq (Linux,$(uname_S))
	OS:=linux
endif
ifeq (FreeBSD,$(uname_S))
	OS:=freebsd
endif
ifeq (OpenBSD,$(uname_S))
	OS:=openbsd
endif
ifeq (Solaris,$(uname_S))
	OS:=solaris
endif
ifeq (SunOS,$(uname_S))
	OS:=solaris
endif
ifeq (,$(OS))
	$(error Unrecognized or unsupported OS for uname: $(uname_S))
endif

# For now, 32 bit is the default model
ifeq (,$(MODEL))
	MODEL:=32
endif

ifneq (,$(MODEL))
    MODEL_FLAG:=-m$(MODEL)
endif

ROOT_OF_THEM_ALL = generated
ROOT = $(ROOT_OF_THEM_ALL)/$(OS)/$(MODEL)

TOOLS = \
    $(ROOT)/rdmd \
    $(ROOT)/ddemangle \
    $(ROOT)/catdoc \
    $(ROOT)/detab \
    $(ROOT)/tolf

CURL_TOOLS = \
    $(ROOT)/dget \
    $(ROOT)/changed

DOC_TOOLS = \
    $(ROOT)/findtags \
    $(ROOT)/dman

TAGS:= \
	expression.tag \
	statement.tag

PHOBOS_TAGS:= \
	std_algorithm.tag \
	std_array.tag \
	std_file.tag \
	std_format.tag \
	std_math.tag \
	std_parallelism.tag \
	std_path.tag \
	std_random.tag \
	std_range.tag \
	std_regex.tag \
	std_stdio.tag \
	std_string.tag \
	std_traits.tag \
	std_typetuple.tag

all: $(TOOLS) $(CURL_TOOLS) $(ROOT)/dustmite

rdmd:      $(ROOT)/rdmd
ddemangle: $(ROOT)/ddemangle
catdoc:    $(ROOT)/catdoc
detab:     $(ROOT)/detab
tolf:      $(ROOT)/tolf
dget:      $(ROOT)/dget
changed:   $(ROOT)/changed
findtags:  $(ROOT)/findtags
dman:      $(ROOT)/dman
dustmite:  $(ROOT)/dustmite

$(ROOT)/dustmite: DustMite/dustmite.d DustMite/dsplit.d
	$(DMD) $(MODEL_FLAG) DustMite/dustmite.d DustMite/dsplit.d -of$(@)

#dreadful custom step because of libcurl dmd linking problem (Bugzilla 7044)
$(CURL_TOOLS): $(ROOT)/%: %.d
	$(DMD) -c -of$(@).o $(<)
	($(DMD) -v -of$(@) $(@).o  2>&1 | grep gcc | cut -f2- -d' ' ; echo -lcurl  ) | xargs $(CC)

$(TOOLS) $(DOC_TOOLS): $(ROOT)/%: %.d
	$(DMD) $(MODEL_FLAG) $(DFLAGS) -of$(@) $(<)

$(TAGS): %.tag: $(DOC)/%.html $(ROOT)/findtags
	$(ROOT)/findtags $< > $@

$(PHOBOS_TAGS): %.tag: $(DOC)/phobos/%.html $(ROOT)/findtags
	$(ROOT)/findtags $< > $@

$(ROOT)/dman: $(TAGS) $(PHOBOS_TAGS)
$(ROOT)/dman: DFLAGS += -J.

install: $(TOOLS) $(CURL_TOOLS)
	install -d $(DESTDIR)$(PREFIX)
	install -t $(DESTDIR)$(PREFIX) $(^)

clean:
	rm -f $(ROOT)/dustmite $(TOOLS) $(DOC_TOOLS) $(TAGS) *.o $(ROOT)/*.o

ifeq ($(WITH_DOC),yes)
all install: $(DOC_TOOLS)
endif

.PHONY: all install clean
