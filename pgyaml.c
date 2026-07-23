/*
 * pgyaml.c - PostgreSQL YAML data type extension
 *
 * Copyright (c) 2026, Andrew Dunstan
 *
 * Licensed under the MIT License.  See the LICENSE file for details.
 *
 * The on-disk layout of a yaml value is:
 *
 *     [varlena header][uint32 orig_len][jsonb subvarlena][orig YAML bytes]
 *
 * On input we parse the YAML with libyaml and translate it into a jsonb
 * datum; both that jsonb and the user-supplied text are stored.  Output,
 * text casts, and wire-format SEND return the original bytes.  Everything
 * else (equality, hashing, ordering, path lookup, JSON conversion) reads
 * the jsonb slice and delegates to the core jsonb machinery, so those
 * operations run without re-parsing.
 */

#include "postgres.h"
#include "fmgr.h"
#include "access/hash.h"
#include "catalog/pg_type.h"
#include "libpq/pqformat.h"
#include "access/stratnum.h"
#include "miscadmin.h"
#include "utils/builtins.h"
#include "utils/float.h"
#include "utils/fmgrprotos.h"
#include "utils/json.h"
#include "utils/jsonb.h"
#include "utils/numeric.h"
#include "utils/varlena.h"

#include <yaml.h>
#include <errno.h>
#include <limits.h>
#include <string.h>
#include <strings.h>

PG_MODULE_MAGIC;

/*
 * pgyaml supports PostgreSQL 14 through the current development branch.
 */
#if PG_VERSION_NUM < 140000
#error "pgyaml requires PostgreSQL 14 or later"
#endif

/*
 * Building a jsonb value differs across server versions.  On PostgreSQL 19
 * (development) JsonbInState became a public type in jsonb.h and
 * pushJsonbValue() takes it directly, leaving the finished value in
 * ->result.  On 14-18 the builder is driven through an opaque
 * JsonbParseState **, and pushJsonbValue() returns the finished value.
 * YamlInState + yaml_push() hide the difference: both spellings leave the
 * completed value in state->result (NULL until the outermost container
 * closes).
 */
#if PG_VERSION_NUM >= 190000
typedef JsonbInState YamlInState;
#else
typedef struct YamlInState
{
	JsonbParseState *parseState;
	JsonbValue *result;
} YamlInState;
#endif

static inline JsonbValue *
yaml_push(YamlInState *state, JsonbIteratorToken tok, JsonbValue *val)
{
#if PG_VERSION_NUM >= 190000
	pushJsonbValue(state, tok, val);
#else
	state->result = pushJsonbValue(&state->parseState, tok, val);
#endif
	return state->result;
}

/*
 * Physical layout of a yaml Datum.  Always accessed through a fully
 * detoasted pointer.
 */
typedef struct YamlValue
{
	int32		vl_len_;		/* varlena header (do not touch directly) */
	uint32		orig_len;		/* byte length of orig YAML text */
	char		data[FLEXIBLE_ARRAY_MEMBER];
	/* data holds [jsonb subvarlena][orig bytes] */
} YamlValue;

#define DatumGetYamlP(d)		((YamlValue *) PG_DETOAST_DATUM(d))
#define PG_GETARG_YAML_P(n)		DatumGetYamlP(PG_GETARG_DATUM(n))
#define YAML_HDRSIZE			(VARHDRSZ + sizeof(uint32))
#define YAML_JSONB_PTR(y)		((Jsonb *) ((y)->data))
#define YAML_JSONB_SIZE(y)		(VARSIZE(YAML_JSONB_PTR(y)))
#define YAML_ORIG_PTR(y)		((y)->data + YAML_JSONB_SIZE(y))
#define YAML_ORIG_LEN(y)		((y)->orig_len)

/* Guard against pathological nesting (including alias cycles). */
#define YAML_MAX_DEPTH			1024

/*
 * Guard against pathological anchor/alias re-expansion.  libyaml resolves
 * aliases to shared node indices at parse time (there is no alias node
 * type), so push_yaml_node sees a DAG rather than a tree: a node reachable
 * via N distinct parent paths is independently re-walked and
 * re-materialized N times.  jsonb has no aliasing of its own, so every
 * such reference must be physically duplicated in the output regardless
 * of how push_yaml_node is written; a chain of anchors each referencing
 * the previous one twice therefore produces an exponential number of
 * materialized values from a linear-sized input.  YAML_MAX_DEPTH bounds
 * chain length, not this; cap total materialized values across one
 * document instead, so pathological input fails cleanly well before it
 * can exhaust memory.
 */
#define YAML_MAX_MATERIALIZED_NODES	50000

/* Forward declarations (Postgres style). */
static bool looks_like_number(const char *str);
static bool yaml_scalar_to_jbvalue(yaml_node_t *node, JsonbValue *jbv);
static bool yaml_charge_node_budget(int64 *nodecount, bool *ok);
static void push_yaml_node(yaml_document_t *doc, yaml_node_t *node,
						   YamlInState *state, JsonbIteratorToken scalar_tok,
						   int depth, int64 *nodecount, bool *ok);
static Jsonb *yaml_text_to_jsonb(const char *input, int input_len);
static YamlValue *build_yaml_value(const char *orig, int orig_len, Jsonb *jb);
static YamlValue *jsonb_to_yaml_value(Jsonb *jb);
static int	yaml_emitter_write_handler(void *data, unsigned char *buffer,
									   size_t size);
static bool emit_jsonb_scalar(yaml_emitter_t *emitter, JsonbValue *v);
static text *jbvalue_to_text(JsonbValue *v);
static JsonbValue *yaml_jsonb_path(Jsonb *jb, const char *path);
static void yaml_arg_to_jsonb(FunctionCallInfo fcinfo, int argno);

/*---------------------------------------------------------------------
 * Scalar classification
 *---------------------------------------------------------------------*/

/*
 * Syntactic check for a YAML 1.1 decimal number.  Hex/octal/binary/Inf/NaN
 * are intentionally rejected here; they'd round-trip as strings.
 */
