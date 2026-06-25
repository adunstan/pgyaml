-- pgyaml--1.0.sql
-- PostgreSQL YAML data type extension (jsonb-backed)
--
-- Copyright (c) 2026, Andrew Dunstan
-- Licensed under the MIT License.  See the LICENSE file for details.

\echo Use "CREATE EXTENSION pgyaml" to load this file. \quit

-- Shell type
CREATE TYPE yaml;

-- I/O
CREATE FUNCTION yaml_in(cstring)
RETURNS yaml
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION yaml_out(yaml)
RETURNS cstring
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION yaml_recv(internal)
RETURNS yaml
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION yaml_send(yaml)
RETURNS bytea
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT IMMUTABLE;

CREATE TYPE yaml (
    INPUT = yaml_in,
    OUTPUT = yaml_out,
    RECEIVE = yaml_recv,
    SEND = yaml_send,
    INTERNALLENGTH = VARIABLE,
    STORAGE = extended,
    ALIGNMENT = int,
    CATEGORY = 'U'
);

-- Conversions
CREATE FUNCTION yaml_to_jsonb(yaml)
RETURNS jsonb
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION jsonb_to_yaml(jsonb)
RETURNS yaml
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION yaml_to_text(yaml)
RETURNS text
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION yaml_to_json(yaml)
RETURNS json
AS $$ SELECT yaml_to_jsonb($1)::json $$
LANGUAGE SQL IMMUTABLE STRICT;

CREATE FUNCTION json_to_yaml(json)
RETURNS yaml
AS $$ SELECT jsonb_to_yaml($1::jsonb) $$
LANGUAGE SQL IMMUTABLE STRICT;

-- Path access
CREATE FUNCTION yaml_get(yaml, text)
RETURNS text
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION yaml_get_int(yaml, text)
RETURNS integer
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION yaml_get_float(yaml, text)
RETURNS float8
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION yaml_get_bool(yaml, text)
RETURNS boolean
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION yaml_typeof(yaml, text)
RETURNS text
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT IMMUTABLE;

CREATE FUNCTION yaml_is_valid(text)
RETURNS boolean
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT IMMUTABLE;

-- Comparison (all delegate to jsonb semantics via C)
CREATE FUNCTION yaml_eq(yaml, yaml) RETURNS boolean
AS 'MODULE_PATHNAME' LANGUAGE C STRICT IMMUTABLE;
CREATE FUNCTION yaml_ne(yaml, yaml) RETURNS boolean
AS 'MODULE_PATHNAME' LANGUAGE C STRICT IMMUTABLE;
CREATE FUNCTION yaml_lt(yaml, yaml) RETURNS boolean
AS 'MODULE_PATHNAME' LANGUAGE C STRICT IMMUTABLE;
CREATE FUNCTION yaml_le(yaml, yaml) RETURNS boolean
AS 'MODULE_PATHNAME' LANGUAGE C STRICT IMMUTABLE;
CREATE FUNCTION yaml_gt(yaml, yaml) RETURNS boolean
AS 'MODULE_PATHNAME' LANGUAGE C STRICT IMMUTABLE;
CREATE FUNCTION yaml_ge(yaml, yaml) RETURNS boolean
AS 'MODULE_PATHNAME' LANGUAGE C STRICT IMMUTABLE;
CREATE FUNCTION yaml_cmp(yaml, yaml) RETURNS integer
AS 'MODULE_PATHNAME' LANGUAGE C STRICT IMMUTABLE;
CREATE FUNCTION yaml_hash(yaml) RETURNS integer
AS 'MODULE_PATHNAME' LANGUAGE C STRICT IMMUTABLE;

-- Operators
CREATE OPERATOR = (
    LEFTARG = yaml, RIGHTARG = yaml, FUNCTION = yaml_eq,
    COMMUTATOR = =, NEGATOR = <>,
    RESTRICT = eqsel, JOIN = eqjoinsel,
    HASHES, MERGES
);
CREATE OPERATOR <> (
    LEFTARG = yaml, RIGHTARG = yaml, FUNCTION = yaml_ne,
    COMMUTATOR = <>, NEGATOR = =,
    RESTRICT = neqsel, JOIN = neqjoinsel
);
CREATE OPERATOR < (
    LEFTARG = yaml, RIGHTARG = yaml, FUNCTION = yaml_lt,
    COMMUTATOR = >, NEGATOR = >=,
    RESTRICT = scalarltsel, JOIN = scalarltjoinsel
);
CREATE OPERATOR <= (
    LEFTARG = yaml, RIGHTARG = yaml, FUNCTION = yaml_le,
    COMMUTATOR = >=, NEGATOR = >,
    RESTRICT = scalarlesel, JOIN = scalarlejoinsel
);
CREATE OPERATOR > (
    LEFTARG = yaml, RIGHTARG = yaml, FUNCTION = yaml_gt,
    COMMUTATOR = <, NEGATOR = <=,
    RESTRICT = scalargtsel, JOIN = scalargtjoinsel
);
CREATE OPERATOR >= (
    LEFTARG = yaml, RIGHTARG = yaml, FUNCTION = yaml_ge,
    COMMUTATOR = <=, NEGATOR = <,
    RESTRICT = scalargesel, JOIN = scalargejoinsel
);

