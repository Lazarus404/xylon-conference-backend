/* MCU mix NIF: sum + soft-knee + mix-minus-self (dirty CPU).
 *
 * Copyright (c) 2013 - 2026 Jahred Love and Xirsys LLC
 * Apache License Version 2.0
 */

#include <erl_nif.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define SOFT_KNEE 30000
#define INT16_MIN_V (-32768)
#define INT16_MAX_V 32767
#define MAX_ACTIVE 64
#define MAX_SAMPLES 4800

typedef struct {
  ERL_NIF_TERM id;
  const int16_t *pcm;
  unsigned samples;
} active_t;

static int16_t soft_then_hard(int32_t s) {
  int32_t abs_s = s < 0 ? -s : s;
  int32_t limited;

  if (abs_s <= SOFT_KNEE) {
    limited = abs_s;
  } else {
    limited = SOFT_KNEE + (abs_s - SOFT_KNEE) / 2;
  }

  if (s < 0) {
    limited = -limited;
  }

  if (limited < INT16_MIN_V) {
    return (int16_t)INT16_MIN_V;
  }
  if (limited > INT16_MAX_V) {
    return (int16_t)INT16_MAX_V;
  }
  return (int16_t)limited;
}

static ERL_NIF_TERM encode_pcm(ErlNifEnv *env, const int32_t *sums, unsigned samples) {
  ERL_NIF_TERM bin_term;
  unsigned char *out = enif_make_new_binary(env, samples * 2, &bin_term);
  unsigned i;

  for (i = 0; i < samples; i++) {
    int16_t v = soft_then_hard(sums[i]);
    out[i * 2] = (unsigned char)(v & 0xff);
    out[i * 2 + 1] = (unsigned char)((v >> 8) & 0xff);
  }

  return bin_term;
}

static int find_active(const active_t *act, unsigned n, ERL_NIF_TERM id) {
  unsigned i;
  for (i = 0; i < n; i++) {
    if (enif_is_identical(act[i].id, id)) {
      return (int)i;
    }
  }
  return -1;
}

/* mix_tick(ActiveList, AllIds, Samples)
 * ActiveList = [{Id, PcmBin}, ...]
 * AllIds = [Id, ...]
 * Returns {:ok, {FullBin, [{Id, MinusBin}, ...]}} | {:error, reason}
 */
static ERL_NIF_TERM mix_tick_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  unsigned samples;
  active_t active[MAX_ACTIVE];
  unsigned n_active = 0;
  ERL_NIF_TERM list;
  ERL_NIF_TERM head;
  ERL_NIF_TERM tail;
  int32_t *full_sums = NULL;
  ERL_NIF_TERM full_bin;
  ERL_NIF_TERM minus_list;
  ERL_NIF_TERM atom_ok;
  ERL_NIF_TERM atom_error;
  ERL_NIF_TERM atom_bad;
  unsigned i;
  unsigned j;

  (void)argc;

  if (!enif_get_uint(env, argv[2], &samples) || samples == 0 || samples > MAX_SAMPLES) {
    return enif_make_badarg(env);
  }

  list = argv[0];
  while (enif_get_list_cell(env, list, &head, &tail)) {
    const ERL_NIF_TERM *tuple;
    int arity;
    ErlNifBinary bin;

    if (n_active >= MAX_ACTIVE) {
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "too_many_active"));
    }

    if (!enif_get_tuple(env, head, &arity, &tuple) || arity != 2) {
      return enif_make_badarg(env);
    }

    if (!enif_inspect_binary(env, tuple[1], &bin) || bin.size != samples * 2) {
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "bad_pcm"));
    }

    active[n_active].id = tuple[0];
    active[n_active].pcm = (const int16_t *)bin.data;
    active[n_active].samples = samples;
    n_active++;
    list = tail;
  }

  if (!enif_is_empty_list(env, list)) {
    return enif_make_badarg(env);
  }

  full_sums = (int32_t *)enif_alloc(sizeof(int32_t) * samples);
  if (!full_sums) {
    return enif_make_tuple2(env, enif_make_atom(env, "error"),
                            enif_make_atom(env, "enomem"));
  }

  memset(full_sums, 0, sizeof(int32_t) * samples);

  for (i = 0; i < n_active; i++) {
    for (j = 0; j < samples; j++) {
      /* PCM16LE */
      const unsigned char *p = (const unsigned char *)active[i].pcm;
      int16_t s = (int16_t)(p[j * 2] | (p[j * 2 + 1] << 8));
      full_sums[j] += (int32_t)s;
    }
  }

  full_bin = encode_pcm(env, full_sums, samples);

  minus_list = enif_make_list(env, 0);
  list = argv[1];

  /* Build list in reverse then reverse -- push cons onto front */
  {
    ERL_NIF_TERM ids[MAX_ACTIVE * 2];
    unsigned n_ids = 0;
    ERL_NIF_TERM id_list = argv[1];

    while (enif_get_list_cell(env, id_list, &head, &tail)) {
      if (n_ids >= MAX_ACTIVE * 2) {
        enif_free(full_sums);
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
                                enif_make_atom(env, "too_many_ids"));
      }
      ids[n_ids++] = head;
      id_list = tail;
    }

    if (!enif_is_empty_list(env, id_list)) {
      enif_free(full_sums);
      return enif_make_badarg(env);
    }

    for (i = 0; i < n_ids; i++) {
      ERL_NIF_TERM id = ids[i];
      int idx = find_active(active, n_active, id);
      int32_t *tmp = (int32_t *)enif_alloc(sizeof(int32_t) * samples);
      ERL_NIF_TERM minus_bin;
      ERL_NIF_TERM pair;

      if (!tmp) {
        enif_free(full_sums);
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
                                enif_make_atom(env, "enomem"));
      }

      memcpy(tmp, full_sums, sizeof(int32_t) * samples);

      if (idx >= 0) {
        const unsigned char *p = (const unsigned char *)active[idx].pcm;
        for (j = 0; j < samples; j++) {
          int16_t s = (int16_t)(p[j * 2] | (p[j * 2 + 1] << 8));
          tmp[j] -= (int32_t)s;
        }
      }

      minus_bin = encode_pcm(env, tmp, samples);
      enif_free(tmp);
      pair = enif_make_tuple2(env, id, minus_bin);
      minus_list = enif_make_list_cell(env, pair, minus_list);
    }

    /* Reverse minus_list to match input id order */
    {
      ERL_NIF_TERM rev = enif_make_list(env, 0);
      ERL_NIF_TERM cur = minus_list;
      while (enif_get_list_cell(env, cur, &head, &tail)) {
        rev = enif_make_list_cell(env, head, rev);
        cur = tail;
      }
      minus_list = rev;
    }
  }

  enif_free(full_sums);

  atom_ok = enif_make_atom(env, "ok");
  (void)atom_error;
  (void)atom_bad;

  return enif_make_tuple2(
      env, atom_ok, enif_make_tuple2(env, full_bin, minus_list));
}

static ErlNifFunc nif_funcs[] = {
    {"mix_tick", 3, mix_tick_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND}};

ERL_NIF_INIT(Elixir.Xylon.Conference.Mcu.Native, nif_funcs, NULL, NULL, NULL, NULL)