static bool
looks_like_number(const char *str)
{
	const char *p = str;
	bool		has_digits = false;

	if (*p == '-' || *p == '+')
		p++;
	if (*p == '\0')
		return false;

	while (*p >= '0' && *p <= '9')
	{
		has_digits = true;
		p++;
	}

	if (*p == '.')
	{
		p++;
		while (*p >= '0' && *p <= '9')
		{
			has_digits = true;
			p++;
		}
	}

	if (!has_digits)
		return false;

	if (*p == 'e' || *p == 'E')
	{
		p++;
		if (*p == '-' || *p == '+')
			p++;
		if (*p < '0' || *p > '9')
			return false;
		while (*p >= '0' && *p <= '9')
			p++;
	}

	return *p == '\0';
}

/*
 * Translate a YAML scalar node to a JsonbValue.  Quoted scalars always
 * become strings; plain scalars resolve to null/bool/number/string per
 * YAML 1.1-ish rules so that type semantics survive the round trip.
 */
static bool
yaml_scalar_to_jbvalue(yaml_node_t *node, JsonbValue *jbv)
{
	char	   *val = (char *) node->data.scalar.value;
	size_t		len = node->data.scalar.length;
	yaml_scalar_style_t style = node->data.scalar.style;

	if (style == YAML_SINGLE_QUOTED_SCALAR_STYLE ||
		style == YAML_DOUBLE_QUOTED_SCALAR_STYLE ||
		style == YAML_LITERAL_SCALAR_STYLE ||
		style == YAML_FOLDED_SCALAR_STYLE)
	{
		jbv->type = jbvString;
		jbv->val.string.val = val;
		jbv->val.string.len = (int) len;
		return true;
	}

	if (len == 0 ||
		strcmp(val, "~") == 0 ||
		strcasecmp(val, "null") == 0)
	{
		jbv->type = jbvNull;
		return true;
	}

	if (strcasecmp(val, "true") == 0 || strcasecmp(val, "yes") == 0 ||
		strcasecmp(val, "on") == 0)
	{
		jbv->type = jbvBool;
		jbv->val.boolean = true;
		return true;
	}
	if (strcasecmp(val, "false") == 0 || strcasecmp(val, "no") == 0 ||
		strcasecmp(val, "off") == 0)
	{
		jbv->type = jbvBool;
		jbv->val.boolean = false;
		return true;
	}

	if (looks_like_number(val))
	{
		Datum		d;

		d = DirectFunctionCall3(numeric_in,
								CStringGetDatum(val),
								ObjectIdGetDatum(InvalidOid),
								Int32GetDatum(-1));
		jbv->type = jbvNumeric;
		jbv->val.numeric = DatumGetNumeric(d);
		return true;
	}

	jbv->type = jbvString;
	jbv->val.string.val = val;
	jbv->val.string.len = (int) len;
	return true;
}

/*
 * Charge one unit against the total-materialized-node budget (see
 * YAML_MAX_MATERIALIZED_NODES above).  Returns false, and sets *ok to
 * false, once the budget is exhausted; the caller must bail out
 * immediately in that case.
 */
static bool
yaml_charge_node_budget(int64 *nodecount, bool *ok)
{
	if (++(*nodecount) > YAML_MAX_MATERIALIZED_NODES)
	{
		*ok = false;
		return false;
	}
	return true;
}

/*
 * Walk a YAML node subtree, pushing its contents into the jsonb build
 * state.  Scalar values are pushed with the caller-supplied token
 * (WJB_ELEM, WJB_VALUE, or WJB_KEY).  *ok is set to false on any
 * structural error.
 */
static void
push_yaml_node(yaml_document_t *doc, yaml_node_t *node,
			   YamlInState *state, JsonbIteratorToken scalar_tok,
			   int depth, int64 *nodecount, bool *ok)
{
	JsonbValue	jbv;
	yaml_node_item_t *item;
	yaml_node_pair_t *pair;
	yaml_node_t *sub;
	yaml_node_t *key_node;
	yaml_node_t *val_node;

	check_stack_depth();

	if (!*ok)
		return;
	if (depth > YAML_MAX_DEPTH)
	{
		*ok = false;
		return;
	}
	if (!yaml_charge_node_budget(nodecount, ok))
		return;

	switch (node->type)
	{
		case YAML_SCALAR_NODE:
			if (!yaml_scalar_to_jbvalue(node, &jbv))
			{
				*ok = false;
				return;
			}
			yaml_push(state, scalar_tok, &jbv);
			return;

		case YAML_SEQUENCE_NODE:
			yaml_push(state, WJB_BEGIN_ARRAY, NULL);
			for (item = node->data.sequence.items.start;
				 item < node->data.sequence.items.top && *ok;
				 item++)
			{
				sub = yaml_document_get_node(doc, *item);
				if (sub == NULL)
				{
					*ok = false;
					return;
				}
				push_yaml_node(doc, sub, state, WJB_ELEM, depth + 1,
							   nodecount, ok);
			}
			if (*ok)
				yaml_push(state, WJB_END_ARRAY, NULL);
			return;

		case YAML_MAPPING_NODE:
			yaml_push(state, WJB_BEGIN_OBJECT, NULL);
			for (pair = node->data.mapping.pairs.start;
				 pair < node->data.mapping.pairs.top && *ok;
				 pair++)
			{
				key_node = yaml_document_get_node(doc, pair->key);
				val_node = yaml_document_get_node(doc, pair->value);
				if (key_node == NULL || val_node == NULL ||
					key_node->type != YAML_SCALAR_NODE)
				{
					*ok = false;
					return;
				}
				if (!yaml_charge_node_budget(nodecount, ok))
					return;
				/* jsonb object keys are always strings */
				jbv.type = jbvString;
				jbv.val.string.val = (char *) key_node->data.scalar.value;
				jbv.val.string.len = (int) key_node->data.scalar.length;
				yaml_push(state, WJB_KEY, &jbv);
				push_yaml_node(doc, val_node, state, WJB_VALUE, depth + 1,
							   nodecount, ok);
			}
			if (*ok)
				yaml_push(state, WJB_END_OBJECT, NULL);
			return;

		default:
			*ok = false;
			return;
	}
}