CREATE OPERATOR CLASS yaml_ops
DEFAULT FOR TYPE yaml USING btree AS
    OPERATOR 1 <,
    OPERATOR 2 <=,
    OPERATOR 3 =,
    OPERATOR 4 >=,
    OPERATOR 5 >,
    FUNCTION 1 yaml_cmp(yaml, yaml);

CREATE OPERATOR CLASS yaml_hash_ops
DEFAULT FOR TYPE yaml USING hash AS
    OPERATOR 1 =,
    FUNCTION 1 yaml_hash(yaml);

-- Containment, existence, and jsonpath operators.  Each delegates to the
-- corresponding jsonb operator against the stored jsonb slice, so
-- semantics match jsonb exactly.
CREATE FUNCTION yaml_contains(yaml, yaml) RETURNS boolean
AS 'MODULE_PATHNAME' LANGUAGE C STRICT IMMUTABLE;
CREATE FUNCTION yaml_contained(yaml, yaml) RETURNS boolean
AS 'MODULE_PATHNAME' LANGUAGE C STRICT IMMUTABLE;
CREATE FUNCTION yaml_exists(yaml, text) RETURNS boolean
AS 'MODULE_PATHNAME' LANGUAGE C STRICT IMMUTABLE;
CREATE FUNCTION yaml_exists_any(yaml, text[]) RETURNS boolean
AS 'MODULE_PATHNAME' LANGUAGE C STRICT IMMUTABLE;
CREATE FUNCTION yaml_exists_all(yaml, text[]) RETURNS boolean
AS 'MODULE_PATHNAME' LANGUAGE C STRICT IMMUTABLE;
CREATE FUNCTION yaml_path_exists_opr(yaml, jsonpath) RETURNS boolean
AS 'MODULE_PATHNAME' LANGUAGE C STRICT IMMUTABLE;
CREATE FUNCTION yaml_path_match_opr(yaml, jsonpath) RETURNS boolean
AS 'MODULE_PATHNAME' LANGUAGE C STRICT IMMUTABLE;

CREATE OPERATOR @> (
    LEFTARG = yaml, RIGHTARG = yaml, FUNCTION = yaml_contains,
    COMMUTATOR = '<@',
    RESTRICT = contsel, JOIN = contjoinsel
);
CREATE OPERATOR <@ (
    LEFTARG = yaml, RIGHTARG = yaml, FUNCTION = yaml_contained,
    COMMUTATOR = '@>',
    RESTRICT = contsel, JOIN = contjoinsel
);
CREATE OPERATOR ? (
    LEFTARG = yaml, RIGHTARG = text, FUNCTION = yaml_exists,
    RESTRICT = contsel, JOIN = contjoinsel
);
CREATE OPERATOR ?| (
    LEFTARG = yaml, RIGHTARG = text[], FUNCTION = yaml_exists_any,
    RESTRICT = contsel, JOIN = contjoinsel
);
CREATE OPERATOR ?& (
    LEFTARG = yaml, RIGHTARG = text[], FUNCTION = yaml_exists_all,
    RESTRICT = contsel, JOIN = contjoinsel
);
CREATE OPERATOR @? (
    LEFTARG = yaml, RIGHTARG = jsonpath, FUNCTION = yaml_path_exists_opr
);
CREATE OPERATOR @@ (
    LEFTARG = yaml, RIGHTARG = jsonpath, FUNCTION = yaml_path_match_opr
);

-- GIN support.  Two opclasses mirror jsonb_ops / jsonb_path_ops:
-- yaml_ops indexes every key and value (and supports all operators
-- above), while yaml_path_ops indexes path+value hashes and supports
-- only @>, @?, @@.  Strategy and support-function numbers are kept
-- identical to jsonb's so the underlying core routines (which we
-- delegate to) behave unchanged.
CREATE FUNCTION gin_extract_yaml(yaml, internal, internal) RETURNS internal
AS 'MODULE_PATHNAME' LANGUAGE C STRICT IMMUTABLE;
CREATE FUNCTION gin_extract_yaml_query(yaml, internal, int2, internal, internal, internal, internal) RETURNS internal
AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE;
CREATE FUNCTION gin_consistent_yaml(internal, int2, yaml, int4, internal, internal, internal, internal) RETURNS boolean
AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE;
CREATE FUNCTION gin_triconsistent_yaml(internal, int2, yaml, int4, internal, internal, internal) RETURNS "char"
AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE;

