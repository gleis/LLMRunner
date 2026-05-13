#include "EmbeddedLlamaC.h"

#include "llama.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct llmr_engine {
    struct llama_model * model;
    struct llama_context * context;
    const struct llama_vocab * vocab;
};

struct string_builder {
    char * data;
    size_t length;
    size_t capacity;
};

static void set_error(char ** error_out, const char * format, ...) {
    if (error_out == NULL) {
        return;
    }

    va_list args;
    va_start(args, format);
    int length = vsnprintf(NULL, 0, format, args);
    va_end(args);

    if (length < 0) {
        *error_out = NULL;
        return;
    }

    char * message = (char *) malloc((size_t) length + 1);
    if (message == NULL) {
        *error_out = NULL;
        return;
    }

    va_start(args, format);
    vsnprintf(message, (size_t) length + 1, format, args);
    va_end(args);
    *error_out = message;
}

static bool sb_init(struct string_builder * builder) {
    builder->capacity = 1024;
    builder->length = 0;
    builder->data = (char *) malloc(builder->capacity);
    if (builder->data == NULL) {
        return false;
    }

    builder->data[0] = '\0';
    return true;
}

static bool sb_append(struct string_builder * builder, const char * bytes, size_t length) {
    if (length == 0) {
        return true;
    }

    size_t needed = builder->length + length + 1;
    if (needed > builder->capacity) {
        size_t next_capacity = builder->capacity;
        while (next_capacity < needed) {
            next_capacity *= 2;
        }

        char * next = (char *) realloc(builder->data, next_capacity);
        if (next == NULL) {
            return false;
        }

        builder->data = next;
        builder->capacity = next_capacity;
    }

    memcpy(builder->data + builder->length, bytes, length);
    builder->length += length;
    builder->data[builder->length] = '\0';
    return true;
}

static char * apply_chat_template(
    llmr_engine * engine,
    const llmr_message * messages,
    size_t message_count,
    char ** error_out
) {
    struct llama_chat_message * chat = (struct llama_chat_message *) calloc(
        message_count,
        sizeof(struct llama_chat_message)
    );

    if (chat == NULL) {
        set_error(error_out, "Could not allocate chat messages.");
        return NULL;
    }

    for (size_t i = 0; i < message_count; i++) {
        chat[i].role = messages[i].role;
        chat[i].content = messages[i].content;
    }

    const char * template = llama_model_chat_template(engine->model, NULL);
    int32_t capacity = 4096;
    char * buffer = NULL;

    for (;;) {
        buffer = (char *) malloc((size_t) capacity);
        if (buffer == NULL) {
            free(chat);
            set_error(error_out, "Could not allocate prompt buffer.");
            return NULL;
        }

        int32_t written = llama_chat_apply_template(template, chat, message_count, true, buffer, capacity);
        if (written < 0) {
            free(buffer);
            free(chat);
            set_error(error_out, "Could not apply the model chat template.");
            return NULL;
        }

        if (written < capacity) {
            buffer[written] = '\0';
            free(chat);
            return buffer;
        }

        free(buffer);
        capacity = written + 1;
    }
}

static void llmr_silent_log_callback(enum ggml_log_level level, const char * text, void * user_data) {
    (void) level;
    (void) text;
    (void) user_data;
}

static int32_t tokenize_prompt(
    const struct llama_vocab * vocab,
    const char * prompt,
    llama_token ** tokens_out
) {
    int32_t prompt_length = (int32_t) strlen(prompt);
    int32_t capacity = prompt_length + 32;
    if (capacity < 128) {
        capacity = 128;
    }

    llama_token * tokens = (llama_token *) malloc((size_t) capacity * sizeof(llama_token));
    if (tokens == NULL) {
        return 0;
    }

    int32_t count = llama_tokenize(vocab, prompt, prompt_length, tokens, capacity, true, true);
    if (count < 0) {
        capacity = -count;
        llama_token * resized = (llama_token *) realloc(tokens, (size_t) capacity * sizeof(llama_token));
        if (resized == NULL) {
            free(tokens);
            return 0;
        }

        tokens = resized;
        count = llama_tokenize(vocab, prompt, prompt_length, tokens, capacity, true, true);
    }

    if (count <= 0) {
        free(tokens);
        return 0;
    }

    *tokens_out = tokens;
    return count;
}

static struct llama_sampler * make_sampler(llmr_generation_options options) {
    if (options.temperature <= 0.0f) {
        return llama_sampler_init_greedy();
    }

    struct llama_sampler_chain_params params = llama_sampler_chain_default_params();
    struct llama_sampler * sampler = llama_sampler_chain_init(params);
    llama_sampler_chain_add(sampler, llama_sampler_init_top_k(options.top_k > 0 ? options.top_k : 40));
    llama_sampler_chain_add(sampler, llama_sampler_init_top_p(options.top_p > 0.0f ? options.top_p : 0.95f, 1));
    llama_sampler_chain_add(sampler, llama_sampler_init_temp(options.temperature));
    llama_sampler_chain_add(sampler, llama_sampler_init_dist(options.seed));
    return sampler;
}