/*
 * Parse a YAML text and return its jsonb representation, or NULL if the
 * input is not a single, alias-free, mapping-scalar-keyed YAML document.
 */
static Jsonb *
yaml_text_to_jsonb(const char *input, int input_len)
{
	yaml_parser_t parser;
	yaml_document_t document;
	yaml_document_t extra;
	yaml_node_t *root;
	YamlInState state = {0};
	JsonbValue	jbv;
	Jsonb	   *jb = NULL;
	bool		ok = true;
	int64		nodecount = 0;
	volatile bool document_valid = false;
	volatile bool extra_valid = false;

	if (!yaml_parser_initialize(&parser))
		return NULL;
	yaml_parser_set_input_string(&parser, (const unsigned char *) input,
								 (size_t) input_len);

	if (!yaml_parser_load(&parser, &document))
	{
		yaml_parser_delete(&parser);
		return NULL;
	}
	document_valid = true;

	/*
	 * yaml_document_t/yaml_parser_t hold libyaml's own (non-palloc'd)
	 * buffers, which an ereport(ERROR) below would leak by longjmp'ing
	 * past their _delete calls.  Guard the whole region that can raise
	 * (JsonbValueToJsonb, numeric_in via yaml_scalar_to_jbvalue, and
	 * pushJsonbValue's size-limit checks inside push_yaml_node) so both
	 * are always released.
	 */
	PG_TRY();
	{
		root = yaml_document_get_root_node(&document);
		if (root != NULL)
		{
			if (root->type == YAML_SCALAR_NODE)
			{
				if (yaml_scalar_to_jbvalue(root, &jbv))
					jb = JsonbValueToJsonb(&jbv);
			}
			else
			{
				push_yaml_node(&document, root, &state, WJB_ELEM, 0,
							   &nodecount, &ok);
				if (ok && state.result != NULL)
					jb = JsonbValueToJsonb(state.result);
			}
		}

		yaml_document_delete(&document);
		document_valid = false;

		/* Reject additional documents in the stream. */
		if (jb != NULL)
		{
			if (!yaml_parser_load(&parser, &extra))
			{
				/* Malformed content after first document — multi-doc. */
				pfree(jb);
				jb = NULL;
			}
			else
			{
				extra_valid = true;
				if (yaml_document_get_root_node(&extra) != NULL)
				{
					pfree(jb);
					jb = NULL;
				}
				yaml_document_delete(&extra);
				extra_valid = false;
			}
		}
	}
	PG_CATCH();
	{
		if (document_valid)
			yaml_document_delete(&document);
		if (extra_valid)
			yaml_document_delete(&extra);
		yaml_parser_delete(&parser);
		PG_RE_THROW();
	}
	PG_END_TRY();

	yaml_parser_delete(&parser);
	return jb;
}

/*---------------------------------------------------------------------
 * Varlena construction and accessors
 *---------------------------------------------------------------------*/

static YamlValue *
build_yaml_value(const char *orig, int orig_len, Jsonb *jb)
{
	Size		jb_size = VARSIZE(jb);
	Size		total = YAML_HDRSIZE + jb_size + (Size) orig_len;
	YamlValue  *y;

	y = (YamlValue *) palloc(total);
	SET_VARSIZE(y, total);
	y->orig_len = (uint32) orig_len;
	memcpy(y->data, jb, jb_size);
	memcpy(y->data + jb_size, orig, orig_len);
	return y;
}

/*---------------------------------------------------------------------
 * I/O
 *---------------------------------------------------------------------*/

PG_FUNCTION_INFO_V1(yaml_in);
Datum
yaml_in(PG_FUNCTION_ARGS)
{
	char	   *str = PG_GETARG_CSTRING(0);
	int			len = (int) strlen(str);
	Jsonb	   *jb;
	YamlValue  *y;

	jb = yaml_text_to_jsonb(str, len);
	if (jb == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
				 errmsg("invalid YAML input")));

	y = build_yaml_value(str, len, jb);
	pfree(jb);
	PG_RETURN_POINTER(y);
}

PG_FUNCTION_INFO_V1(yaml_out);
Datum
yaml_out(PG_FUNCTION_ARGS)
{
	YamlValue  *y = PG_GETARG_YAML_P(0);
	char	   *out;
	int			len = (int) YAML_ORIG_LEN(y);

	out = palloc(len + 1);
	memcpy(out, YAML_ORIG_PTR(y), len);
	out[len] = '\0';
	PG_RETURN_CSTRING(out);
}

PG_FUNCTION_INFO_V1(yaml_recv);
Datum
yaml_recv(PG_FUNCTION_ARGS)
{
	StringInfo	buf = (StringInfo) PG_GETARG_POINTER(0);
	char	   *str;
	int			nbytes;
	Jsonb	   *jb;
	YamlValue  *y;

	str = pq_getmsgtext(buf, buf->len - buf->cursor, &nbytes);
	jb = yaml_text_to_jsonb(str, nbytes);
	if (jb == NULL)
	{
		pfree(str);
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
				 errmsg("invalid YAML input")));
	}

	y = build_yaml_value(str, nbytes, jb);
	pfree(str);
	pfree(jb);
	PG_RETURN_POINTER(y);
}

PG_FUNCTION_INFO_V1(yaml_send);
Datum
yaml_send(PG_FUNCTION_ARGS)
{
	YamlValue  *y = PG_GETARG_YAML_P(0);
	StringInfoData buf;

	pq_begintypsend(&buf);
	pq_sendtext(&buf, YAML_ORIG_PTR(y), (int) YAML_ORIG_LEN(y));
	PG_RETURN_BYTEA_P(pq_endtypsend(&buf));
}

