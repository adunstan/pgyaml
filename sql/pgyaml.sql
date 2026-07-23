-- Basic extension setup
CREATE EXTENSION pgyaml;

-- Test basic I/O
SELECT 'name: test'::yaml;
SELECT 'value: 123'::yaml;
SELECT 'flag: true'::yaml;

-- Test multi-line YAML
SELECT 'name: test
value: 123
flag: true'::yaml;

-- Test nested structure
SELECT 'person:
  name: John
  age: 30'::yaml;

-- Test sequence
SELECT 'items:
  - one
  - two
  - three'::yaml;

-- Test invalid YAML (should error)
\set ON_ERROR_STOP off
SELECT 'invalid: yaml: content:'::yaml;
\set ON_ERROR_STOP on

-- Test yaml_is_valid
SELECT yaml_is_valid('name: test');
SELECT yaml_is_valid('valid: true');
SELECT yaml_is_valid('  bad yaml::');

-- Test yaml_get with mapping
SELECT yaml_get('name: John
age: 30'::yaml, 'name');
SELECT yaml_get('name: John
age: 30'::yaml, 'age');

-- Test yaml_get with nested mapping
SELECT yaml_get('person:
  name: Jane
  city: NYC'::yaml, 'person.name');
SELECT yaml_get('person:
  name: Jane
  city: NYC'::yaml, 'person.city');

-- Test yaml_get with sequence
SELECT yaml_get('items:
  - first
  - second
  - third'::yaml, 'items.0');
SELECT yaml_get('items:
  - first
  - second
  - third'::yaml, 'items.1');
SELECT yaml_get('items:
  - first
  - second
  - third'::yaml, 'items.2');

-- An empty path segment is a malformed path, not a data-dependent "not
-- found": reject it outright rather than silently treating it the same
-- as the equivalent well-formed path (strtok_r would otherwise collapse
-- "items..0"/".items"/"items." down to "items.0"/"items"/"items").
\set ON_ERROR_STOP off
SELECT yaml_get('items:
  - first
  - second
  - third'::yaml, 'items..0');
SELECT yaml_get('items:
  - first
  - second
  - third'::yaml, '.items');
SELECT yaml_get('items:
  - first
  - second
  - third'::yaml, 'items.');
\set ON_ERROR_STOP on

-- An array-index path segment must be plain decimal digits: a leading
-- '+' or leading whitespace is rejected (returning NULL, the same as
-- any other malformed index against an array) rather than silently
-- accepted the way generic strtol() parsing alone would accept it.
--
-- The overflow check below (errno/UINT_MAX, guarding against a token
-- too large for a long or a uint32 index) also returns NULL here, but
-- coincidentally: any overflowing token clamps to the same sentinel
-- value regardless of its actual digits, which lands far out of range
-- for this 3-element array either way. Only a container with billions
-- of elements would expose the difference between "properly rejected"
-- and "silently wrapped to an unrelated index" -- not practical to
-- test here, but the check still guards real callers with huge
-- containers.
SELECT yaml_get('items:
  - first
  - second
  - third'::yaml, 'items.99999999999999999999');
SELECT yaml_get('items:
  - first
  - second
  - third'::yaml, 'items.+0');
SELECT yaml_get('items:
  - first
  - second
  - third'::yaml, 'items. 0');

-- Test yaml_get with non-existent path
SELECT yaml_get('name: test'::yaml, 'missing');
SELECT yaml_get('name: test'::yaml, 'name.nested');

-- Test yaml_get_int
SELECT yaml_get_int('count: 42'::yaml, 'count');
SELECT yaml_get_int('values:
  - 10
  - 20
  - 30'::yaml, 'values.1');

-- yaml_get_int: string scalars that parse as integers are accepted;
-- junk strings and non-numeric types raise.
SELECT yaml_get_int('n: "42"'::yaml, 'n');
SELECT yaml_get_int('n: "-7"'::yaml, 'n');
\set ON_ERROR_STOP off
SELECT yaml_get_int('n: "abc"'::yaml, 'n');
SELECT yaml_get_int('n: "3.14"'::yaml, 'n');
SELECT yaml_get_int('n: true'::yaml, 'n');
SELECT yaml_get_int('n: null'::yaml, 'n');
SELECT yaml_get_int('n: {a: 1}'::yaml, 'n');
\set ON_ERROR_STOP on

-- Test yaml_get_float
SELECT yaml_get_float('price: 19.99'::yaml, 'price');
SELECT yaml_get_float('pi: 3.14159'::yaml, 'pi');

-- yaml_get_float: string scalars that parse as float are accepted;
-- junk strings and non-numeric types raise.
SELECT yaml_get_float('x: "3.14"'::yaml, 'x');
SELECT yaml_get_float('x: "-1e2"'::yaml, 'x');
\set ON_ERROR_STOP off
SELECT yaml_get_float('x: "abc"'::yaml, 'x');
SELECT yaml_get_float('x: true'::yaml, 'x');
SELECT yaml_get_float('x: null'::yaml, 'x');
SELECT yaml_get_float('x: [1, 2]'::yaml, 'x');
\set ON_ERROR_STOP on

-- Test yaml_get_bool
SELECT yaml_get_bool('enabled: true'::yaml, 'enabled');
SELECT yaml_get_bool('enabled: false'::yaml, 'enabled');
SELECT yaml_get_bool('enabled: yes'::yaml, 'enabled');
SELECT yaml_get_bool('enabled: no'::yaml, 'enabled');
SELECT yaml_get_bool('enabled: on'::yaml, 'enabled');
SELECT yaml_get_bool('enabled: off'::yaml, 'enabled');

-- Test yaml_typeof
SELECT yaml_typeof('name: test'::yaml, '');
SELECT yaml_typeof('name: test'::yaml, 'name');
SELECT yaml_typeof('items:
  - one
  - two'::yaml, 'items');
SELECT yaml_typeof('items:
  - one
  - two'::yaml, 'items.0');

-- yaml_typeof: root-scalar documents uniformly return 'scalar', including null
SELECT yaml_typeof('null'::yaml, '');
SELECT yaml_typeof('42'::yaml, '');
SELECT yaml_typeof('true'::yaml, '');
SELECT yaml_typeof('just a string'::yaml, '');
-- yaml_typeof: a null leaf also returns 'scalar' (consistent with root)
SELECT yaml_typeof('a: null'::yaml, 'a');

-- Test yaml_to_json
SELECT yaml_to_json('name: John'::yaml);
SELECT yaml_to_json('count: 42'::yaml);
SELECT yaml_to_json('flag: true'::yaml);
SELECT yaml_to_json('empty: null'::yaml);
SELECT yaml_to_json('items:
  - one
  - two'::yaml);
SELECT yaml_to_json('person:
  name: Jane
  age: 25'::yaml);

-- Nested containers in YAML->JSON (regression: used to silently fail)
SELECT yaml_to_json('matrix:
  - - 1
    - 2
  - - 3
    - 4'::yaml);
SELECT yaml_to_json('- a: 1
  b: 2
- c: 3
  d: 4'::yaml);
SELECT yaml_to_json('outer:
  inner:
    - tag: x
      values: [1, 2, 3]
    - tag: y
      values: [4, 5]'::yaml);

-- Test json_to_yaml
SELECT json_to_yaml('{"name": "John"}'::json);
SELECT json_to_yaml('{"count": 42}'::json);
SELECT json_to_yaml('{"items": ["a", "b", "c"]}'::json);

-- JSON->YAML decodes \uXXXX escapes to UTF-8 and round-trips
SELECT yaml_to_json(json_to_yaml('{"greeting": "caf\u00e9"}'::json));
-- Supplementary plane via surrogate pair
SELECT yaml_to_json(json_to_yaml('{"emoji": "\uD83D\uDE00"}'::json));
-- Malformed escape is rejected
\set ON_ERROR_STOP off
SELECT json_to_yaml('{"x": "\uZZZZ"}'::json);
SELECT json_to_yaml('{"x": "\uD83D"}'::json);
\set ON_ERROR_STOP on

-- Test comparison operators
SELECT 'a: 1'::yaml = 'a: 1'::yaml;
SELECT 'a: 1'::yaml = 'a: 2'::yaml;
SELECT 'a: 1'::yaml <> 'a: 2'::yaml;
SELECT 'a: 1'::yaml < 'b: 1'::yaml;
SELECT 'b: 1'::yaml > 'a: 1'::yaml;

-- Canonicalization: reordered keys compare equal
SELECT 'a: 1
b: 2'::yaml = 'b: 2
a: 1'::yaml;

-- Canonicalization: extra whitespace is normalized
SELECT 'a:   1'::yaml = 'a: 1'::yaml;

-- Canonicalization: flow and block styles compare equal
SELECT '{a: 1, b: 2}'::yaml = 'a: 1
b: 2'::yaml;

-- Canonicalization preserves type: quoted "42" stays a string, bare 42 stays a number
SELECT yaml_to_json('x: "42"'::yaml);
SELECT yaml_to_json('x: 42'::yaml);
SELECT 'x: "42"'::yaml = 'x: 42'::yaml;

-- Canonicalization rejects multi-document input
\set ON_ERROR_STOP off
SELECT E'a: 1\n---\nb: 2'::yaml;
\set ON_ERROR_STOP on

-- Test indexing
CREATE TABLE yaml_test (id serial, data yaml);
INSERT INTO yaml_test (data) VALUES ('name: Alice'::yaml);
INSERT INTO yaml_test (data) VALUES ('name: Bob'::yaml);
INSERT INTO yaml_test (data) VALUES ('name: Charlie'::yaml);

CREATE INDEX ON yaml_test USING btree (data);
CREATE INDEX ON yaml_test USING hash (data);

SELECT * FROM yaml_test WHERE data = 'name: Bob'::yaml;
SELECT * FROM yaml_test ORDER BY data;

-- Binary wire format (yaml_recv/yaml_send): round-trip via a client-side
-- \copy in binary format exercises the recv path directly (COPY
-- TEXT/CSV never calls it).  \copy is a psql-side operation, resolved
-- relative to the client's own working directory (pg_regress runs
-- psql from the extension's source tree, mirroring the \copy ...
-- 'data/hstore.data' convention used by contrib/hstore), so this needs
-- no superuser server-side file access and no absolute path.
CREATE TABLE yaml_test_bin (id serial, data yaml);
INSERT INTO yaml_test_bin (id, data) VALUES
  (1, 'name: test'::yaml),
  (2, 'person:
  name: Jane
  age: 25'::yaml),
  (3, 'items:
  - one
  - two
  - three'::yaml),
  (4, '42'::yaml),
  (5, 'null'::yaml);

\copy yaml_test_bin TO 'results/yaml_test_bin.data' WITH (FORMAT binary)
TRUNCATE yaml_test_bin;
\copy yaml_test_bin FROM 'results/yaml_test_bin.data' WITH (FORMAT binary)

-- Byte-exact survival of the original text and jsonb-backed semantics
SELECT id, data FROM yaml_test_bin ORDER BY id;
SELECT id, yaml_to_jsonb(data) FROM yaml_test_bin ORDER BY id;

DROP TABLE yaml_test_bin;

-- Containment, existence, and jsonpath operators
SELECT 'a: 1
b: 2'::yaml @> 'a: 1'::yaml;
SELECT 'a: 1
b: 2'::yaml @> 'c: 3'::yaml;
SELECT 'a: 1'::yaml <@ 'a: 1
b: 2'::yaml;
SELECT 'a: 1
b: 2'::yaml ? 'a';
SELECT 'a: 1
b: 2'::yaml ? 'c';
SELECT 'a: 1
b: 2'::yaml ?| ARRAY['a','c'];
SELECT 'a: 1
b: 2'::yaml ?| ARRAY['c','d'];
SELECT 'a: 1
b: 2'::yaml ?& ARRAY['a','b'];
SELECT 'a: 1
b: 2'::yaml ?& ARRAY['a','c'];
SELECT 'a: 1
b: 2'::yaml @? '$.a';
SELECT 'a: 1
b: 2'::yaml @? '$.c';
SELECT 'a: 1
b: 2'::yaml @@ '$.a > 0';
SELECT 'a: 1
b: 2'::yaml @@ '$.a > 100';

-- GIN indexing: both opclasses plan and return correctly
CREATE TABLE yaml_gin_test (id serial, data yaml);
INSERT INTO yaml_gin_test (data)
SELECT format('k: %s
v: %s', g, g * 2)::yaml FROM generate_series(1, 50) g;
INSERT INTO yaml_gin_test (data) VALUES ('k: target
v: found'::yaml);

CREATE INDEX yaml_gin_default ON yaml_gin_test USING gin (data);
CREATE INDEX yaml_gin_path ON yaml_gin_test USING gin (data yaml_path_ops);

-- Jsonpath query functions
SELECT yaml_path_query('nums: [1, 2, 3, 4]'::yaml, '$.nums[*] ? (@ > 2)');
SELECT yaml_path_query_array('nums: [1, 2, 3, 4]'::yaml, '$.nums[*] ? (@ > 2)');
SELECT yaml_path_query_first('nums: [10, 20]'::yaml, '$.nums[*]');
SELECT yaml_path_query('n: [1, 2, 3]'::yaml,
                       '$.n[*] ? (@ > $threshold)',
                       vars => '{"threshold": 1}'::jsonb);
-- silent => true swallows evaluation errors from strict mode
SELECT yaml_path_query_first('{}'::yaml, 'strict $.missing', silent => true);

SET enable_seqscan = off;
SELECT id FROM yaml_gin_test WHERE data @> 'k: target'::yaml;
SELECT count(*) FROM yaml_gin_test WHERE data ? 'k';
SELECT count(*) FROM yaml_gin_test WHERE data ?| ARRAY['k','missing'];
SELECT count(*) FROM yaml_gin_test WHERE data ?& ARRAY['k','v'];
SELECT id FROM yaml_gin_test WHERE data @? '$.k ? (@ == "target")';
SELECT id FROM yaml_gin_test WHERE data @@ '$.k == "target"';

-- A single @> containment against a multi-key document extracts more than
-- one GIN key from one operand, so the bitmap scan must AND several
-- "maybe" results together within one gin_(tri)consistent_yaml(_path) call
-- -- this only happens with 2+ keys/conditions (a single-key scan never
-- reaches triconsistent, only consistent). Two further ANDed @> clauses
-- on the same column add a second, independent path to the same code
-- (BitmapAnd-eligible query over one GIN index).
--
-- yaml_gin_path (yaml_path_ops) also supports @>/@?, and is always
-- cheaper than yaml_gin_default (yaml_ops) for these operators, so the
-- planner picks it even when both indexes exist. To pin each opclass's
-- triconsistent function down individually, drop the other index before
-- each block rather than relying on cost-based selection.
--
-- This isolation matters for more than plan-shape correctness: verified
-- (by temporarily forcing gin_triconsistent_yaml to return GIN_MAYBE
-- unconditionally) that the yaml_ops block below is a real correctness
-- gate -- the neutered function produced both wrong row counts and a
-- reproducible backend crash, because skipping the real jsonb
-- triconsistent logic also skips setting the required *recheck output
-- argument. The yaml_path_ops block's queries, by contrast, still
-- returned correct final rows under the same neuter (bitmap heap
-- recheck re-applies the real @? operator regardless of what
-- triconsistent reported), so that half only proves triconsistent is
-- reached/plan-shape-correct, not that its internal logic is right.
SET enable_bitmapscan = on;

-- yaml_ops / gin_triconsistent_yaml: drop the path index so the default
-- opclass is the only one available for these @> queries.
DROP INDEX yaml_gin_path;

EXPLAIN (COSTS OFF)
SELECT id FROM yaml_gin_test WHERE data @> 'k: target
v: found'::yaml;
SELECT id FROM yaml_gin_test WHERE data @> 'k: target
v: found'::yaml;

EXPLAIN (COSTS OFF)
SELECT id FROM yaml_gin_test
  WHERE data @> 'k: target'::yaml AND data @> 'v: found'::yaml;
SELECT id FROM yaml_gin_test
  WHERE data @> 'k: target'::yaml AND data @> 'v: found'::yaml;

-- A pair of conditions that cannot both be satisfied by the same row
-- (still requires triconsistent to combine "maybe" bitmaps correctly,
-- this time yielding a definite "no" rather than a definite "yes")
SELECT count(*) FROM yaml_gin_test
  WHERE data @> 'k: target'::yaml AND data @> 'k: 7'::yaml;

CREATE INDEX yaml_gin_path ON yaml_gin_test USING gin (data yaml_path_ops);

-- yaml_path_ops / gin_triconsistent_yaml_path: drop the default index so
-- the path opclass is the only one available for these @? queries.
-- (Coverage-only for this opclass -- see note above: bitmap heap
-- recheck re-validates the real @? operator regardless of what
-- triconsistent returns here, so this proves the function is reached
-- with the right plan shape, not that its logic is correct.)
DROP INDEX yaml_gin_default;

EXPLAIN (COSTS OFF)
SELECT id FROM yaml_gin_test
  WHERE data @? '$.k ? (@ == "target")' AND data @? '$.v ? (@ == "found")';
SELECT id FROM yaml_gin_test
  WHERE data @? '$.k ? (@ == "target")' AND data @? '$.v ? (@ == "found")';

SELECT count(*) FROM yaml_gin_test
  WHERE data @? '$.k ? (@ == "target")' AND data @? '$.k ? (@ == "7")';

RESET enable_seqscan;
RESET enable_bitmapscan;
DROP TABLE yaml_gin_test;

-- TOAST: force out-of-line storage of the custom varlena layout
-- ([varlena hdr][orig_len][jsonb subvarlena][orig bytes]) and confirm
-- YAML_JSONB_PTR/YAML_ORIG_PTR still locate their slices correctly once
-- the value has been compressed/detoasted rather than read inline.
-- md5() output is high-entropy hex, so chaining 100 of them (3200 bytes,
-- single unbroken token so libyaml can't fold/wrap it) comfortably
-- exceeds TOAST_TUPLE_THRESHOLD even after pglz compression.
CREATE TABLE yaml_toast_test (id serial, data yaml, plain_len int);
CREATE TABLE yaml_toast_plain (id serial, data yaml);
ALTER TABLE yaml_toast_test ALTER COLUMN data SET STORAGE EXTENDED;
ALTER TABLE yaml_toast_plain ALTER COLUMN data SET STORAGE PLAIN;

INSERT INTO yaml_toast_test (id, data, plain_len)
SELECT 1, format('big: %s', string_agg(md5(g::text), ''))::yaml,
       length(format('big: %s', string_agg(md5(g::text), '')))
FROM generate_series(1, 100) g;

-- STORAGE PLAIN forbids compression and out-of-line storage, so this row
-- with identical content is a same-shape control: its pg_column_size is
-- the true uncompressed on-disk size of the [hdr][orig_len][jsonb][orig]
-- layout.  The EXTENDED row above must come out smaller, proving the
-- value was actually compressed/toasted rather than stored inline as-is
-- (TOAST_TUPLE_THRESHOLD is 2KB; this ~6.5KB combined payload -- 3.2KB
-- jsonb copy plus 3.2KB orig text -- is comfortably over it).
INSERT INTO yaml_toast_plain (id, data)
SELECT 1, format('big: %s', string_agg(md5(g::text), ''))::yaml
FROM generate_series(1, 100) g;

SELECT (SELECT pg_column_size(data) FROM yaml_toast_test WHERE id = 1) <
       (SELECT pg_column_size(data) FROM yaml_toast_plain WHERE id = 1)
       AS was_toasted;

DROP TABLE yaml_toast_plain;

-- Equality on a detoasted large value (delegates to compareJsonbContainers
-- over the embedded jsonb slice -- exercises YAML_JSONB_PTR post-detoast)
SELECT data = data FROM yaml_toast_test WHERE id = 1;
SELECT data <> jsonb_to_yaml('{"big": "different"}'::jsonb) FROM yaml_toast_test WHERE id = 1;

-- Path access into the large scalar returns it byte-for-byte: check the
-- fixed-content prefix explicitly, then confirm the full length matches
-- (together these pin down the whole 3200-char value without embedding
-- it as a literal).
SELECT left(yaml_get(data, 'big'), 64) = md5(1::text) || md5(2::text)
FROM yaml_toast_test WHERE id = 1;
SELECT length(yaml_get(data, 'big')) = plain_len - length('big: ')
FROM yaml_toast_test WHERE id = 1;

-- Cast to jsonb operates on the jsonb slice embedded past the orig_len
-- header -- if YAML_JSONB_PTR/YAML_ORIG_PTR miscomputed the offset after
-- detoasting, this would return garbage, a truncated value, or crash.
SELECT yaml_to_jsonb(data) -> 'big' = to_jsonb(yaml_get(data, 'big'))
FROM yaml_toast_test WHERE id = 1;
SELECT yaml_typeof(data, 'big') FROM yaml_toast_test WHERE id = 1;

-- Round-trip through yaml_out (orig bytes, past the jsonb slice) still
-- matches the original text exactly
SELECT (data::text) = format('big: %s', string_agg(md5(g::text), ''))
FROM yaml_toast_test, generate_series(1, 100) g WHERE id = 1
GROUP BY data;

DROP TABLE yaml_toast_test;

-- Test cast to text
SELECT 'name: test'::yaml::text;

-- Test cast from text
SELECT 'value: 123'::text::yaml;

-- yaml -> text is implicit (text functions accept yaml directly)
SELECT length('name: test'::yaml);

-- yaml -> json is assignment-only: implicit use in an expression fails.
-- Use terse verbosity: the DETAIL/HINT wording for an unresolved function
-- differs across server versions (split into DETAIL+HINT on PG19), so keep
-- only the version-stable primary message.
\set ON_ERROR_STOP off
\set VERBOSITY terse
SELECT json_array_length('items:
  - a
  - b'::yaml);
\set VERBOSITY default
\set ON_ERROR_STOP on

-- But the explicit cast still works
SELECT json_array_length(('items:
  - a
  - b'::yaml)::json -> 'items');

-- yaml_to_jsonb exposes the decomposed form directly
SELECT yaml_to_jsonb('person:
  name: Jane
  age: 25'::yaml);

-- Round-trip fidelity: yaml_out returns the original bytes (including
-- whitespace and key order), unlike the old canonicalize-on-input design.
SELECT 'z: 1
a: 2
m: 3'::yaml;

-- Scalar-rooted documents are allowed
SELECT 'just a string'::yaml;
SELECT '42'::yaml;
SELECT 'null'::yaml;

-- Scalar-rooted values can still be converted to jsonb
SELECT yaml_to_jsonb('42'::yaml);
SELECT yaml_to_jsonb('null'::yaml);
SELECT yaml_to_jsonb('just a string'::yaml);

-- Anchors and aliases: libyaml resolves them at parse time and the
-- referenced content is duplicated into each use site in the jsonb.
SELECT yaml_to_jsonb('i: &x hello
j: *x'::yaml);
SELECT yaml_get('defaults: &d
  color: blue
  size: large
item1: *d
item2: *d'::yaml, 'item1.color');
SELECT yaml_get('defaults: &d
  color: blue
  size: large
item1: *d
item2: *d'::yaml, 'item2.size');
-- Aliased scalars work too
SELECT yaml_get_int('x: &n 42
y: *n'::yaml, 'y');
-- Cyclic aliases trip the 1024-level depth guard and are rejected
\set ON_ERROR_STOP off
SELECT '&loop [ *loop ]'::yaml;
\set ON_ERROR_STOP on

-- Non-cyclic alias re-expansion is bounded independently of recursion
-- depth: a chain of anchors each referencing the previous one twice stays
-- well within the depth guard (21 levels) but would materialize 2^20
-- copies of the leaf value if fully expanded. The total-materialized-value
-- budget rejects this cleanly long before that happens.
\set ON_ERROR_STOP off
SELECT ('a0: &a0 leaf
a1: &a1 [*a0, *a0]
a2: &a2 [*a1, *a1]
a3: &a3 [*a2, *a2]
a4: &a4 [*a3, *a3]
a5: &a5 [*a4, *a4]
a6: &a6 [*a5, *a5]
a7: &a7 [*a6, *a6]
a8: &a8 [*a7, *a7]
a9: &a9 [*a8, *a8]
a10: &a10 [*a9, *a9]
a11: &a11 [*a10, *a10]
a12: &a12 [*a11, *a11]
a13: &a13 [*a12, *a12]
a14: &a14 [*a13, *a13]
a15: &a15 [*a14, *a14]
a16: &a16 [*a15, *a15]
a17: &a17 [*a16, *a16]
a18: &a18 [*a17, *a17]
a19: &a19 [*a18, *a18]
a20: &a20 [*a19, *a19]
root: *a20'::yaml)::text;
\set ON_ERROR_STOP on

-- jsonb_to_yaml round-trip preserves type semantics
SELECT jsonb_to_yaml('{"a": 1, "b": "hello", "c": true, "d": null}'::jsonb);

-- yaml_get on a non-scalar path now returns the sub-document as JSON text
SELECT yaml_get('person:
  name: Jane
  address:
    city: NYC
    zip: "10001"'::yaml, 'person');
SELECT yaml_get('person:
  address:
    city: NYC'::yaml, 'person.address');

-- yaml_is_valid matches yaml_in: rejects malformed and multi-doc input
SELECT yaml_is_valid('name: test');
SELECT yaml_is_valid('  bad yaml: : :');
SELECT yaml_is_valid(E'a: 1\n---\nb: 2');
-- malformed second document must also be rejected (not silently accepted)
SELECT yaml_is_valid(E'a: 1\n---\n: : bad');
SELECT yaml_is_valid('');

-- Text I/O round-trip fidelity (the pg_dump/restore path).  jsonb_to_yaml
-- must not emit a type-ambiguous string (yes/no/on/off/true/false/null/~,
-- a bare number, or empty) as a plain scalar, or it would silently reparse
-- as a bool/null/number when the value travels back through yaml_out ->
-- yaml_in (which is exactly what COPY TEXT, and therefore pg_dump, does).
-- These cases have no prior coverage -- their absence is what hid the bug.

-- Ambiguous string values are quoted; unambiguous ones stay plain.
SELECT jsonb_to_yaml('{"s_yes":"yes","s_num":"42","s_null":"null","plain":"hello"}'::jsonb);

-- Invariant: a value's embedded jsonb equals the jsonb its own emitted
-- text reparses to.  Must hold for every value, however constructed.
SELECT bool_and(yaml_to_jsonb(y) = (y::text::yaml)::jsonb) AS all_consistent
FROM (VALUES
    (jsonb_to_yaml('{"a":"yes","b":"42","c":"null","d":"on","e":"~","f":""}'::jsonb)),
    (jsonb_to_yaml('{"g":"no","h":"off","i":"true","j":"-1.5e3"}'::jsonb)),
    (jsonb_to_yaml('{"arr":["yes","42",null,7,true],"nest":{"k":"on"}}'::jsonb))
) v(y);

-- End-to-end restore path: COPY TEXT out and back in preserves string-ness
-- (before the fix these came back as bool/null/number).
CREATE TABLE yaml_dump_test (id int, y yaml);
INSERT INTO yaml_dump_test VALUES
    (1, jsonb_to_yaml('{"flag":"yes","name":"null","port":"22","count":42,"ok":true}'::jsonb));
\copy yaml_dump_test TO 'results/yaml_dump_test.data' WITH (FORMAT text)
TRUNCATE yaml_dump_test;
\copy yaml_dump_test FROM 'results/yaml_dump_test.data' WITH (FORMAT text)
SELECT id, yaml_to_jsonb(y) FROM yaml_dump_test ORDER BY id;
DROP TABLE yaml_dump_test;

-- Delegating operators must restore fcinfo->args after swapping in the
-- embedded jsonb.  A constant yaml/jsonpath operand is loaded into fcinfo
-- once and reused across rows, so an in-place swap left un-restored is
-- re-read as a YamlValue on the next row -- a wild pointer that crashed
-- the backend.  Exercise the delegating operators over a multi-row
-- seqscan with a constant operand; the earlier single-row, direct-operator
-- tests never reused the constant, so this went uncaught.
CREATE TABLE yaml_oprestore (id int, d yaml);
INSERT INTO yaml_oprestore VALUES
    (1, 'a: {b: 1}'), (2, 'a: {b: 2}'), (3, 'b: 1'), (4, 'a: {b: 1, c: 9}');
SET enable_seqscan = on;
SET enable_bitmapscan = off;
SET enable_indexscan = off;
-- @> / <@ with a constant yaml RHS reused across rows (the crash repro)
SELECT id FROM yaml_oprestore WHERE d @> 'a: {b: 1}'::yaml ORDER BY id;
SELECT id FROM yaml_oprestore WHERE d <@ 'a: {b: 1, c: 9}'::yaml ORDER BY id;
-- key existence and jsonpath with a constant RHS reused across rows
SELECT id FROM yaml_oprestore WHERE d ? 'a' ORDER BY id;
SELECT id FROM yaml_oprestore WHERE d @@ '$.a.b == 1' ORDER BY id;
SELECT id FROM yaml_oprestore WHERE d @? '$.a.b ? (@ == 1)' ORDER BY id;
-- a constant yaml as the FIRST argument, reused across rows
SELECT count(*) FROM yaml_oprestore,
    LATERAL yaml_path_query_first('x: [1, 2, 3]'::yaml, '$.x[1]') q;
RESET enable_seqscan;
RESET enable_bitmapscan;
RESET enable_indexscan;
DROP TABLE yaml_oprestore;

-- Cleanup
DROP TABLE yaml_test;
DROP EXTENSION pgyaml;