static bool append_token_piece(
    llmr_engine * engine,
    llama_token token,
    struct string_builder * output,
    llmr_token_callback callback,
    void * user_data,
    char ** error_out
) {
    char piece[256];
    int32_t piece_length = llama_token_to_piece(engine->vocab, token, piece, sizeof(piece), 0, false);

    if (piece_length < 0) {
        int32_t needed = -piece_length;
        char * large_piece = (char *) malloc((size_t) needed);
        if (large_piece == NULL) {
            set_error(error_out, "Could not allocate token piece.");
            return false;
        }

        piece_length = llama_token_to_piece(engine->vocab, token, large_piece, needed, 0, false);
        if (piece_length > 0) {
            if (!sb_append(output, large_piece, (size_t) piece_length)) {
                free(large_piece);
                set_error(error_out, "Could not append token piece.");
                return false;
            }
            if (callback != NULL) {
                callback(large_piece, (size_t) piece_length, user_data);
            }
        }
        free(large_piece);
        return true;
    }

    if (piece_length > 0) {
        if (!sb_append(output, piece, (size_t) piece_length)) {
            set_error(error_out, "Could not append token piece.");
            return false;
        }
        if (callback != NULL) {
            callback(piece, (size_t) piece_length, user_data);
        }
    }

    return true;
}

static char * generate_from_prompt(
    llmr_engine * engine,
    const char * prompt,
    llmr_generation_options options,
    llmr_token_callback callback,
    void * user_data,
    char ** error_out
) {
    if (engine == NULL || engine->context == NULL || engine->vocab == NULL) {
        set_error(error_out, "Embedded engine is not initialized.");
        return NULL;
    }

    llama_token * prompt_tokens = NULL;
    int32_t prompt_count = tokenize_prompt(engine->vocab, prompt, &prompt_tokens);

    if (prompt_count <= 0) {
        set_error(error_out, "Could not tokenize prompt.");
        return NULL;
    }

    llama_memory_clear(llama_get_memory(engine->context), true);

    struct llama_batch prompt_batch = llama_batch_get_one(prompt_tokens, prompt_count);
    int32_t decode_result = llama_decode(engine->context, prompt_batch);
    free(prompt_tokens);

    if (decode_result != 0) {
        set_error(error_out, "Prompt decode failed with code %d.", decode_result);
        return NULL;
    }

    struct llama_sampler * sampler = make_sampler(options);
    if (sampler == NULL) {
        set_error(error_out, "Could not create sampler.");
        return NULL;
    }

    struct string_builder output;
    if (!sb_init(&output)) {
        llama_sampler_free(sampler);
        set_error(error_out, "Could not allocate output buffer.");
        return NULL;
    }

    int32_t max_tokens = options.max_tokens > 0 ? options.max_tokens : 256;

    for (int32_t i = 0; i < max_tokens; i++) {
        llama_token token = llama_sampler_sample(sampler, engine->context, -1);
        llama_sampler_accept(sampler, token);

        if (llama_vocab_is_eog(engine->vocab, token)) {
            break;
        }

        if (!append_token_piece(engine, token, &output, callback, user_data, error_out)) {
            free(output.data);
            llama_sampler_free(sampler);
            return NULL;
        }

        struct llama_batch next_batch = llama_batch_get_one(&token, 1);
        decode_result = llama_decode(engine->context, next_batch);
        if (decode_result != 0) {
            free(output.data);
            llama_sampler_free(sampler);
            set_error(error_out, "Token decode failed with code %d.", decode_result);
            return NULL;
        }
    }

    llama_sampler_free(sampler);
    return output.data;
}

void llmr_backend_init(void) {
    static bool initialized = false;
    if (!initialized) {
        ggml_log_set(llmr_silent_log_callback, NULL);
        llama_log_set(llmr_silent_log_callback, NULL);
        llama_backend_init();
        initialized = true;
    }
}

llmr_engine * llmr_engine_create(
    const char * model_path,
    int32_t context_size,
    int32_t gpu_layers,
    char ** error_out
) {
    llmr_backend_init();

    struct llama_model_params model_params = llama_model_default_params();
    model_params.n_gpu_layers = gpu_layers;

    struct llama_model * model = llama_model_load_from_file(model_path, model_params);
    if (model == NULL) {
        set_error(error_out, "Could not load model at %s.", model_path);
        return NULL;
    }

    struct llama_context_params context_params = llama_context_default_params();
    context_params.n_ctx = context_size > 0 ? (uint32_t) context_size : 8192;
    context_params.n_batch = 512;
    context_params.n_seq_max = 1;

    struct llama_context * context = llama_init_from_model(model, context_params);
    if (context == NULL) {
        llama_model_free(model);
        set_error(error_out, "Could not create llama context for %s.", model_path);
        return NULL;
    }

    llmr_engine * engine = (llmr_engine *) calloc(1, sizeof(llmr_engine));
    if (engine == NULL) {
        llama_free(context);
        llama_model_free(model);
        set_error(error_out, "Could not allocate embedded engine.");
        return NULL;
    }

    engine->model = model;
    engine->context = context;
    engine->vocab = llama_model_get_vocab(model);
    return engine;
}

