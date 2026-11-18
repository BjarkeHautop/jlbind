/*
 * How a client calls the compiled Julia library. A client's generated R
 * wrappers call
 *
 *     .External(.jlbind$.call, .jlbind$<name>, <arguments>)
 *
 * where `.jlbind$.call` is jlbind_call() below and `.jlbind$<name>` is an
 * entry made by jlbind_entries() when jlbind::bind_client() binds the client:
 * an external pointer to the library's `<module>_<name>`, or a null one while
 * the client is not bound. Its tag is the client's name, for the error when it
 * is not bound.
 *
 * Every entrypoint (see `@rcall` in JLBind) has the signature
 * `SEXP f(SEXP *args, int n)`, and checks `n` itself.
 */

#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>

typedef SEXP (*jlbind_fn)(SEXP *, int);

/* Entries for the client `package` from `addresses`, a list of the library
 * symbols' addresses (external pointers, as from getNativeSymbolInfo()), each
 * NULL for a null entry, for a client that is not bound. The symbols are
 * looked up in R, through the library's DLLInfo, since every library loaded
 * has the DLL name `jlbind`, under which R_FindSymbol() searches only one. */
SEXP jlbind_entries(SEXP addresses, SEXP package)
{
    R_xlen_t n = XLENGTH(addresses);
    SEXP out = PROTECT(Rf_allocVector(VECSXP, n));
    for (R_xlen_t i = 0; i < n; i++) {
        SEXP a = VECTOR_ELT(addresses, i);
        DL_FUNC f = Rf_isNull(a) ? NULL : R_ExternalPtrAddrFn(a);
        SET_VECTOR_ELT(out, i, R_MakeExternalPtrFn(f, package, R_NilValue));
    }
    UNPROTECT(1);
    return out;
}

/* Sets the number of Julia threads with a library's
 * jlbind_set_julia_threads() (set_threads.c in JLBind) at `address`, before
 * its Julia starts: 0 if it did, else nonzero. */
SEXP jlbind_set_threads(SEXP address, SEXP threads)
{
    typedef void (*set_fn)(int *, int *);
    set_fn f = (set_fn)R_ExternalPtrAddrFn(address);
    int n = Rf_asInteger(threads), status = 0;
    f(&n, &status);
    return Rf_ScalarInteger(status);
}

/* Arguments up to this many are passed in an array on the stack, more in one
 * that R frees when the call returns. */
#define STACK_ARGS 16

/* .External(jlbind_call, entry, ...): calls the entry with the arguments. The
 * library never raises an R error itself, since R's error longjmp would unwind
 * through Julia frames. It returns a failure as a character vector of class
 * `jlbind_error`, which is raised here, after the Julia call has returned. */
SEXP jlbind_call(SEXP args)
{
    args = CDR(args);
    SEXP entry = CAR(args);
    if (TYPEOF(entry) != EXTPTRSXP || TYPEOF(R_ExternalPtrTag(entry)) != STRSXP)
        Rf_errorcall(R_NilValue, "Not a jlbind entrypoint.");
    jlbind_fn fn = (jlbind_fn)R_ExternalPtrAddrFn(entry);
    if (fn == NULL) {
        const char *package = CHAR(STRING_ELT(R_ExternalPtrTag(entry), 0));
        Rf_errorcall(R_NilValue,
                     "The compiled Julia library of %s is not available; run "
                     "jlbind::check_bound(\"%s\") for details.",
                     package, package);
    }
    args = CDR(args);
    int n = Rf_length(args);
    SEXP stack[STACK_ARGS];
    SEXP *a = n <= STACK_ARGS ? stack : (SEXP *)R_alloc(n, sizeof(SEXP));
    for (int i = 0; i < n; i++, args = CDR(args))
        a[i] = CAR(args);
    SEXP res = fn(a, n);
    if (TYPEOF(res) == STRSXP && Rf_inherits(res, "jlbind_error"))
        Rf_errorcall(R_NilValue, "%s", Rf_translateChar(STRING_ELT(res, 0)));
    return res;
}