/*---------------------------------------------------------------------
 * Validity
 *---------------------------------------------------------------------*/

PG_FUNCTION_INFO_V1(yaml_is_valid);
Datum
yaml_is_valid(PG_FUNCTION_ARGS)
{
	text	   *input = PG_GETARG_TEXT_PP(0);
	Jsonb	   *jb;

	jb = yaml_text_to_jsonb(VARDATA_ANY(input), VARSIZE_ANY_EXHDR(input));
	if (jb == NULL)
		PG_RETURN_BOOL(false);
	pfree(jb);
	PG_RETURN_BOOL(true);
}

/*---------------------------------------------------------------------
 * yaml <-> jsonb
 *---------------------------------------------------------------------*/

PG_FUNCTION_INFO_V1(yaml_to_jsonb);
Datum
yaml_to_jsonb(PG_FUNCTION_ARGS)
{
	YamlValue  *y = PG_GETARG_YAML_P(0);
	Jsonb	   *src = YAML_JSONB_PTR(y);
	Size		sz = VARSIZE(src);
	Jsonb	   *copy = palloc(sz);

	memcpy(copy, src, sz);
	PG_RETURN_JSONB_P(copy);
}

static int
yaml_emitter_write_handler(void *data, unsigned char *buffer, size_t size)
{
	StringInfo	buf = (StringInfo) data;

	appendBinaryStringInfo(buf, (char *) buffer, size);
	return 1;
}

/*
 * Would this string, emitted as a plain (unquoted) YAML scalar, be
 * resolved to a NON-string by yaml_scalar_to_jbvalue on the way back in?
 * If so the emitter must quote it, otherwise a jsonb string like "yes" or
 * "42" would silently reparse as a boolean or number -- e.g. across a
 * dump/restore, which round-trips through the text I/O path.  This mirrors
 * the plain-scalar rules in yaml_scalar_to_jbvalue exactly.
 */
static bool
plain_would_reparse_nonstring(const char *val, int len)
{
	char	   *s;
	bool		result;

	if (len == 0)
		return true;			/* empty plain scalar -> null on reparse */

	s = pnstrdup(val, len);
	result = (strcmp(s, "~") == 0 ||
			  strcasecmp(s, "null") == 0 ||
			  strcasecmp(s, "true") == 0 ||
			  strcasecmp(s, "false") == 0 ||
			  strcasecmp(s, "yes") == 0 ||
			  strcasecmp(s, "no") == 0 ||
			  strcasecmp(s, "on") == 0 ||
			  strcasecmp(s, "off") == 0 ||
			  looks_like_number(s));
	pfree(s);
	return result;
}

/*
 * Emit a jsonb scalar value as a YAML scalar event.  A string that would
 * be unambiguous as a plain scalar uses YAML_ANY_SCALAR_STYLE (libyaml
 * picks plain or double-quoted); a string that would reparse as a
 * non-string is forced to a quoted style so its string-ness survives the
 * round trip.  Non-strings always emit plain so their type resolves
 * correctly on re-parse.
 */
static bool
emit_jsonb_scalar(yaml_emitter_t *emitter, JsonbValue *v)
{
	yaml_event_t event;
	char	   *txt;
	size_t		len;
	yaml_scalar_style_t style;
	int			plain_ok;
	int			quoted_ok;
	bool		result;

	switch (v->type)
	{
		case jbvNull:
			txt = "null";
			len = 4;
			style = YAML_PLAIN_SCALAR_STYLE;
			plain_ok = 1;
			quoted_ok = 0;
			break;
		case jbvBool:
			if (v->val.boolean)
			{
				txt = "true";
				len = 4;
			}
			else
			{
				txt = "false";
				len = 5;
			}
			style = YAML_PLAIN_SCALAR_STYLE;
			plain_ok = 1;
			quoted_ok = 0;
			break;
		case jbvNumeric:
			txt = DatumGetCString(DirectFunctionCall1(numeric_out,
													  NumericGetDatum(v->val.numeric)));
			len = strlen(txt);
			style = YAML_PLAIN_SCALAR_STYLE;
			plain_ok = 1;
			quoted_ok = 0;
			break;
		case jbvString:
			txt = v->val.string.val;
			len = (size_t) v->val.string.len;
			style = YAML_ANY_SCALAR_STYLE;
			quoted_ok = 1;
			/* Force quoting when a plain emission would change type. */
			plain_ok = plain_would_reparse_nonstring(v->val.string.val,
													 v->val.string.len) ? 0 : 1;
			break;
		default:
			return false;
	}

	if (!yaml_scalar_event_initialize(&event, NULL, NULL,
									  (yaml_char_t *) txt, (int) len,
									  plain_ok, quoted_ok, style))
		return false;
	result = yaml_emitter_emit(emitter, &event) != 0;
	return result;
}

/*
 * Iterate a jsonb and emit an equivalent YAML document text.  The jsonb
 * is cloned verbatim into the output YamlValue; only the orig text is
 * generated.
 */
