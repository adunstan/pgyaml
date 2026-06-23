# pgyaml

A PostgreSQL extension providing a `yaml` data type backed by parsed
jsonb. YAML input is parsed once with libyaml and stored alongside the
original text; comparison, hashing, path lookup, containment,
existence, jsonpath, and JSON conversion all delegate to the core
jsonb machinery without re-parsing. GIN indexing is supported natively
through opclasses that mirror `jsonb_ops` and `jsonb_path_ops`.

## Use cases

The type earns its keep when the source is human-authored YAML that
users expect to round-trip with their own formatting and comments, but
ops still needs to query or index structured fields. A few fits:

- **Kubernetes / Helm manifests.** Store Deployment, Service, and
  Ingress YAML as-written; find workloads by image, label, or
  resource request with containment or jsonpath queries, and keep
  the original document (comments included) to hand back to kubectl.
- **CI/CD pipeline catalog.** Collect GitHub Actions, GitLab CI, or
  CircleCI configs across repos; answer "which workflows call action
  X", "which pipelines run on `main`", or "which jobs request a
  self-hosted runner" without reparsing YAML on every query.
- **Tenant / application configuration.** Ship configs that product
  and support teams edit by hand, index the structured fields for
  fast lookup, and preserve comments so the stored artifact still
  reads like the file that was committed. (See the Examples below.)
- **Ansible / SaltStack inventories and playbooks.** Query hosts by
  group, tasks by module, or roles by variable without shelling out
  to a YAML parser inside a function.
- **OpenAPI / AsyncAPI specs.** Keep a searchable catalog of API
  specs; locate endpoints by operationId, method, or response schema
  using jsonpath, with a GIN index backing the lookups.
- **Policy documents.** Compliance, RBAC, or OPA-adjacent rules
  authored in YAML, where auditors want the original text and
  reviewers want to query which rules touch a given resource.
- **Feature-flag / rollout manifests.** YAML files checked into a
  config repo and mirrored into the database so runtime code can
  look up flag state via a GIN-indexed containment query.

For pure machine-generated payloads with no expectation that a human
will ever read them, plain `jsonb` is usually the better fit —
`yaml_to_jsonb` / `jsonb_to_yaml` let you interoperate when needed.

## Installation

Requires libyaml (with headers) and a PostgreSQL server built from
source (for `pg_config` and the extension build infrastructure).
Install libyaml via your platform's usual mechanism.

```sh
make PG_CONFIG=/path/to/pg_config
make PG_CONFIG=/path/to/pg_config install
```

Then in psql:

```sql
CREATE EXTENSION pgyaml;
```

## Type

### `yaml`

A validated YAML document. Stored as a varlena with layout
`[header][orig_len][jsonb][orig bytes]`:

- The **orig bytes** are returned verbatim by `yaml_out` and the
  `yaml::text` cast, preserving the user's formatting and key order.
- The **jsonb** slice is the decomposed form; all structural operations
  read it, so path lookup and comparison never re-run libyaml.

Only a single YAML document is accepted; streams with `---` separators
are rejected. Non-scalar mapping keys are rejected (jsonb requires
scalar keys). Anchors and aliases are resolved by libyaml at parse
time and the referenced content is duplicated into each use site in
the jsonb, so graph sharing is not preserved. Cyclic aliases are
rejected by a 1024-level depth guard.

## Functions

### I/O and conversion

| Function | Returns | Notes |
|---|---|---|
| `yaml_in(cstring)` | `yaml` | Parses and validates; raises on any rejected construct. |
| `yaml_out(yaml)` | `cstring` | Returns the original bytes. |
| `yaml_to_text(yaml)` | `text` | Same as the implicit `::text` cast. |
| `yaml_to_jsonb(yaml)` | `jsonb` | Exposes the parsed form for queries with `->`, `->>`, `#>`, GIN, etc. |
| `jsonb_to_yaml(jsonb)` | `yaml` | Emits a YAML block-style document via libyaml. |
| `yaml_to_json(yaml)` | `json` | Convenience: `yaml_to_jsonb($1)::json`. |
| `json_to_yaml(json)` | `yaml` | Convenience: `jsonb_to_yaml($1::jsonb)`. |

### Path extraction

Path syntax is dot-separated. Numeric tokens index sequences; anything
else looks up a mapping key.

