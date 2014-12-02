# -*- mode: makefile; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
# vim: ts=4 sw=4 ft=makefile noet
# Copyright (c) 2013-2014, Loïc Hoguin <essen@ninenines.eu>
# Copyright (c) 2014, Andrew Bennett <andrew@pixid.com>
#
# Permission to use, copy, modify, and/or distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

.PHONY: all app clean distclean

REBAR_MK_VERSION = 2

# Core configuration.

PROJECT ?= $(notdir $(CURDIR))
PROJECT := $(strip $(PROJECT))

# Verbosity.

V ?= 0

gen_verbose_0 = @echo " GEN   " $@;
gen_verbose = $(gen_verbose_$(V))

# Core targets.

all:: app

clean::
	$(gen_verbose) rm -f erl_crash.dump

distclean:: clean

# Core functions.

define core_http_get
	wget --no-check-certificate -O $(1) $(2)|| rm $(1)
endef

# Copyright (c) 2014, Andrew Bennett <potatosaladx@gmail.com>
# This file is part of rebar.mk and subject to the terms of the ISC License.

.PHONY: clean-app

# Configuration.

# Verbosity.

# Core targets.

app:: compile-app

clean:: clean-app

# App related targets.

clean-app: rebar
	$(rebar) clean

compile-app: rebar
	$(rebar) compile

shell: rebar
	$(rebar) shell

# Copyright (c) 2014, Andrew Bennett <potatosaladx@gmail.com>
# This file is part of rebar.mk and subject to the terms of the ISC License.

.PHONY: rebar distclean-rebar

# Configuration.

REBAR_CONFIG ?= $(CURDIR)/rebar.config

REBAR ?= $(CURDIR)/rebar3
export REBAR

REBAR_URL ?= https://s3.amazonaws.com/rebar3/rebar3
REBAR_OPTS ?=

# Verbosity.

rebar_args_3 = -v 3
rebar_args_2 = -v 2
rebar_args_1 = -v 1
rebar_args = $(rebar_args_$(V))

rebar_verbose_0 = @echo " REBAR " $(@F);
rebar_verbose = $(rebar_verbose_$(V))

rebar = $(rebar_verbose) V=$(V) $(REBAR) $(rebar_args)

# Core targets.

distclean:: distclean-rebar

# Plugin-specific targets.

define rebar_fetch
	$(call core_http_get,$(REBAR),$(REBAR_URL))
	chmod +x $(REBAR)
endef

$(REBAR):
	@$(call rebar_fetch)

distclean-rebar:
	$(gen_verbose) rm -rf $(REBAR)

rebar:: $(REBAR)
