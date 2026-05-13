#ifndef EMBEDDED_LLAMA_C_H
#define EMBEDDED_LLAMA_C_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct llmr_engine llmr_engine;

typedef struct llmr_message {
    const char * role;
    const char * content;
} llmr_message;

typedef struct llmr_generation_options {
    int32_t max_tokens;
    float temperature;
    int32_t top_k;
    float top_p;
    uint32_t seed;
} llmr_generation_options;

void llmr_backend_init(void);

llmr_engine * llmr_engine_create(
    const char * model_path,
    int32_t context_size,
    int32_t gpu_layers,
    char ** error_out
);

void llmr_engine_free(llmr_engine * engine);

char * llmr_generate_chat(
    llmr_engine * engine,
    const llmr_message * messages,
    size_t message_count,
    llmr_generation_options options,
    char ** error_out
);

void llmr_string_free(char * value);

#ifdef __cplusplus
}
#endif

#endif
