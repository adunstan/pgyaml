EXTENSION = pgyaml
MODULE_big = pgyaml
DATA = pgyaml--1.0.sql
OBJS = pgyaml.o
REGRESS = pgyaml
# Unicode-escape tests need a real encoding; force UTF8 so the suite passes
# regardless of the server's default.
REGRESS_OPTS = --encoding=UTF8 --no-locale

PG_CPPFLAGS = $(shell pkg-config --cflags yaml-0.1 2>/dev/null)
SHLIB_LINK = $(shell pkg-config --libs yaml-0.1 2>/dev/null || echo -lyaml)

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
