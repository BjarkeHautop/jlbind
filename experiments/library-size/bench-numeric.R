# Times the numeric kernels (kernels.jl) in a library built from hellojl with
# kernels.jl appended to HelloBindings.jl, calling them directly by symbol:
#     Rscript bench-numeric.R <jlbind.so> <out.csv>
# Each time is the best of 5.
h <- dyn.load(commandArgs(TRUE)[1], local = TRUE, now = TRUE)
H <- function(f, ...) {
  .Call(
    getNativeSymbolInfo(paste0("HelloBindings_", f, "_", ...length()), h),
    ...
  )
}
best <- function(e, n = 5) min(replicate(n, system.time(eval(e))[["elapsed"]]))
set.seed(1)
x <- runif(2e7)
x2 <- runif(1e5)
invisible(H("greet", "warmup"))
r <- c(
  matmul_1000 = best(quote(H("matmul", 1000L))),
  dot_1e5_x2e4 = best(quote(H("dotsum", x2, 20000L))),
  exp_sin_2e7 = best(quote(H("mapexp", x))),
  sort_2e7 = best(quote(H("sortsum", x))),
  rk4_lorenz_5e7 = best(quote(H("lorenz", 50000000L)))
)
write.csv(
  data.frame(task = names(r), secs = r),
  commandArgs(TRUE)[2],
  row.names = FALSE
)