| Function | Returns | Behavior |
|---|---|---|
| `yaml_get(yaml, text)` | `text` | Scalar → its text form; mapping/sequence → JSON text; missing → NULL. |
| `yaml_get_int(yaml, text)` | `integer` | Numeric scalars are converted; string scalars are parsed as integers (and raise on bad input); other types raise. |
| `yaml_get_float(yaml, text)` | `float8` | Numeric scalars are converted; string scalars are parsed as `float8` (and raise on bad input); other types raise. |
| `yaml_get_bool(yaml, text)` | `boolean` | Requires a boolean scalar; errors otherwise. |
| `yaml_typeof(yaml, text)` | `text` | `'scalar'`, `'sequence'`, `'mapping'`, or NULL. Empty path describes the root. |

### Jsonpath queries

Signatures mirror `jsonb_path_query*`. Results come back as `jsonb`
so they compose with the rest of the jsonb toolbox; cast through
`jsonb_to_yaml()` if you need a YAML-shaped value.

| Function | Returns |
|---|---|
| `yaml_path_query(target yaml, path jsonpath, vars jsonb DEFAULT '{}', silent boolean DEFAULT false)` | `SETOF jsonb` |
| `yaml_path_query_array(target yaml, path jsonpath, vars jsonb DEFAULT '{}', silent boolean DEFAULT false)` | `jsonb` |
| `yaml_path_query_first(target yaml, path jsonpath, vars jsonb DEFAULT '{}', silent boolean DEFAULT false)` | `jsonb` |

For the boolean-only jsonpath tests (`@?` and `@@`), use the
operators in the table below — those are GIN-indexable, these
functions are not.

### Validation

| Function | Returns | Behavior |
|---|---|---|
| `yaml_is_valid(text)` | `boolean` | True iff `yaml_in` would accept the input. |

## Operators and indexing

### Equality and ordering

`=`, `<>`, `<`, `<=`, `>`, `>=` delegate to `compareJsonbContainers`, so
equality is *semantic*: values that parse to the same jsonb tree compare
equal even if their YAML source differs in key order, whitespace, or
flow-vs-block style. The default `yaml_ops` (btree) and `yaml_hash_ops`
(hash) opclasses inherit this behavior.

Ordering (`<`, `>=`, etc.) follows jsonb's rules — type class, then
length, then contents. It provides a deterministic sort but has no
YAML-specific meaning.

### Containment, existence, and jsonpath

The operator surface mirrors jsonb exactly; each delegates to the
corresponding core jsonb operator against the stored jsonb slice.

| Operator | Right-hand type | Meaning |
|---|---|---|
| `yaml @> yaml` | `yaml` | Left-hand contains right-hand (recursive subset). |
| `yaml <@ yaml` | `yaml` | Left-hand is contained in right-hand. |
| `yaml ? text` | `text` | Key/element exists at the top level. |
| `yaml ?\| text[]` | `text[]` | Any of the listed keys exists. |
| `yaml ?& text[]` | `text[]` | All of the listed keys exist. |
| `yaml @? jsonpath` | `jsonpath` | The path yields at least one match. |
| `yaml @@ jsonpath` | `jsonpath` | The path predicate is true. |

### GIN

Two GIN opclasses, structurally identical to jsonb's:

- **`yaml_ops`** (default) — indexes every key and every scalar value.
  Supports `@>`, `?`, `?|`, `?&`, `@?`, `@@`. Larger but flexible.
- **`yaml_path_ops`** — indexes hashes of path+value pairs. Supports
  only `@>`, `@?`, `@@`, but is smaller and faster for containment
  queries.

```sql
CREATE INDEX ON t USING gin (col);                   -- yaml_ops
CREATE INDEX ON t USING gin (col yaml_path_ops);     -- yaml_path_ops
```

No cast through jsonb is needed at either index-definition or
query-time.

## Casts

| From | To | Implicitness | Notes |
|---|---|---|---|
| `yaml` | `text` | **implicit** | Returns the original bytes. |
| `text` | `yaml` | assignment | Requires `::yaml` in expressions. |
| `yaml` | `jsonb` | assignment | The decomposed form. |
| `jsonb` | `yaml` | assignment | Emits block-style YAML. |
| `yaml` | `json` | assignment | Via jsonb. |
| `json` | `yaml` | assignment | Via jsonb. |

Only `yaml → text` is implicit. `yaml → jsonb` and `yaml → json` are
assignment-only so the type doesn't have multiple competing implicit
conversions (which would produce "function is not unique" errors in
function resolution).

## Scalar type resolution

When YAML is parsed to jsonb, plain (unquoted) scalars are resolved to:

- `null`, `~`, empty → `null`
- `true`, `yes`, `on` (case-insensitive) → `true`
- `false`, `no`, `off` (case-insensitive) → `false`
- integer or decimal number → `numeric`
- anything else → string

Quoted scalars (single, double, literal `|`, folded `>`) always become
strings. This means `'42'::yaml` (plain) round-trips as a number while
`'"42"'::yaml` (quoted) round-trips as a string:

