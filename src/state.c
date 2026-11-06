/*
 * What lets a reference to a Julia object (JLBind's `RRef`) be saved. R writes an
 * external pointer as a null pointer, and only an ALTREP vector gets a say in how
 * it is written. So a reference of a type with `JLBind.r_saved_by()` holds this
 * empty vector, which on saving is written as the plain R data from the client
 * package's `.jlbind_saved_state()`, and on loading becomes that data, from which
 * JLBind rebuilds the object on first use.
 *
 * R looks the class up by name when reading a file, loading the package named
 * here, so the class must not be in the library, which may not be available. It
 * is here rather than in the clients' generated shims so that updating jlbind is
 * enough to change it.
 */

#include <R.h>
#include <Rinternals.h>
#include <R_ext/Altrep.h>
#include <R_ext/Rdynload.h>

static R_altrep_class_t state_class;

static R_xlen_t state_length(SEXP x)
{
    return 0;
}

static void *state_dataptr(SEXP x, Rboolean writable)
{
    return (void *)1;
}

/* The state is written inside a list of length one, because after unserializing
 * R replaces the attributes of the result with those of the hook (none), which
 * would drop the state's names. */
static SEXP state_serialized(SEXP x)
{
    SEXP ns = PROTECT(R_FindNamespace(R_altrep_data2(x)));
    SEXP call = PROTECT(
        Rf_lang2(Rf_install(".jlbind_saved_state"), R_altrep_data1(x)));
    SEXP state = PROTECT(Rf_eval(call, ns));
    SEXP wrapped = PROTECT(Rf_allocVector(VECSXP, 1));
    SET_VECTOR_ELT(wrapped, 0, state);
    UNPROTECT(4);
    return wrapped;
}

static SEXP state_unserialize(SEXP class, SEXP state)
{
    return state;
}

/* Called by JLBind, through R_GetCCallable(), with a new reference and the name
 * of the package it belongs to, a character vector. */
static SEXP jlbind_state_hook(SEXP ref, SEXP package)
{
    return R_new_altrep(state_class, ref, package);
}

void R_init_jlbind(DllInfo *dll)
{
    R_registerRoutines(dll, NULL, NULL, NULL, NULL);
    R_useDynamicSymbols(dll, FALSE);
    R_forceSymbols(dll, TRUE);

    state_class = R_make_altinteger_class("jlbind_state", "jlbind", dll);
    R_set_altrep_Length_method(state_class, state_length);
    R_set_altvec_Dataptr_method(state_class, state_dataptr);
    R_set_altrep_Serialized_state_method(state_class, state_serialized);
    R_set_altrep_Unserialize_method(state_class, state_unserialize);
    R_RegisterCCallable("jlbind", "jlbind_state_hook",
                        (DL_FUNC)&jlbind_state_hook);
}