void llmr_engine_free(llmr_engine * engine) {
    if (engine == NULL) {
        return;
    }

    if (engine->context != NULL) {
        llama_free(engine->context);
    }

    if (engine->model != NULL) {
        llama_model_free(engine->model);
    }

    free(engine);
}

char * llmr_generate_chat(
    llmr_engine * engine,
    const llmr_message * messages,
    size_t message_count,
    llmr_generation_options options,
    char ** error_out
) {
    char * prompt = apply_chat_template(engine, messages, message_count, error_out);
    if (prompt == NULL) {
        return NULL;
    }

    char * output = generate_from_prompt(engine, prompt, options, NULL, NULL, error_out);
    free(prompt);
    return output;
}

char * llmr_generate_chat_stream(
    llmr_engine * engine,
    const llmr_message * messages,
    size_t message_count,
    llmr_generation_options options,
    llmr_token_callback callback,
    void * user_data,
    char ** error_out
) {
    char * prompt = apply_chat_template(engine, messages, message_count, error_out);
    if (prompt == NULL) {
        return NULL;
    }

    char * output = generate_from_prompt(engine, prompt, options, callback, user_data, error_out);
    free(prompt);
    return output;
}

char * llmr_generate_completion(
    llmr_engine * engine,
    const char * prompt,
    llmr_generation_options options,
    llmr_token_callback callback,
    void * user_data,
    char ** error_out
) {
    return generate_from_prompt(engine, prompt, options, callback, user_data, error_out);
}

llmr_embedding_result llmr_embed_text(
    const char * model_path,
    int32_t context_size,
    int32_t gpu_layers,
    const char * input,
    char ** error_out
) {
    llmr_embedding_result empty = { NULL, 0 };
    llmr_backend_init();

    struct llama_model_params model_params = llama_model_default_params();
    model_params.n_gpu_layers = gpu_layers;

    struct llama_model * model = llama_model_load_from_file(model_path, model_params);
    if (model == NULL) {
        set_error(error_out, "Could not load embedding model at %s.", model_path);
        return empty;
    }

    struct llama_context_params context_params = llama_context_default_params();
    context_params.n_ctx = context_size > 0 ? (uint32_t) context_size : 8192;
    context_params.n_batch = 512;
    context_params.n_seq_max = 1;
    context_params.embeddings = true;
    context_params.pooling_type = LLAMA_POOLING_TYPE_MEAN;

    struct llama_context * context = llama_init_from_model(model, context_params);
    if (context == NULL) {
        llama_model_free(model);
        set_error(error_out, "Could not create embedding context for %s.", model_path);
        return empty;
    }

    const struct llama_vocab * vocab = llama_model_get_vocab(model);
    llama_token * tokens = NULL;
    int32_t token_count = tokenize_prompt(vocab, input, &tokens);
    if (token_count <= 0) {
        llama_free(context);
        llama_model_free(model);
        set_error(error_out, "Could not tokenize embedding input.");
        return empty;
    }

    struct llama_batch batch = llama_batch_get_one(tokens, token_count);
    int32_t decode_result = llama_decode(context, batch);
    free(tokens);

    if (decode_result != 0) {
        llama_free(context);
        llama_model_free(model);
        set_error(error_out, "Embedding decode failed with code %d.", decode_result);
        return empty;
    }

    float * source = llama_get_embeddings_seq(context, 0);
    if (source == NULL) {
        source = llama_get_embeddings_ith(context, -1);
    }

    if (source == NULL) {
        llama_free(context);
        llama_model_free(model);
        set_error(error_out, "Model did not return embeddings.");
        return empty;
    }

    int32_t count = llama_model_n_embd(model);
    float * values = (float *) malloc((size_t) count * sizeof(float));
    if (values == NULL) {
        llama_free(context);
        llama_model_free(model);
        set_error(error_out, "Could not allocate embedding output.");
        return empty;
    }

    memcpy(values, source, (size_t) count * sizeof(float));
    llama_free(context);
    llama_model_free(model);

    llmr_embedding_result result = { values, count };
    return result;
}

void llmr_string_free(char * value) {
    free(value);
}

void llmr_embedding_result_free(llmr_embedding_result result) {
    free(result.values);
}
