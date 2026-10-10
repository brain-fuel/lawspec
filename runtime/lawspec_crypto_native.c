/* OpenSSL operations not exposed by OTP 29's crypto API: compact key seeds,
 * signature contexts and deterministic known-answer tests. Ordinary random
 * encapsulation, signing, verification and AEAD use OTP directly.
 * ref:DEC-typed-core-boundary
 */
#include <erl_nif.h>
#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/err.h>
#include <openssl/params.h>
#include <openssl/core_names.h>
#include <string.h>

#if OPENSSL_VERSION_NUMBER < 0x30500000L
#error "LawSpec crypto requires OpenSSL 3.5 or newer"
#endif
#if !defined(LAWSPEC_OPENSSL_MAJOR) || OPENSSL_VERSION_MAJOR != LAWSPEC_OPENSSL_MAJOR
#error "Build LawSpec crypto with the same OpenSSL major version as Erlang/OTP"
#endif

typedef struct {
    const char *tag, *name;
    size_t seed, public_key, private_key, signature;
} Algorithm;

static const Algorithm algorithms[] = {
    {"mlkem768", "ML-KEM-768", 64, 1184, 2400, 0},
    {"mldsa65", "ML-DSA-65", 32, 1952, 4032, 3309},
    {"slh_dsa_shake_128f", "SLH-DSA-SHAKE-128f", 48, 32, 64, 17088}
};

static const Algorithm *algorithm(ErlNifEnv *env, ERL_NIF_TERM term) {
    char tag[32];
    size_t i;
    if (!enif_get_atom(env, term, tag, sizeof(tag), ERL_NIF_LATIN1)) return NULL;
    for (i = 0; i < sizeof(algorithms) / sizeof(algorithms[0]); ++i)
        if (!strcmp(tag, algorithms[i].tag)) return &algorithms[i];
    return NULL;
}

/* No key material or provider error strings enter diagnostics. OpenSSL's
 * per-thread error queue must not leak between jobs on a dirty scheduler. */
static ERL_NIF_TERM failure(ErlNifEnv *env, const char *operation) {
    ERR_clear_error();
    return enif_raise_exception(env, enif_make_tuple2(env,
        enif_make_atom(env, "lawspec_crypto_failure"), enif_make_atom(env, operation)));
}

static EVP_PKEY *import_key(const Algorithm *alg, const char *parameter,
                           const ErlNifBinary *bytes, int selection) {
    EVP_PKEY *key = NULL;
    EVP_PKEY_CTX *ctx = EVP_PKEY_CTX_new_from_name(NULL, alg->name, NULL);
    OSSL_PARAM params[] = {
        OSSL_PARAM_construct_octet_string(parameter, bytes->data, bytes->size),
        OSSL_PARAM_construct_end()
    };
    if (!ctx || EVP_PKEY_fromdata_init(ctx) <= 0
        || EVP_PKEY_fromdata(ctx, &key, selection, params) <= 0) {
        EVP_PKEY_free(key);
        key = NULL;
    }
    EVP_PKEY_CTX_free(ctx);
    return key;
}

static ERL_NIF_TERM expand(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    const Algorithm *alg;
    ErlNifBinary seed, pub = {0}, priv = {0};
    EVP_PKEY_CTX *ctx = NULL;
    EVP_PKEY *key = NULL;
    size_t written;
    int pub_allocated = 0, priv_allocated = 0, ok = 0;
    ERL_NIF_TERM result;
    if (argc != 2 || !(alg = algorithm(env, argv[0]))
        || !enif_inspect_binary(env, argv[1], &seed) || seed.size != alg->seed)
        return enif_make_badarg(env);
    ERR_clear_error();
    if (alg == &algorithms[2]) {
        /* SLH's seed parameter is used only for the NIST key-generation tests. */
        OSSL_PARAM params[] = {
            OSSL_PARAM_construct_octet_string("seed", seed.data, seed.size),
            OSSL_PARAM_construct_end()
        };
        ctx = EVP_PKEY_CTX_new_from_name(NULL, alg->name, NULL);
        if (!ctx || EVP_PKEY_keygen_init(ctx) <= 0
            || EVP_PKEY_CTX_set_params(ctx, params) <= 0
            || EVP_PKEY_generate(ctx, &key) <= 0) goto done;
    } else {
        key = import_key(alg, "seed", &seed, EVP_PKEY_KEYPAIR);
        if (!key) goto done;
    }
    if (!(pub_allocated = enif_alloc_binary(alg->public_key, &pub))
        || !(priv_allocated = enif_alloc_binary(alg->private_key, &priv))) goto done;
    if (!EVP_PKEY_get_octet_string_param(key, OSSL_PKEY_PARAM_PUB_KEY,
            pub.data, pub.size, &written) || written != pub.size
        || !EVP_PKEY_get_octet_string_param(key, OSSL_PKEY_PARAM_PRIV_KEY,
            priv.data, priv.size, &written) || written != priv.size) goto done;
    ok = 1;
done:
    EVP_PKEY_free(key);
    EVP_PKEY_CTX_free(ctx);
    if (ok) {
        result = enif_make_tuple2(env, enif_make_binary(env, &pub), enif_make_binary(env, &priv));
        ERR_clear_error();
        return result;
    }
    if (pub_allocated) enif_release_binary(&pub);
    if (priv_allocated) { OPENSSL_cleanse(priv.data, priv.size); enif_release_binary(&priv); }
    return failure(env, "expand_seed");
}