static YamlValue *
jsonb_to_yaml_value(Jsonb *jb)
{
	yaml_emitter_t emitter;
	yaml_event_t event;
	StringInfoData out;
	JsonbIterator *it;
	JsonbIteratorToken tok;
	JsonbValue	v;
	bool		ok;
	YamlValue  *result;

	initStringInfo(&out);

	if (!yaml_emitter_initialize(&emitter))
	{
		pfree(out.data);
		return NULL;
	}

	/*
	 * yaml_emitter_t holds libyaml's own (non-palloc'd) buffers, which an
	 * ereport(ERROR) below would leak by longjmp'ing past
	 * yaml_emitter_delete.  numeric_out (via emit_jsonb_scalar) and
	 * enlargeStringInfo's MaxAllocSize ceiling (via the write handler,
	 * called from every yaml_emitter_emit) can both raise, so guard the
	 * whole emit loop.
	 */
	PG_TRY();
	{
		yaml_emitter_set_output(&emitter, yaml_emitter_write_handler, &out);
		yaml_emitter_set_unicode(&emitter, 1);

		ok = yaml_stream_start_event_initialize(&event, YAML_UTF8_ENCODING) &&
			yaml_emitter_emit(&emitter, &event) &&
			yaml_document_start_event_initialize(&event, NULL, NULL, NULL, 1) &&
			yaml_emitter_emit(&emitter, &event);

		it = JsonbIteratorInit(&jb->root);
		while (ok && (tok = JsonbIteratorNext(&it, &v, false)) != WJB_DONE)
		{
			switch (tok)
			{
				case WJB_BEGIN_ARRAY:
					if (v.val.array.rawScalar)
					{
						/* A root-level scalar wrapped in a pseudo-array */
						JsonbValue	scalar;

						tok = JsonbIteratorNext(&it, &scalar, false);
						Assert(tok == WJB_ELEM);
						ok = emit_jsonb_scalar(&emitter, &scalar);
						tok = JsonbIteratorNext(&it, &v, false);
						Assert(tok == WJB_END_ARRAY);
					}
					else
					{
						ok = yaml_sequence_start_event_initialize(&event, NULL,
																  NULL, 1,
																  YAML_BLOCK_SEQUENCE_STYLE) &&
							yaml_emitter_emit(&emitter, &event);
					}
					break;
				case WJB_END_ARRAY:
					ok = yaml_sequence_end_event_initialize(&event) &&
						yaml_emitter_emit(&emitter, &event);
					break;
				case WJB_BEGIN_OBJECT:
					ok = yaml_mapping_start_event_initialize(&event, NULL, NULL, 1,
															 YAML_BLOCK_MAPPING_STYLE) &&
						yaml_emitter_emit(&emitter, &event);
					break;
				case WJB_END_OBJECT:
					ok = yaml_mapping_end_event_initialize(&event) &&
						yaml_emitter_emit(&emitter, &event);
					break;
				case WJB_KEY:
				case WJB_VALUE:
				case WJB_ELEM:
					ok = emit_jsonb_scalar(&emitter, &v);
					break;
				default:
					ok = false;
					break;
			}
		}

		if (ok)
			ok = yaml_document_end_event_initialize(&event, 1) &&
				yaml_emitter_emit(&emitter, &event) &&
				yaml_stream_end_event_initialize(&event) &&
				yaml_emitter_emit(&emitter, &event);
	}
	PG_CATCH();
	{
		yaml_emitter_delete(&emitter);
		PG_RE_THROW();
	}
	PG_END_TRY();

	yaml_emitter_delete(&emitter);

	if (!ok)
	{
		pfree(out.data);
		return NULL;
	}

	/* Trim trailing newline for display consistency. */
	while (out.len > 0 && out.data[out.len - 1] == '\n')
		out.data[--out.len] = '\0';

	result = build_yaml_value(out.data, out.len, jb);
	pfree(out.data);
	return result;
}

PG_FUNCTION_INFO_V1(jsonb_to_yaml);
Datum
jsonb_to_yaml(PG_FUNCTION_ARGS)
{
	Jsonb	   *jb = PG_GETARG_JSONB_P(0);
	YamlValue  *y = jsonb_to_yaml_value(jb);

	if (y == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
				 errmsg("could not convert jsonb to YAML")));

	PG_RETURN_POINTER(y);
}

/*---------------------------------------------------------------------
 * Path extraction (via jsonb)
 *---------------------------------------------------------------------*/

/*
 * Walk a dot-separated path into a jsonb.  Numeric tokens index arrays;
 * anything else looks up an object key.  Returns NULL if the path is
 * not present or crosses a scalar.  Raises an error if the path string
 * itself is malformed (an empty segment): that is a caller/query bug
 * detectable from the path alone, independent of the data being
 * queried, so it gets a hard error rather than being silently folded
 * into "not found" the way a data-dependent traversal miss is.
 */
static JsonbValue *
yaml_jsonb_path(Jsonb *jb, const char *path)
{
	JsonbContainer *container;
	JsonbValue *jbv = NULL;
	JsonbValue	key;
	char	   *path_copy;
	char	   *token;
	char	   *saveptr;
	char	   *endptr;
	long		index;

	if (path == NULL || *path == '\0')
		return NULL;

	if (path[0] == '.' || path[strlen(path) - 1] == '.' ||
		strstr(path, "..") != NULL)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
				 errmsg("invalid yaml path \"%s\": empty path segment",
						path)));

	container = &jb->root;
	path_copy = pstrdup(path);
	token = strtok_r(path_copy, ".", &saveptr);

	while (token != NULL)
	{
		if (JsonContainerIsArray(container) && !JsonContainerIsScalar(container))
		{
			const char *p;
			bool		all_digits = true;

			for (p = token; *p != '\0'; p++)
			{
				if (*p < '0' || *p > '9')
				{
					all_digits = false;
					break;
				}
			}

			if (!all_digits)
			{
				pfree(path_copy);
				return NULL;
			}

			errno = 0;
			index = strtol(token, &endptr, 10);
			if (*endptr != '\0' || errno == ERANGE ||
				index < 0 || index > UINT_MAX)
			{
				pfree(path_copy);
				return NULL;
			}
			jbv = getIthJsonbValueFromContainer(container, (uint32) index);
		}
		else if (JsonContainerIsObject(container))
		{
			key.type = jbvString;
			key.val.string.val = token;
			key.val.string.len = (int) strlen(token);
			jbv = findJsonbValueFromContainer(container, JB_FOBJECT, &key);
		}
		else
		{
			pfree(path_copy);
			return NULL;
		}

		if (jbv == NULL)
		{
			pfree(path_copy);
			return NULL;
		}

		token = strtok_r(NULL, ".", &saveptr);
		if (token != NULL)
		{
			if (jbv->type != jbvBinary)
			{
				pfree(path_copy);
				return NULL;
			}
			container = jbv->val.binary.data;
		}
	}

	pfree(path_copy);
	return jbv;
}

