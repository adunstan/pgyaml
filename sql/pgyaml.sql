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
RESET enable_seqscan;
DROP TABLE yaml_gin_test;

-- Test cast to text
SELECT 'name: test'::yaml::text;

-- Test cast from text
SELECT 'value: 123'::text::yaml;

-- yaml -> text is implicit (text functions accept yaml directly)
SELECT length('name: test'::yaml);

-- yaml -> json is assignment-only: implicit use in an expression fails
\set ON_ERROR_STOP off
SELECT json_array_length('items:
  - a
  - b'::yaml);
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

-- Cleanup
DROP TABLE yaml_test;
DROP EXTENSION pgyaml;