/* FIPS 203 deterministic encapsulation for known-answer tests only. */
static ERL_NIF_TERM encapsulate_test(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary pub, randomness, ciphertext = {0}, secret = {0};
    EVP_PKEY *key = NULL;
    EVP_PKEY_CTX *ctx = NULL;
    size_t ciphertext_size = 1088, secret_size = 32;
    int ciphertext_allocated = 0, secret_allocated = 0, ok = 0;
    ERL_NIF_TERM result;
    if (argc != 2 || !enif_inspect_binary(env, argv[0], &pub) || pub.size != 1184
        || !enif_inspect_binary(env, argv[1], &randomness) || randomness.size != 32)
        return enif_make_badarg(env);
    ERR_clear_error();
    OSSL_PARAM params[] = {
        OSSL_PARAM_construct_octet_string(OSSL_KEM_PARAM_IKME, randomness.data, randomness.size),
        OSSL_PARAM_construct_end()
    };
    key = import_key(&algorithms[0], OSSL_PKEY_PARAM_PUB_KEY, &pub, EVP_PKEY_PUBLIC_KEY);
    if (!key || !(ctx = EVP_PKEY_CTX_new_from_pkey(NULL, key, NULL))
        || EVP_PKEY_encapsulate_init(ctx, params) <= 0) goto done;
    if (!(ciphertext_allocated = enif_alloc_binary(ciphertext_size, &ciphertext))
        || !(secret_allocated = enif_alloc_binary(secret_size, &secret))) goto done;
    if (EVP_PKEY_encapsulate(ctx, ciphertext.data, &ciphertext_size, secret.data, &secret_size) <= 0
        || ciphertext_size != ciphertext.size || secret_size != secret.size) goto done;
    ok = 1;
done:
    EVP_PKEY_CTX_free(ctx);
    EVP_PKEY_free(key);
    if (ok) {
        result = enif_make_tuple2(env, enif_make_binary(env, &ciphertext), enif_make_binary(env, &secret));
        ERR_clear_error();
        return result;
    }
    if (ciphertext_allocated) enif_release_binary(&ciphertext);
    if (secret_allocated) { OPENSSL_cleanse(secret.data, secret.size); enif_release_binary(&secret); }
    return failure(env, "encapsulate_test");
}