static text *
jbvalue_to_text(JsonbValue *v)
{
	char	   *str;
	StringInfoData buf;
	text	   *result;

	switch (v->type)
	{
		case jbvNull:
			return NULL;
		case jbvString:
			return cstring_to_text_with_len(v->val.string.val,
											v->val.string.len);
		case jbvNumeric:
			str = DatumGetCString(DirectFunctionCall1(numeric_out,
													  NumericGetDatum(v->val.numeric)));
			return cstring_to_text(str);
		case jbvBool:
			return cstring_to_text(v->val.boolean ? "true" : "false");
		case jbvBinary:
			initStringInfo(&buf);
			JsonbToCString(&buf, v->val.binary.data, v->val.binary.len);
			result = cstring_to_text_with_len(buf.data, buf.len);
			pfree(buf.data);
			return result;
		default:
			return NULL;
	}
}

PG_FUNCTION_INFO_V1(yaml_get);
Datum
yaml_get(PG_FUNCTION_ARGS)
{
	YamlValue  *y = PG_GETARG_YAML_P(0);
	text	   *path = PG_GETARG_TEXT_PP(1);
	char	   *path_str = text_to_cstring(path);
	JsonbValue *v;
	text	   *result;

	v = yaml_jsonb_path(YAML_JSONB_PTR(y), path_str);
	pfree(path_str);
	if (v == NULL)
		PG_RETURN_NULL();

	result = jbvalue_to_text(v);
	if (result == NULL)
		PG_RETURN_NULL();
	PG_RETURN_TEXT_P(result);
}

PG_FUNCTION_INFO_V1(yaml_get_int);
Datum
yaml_get_int(PG_FUNCTION_ARGS)
{
	YamlValue  *y = PG_GETARG_YAML_P(0);
	text	   *path = PG_GETARG_TEXT_PP(1);
	char	   *path_str = text_to_cstring(path);
	JsonbValue *v;
	int32		intval;

	v = yaml_jsonb_path(YAML_JSONB_PTR(y), path_str);
	pfree(path_str);
	if (v == NULL)
		PG_RETURN_NULL();

	if (v->type == jbvNumeric)
		intval = DatumGetInt32(DirectFunctionCall1(numeric_int4,
												   NumericGetDatum(v->val.numeric)));
	else if (v->type == jbvString)
	{
		char	   *s = pnstrdup(v->val.string.val, v->val.string.len);

		intval = pg_strtoint32(s);
		pfree(s);
	}
	else
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
				 errmsg("yaml value at path is not coercible to integer")));

	PG_RETURN_INT32(intval);
}

PG_FUNCTION_INFO_V1(yaml_get_float);
Datum
yaml_get_float(PG_FUNCTION_ARGS)
{
	YamlValue  *y = PG_GETARG_YAML_P(0);
	text	   *path = PG_GETARG_TEXT_PP(1);
	char	   *path_str = text_to_cstring(path);
	JsonbValue *v;
	float8		fval;

	v = yaml_jsonb_path(YAML_JSONB_PTR(y), path_str);
	pfree(path_str);
	if (v == NULL)
		PG_RETURN_NULL();

	if (v->type == jbvNumeric)
		fval = DatumGetFloat8(DirectFunctionCall1(numeric_float8,
												  NumericGetDatum(v->val.numeric)));
	else if (v->type == jbvString)
	{
		char	   *s = pnstrdup(v->val.string.val, v->val.string.len);

#if PG_VERSION_NUM >= 160000
		fval = float8in_internal(s, NULL, "float8", s, NULL);
#else
		fval = float8in_internal(s, NULL, "float8", s);
#endif
		pfree(s);
	}
	else
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
				 errmsg("yaml value at path is not coercible to float8")));

	PG_RETURN_FLOAT8(fval);
}

PG_FUNCTION_INFO_V1(yaml_get_bool);
Datum
yaml_get_bool(PG_FUNCTION_ARGS)
{
	YamlValue  *y = PG_GETARG_YAML_P(0);
	text	   *path = PG_GETARG_TEXT_PP(1);
	char	   *path_str = text_to_cstring(path);
	JsonbValue *v;

	v = yaml_jsonb_path(YAML_JSONB_PTR(y), path_str);
	pfree(path_str);
	if (v == NULL)
		PG_RETURN_NULL();

	if (v->type == jbvBool)
		PG_RETURN_BOOL(v->val.boolean);

	ereport(ERROR,
			(errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
			 errmsg("yaml value at path is not a boolean")));
}

PG_FUNCTION_INFO_V1(yaml_typeof);
Datum
yaml_typeof(PG_FUNCTION_ARGS)
{
	YamlValue  *y = PG_GETARG_YAML_P(0);
	text	   *path = PG_GETARG_TEXT_PP(1);
	char	   *path_str = text_to_cstring(path);
	JsonbValue *v;
	const char *name;

	if (*path_str == '\0')
	{
		/* Describe the root */
		JsonbContainer *c = &YAML_JSONB_PTR(y)->root;

		if (JsonContainerIsScalar(c))
			name = "scalar";
		else if (JsonContainerIsArray(c))
			name = "sequence";
		else if (JsonContainerIsObject(c))
			name = "mapping";
		else
			name = NULL;

		pfree(path_str);

		if (name == NULL)
			PG_RETURN_NULL();
		PG_RETURN_TEXT_P(cstring_to_text(name));
	}

	v = yaml_jsonb_path(YAML_JSONB_PTR(y), path_str);
	pfree(path_str);
	if (v == NULL)
		PG_RETURN_NULL();

	switch (v->type)
	{
		case jbvNull:
		case jbvString:
		case jbvNumeric:
		case jbvBool:
			name = "scalar";
			break;
		case jbvBinary:
			if (JsonContainerIsArray(v->val.binary.data))
				name = "sequence";
			else if (JsonContainerIsObject(v->val.binary.data))
				name = "mapping";
			else
				name = NULL;
			break;
		default:
			name = NULL;
	}
	if (name == NULL)
		PG_RETURN_NULL();
	PG_RETURN_TEXT_P(cstring_to_text(name));
}

