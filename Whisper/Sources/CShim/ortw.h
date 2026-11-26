#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct OrtwSession OrtwSession;
typedef struct OrtwValue OrtwValue;

enum { ORTW_FLOAT = 1, ORTW_INT32 = 6, ORTW_INT64 = 7 };

typedef struct {
	const char *name;
	int type;
	const void *data;
	const int64_t *shape;
	int rank;
} OrtwInput;

OrtwSession *ortw_session_create(const char *model_path, int threads, char *err, size_t errlen);
void ortw_session_release(OrtwSession *s);

int ortw_run(OrtwSession *s, const OrtwInput *inputs, int ninputs, const char *const *output_names, int noutputs,
             OrtwValue **outputs, char *err, size_t errlen);

const void *ortw_value_data(OrtwValue *v);
int ortw_value_shape(OrtwValue *v, int64_t *shape, int maxrank);
void ortw_value_release(OrtwValue *v);