```sql
SELECT yaml_to_jsonb('n: 42'::yaml);     -- {"n": 42}
SELECT yaml_to_jsonb('n: "42"'::yaml);   -- {"n": "42"}
SELECT 'n: 42'::yaml = 'n: "42"'::yaml;  -- f
```

Hex (`0x10`), octal (`0o17`), binary (`0b101`), `.inf`, and `.nan` are
**not** recognized as numbers; they round-trip as strings.

## Limitations

Deliberate non-goals:

- **Comments** survive in the stored orig bytes (so `yaml_out` and
  `::text` return them verbatim), but they are absent from the jsonb
  side and are therefore invisible to comparison, path lookup, and
  `jsonb_to_yaml` output.
- **Anchors and aliases** (`&x` / `*x`) are accepted but flattened:
  libyaml resolves each alias to the anchored node, and we deep-copy
  that content into the jsonb at every reference, so shared structure
  is lost. Cyclic aliases hit a 1024-level depth guard and are
  rejected (a DoS-avoidance measure since jsonb can't represent
  cycles).
- **Multi-document streams** (`---`) are rejected. Split them in the
  application if you need per-document rows.
- **Duplicate mapping keys** collapse per jsonb's last-wins rule.
- **Non-scalar mapping keys** (YAML allows them) are rejected.
- **Tags** (`!!str`, `!Foo`) are ignored — scalar style is the only
  type-hint we honor.
- **Original key order** is preserved in `yaml_out` via the stored orig
  bytes, but is lost when you cast through jsonb (jsonb sorts keys
  internally). `jsonb_to_yaml` emits keys in jsonb's canonical order,
  not any original order.
- **Byte-identical round-trip** is not guaranteed across a
  `yaml → jsonb → yaml` cycle: `jsonb_to_yaml` emits a freshly
  generated block-style document.

Comments and original formatting do round-trip through `yaml_out` /
`::text`, but they don't participate in any structural operation. If
you need multi-document streams, or anchor/alias sharing or comments
preserved across a pass through jsonb, you want a `text` column (with
`yaml_is_valid()` as a check constraint), not this type.

## Examples

```sql
-- Store and query configuration
CREATE TABLE tenant_config (
    tenant_id int PRIMARY KEY,
    config    yaml
);

INSERT INTO tenant_config VALUES
    (1, 'replicas: 3
features:
  - billing
  - analytics
quota:
  storage: 100Gi
  requests: 10000'::yaml);

-- Text-level access preserves the user's formatting
SELECT config FROM tenant_config WHERE tenant_id = 1;

-- Path extraction via the jsonb side (no libyaml at query time)
SELECT yaml_get_int(config, 'replicas'),
       yaml_get(config, 'features.0')
FROM tenant_config
WHERE tenant_id = 1;

-- Jsonb operators work directly after casting
SELECT config::jsonb -> 'quota' ->> 'storage'
FROM tenant_config
WHERE tenant_id = 1;

-- Containment: scalar, sequence-subset, and nested-mapping-subset
SELECT tenant_id FROM tenant_config
 WHERE config @> 'replicas: 3'::yaml;
SELECT tenant_id FROM tenant_config
 WHERE config @> 'features: [billing]'::yaml;
SELECT tenant_id FROM tenant_config
 WHERE config @> 'quota: {storage: 100Gi}'::yaml;

-- Key existence
SELECT tenant_id FROM tenant_config WHERE config ? 'quota';
SELECT tenant_id FROM tenant_config
 WHERE config ?& ARRAY['replicas','quota'];

-- Jsonpath predicates (boolean-returning, GIN-indexable)
SELECT tenant_id FROM tenant_config
 WHERE config @@ '$.replicas > 2';
SELECT tenant_id FROM tenant_config
 WHERE config @? '$.features[*] ? (@ == "billing")';

-- Jsonpath extraction (returns jsonb)
SELECT yaml_path_query_array(config, '$.features[*]')
  FROM tenant_config WHERE tenant_id = 1;
SELECT yaml_path_query_first(config, '$.quota.storage')
  FROM tenant_config WHERE tenant_id = 1;

-- GIN index supports containment, existence, and jsonpath predicates
CREATE INDEX ON tenant_config USING gin (config);

-- Semantic equality: formatting differences don't matter
SELECT 'a: 1
b: 2'::yaml = 'b: 2
a: 1'::yaml;                          -- t

SELECT '{a: 1, b: 2}'::yaml
     = 'a: 1
b: 2'::yaml;                          -- t
```

## License

MIT License. See [LICENSE](LICENSE).
