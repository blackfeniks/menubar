#include "ortw.h"

#include <onnxruntime_c_api.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct OrtwSession {
	OrtSession *session;
};

static const OrtApi *api;
static OrtEnv *env;
static OrtMemoryInfo *cpu_info;
static OrtAllocator *allocator;
static pthread_once_t once = PTHREAD_ONCE_INIT;
static char init_error[256];

static void set_err(char *err, size_t errlen, OrtStatus *st) {
	if (err && errlen) snprintf(err, errlen, "%s", st ? api->GetErrorMessage(st) : "unknown error");
	if (st) api->ReleaseStatus(st);
}

static void init_once(void) {
	api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
	if (!api) {
		snprintf(init_error, sizeof init_error, "ONNX Runtime API v%d unavailable", ORT_API_VERSION);
		return;
	}
	OrtStatus *st = api->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "whisper", &env);
	if (!st) st = api->DisableTelemetryEvents(env);
	if (!st) st = api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &cpu_info);
	if (!st) st = api->GetAllocatorWithDefaultOptions(&allocator);
	if (st) {
		snprintf(init_error, sizeof init_error, "%s", api->GetErrorMessage(st));
		api->ReleaseStatus(st);
		env = NULL;
	}
}

OrtwSession *ortw_session_create(const char *model_path, int threads, char *err, size_t errlen) {
	pthread_once(&once, init_once);
	if (!env) {
		if (err && errlen) snprintf(err, errlen, "%s", init_error);
		return NULL;
	}
	OrtSessionOptions *opts = NULL;
	OrtSession *session = NULL;
	OrtStatus *st = api->CreateSessionOptions(&opts);
	if (!st) st = api->SetSessionGraphOptimizationLevel(opts, ORT_ENABLE_ALL);
	if (!st && threads > 0) st = api->SetIntraOpNumThreads(opts, threads);
	if (!st) st = api->SetInterOpNumThreads(opts, 1);
	if (!st) st = api->AddSessionConfigEntry(opts, "session.intra_op.allow_spinning", "0");
	if (!st) st = api->AddSessionConfigEntry(opts, "session.inter_op.allow_spinning", "0");
	if (!st) st = api->CreateSession(env, model_path, opts, &session);
	if (opts) api->ReleaseSessionOptions(opts);
	if (st) {
		set_err(err, errlen, st);
		return NULL;
	}
	OrtwSession *s = calloc(1, sizeof *s);
	s->session = session;
	return s;
}

void ortw_session_release(OrtwSession *s) {
	if (!s) return;
	api->ReleaseSession(s->session);
	free(s);
}

static size_t elem_size(int type) {
	switch (type) {
	case ORTW_FLOAT: return 4;
	case ORTW_INT32: return 4;
	case ORTW_INT64: return 8;
	default: return 0;
	}
}

int ortw_run(OrtwSession *s, const OrtwInput *inputs, int ninputs, const char *const *output_names, int noutputs,
             OrtwValue **outputs, char *err, size_t errlen) {
	OrtValue *in_vals[16] = {0};
	const char *in_names[16];
	OrtStatus *st = NULL;
	if (ninputs > 16 || noutputs > 16) {
		snprintf(err, errlen, "too many inputs or outputs");
		return -1;
	}
	for (int i = 0; i < ninputs && !st; i++) {
		in_names[i] = inputs[i].name;
		size_t count = 1;
		for (int d = 0; d < inputs[i].rank; d++) count *= (size_t)inputs[i].shape[d];
		st = api->CreateTensorAsOrtValue(allocator, inputs[i].shape, (size_t)inputs[i].rank,
		                                 (ONNXTensorElementDataType)inputs[i].type, &in_vals[i]);
		if (!st && count) {
			void *dst = NULL;
			st = api->GetTensorMutableData(in_vals[i], &dst);
			if (!st) memcpy(dst, inputs[i].data, count * elem_size(inputs[i].type));
		}
	}
	OrtValue *out_vals[16] = {0};
	if (!st) st = api->Run(s->session, NULL, in_names, (const OrtValue *const *)in_vals, (size_t)ninputs, output_names,
	                       (size_t)noutputs, out_vals);
	for (int i = 0; i < ninputs; i++)
		if (in_vals[i]) api->ReleaseValue(in_vals[i]);
	if (st) {
		set_err(err, errlen, st);
		for (int i = 0; i < noutputs; i++)
			if (out_vals[i]) api->ReleaseValue(out_vals[i]);
		return -1;
	}
	for (int i = 0; i < noutputs; i++) outputs[i] = (OrtwValue *)out_vals[i];
	return 0;
}

const void *ortw_value_data(OrtwValue *v) {
	void *p = NULL;
	OrtStatus *st = api->GetTensorMutableData((OrtValue *)v, &p);
	if (st) {
		api->ReleaseStatus(st);
		return NULL;
	}
	return p;
}

int ortw_value_shape(OrtwValue *v, int64_t *shape, int maxrank) {
	OrtTensorTypeAndShapeInfo *info = NULL;
	OrtStatus *st = api->GetTensorTypeAndShape((OrtValue *)v, &info);
	size_t rank = 0;
	if (!st) st = api->GetDimensionsCount(info, &rank);
	if (!st && (int)rank <= maxrank) st = api->GetDimensions(info, shape, rank);
	if (info) api->ReleaseTensorTypeAndShapeInfo(info);
	if (st) {
		api->ReleaseStatus(st);
		return -1;
	}
	return (int)rank;
}

void ortw_value_release(OrtwValue *v) {
	if (v) api->ReleaseValue((OrtValue *)v);
}