CREATE FUNCTION gin_extract_yaml_path(yaml, internal, internal) RETURNS internal
AS 'MODULE_PATHNAME' LANGUAGE C STRICT IMMUTABLE;
CREATE FUNCTION gin_extract_yaml_query_path(yaml, internal, int2, internal, internal, internal, internal) RETURNS internal
AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE;
CREATE FUNCTION gin_consistent_yaml_path(internal, int2, yaml, int4, internal, internal, internal, internal) RETURNS boolean
AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE;
CREATE FUNCTION gin_triconsistent_yaml_path(internal, int2, yaml, int4, internal, internal, internal) RETURNS "char"
AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE;

CREATE OPERATOR CLASS yaml_ops
DEFAULT FOR TYPE yaml USING gin AS
    OPERATOR 7  @> (yaml, yaml),
    OPERATOR 9  ? (yaml, text),
    OPERATOR 10 ?| (yaml, text[]),
    OPERATOR 11 ?& (yaml, text[]),
    OPERATOR 15 @? (yaml, jsonpath),
    OPERATOR 16 @@ (yaml, jsonpath),
    FUNCTION 1 gin_compare_jsonb(text, text),
    FUNCTION 2 gin_extract_yaml(yaml, internal, internal),
    FUNCTION 3 gin_extract_yaml_query(yaml, internal, int2, internal, internal, internal, internal),
    FUNCTION 4 gin_consistent_yaml(internal, int2, yaml, int4, internal, internal, internal, internal),
    FUNCTION 6 gin_triconsistent_yaml(internal, int2, yaml, int4, internal, internal, internal),
    STORAGE text;

-- Jsonpath query functions, mirroring jsonb_path_query* signatures.
-- Results are jsonb (cast via jsonb_to_yaml if a YAML-shaped value is
-- needed).  The `vars` and `silent` arguments behave as in jsonb.
CREATE FUNCTION yaml_path_query(target yaml, path jsonpath,
                                vars jsonb DEFAULT '{}', silent boolean DEFAULT false)
RETURNS SETOF jsonb
AS 'MODULE_PATHNAME' LANGUAGE C STRICT IMMUTABLE;
CREATE FUNCTION yaml_path_query_array(target yaml, path jsonpath,
                                      vars jsonb DEFAULT '{}', silent boolean DEFAULT false)
RETURNS jsonb
AS 'MODULE_PATHNAME' LANGUAGE C STRICT IMMUTABLE;
CREATE FUNCTION yaml_path_query_first(target yaml, path jsonpath,
                                      vars jsonb DEFAULT '{}', silent boolean DEFAULT false)
RETURNS jsonb
AS 'MODULE_PATHNAME' LANGUAGE C STRICT IMMUTABLE;

CREATE OPERATOR CLASS yaml_path_ops
FOR TYPE yaml USING gin AS
    OPERATOR 7  @> (yaml, yaml),
    OPERATOR 15 @? (yaml, jsonpath),
    OPERATOR 16 @@ (yaml, jsonpath),
    FUNCTION 1 btint4cmp(int4, int4),
    FUNCTION 2 gin_extract_yaml_path(yaml, internal, internal),
    FUNCTION 3 gin_extract_yaml_query_path(yaml, internal, int2, internal, internal, internal, internal),
    FUNCTION 4 gin_consistent_yaml_path(internal, int2, yaml, int4, internal, internal, internal, internal),
    FUNCTION 6 gin_triconsistent_yaml_path(internal, int2, yaml, int4, internal, internal, internal),
    STORAGE int4;

-- Casts.  yaml->text is implicit (natural for display); conversions to/from
-- structured types are assignment-only so the type doesn't have multiple
-- competing implicit conversions out, and so raw text doesn't silently
-- become yaml in expression contexts.
CREATE CAST (yaml AS text) WITH FUNCTION yaml_to_text(yaml) AS IMPLICIT;
CREATE CAST (text AS yaml) WITH INOUT AS ASSIGNMENT;
CREATE CAST (yaml AS jsonb) WITH FUNCTION yaml_to_jsonb(yaml) AS ASSIGNMENT;
CREATE CAST (jsonb AS yaml) WITH FUNCTION jsonb_to_yaml(jsonb) AS ASSIGNMENT;
CREATE CAST (yaml AS json) WITH FUNCTION yaml_to_json(yaml) AS ASSIGNMENT;
CREATE CAST (json AS yaml) WITH FUNCTION json_to_yaml(json) AS ASSIGNMENT;
