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

typedef struct llmr_embedding_result {
    float * values;
    int32_t count;
} llmr_embedding_result;

typedef void (*llmr_token_callback)(
    const char * bytes,
    size_t length,
    void * user_data
);

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

char * llmr_generate_chat_stream(
    llmr_engine * engine,
    const llmr_message * messages,
    size_t message_count,
    llmr_generation_options options,
    llmr_token_callback callback,
    void * user_data,
    char ** error_out
);

char * llmr_generate_completion(
    llmr_engine * engine,
    const char * prompt,
    llmr_generation_options options,
    llmr_token_callback callback,
    void * user_data,
    char ** error_out
);

llmr_embedding_result llmr_embed_text(
    const char * model_path,
    int32_t context_size,
    int32_t gpu_layers,
    const char * input,
    char ** error_out
);

void llmr_string_free(char * value);
void llmr_embedding_result_free(llmr_embedding_result result);

#ifdef __cplusplus
}
#endif

#endif