/*---------------------------------------------------------------------
 * Comparison and hashing (delegate to jsonb)
 *---------------------------------------------------------------------*/

static int
yaml_cmp_internal(YamlValue *a, YamlValue *b)
{
	return compareJsonbContainers(&YAML_JSONB_PTR(a)->root,
								  &YAML_JSONB_PTR(b)->root);
}

PG_FUNCTION_INFO_V1(yaml_eq);
Datum
yaml_eq(PG_FUNCTION_ARGS)
{
	YamlValue  *a = PG_GETARG_YAML_P(0);
	YamlValue  *b = PG_GETARG_YAML_P(1);

	PG_RETURN_BOOL(yaml_cmp_internal(a, b) == 0);
}

PG_FUNCTION_INFO_V1(yaml_ne);
Datum
yaml_ne(PG_FUNCTION_ARGS)
{
	YamlValue  *a = PG_GETARG_YAML_P(0);
	YamlValue  *b = PG_GETARG_YAML_P(1);

	PG_RETURN_BOOL(yaml_cmp_internal(a, b) != 0);
}

PG_FUNCTION_INFO_V1(yaml_lt);
Datum
yaml_lt(PG_FUNCTION_ARGS)
{
	YamlValue  *a = PG_GETARG_YAML_P(0);
	YamlValue  *b = PG_GETARG_YAML_P(1);

	PG_RETURN_BOOL(yaml_cmp_internal(a, b) < 0);
}

PG_FUNCTION_INFO_V1(yaml_le);
Datum
yaml_le(PG_FUNCTION_ARGS)
{
	YamlValue  *a = PG_GETARG_YAML_P(0);
	YamlValue  *b = PG_GETARG_YAML_P(1);

	PG_RETURN_BOOL(yaml_cmp_internal(a, b) <= 0);
}

PG_FUNCTION_INFO_V1(yaml_gt);
Datum
yaml_gt(PG_FUNCTION_ARGS)
{
	YamlValue  *a = PG_GETARG_YAML_P(0);
	YamlValue  *b = PG_GETARG_YAML_P(1);

	PG_RETURN_BOOL(yaml_cmp_internal(a, b) > 0);
}

PG_FUNCTION_INFO_V1(yaml_ge);
Datum
yaml_ge(PG_FUNCTION_ARGS)
{
	YamlValue  *a = PG_GETARG_YAML_P(0);
	YamlValue  *b = PG_GETARG_YAML_P(1);

	PG_RETURN_BOOL(yaml_cmp_internal(a, b) >= 0);
}

PG_FUNCTION_INFO_V1(yaml_cmp);
Datum
yaml_cmp(PG_FUNCTION_ARGS)
{
	YamlValue  *a = PG_GETARG_YAML_P(0);
	YamlValue  *b = PG_GETARG_YAML_P(1);

	PG_RETURN_INT32(yaml_cmp_internal(a, b));
}

PG_FUNCTION_INFO_V1(yaml_hash);
Datum
yaml_hash(PG_FUNCTION_ARGS)
{
	YamlValue  *y = PG_GETARG_YAML_P(0);
	Jsonb	   *jb = YAML_JSONB_PTR(y);

	/*
	 * Delegate to the core jsonb hash function to get semantic hashing that
	 * matches equality.
	 */
	PG_RETURN_DATUM(DirectFunctionCall1(jsonb_hash, JsonbPGetDatum(jb)));
}

/*---------------------------------------------------------------------
 * Text cast
 *---------------------------------------------------------------------*/

PG_FUNCTION_INFO_V1(yaml_to_text);
Datum
yaml_to_text(PG_FUNCTION_ARGS)
{
	YamlValue  *y = PG_GETARG_YAML_P(0);

	PG_RETURN_TEXT_P(cstring_to_text_with_len(YAML_ORIG_PTR(y),
											  YAML_ORIG_LEN(y)));
}

/*---------------------------------------------------------------------
 * Jsonb-delegating containment, existence, and jsonpath operators.
 *
 * Each wrapper extracts the embedded jsonb from the yaml Datum, copies
 * it into its own palloc'd buffer (freeing any detoasted YamlValue
 * copy), installs the jsonb pointer into fcinfo->args, and invokes the
 * corresponding core jsonb function.
 *---------------------------------------------------------------------*/

static void
yaml_arg_to_jsonb(FunctionCallInfo fcinfo, int argno)
{
	Datum		orig = fcinfo->args[argno].value;
	YamlValue  *y = (YamlValue *) PG_DETOAST_DATUM(orig);
	Jsonb	   *src = YAML_JSONB_PTR(y);
	Size		sz = VARSIZE(src);
	Jsonb	   *copy = palloc(sz);

	memcpy(copy, src, sz);
	if ((Pointer) y != DatumGetPointer(orig))
		pfree(y);
	fcinfo->args[argno].value = JsonbPGetDatum(copy);
}

PG_FUNCTION_INFO_V1(yaml_contains);
Datum
yaml_contains(PG_FUNCTION_ARGS)
{
	yaml_arg_to_jsonb(fcinfo, 0);
	yaml_arg_to_jsonb(fcinfo, 1);
	return jsonb_contains(fcinfo);
}

PG_FUNCTION_INFO_V1(yaml_contained);
Datum
yaml_contained(PG_FUNCTION_ARGS)
{
	yaml_arg_to_jsonb(fcinfo, 0);
	yaml_arg_to_jsonb(fcinfo, 1);
	return jsonb_contained(fcinfo);
}

PG_FUNCTION_INFO_V1(yaml_exists);
Datum
yaml_exists(PG_FUNCTION_ARGS)
{
	yaml_arg_to_jsonb(fcinfo, 0);
	return jsonb_exists(fcinfo);
}

