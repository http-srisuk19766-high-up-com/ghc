#include "Rts.h"

struct BacktraceFrame_ {
    uintptr_t pc;
    const char *function;
    const char *filename;
    int lineno;
    int colno;
};

typedef struct BacktraceFrame_ BacktraceFrame;

// Default chunk capacity
#define BACKTRACE_CHUNK_SZ 256

struct BacktraceChunk_ {
    uint16_t n_frames;                         // number of frames in this chunk
    struct BacktraceChunk_ *next;              // the chunk following this one
    BacktraceFrame frames[BACKTRACE_CHUNK_SZ]; // the actual stack frames
};

typedef struct BacktraceChunk_ BacktraceChunk;

struct Backtrace_ {
    StgWord n_frames;             // Total number of frames in the backtrace
    BacktraceChunk frames;        // The first chunk of frames
};

typedef struct Backtrace_ Backtrace;

void backtrace_free(Backtrace *bt);
void print_backtrace(FILE *file, Backtrace *bt);

struct LibDwSession_;
typedef struct LibDwSession_ LibDwSession;

void libdw_free(LibDwSession *session);
LibDwSession *libdw_init(void);
Backtrace *libdw_get_backtrace(LibDwSession *session);
Backtrace *libdw_get_stg_backtrace(LibDwSession *session, StgTSO *tso);