static ERL_NIF_TERM sign_context(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    const Algorithm *alg;
    ErlNifBinary secret, message, context, signature = {0};
    EVP_PKEY *key = NULL;
    EVP_PKEY_CTX *ctx = NULL;
    EVP_SIGNATURE *scheme = NULL;
    int deterministic, allocated = 0, ok = 0;
    size_t length;
    ERL_NIF_TERM result;
    if (argc != 5 || !(alg = algorithm(env, argv[0])) || !alg->signature
        || !enif_inspect_binary(env, argv[1], &secret)
        || secret.size != (alg == &algorithms[1] ? alg->seed : alg->private_key)
        || !enif_inspect_binary(env, argv[2], &message)
        || !enif_inspect_binary(env, argv[3], &context) || context.size > 255)
        return enif_make_badarg(env);
    if (enif_is_identical(argv[4], enif_make_atom(env, "true"))) deterministic = 1;
    else if (enif_is_identical(argv[4], enif_make_atom(env, "false"))) deterministic = 0;
    else return enif_make_badarg(env);
    ERR_clear_error();
    OSSL_PARAM params[] = {
        OSSL_PARAM_construct_octet_string(OSSL_SIGNATURE_PARAM_CONTEXT_STRING, context.data, context.size),
        OSSL_PARAM_construct_int(OSSL_SIGNATURE_PARAM_DETERMINISTIC, &deterministic),
        OSSL_PARAM_construct_end()
    };
    key = import_key(alg, alg == &algorithms[1] ? "seed" : OSSL_PKEY_PARAM_PRIV_KEY,
        &secret, EVP_PKEY_KEYPAIR);
    if (!key || !(ctx = EVP_PKEY_CTX_new_from_pkey(NULL, key, NULL))
        || !(scheme = EVP_SIGNATURE_fetch(NULL, alg->name, NULL))
        || EVP_PKEY_sign_message_init(ctx, scheme, params) <= 0) goto done;
    length = alg->signature;
    if (!(allocated = enif_alloc_binary(length, &signature))) goto done;
    if (EVP_PKEY_sign(ctx, signature.data, &length, message.data, message.size) <= 0
        || length != signature.size) goto done;
    ok = 1;
done:
    EVP_SIGNATURE_free(scheme);
    EVP_PKEY_CTX_free(ctx);
    EVP_PKEY_free(key);
    if (ok) {
        result = enif_make_binary(env, &signature);
        ERR_clear_error();
        return result;
    }
    if (allocated) enif_release_binary(&signature);
    return failure(env, "sign_context");
}

static ERL_NIF_TERM verify_context(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    const Algorithm *alg;
    ErlNifBinary pub, message, signature, context;
    EVP_PKEY *key = NULL;
    EVP_PKEY_CTX *ctx = NULL;
    EVP_SIGNATURE *scheme = NULL;
    int verified = -1;
    if (argc != 5 || !(alg = algorithm(env, argv[0])) || !alg->signature
        || !enif_inspect_binary(env, argv[1], &pub)
        || !enif_inspect_binary(env, argv[2], &message)
        || !enif_inspect_binary(env, argv[3], &signature)
        || !enif_inspect_binary(env, argv[4], &context)) return enif_make_badarg(env);
    if (pub.size != alg->public_key || signature.size != alg->signature || context.size > 255)
        return enif_make_atom(env, "false");
    ERR_clear_error();
    OSSL_PARAM params[] = {
        OSSL_PARAM_construct_octet_string(OSSL_SIGNATURE_PARAM_CONTEXT_STRING, context.data, context.size),
        OSSL_PARAM_construct_end()
    };
    key = import_key(alg, OSSL_PKEY_PARAM_PUB_KEY, &pub, EVP_PKEY_PUBLIC_KEY);
    if (!key || !(ctx = EVP_PKEY_CTX_new_from_pkey(NULL, key, NULL))
        || !(scheme = EVP_SIGNATURE_fetch(NULL, alg->name, NULL))
        || EVP_PKEY_verify_message_init(ctx, scheme, params) <= 0) goto done;
    verified = EVP_PKEY_verify(ctx, signature.data, signature.size, message.data, message.size);
done:
    EVP_SIGNATURE_free(scheme);
    EVP_PKEY_CTX_free(ctx);
    EVP_PKEY_free(key);
    if (verified < 0) return failure(env, "verify_context");
    ERR_clear_error();
    return enif_make_atom(env, verified == 1 ? "true" : "false");
}

static int load(ErlNifEnv *env, void **private_data, ERL_NIF_TERM info) {
    unsigned int expected;
    (void)private_data;
    return !enif_get_uint(env, info, &expected) || expected != OPENSSL_VERSION_MAJOR
        || OPENSSL_version_major() != expected || OpenSSL_version_num() < 0x30500000L;
}

/* Cover restores the original Erlang module after instrumentation. The
 * bridge holds no private state or resource types across calls, so each
 * module instance can use the same library after the ordinary ABI check. */
static int upgrade(ErlNifEnv *env, void **private_data, void **old_private_data, ERL_NIF_TERM info) {
    (void)old_private_data;
    return load(env, private_data, info);
}

static ErlNifFunc functions[] = {
    {"expand", 2, expand, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"encapsulate_test", 2, encapsulate_test, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"sign_context", 5, sign_context, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"verify_context", 5, verify_context, ERL_NIF_DIRTY_JOB_CPU_BOUND}
};
ERL_NIF_INIT(lawspec_beam_crypto_native, functions, load, NULL, upgrade, NULL)