PG_FUNCTION_INFO_V1(yaml_exists_any);
Datum
yaml_exists_any(PG_FUNCTION_ARGS)
{
	yaml_arg_to_jsonb(fcinfo, 0);
	return jsonb_exists_any(fcinfo);
}

PG_FUNCTION_INFO_V1(yaml_exists_all);
Datum
yaml_exists_all(PG_FUNCTION_ARGS)
{
	yaml_arg_to_jsonb(fcinfo, 0);
	return jsonb_exists_all(fcinfo);
}

PG_FUNCTION_INFO_V1(yaml_path_exists_opr);
Datum
yaml_path_exists_opr(PG_FUNCTION_ARGS)
{
	yaml_arg_to_jsonb(fcinfo, 0);
	return jsonb_path_exists_opr(fcinfo);
}

PG_FUNCTION_INFO_V1(yaml_path_match_opr);
Datum
yaml_path_match_opr(PG_FUNCTION_ARGS)
{
	yaml_arg_to_jsonb(fcinfo, 0);
	return jsonb_path_match_opr(fcinfo);
}

/*---------------------------------------------------------------------
 * GIN support.  For extract_value the indexed arg is the yaml in slot
 * 0; for extract_query the query arg is in slot 0; for
 * (tri)consistent the query arg is in slot 2.  Only the @>
 * (containment) strategy passes a yaml query — the ?, ?|, ?&, @?, @@
 * strategies pass text / text[] / jsonpath and go through unchanged.
 *---------------------------------------------------------------------*/

PG_FUNCTION_INFO_V1(gin_extract_yaml);
Datum
gin_extract_yaml(PG_FUNCTION_ARGS)
{
	yaml_arg_to_jsonb(fcinfo, 0);
	return gin_extract_jsonb(fcinfo);
}

PG_FUNCTION_INFO_V1(gin_extract_yaml_query);
Datum
gin_extract_yaml_query(PG_FUNCTION_ARGS)
{
	StrategyNumber strategy = PG_GETARG_UINT16(2);

	if (strategy == JsonbContainsStrategyNumber)
		yaml_arg_to_jsonb(fcinfo, 0);
	return gin_extract_jsonb_query(fcinfo);
}

PG_FUNCTION_INFO_V1(gin_consistent_yaml);
Datum
gin_consistent_yaml(PG_FUNCTION_ARGS)
{
	StrategyNumber strategy = PG_GETARG_UINT16(1);

	if (strategy == JsonbContainsStrategyNumber)
		yaml_arg_to_jsonb(fcinfo, 2);
	return gin_consistent_jsonb(fcinfo);
}

PG_FUNCTION_INFO_V1(gin_triconsistent_yaml);
Datum
gin_triconsistent_yaml(PG_FUNCTION_ARGS)
{
	StrategyNumber strategy = PG_GETARG_UINT16(1);

	if (strategy == JsonbContainsStrategyNumber)
		yaml_arg_to_jsonb(fcinfo, 2);
	return gin_triconsistent_jsonb(fcinfo);
}

PG_FUNCTION_INFO_V1(gin_extract_yaml_path);
Datum
gin_extract_yaml_path(PG_FUNCTION_ARGS)
{
	yaml_arg_to_jsonb(fcinfo, 0);
	return gin_extract_jsonb_path(fcinfo);
}

PG_FUNCTION_INFO_V1(gin_extract_yaml_query_path);
Datum
gin_extract_yaml_query_path(PG_FUNCTION_ARGS)
{
	StrategyNumber strategy = PG_GETARG_UINT16(2);

	if (strategy == JsonbContainsStrategyNumber)
		yaml_arg_to_jsonb(fcinfo, 0);
	return gin_extract_jsonb_query_path(fcinfo);
}

PG_FUNCTION_INFO_V1(gin_consistent_yaml_path);
Datum
gin_consistent_yaml_path(PG_FUNCTION_ARGS)
{
	StrategyNumber strategy = PG_GETARG_UINT16(1);

	if (strategy == JsonbContainsStrategyNumber)
		yaml_arg_to_jsonb(fcinfo, 2);
	return gin_consistent_jsonb_path(fcinfo);
}

PG_FUNCTION_INFO_V1(gin_triconsistent_yaml_path);
Datum
gin_triconsistent_yaml_path(PG_FUNCTION_ARGS)
{
	StrategyNumber strategy = PG_GETARG_UINT16(1);

	if (strategy == JsonbContainsStrategyNumber)
		yaml_arg_to_jsonb(fcinfo, 2);
	return gin_triconsistent_jsonb_path(fcinfo);
}

/*---------------------------------------------------------------------
 * jsonpath query functions.  Signature matches jsonb: target, path,
 * vars DEFAULT '{}', silent DEFAULT false.  Results come back as jsonb
 * (callers can cast to yaml if they want a YAML-shaped value).
 *---------------------------------------------------------------------*/

PG_FUNCTION_INFO_V1(yaml_path_query);
Datum
yaml_path_query(PG_FUNCTION_ARGS)
{
	Datum		orig = fcinfo->args[0].value;
	Datum		result;

	/*
	 * Value-per-call SRFs reuse fcinfo across iterations, so we must
	 * restore args[0] before returning — otherwise the next call's
	 * yaml_arg_to_jsonb would try to treat our already-swapped jsonb
	 * pointer as a YamlValue.
	 */
	yaml_arg_to_jsonb(fcinfo, 0);
	result = jsonb_path_query(fcinfo);
	fcinfo->args[0].value = orig;
	return result;
}

PG_FUNCTION_INFO_V1(yaml_path_query_array);
Datum
yaml_path_query_array(PG_FUNCTION_ARGS)
{
	yaml_arg_to_jsonb(fcinfo, 0);
	return jsonb_path_query_array(fcinfo);
}

PG_FUNCTION_INFO_V1(yaml_path_query_first);
Datum
yaml_path_query_first(PG_FUNCTION_ARGS)
{
	yaml_arg_to_jsonb(fcinfo, 0);
	return jsonb_path_query_first(fcinfo);
}
